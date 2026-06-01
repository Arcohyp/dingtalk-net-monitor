<#
网络监控程序 v2.0.0 - PowerShell 版本
支持多类型探测(Ping/DNS/HTTP/TCP)、网卡感知、Web面板、结构化日志、并行探测、异步通知

配置文件: config.json (首次启动时会自动引导创建)
用法: powershell -ExecutionPolicy Bypass -File NetworkMonitor.ps1 [参数]
#>

param(
    [Parameter(Position=0)]
    [string]$Report = "",
    [string]$ConfigFile = "config.json",
    [switch]$Silent,
    [switch]$NoSound,
    [int]$PingInterval = 0,
    [switch]$Help
)

$script:Version = "2.0.0"

# 确保工作目录为脚本所在目录
$script:BaseDir = Split-Path $PSCommandPath -Parent
Set-Location $script:BaseDir

# 设置控制台编码为 UTF-8，避免中文乱码
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

# ========== 进程单例锁 ==========

$script:mutex = $null
try {
    $script:mutex = New-Object System.Threading.Mutex($true, "Global\NetworkMonitorDaemon", [ref]$null)
    if (-not $script:mutex.WaitOne(0, $false)) {
        Write-Host "错误: 网络监控程序已经在运行中（检测到另一个实例占用全局锁）" -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "警告: 无法创建全局互斥锁，继续运行（可能与其他实例冲突）: $_" -ForegroundColor Yellow
}

# ========== 正常退出标志 ==========

$script:NormalExit = $false
$script:StopRequested = $false

function Set-NormalExitFlag {
    $flagFile = Join-Path $script:BaseDir ".nm_normal_exit"
    try {
        [System.IO.File]::WriteAllText($flagFile, "1", [System.Text.Encoding]::UTF8)
    } catch {}
}

# 注册 Ctrl+C 处理程序，确保守护进程能识别正常退出
$cancelEvent = {
    Set-NormalExitFlag
    $script:StopRequested = $true
    $script:NormalExit = $true
}
[Console]::add_CancelKeyPress($cancelEvent)

# ========== 基础工具 ==========

function Invoke-SafeAction {
    param([scriptblock]$Action, [string]$ErrorMessage, [bool]$ContinueOnError = $false)
    try {
        & $Action
    } catch {
        if ($ErrorMessage) { Write-Host "错误: $ErrorMessage - $_" -ForegroundColor Red }
        else { Write-Host "错误: $_" -ForegroundColor Red }
        if (-not $ContinueOnError) { exit 1 }
    }
}

if ($Help) {
    Write-Host ""
    Write-Host "网络监控程序 v$script:Version - 使用帮助"
    Write-Host "======================================="
    Write-Host ""
    Write-Host "用法: powershell -ExecutionPolicy Bypass -File NetworkMonitor.ps1 [参数]"
    Write-Host ""
    Write-Host "参数:"
    Write-Host "  [日期]                生成日报，如 2026-05-11（留空则启动监控）"
    Write-Host "  -ConfigFile <路径>    指定配置文件路径（默认: config.json）"
    Write-Host "  -Silent               静默模式，不显示启动信息和日常日志"
    Write-Host "  -NoSound              禁用声音警报"
    Write-Host "  -PingInterval <秒>    临时覆盖检测间隔"
    Write-Host "  -Help                 显示此帮助信息"
    Write-Host ""
    Write-Host "示例:"
    Write-Host '  powershell -File NetworkMonitor.ps1 -Silent -NoSound'
    Write-Host '  powershell -File NetworkMonitor.ps1 2026-05-11'
    Write-Host ""
    exit 0
}

# ========== 密钥管理 ==========

function Encrypt-Secret {
    param([string]$Secret, [string]$FilePath)
    $secure = ConvertTo-SecureString -String $Secret -AsPlainText -Force
    $encrypted = ConvertFrom-SecureString -SecureString $secure
    $encrypted | Set-Content -Path $FilePath -Encoding UTF8
}

function Decrypt-Secret {
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) { return $null }
    try {
        $encrypted = (Get-Content -Path $FilePath -Raw -Encoding UTF8).Trim()
        $secure = ConvertTo-SecureString -String $encrypted
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        return $plain
    } catch {
        Write-Log "解密密钥失败: $_" -Level "ERROR"
        return $null
    }
}

function Get-DingtalkSecret {
    param($Config)
    $secretFile = if ($Config.dingtalk_secret_file) { $Config.dingtalk_secret_file } else { ".dingtalk_secret" }

    $secret = Decrypt-Secret -FilePath $secretFile
    if ($secret) { return $secret }

    if ($Config.dingtalk_secret) {
        $secret = $Config.dingtalk_secret
        try {
            Encrypt-Secret -Secret $secret -FilePath $secretFile
            $Config.PSObject.Properties.Remove("dingtalk_secret")
            $Config | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigFile -Encoding UTF8
            Write-Log "已将钉钉 Secret 迁移到加密文件 $secretFile" -Level "INFO"
        } catch {
            Write-Log "迁移密钥失败: $_" -Level "WARNING"
        }
        return $secret
    }
    return $null
}

function Get-DingtalkWebhook {
    param($Config)
    $webhookFile = ".dingtalk_webhook"

    # 先尝试读取加密文件
    $webhook = Decrypt-Secret -FilePath $webhookFile
    if ($webhook) { return $webhook }

    # 向后兼容：从 config.json 迁移
    if ($Config.dingtalk_webhook -and $Config.dingtalk_webhook -ne "") {
        $webhook = $Config.dingtalk_webhook
        try {
            Encrypt-Secret -Secret $webhook -FilePath $webhookFile
            $Config.PSObject.Properties.Remove("dingtalk_webhook")
            $Config | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigFile -Encoding UTF8
            Write-Log "已将钉钉 Webhook 迁移到加密文件 $webhookFile" -Level "INFO"
        } catch {
            Write-Log "迁移 Webhook 失败: $_" -Level "WARNING"
        }
        return $webhook
    }
    return $null
}

# ========== 配置管理 ==========

function Initialize-Config {
    Write-Host ""
    Write-Host "=========================================="
    Write-Host "       首次启动 - 配置向导"
    Write-Host "=========================================="
    Write-Host ""
    Write-Host "请输入钉钉机器人配置（直接回车可跳过）："
    Write-Host ""

    $webhook = Read-Host "钉钉 Webhook 地址"
    $secret = Read-Host "钉钉 Secret"

    $config = @{
        targets = @(
            @{ name = "百度Ping"; type = "ping"; host = "www.baidu.com" }
            @{ name = "GoogleDNS-Ping"; type = "ping"; host = "8.8.8.8" }
            @{ name = "Cloudflare-Ping"; type = "ping"; host = "1.1.1.1" }
            @{ name = "百度HTTP"; type = "http"; url = "https://www.baidu.com"; method = "HEAD" }
        )
        ping_interval = 3
        ping_count = 3
        ping_timeout = 1000
        retry_count = 2
        packet_loss_threshold = 50
        unstable_threshold = 30
        latency_warning_threshold = 200
        alert_cooldown = 300
        dingtalk_webhook = $webhook
        dingtalk_secret_file = ".dingtalk_secret"
        enable_sound = $true
        log_file = "network_monitor.log"
        log_max_size_mb = 10
        log_max_backups = 5
        do_not_disturb = @{
            enabled = $true
            start_time = "22:00"
            end_time = "08:00"
        }
        monitor_adapter_switch = $true
        enable_web_panel = $false
        web_status_file = "status.html"
        enable_event_log = $true
        event_log_file = "network_events.jsonl"
        latency_alert_cooldown = 3600
        parallel_workers = 4
        event_log_max_age_days = 30
        event_log_max_size_mb = 50
    }

    Invoke-SafeAction -Action {
        $config | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigFile -Encoding UTF8
        if ($secret) {
            Encrypt-Secret -Secret $secret -FilePath ".dingtalk_secret"
            Write-Host "密钥已加密保存到 .dingtalk_secret" -ForegroundColor Green
        }
        if ($webhook) {
            Encrypt-Secret -Secret $webhook -FilePath ".dingtalk_webhook"
            Write-Host "Webhook 已加密保存到 .dingtalk_webhook" -ForegroundColor Green
        }
        Write-Host ""
        Write-Host "配置已保存到 $ConfigFile"
        if (-not $webhook) { Write-Host "提示: 未配置钉钉，将仅使用本地通知" }
        Write-Host ""
        Start-Sleep -Seconds 1
        return $config
    } -ErrorMessage "无法保存配置文件"
}

function Test-Config {
    param($Config)
    $warnings = @()
    $modified = $false

    # 向后兼容: ping_targets -> targets
    $pingTargets = $Config | Select-Object -ExpandProperty ping_targets -ErrorAction SilentlyContinue
    if ($pingTargets -and $pingTargets.Count -gt 0) {
        $targets = @()
        foreach ($t in $pingTargets) {
            $targets += @{ name = $t; type = "ping"; host = $t }
        }
        $Config | Add-Member -NotePropertyName targets -NotePropertyValue $targets -Force
        try { $Config.PSObject.Properties.Remove('ping_targets') } catch {}
        $warnings += "已自动将 ping_targets 迁移到新的 targets 格式"
        $modified = $true
    }

    # 向后兼容: dingtalk_secret -> 加密文件
    $dingtalkSecret = $Config | Select-Object -ExpandProperty dingtalk_secret -ErrorAction SilentlyContinue
    if ($dingtalkSecret -and $dingtalkSecret -ne "") {
        $secretFile = if ($Config.dingtalk_secret_file) { $Config.dingtalk_secret_file } else { ".dingtalk_secret" }
        Encrypt-Secret -Secret $dingtalkSecret -FilePath $secretFile
        try { $Config.PSObject.Properties.Remove('dingtalk_secret') } catch {}
        $warnings += "已将钉钉 Secret 迁移到加密文件 $secretFile"
        $modified = $true
    }

    # 向后兼容: dingtalk_webhook -> 加密文件
    $dingtalkWebhook = $Config | Select-Object -ExpandProperty dingtalk_webhook -ErrorAction SilentlyContinue
    if ($dingtalkWebhook -and $dingtalkWebhook -ne "") {
        Encrypt-Secret -Secret $dingtalkWebhook -FilePath ".dingtalk_webhook"
        try { $Config.PSObject.Properties.Remove('dingtalk_webhook') } catch {}
        $warnings += "已将钉钉 Webhook 迁移到加密文件 .dingtalk_webhook"
        $modified = $true
    }

    # 补全新增配置项
    if (-not $Config.targets -or $Config.targets.Count -eq 0) {
        $Config | Add-Member -NotePropertyName targets -NotePropertyValue @(
            @{ name = "www.baidu.com"; type = "ping"; host = "www.baidu.com" }
            @{ name = "8.8.8.8"; type = "ping"; host = "8.8.8.8" }
            @{ name = "1.1.1.1"; type = "ping"; host = "1.1.1.1" }
        ) -Force
        $warnings += "未配置探测目标，使用默认值"
        $modified = $true
    }
    if (-not $Config.ping_count -or $Config.ping_count -lt 1) { $Config.ping_count = 3 }
    if (-not $Config.ping_timeout -or $Config.ping_timeout -lt 100) { $Config.ping_timeout = 1000 }
    if (-not $Config.retry_count -or $Config.retry_count -lt 0) { $Config.retry_count = 2 }
    if (-not $Config.latency_warning_threshold -or $Config.latency_warning_threshold -lt 1) { $Config.latency_warning_threshold = 200 }
    if (-not $Config.log_max_size_mb -or $Config.log_max_size_mb -lt 1) { $Config.log_max_size_mb = 10 }
    if (-not $Config.log_max_backups -or $Config.log_max_backups -lt 1) { $Config.log_max_backups = 5 }
    if (-not $Config.do_not_disturb) {
        $Config | Add-Member -NotePropertyName do_not_disturb -NotePropertyValue (@{
            enabled = $true; start_time = "22:00"; end_time = "08:00"
        }) -Force
        $modified = $true
    }
    if (-not $Config.PSObject.Properties['dingtalk_secret_file']) {
        $Config | Add-Member -NotePropertyName dingtalk_secret_file -NotePropertyValue ".dingtalk_secret" -Force
        $modified = $true
    }
    if (-not $Config.PSObject.Properties['monitor_adapter_switch']) {
        $Config | Add-Member -NotePropertyName monitor_adapter_switch -NotePropertyValue $true -Force
        $modified = $true
    }
    if (-not $Config.PSObject.Properties['enable_web_panel']) {
        $Config | Add-Member -NotePropertyName enable_web_panel -NotePropertyValue $false -Force
        $modified = $true
    }
    if (-not $Config.PSObject.Properties['web_status_file']) {
        $Config | Add-Member -NotePropertyName web_status_file -NotePropertyValue "status.html" -Force
        $modified = $true
    }
    if (-not $Config.PSObject.Properties['enable_event_log']) {
        $Config | Add-Member -NotePropertyName enable_event_log -NotePropertyValue $true -Force
        $modified = $true
    }
    if (-not $Config.PSObject.Properties['event_log_file']) {
        $Config | Add-Member -NotePropertyName event_log_file -NotePropertyValue "network_events.jsonl" -Force
        $modified = $true
    }
    if (-not $Config.PSObject.Properties['latency_alert_cooldown']) {
        $Config | Add-Member -NotePropertyName latency_alert_cooldown -NotePropertyValue 3600 -Force
        $modified = $true
    }
    if (-not $Config.PSObject.Properties['parallel_workers']) {
        $Config | Add-Member -NotePropertyName parallel_workers -NotePropertyValue 4 -Force
        $modified = $true
    }
    if (-not $Config.PSObject.Properties['event_log_max_age_days']) {
        $Config | Add-Member -NotePropertyName event_log_max_age_days -NotePropertyValue 30 -Force
        $modified = $true
    }
    if (-not $Config.PSObject.Properties['event_log_max_size_mb']) {
        $Config | Add-Member -NotePropertyName event_log_max_size_mb -NotePropertyValue 50 -Force
        $modified = $true
    }

    # 阈值校验
    if ($Config.packet_loss_threshold -le 0) {
        $warnings += "packet_loss_threshold 无效，已自动调整为 50"
        $Config.packet_loss_threshold = 50
        $modified = $true
    }
    if ($Config.unstable_threshold -le 0) {
        $warnings += "unstable_threshold 无效，已自动调整为 30"
        $Config.unstable_threshold = 30
        $modified = $true
    }
    if ($Config.unstable_threshold -ge $Config.packet_loss_threshold) {
        $warnings += "unstable_threshold 应小于 packet_loss_threshold，已自动调整"
        $Config.unstable_threshold = [math]::Max(1, [math]::Floor($Config.packet_loss_threshold * 0.6))
        $modified = $true
    }
    if ($Config.ping_interval -lt 1) {
        $warnings += "ping_interval 无效，已自动调整为 3"
        $Config.ping_interval = 3
        $modified = $true
    }
    if ($Config.parallel_workers -lt 1) {
        $Config.parallel_workers = 4
        $modified = $true
    }

    if ($modified) {
        $Config | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigFile -Encoding UTF8
        Write-Log "配置已自动更新并保存" -Level "INFO"
    }

    if ($warnings.Count -gt 0) {
        Write-Host ""
        Write-Host "配置警告:" -ForegroundColor Yellow
        foreach ($w in $warnings) { Write-Host "  - $w" -ForegroundColor Yellow }
        Write-Host ""
    }

    return $Config
}

function Load-Config {
    if (-not (Test-Path $ConfigFile)) { return Initialize-Config }
    Invoke-SafeAction -Action {
        $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        return $config
    } -ErrorMessage "配置文件格式无效"
}

# ========== 日志系统 ==========

function Rotate-Log {
    param([string]$LogFile, [int]$MaxSizeMB = 10, [int]$MaxBackups = 5)
    if (-not (Test-Path $LogFile)) { return }
    $fileInfo = Get-Item $LogFile
    if (($fileInfo.Length / 1MB) -ge $MaxSizeMB) {
        $oldestBackup = "$LogFile.$MaxBackups"
        if (Test-Path $oldestBackup) { Remove-Item $oldestBackup -Force }
        for ($i = $MaxBackups - 1; $i -ge 1; $i--) {
            $oldFile = "$LogFile.$i"
            $newFile = "$LogFile.$($i + 1)"
            if (Test-Path $oldFile) { Rename-Item $oldFile $newFile -Force }
        }
        Rename-Item $LogFile "$LogFile.1" -Force
        Write-Log "日志文件滚动完成" -Level "INFO"
    }
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    if ($config -and $config.log_file) {
        $written = $false
        for ($i = 0; $i -lt 5; $i++) {
            try {
                Add-Content -Path $config.log_file -Value $logEntry -Encoding utf8
                $written = $true
                break
            } catch {
                if ($i -lt 4) { Start-Sleep -Milliseconds 50 }
            }
        }
        if (-not $written) {
            Write-Host "[$timestamp] [ERROR] 日志写入失败: 文件持续被占用 ($($config.log_file))" -ForegroundColor Red
        }
    }
    if (-not $Silent) {
        $colorMap = @{ "INFO" = "White"; "WARNING" = "Yellow"; "ERROR" = "Red" }
        $consoleColor = $colorMap[$Level]; if (-not $consoleColor) { $consoleColor = "White" }
        Write-Host $logEntry -ForegroundColor $consoleColor
    }
}

# ========== 事件日志 ==========

function Rotate-EventLog {
    param([string]$LogPath, [int]$MaxSizeMB = 50, [int]$MaxBackups = 3)
    if (-not (Test-Path $LogPath)) { return }
    $fileInfo = Get-Item $LogPath
    if (($fileInfo.Length / 1MB) -ge $MaxSizeMB) {
        $oldestBackup = "$LogPath.$MaxBackups"
        if (Test-Path $oldestBackup) { Remove-Item $oldestBackup -Force }
        for ($i = $MaxBackups - 1; $i -ge 1; $i--) {
            $oldFile = "$LogPath.$i"
            $newFile = "$LogPath.$($i + 1)"
            if (Test-Path $oldFile) { Rename-Item $oldFile $newFile -Force }
        }
        Rename-Item $LogPath "$LogPath.1" -Force
    }
}

function Clean-OldEventLogs {
    param([string]$BaseFile, [int]$MaxAgeDays)
    if ($MaxAgeDays -le 0) { return }
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($BaseFile)
    $dir = Split-Path -Parent $BaseFile
    if ([string]::IsNullOrEmpty($dir)) { $dir = (Get-Location).Path }
    $pattern = Join-Path $dir "${baseName}_*.jsonl*"
    $cutoff = (Get-Date).AddDays(-$MaxAgeDays)
    Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Where-Object {
        $_.LastWriteTime -lt $cutoff
    } | ForEach-Object {
        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Write-EventLog {
    param([string]$Type, [hashtable]$Data)
    if (-not $config.enable_event_log) { return }
    try {
        $event = @{ time = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fff"); type = $Type; data = $Data } | ConvertTo-Json -Compress -Depth 5
        $date = Get-Date -Format "yyyy-MM-dd"
        $baseFile = $config.event_log_file -replace '\.jsonl$', ''
        $logPath = "$baseFile`_$date.jsonl"

        # 先滚动当日日志
        Rotate-EventLog -LogPath $logPath -MaxSizeMB $config.event_log_max_size_mb

        $written = $false
        for ($i = 0; $i -lt 20; $i++) {
            try {
                [System.IO.File]::AppendAllText($logPath, $event + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
                $written = $true
                break
            } catch {
                if ($i -lt 19) { Start-Sleep -Milliseconds 100 }
            }
        }
        if (-not $written) {
            Write-Log "事件日志写入失败: 文件持续被占用 ($logPath)" -Level "WARNING"
        }
    } catch {
        Write-Log "事件日志写入失败: $_" -Level "WARNING"
    }
}

# ========== 钉钉通知 ==========

function Get-DingtalkSignature {
    param([string]$Secret)
    if (-not $Secret) { return "" }
    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $stringToSign = "$timestamp`n$Secret"
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    try {
        $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($Secret)
        $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($stringToSign))
        $sign = [System.Convert]::ToBase64String($hash)
        $sign = [System.Uri]::EscapeDataString($sign)
        return "&timestamp=$timestamp&sign=$sign"
    } finally {
        $hmac.Dispose()
    }
}

function Send-DingtalkMessage {
    param([string]$Webhook, [string]$Secret, [string]$Message)
    if (-not $Webhook) {
        Write-Log "钉钉 Webhook 未配置，跳过发送" -Level "WARNING"
        return $false
    }
    try {
        $signature = Get-DingtalkSignature -Secret $Secret
        $url = $Webhook + $signature
        $body = @{ msgtype = "text"; text = @{ content = $Message } } | ConvertTo-Json -Compress
        Write-Log "正在发送钉钉消息..." -Level "INFO"
        $response = Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec 10
        if ($response.errcode -eq 0) {
            Write-Log "钉钉通知发送成功" -Level "INFO"
            return $true
        } else {
            Write-Log "钉钉发送失败: $($response.errmsg)" -Level "WARNING"
            return $false
        }
    } catch {
        Write-Log "钉钉发送异常: $_" -Level "WARNING"
        return $false
    }
}

function Send-DingtalkMessage-Async {
    param([string]$Webhook, [string]$Secret, [string]$Message)
    if (-not $Webhook) { return }
    $baseDir = $script:BaseDir
    Start-Job -ScriptBlock {
        param($url, $secret, $msg, $base)
        $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $stringToSign = "$timestamp`n$secret"
        $hmac = New-Object System.Security.Cryptography.HMACSHA256
        try {
            $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($secret)
            $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($stringToSign))
            $sign = [System.Convert]::ToBase64String($hash)
            $sign = [System.Uri]::EscapeDataString($sign)
            $fullUrl = "$url&timestamp=$timestamp&sign=$sign"
            $body = @{ msgtype = "text"; text = @{ content = $msg } } | ConvertTo-Json -Compress
            try {
                Invoke-RestMethod -Uri $fullUrl -Method Post -Body $body -ContentType "application/json; charset=utf-8" -TimeoutSec 10 | Out-Null
            } catch {
                $errMsg = $_.Exception.Message
                $errFile = Join-Path $base "async_dingtalk_errors.log"
                [System.IO.File]::AppendAllText($errFile, "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] 钉钉异步发送失败: $errMsg`n", [System.Text.Encoding]::UTF8)
            }
        } finally {
            $hmac.Dispose()
        }
    } -ArgumentList $Webhook, $Secret, $Message, $baseDir | Out-Null
}

# ========== 勿扰时段 ==========

function Test-DoNotDisturb {
    param($DndConfig)
    if (-not $DndConfig -or -not $DndConfig.enabled) { return $false }
    $currentTime = (Get-Date).ToString("HH:mm")
    $start = $DndConfig.start_time; $end = $DndConfig.end_time
    if ($start -le $end) { return ($currentTime -ge $start -and $currentTime -le $end) }
    else { return ($currentTime -ge $start -or $currentTime -le $end) }
}

# ========== 网卡信息 ==========

function Get-DefaultAdapter {
    try {
        $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -and $_.NextHop -ne "0.0.0.0" } |
            Sort-Object @{Expression = { if ($_.InterfaceMetric) { $_.InterfaceMetric } else { 9999 } } } |
            Select-Object -First 1
        if (-not $route) { return @{ Name = "无"; Status = "Down"; IPAddress = ""; Type = "" } }
        $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
        if (-not $adapter) { return @{ Name = "未知"; Status = "Unknown"; IPAddress = ""; Type = "" } }
        $ip = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty IPAddress
        return @{ Name = $adapter.Name; Status = $adapter.Status; IPAddress = $ip; Type = $adapter.InterfaceDescription }
    } catch {
        return @{ Name = "获取失败"; Status = "Error"; IPAddress = ""; Type = "" }
    }
}

function Get-WifiStatus {
    try {
        $output = netsh wlan show interfaces 2>$null
        if ($output -match "没有连接任何无线网络" -or $output -match "There is no wireless interface") {
            return @{ Connected = $false; SSID = ""; Signal = ""; State = "未连接" }
        }
        $ssid = ""; $signal = ""; $state = ""
        foreach ($line in $output) {
            if ($line -match "\s*SSID\s*:\s*(.+)") { $ssid = $matches[1].Trim() }
            if ($line -match "\s*Signal\s*:\s*(.+)") { $signal = $matches[1].Trim() }
            if ($line -match "\s*状态\s*:\s*(.+)") { $state = $matches[1].Trim() }
            if ($line -match "\s*State\s*:\s*(.+)") { if (-not $state) { $state = $matches[1].Trim() } }
        }
        return @{ Connected = ($ssid -ne ""); SSID = $ssid; Signal = $signal; State = if ($state) { $state } else { "未知" } }
    } catch {
        return @{ Connected = $false; SSID = ""; Signal = ""; State = "获取失败" }
    }
}

function Get-AdapterSummary {
    param([hashtable]$Adapter, [hashtable]$Wifi)
    $summary = "当前出网网卡: $($Adapter.Name) ($($Adapter.IPAddress))`n网卡类型: $($Adapter.Type)"
    if ($Wifi) {
        if ($Wifi.Connected) { $summary += "`nWiFi 状态: 已连接 ($($Wifi.SSID)) 信号: $($Wifi.Signal)" }
        else { $summary += "`nWiFi 状态: $($Wifi.State)" }
    }
    return $summary
}

# 网卡信息缓存
$script:cachedAdapter = $null
$script:cachedWifi = $null
$script:lastAdapterRefresh = [DateTime]::MinValue

function Get-CachedAdapterInfo {
    param([bool]$ForceRefresh = $false)
    $now = Get-Date
    if ($ForceRefresh -or -not $script:lastAdapterRefresh -or ($now - $script:lastAdapterRefresh).TotalSeconds -ge 30) {
        $script:cachedAdapter = Get-DefaultAdapter
        $script:cachedWifi = Get-WifiStatus
        $script:lastAdapterRefresh = $now
    }
    return @{ Adapter = $script:cachedAdapter; Wifi = $script:cachedWifi }
}

function Send-Summary {
    if ($script:pendingMessages.Count -eq 0) { return }
    $dndStart = $script:lastDndStartTime
    $dndEnd = Get-Date
    $disconnects = $script:pendingMessages | Where-Object { $_.Type -eq "disconnect" }
    $unstables = $script:pendingMessages | Where-Object { $_.Type -eq "unstable" }
    $latencies = $script:pendingMessages | Where-Object { $_.Type -eq "latency" }
    $adapterChanges = $script:pendingMessages | Where-Object { $_.Type -eq "adapter_change" }

    $summary = "🌙 勿扰时段网络事件汇总`n时间: $($dndStart.ToString('MM-dd HH:mm')) ~ $($dndEnd.ToString('MM-dd HH:mm'))`n`n"

    if ($adapterChanges.Count -gt 0) {
        $summary += "🔄 网卡切换 $($adapterChanges.Count) 次`n"
        foreach ($ac in $adapterChanges) { $summary += "   $($ac.Timestamp.ToString('HH:mm:ss')): $($ac.FromName) → $($ac.ToName)`n" }
        $summary += "`n"
    }
    if ($disconnects.Count -gt 0) {
        $first = $disconnects | Select-Object -First 1
        $last = $disconnects | Select-Object -Last 1
        $summary += "⚠️ 网络断开 $($disconnects.Count) 次`n"
        $summary += "   首次: $($first.Timestamp.ToString('HH:mm:ss'))`n"
        $summary += "   末次: $($last.Timestamp.ToString('HH:mm:ss'))`n"
        if ($last.AdapterInfo) { $summary += "   出网网卡: $($last.AdapterInfo)`n" }
        $summary += "`n"
    }
    if ($unstables.Count -gt 0) {
        $avgLoss = ($unstables | Measure-Object -Property Loss -Average).Average
        $summary += "📊 不稳定预警 $($unstables.Count) 次`n"
        $summary += "   平均丢包率: $($avgLoss.ToString('F1'))%`n`n"
    }
    if ($latencies.Count -gt 0) {
        $avgLatency = ($latencies | Measure-Object -Property Latency -Average).Average
        $summary += "⏱️ 延迟过高预警 $($latencies.Count) 次`n"
        $summary += "   平均延迟: $($avgLatency.ToString('F0'))ms`n`n"
    }
    $summary += "共 $($script:pendingMessages.Count) 条事件被延迟通知"

    Write-Log $summary -Level "INFO"
    Send-DingtalkMessage-Async -Webhook $config.dingtalk_webhook -Secret $script:dingtalkSecret -Message $summary
    $script:pendingMessages = @()
}

# ========== 通知 ==========

function Play-Sound {
    param([bool]$Enable)
    if (-not $Enable -or $NoSound) { return }
    try {
        [console]::Beep(1000, 500)
        Start-Sleep -Milliseconds 200
        [console]::Beep(1000, 500)
    } catch {
        Write-Log "播放声音失败: $_" -Level "WARNING"
    }
}

function Show-Notification {
    param([string]$Title, [string]$Message)
    if ($Silent) { return }
    try {
        Start-Job -ScriptBlock {
            param($t, $m)
            Add-Type -AssemblyName System.Windows.Forms
            $notify = New-Object System.Windows.Forms.NotifyIcon
            $notify.Icon = [System.Drawing.SystemIcons]::Information
            $notify.Visible = $true
            $notify.ShowBalloonTip(10000, $t, $m, [System.Windows.Forms.ToolTipIcon]::None)
            Start-Sleep -Seconds 12
            $notify.Dispose()
        } -ArgumentList $Title, $Message | Out-Null
    } catch {
        Write-Log "显示通知失败: $_" -Level "WARNING"
    }
}

# ========== 多类型探测（串行回退）==========

function Test-Target-Ping {
    param($Target, [int]$Count = 3, [int]$TimeoutMs = 1000, [int]$RetryCount = 2)
    $latencies = @(); $success = $false; $sent = 0; $recv = 0
    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        for ($r = 0; $r -le $RetryCount; $r++) {
            $ok = 0
            for ($i = 0; $i -lt $Count; $i++) {
                $sent++
                try {
                    $reply = $ping.Send($Target.host, $TimeoutMs)
                    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        $latencies += $reply.RoundtripTime; $ok++; $recv++
                    }
                } catch {}
            }
            if ($ok -gt 0) { $success = $true; break }
            if ($r -lt $RetryCount) { Start-Sleep -Milliseconds 200 }
        }
    } finally {
        $ping.Dispose()
    }
    $avg = if ($latencies.Count -gt 0) { ($latencies | Measure-Object -Average).Average } else { -1 }
    return [PSCustomObject]@{
        Name = $Target.name; Type = "ping"; Host = $Target.host
        Success = $success; AvgLatency = $avg
        SentCount = $sent; RecvCount = $recv
        Detail = if ($success) { "OK, $recv/$sent replies" } else { "No reply" }
    }
}

function Test-Target-Dns {
    param($Target)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if ($Target.server) {
            $result = Resolve-DnsName -Name $Target.host -Server $Target.server -ErrorAction Stop
        } else {
            $result = Resolve-DnsName -Name $Target.host -ErrorAction Stop
        }
        $sw.Stop()
        return [PSCustomObject]@{
            Name = $Target.name; Type = "dns"; Host = $Target.host
            Success = $true; AvgLatency = $sw.ElapsedMilliseconds
            SentCount = 1; RecvCount = 1
            Detail = "Resolved to $($result[0].IPAddress)"
        }
    } catch {
        $sw.Stop()
        return [PSCustomObject]@{
            Name = $Target.name; Type = "dns"; Host = $Target.host
            Success = $false; AvgLatency = -1
            SentCount = 1; RecvCount = 0
            Detail = $_.Exception.Message
        }
    }
}

function Test-Target-Http {
    param($Target, [int]$TimeoutMs = 5000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $method = if ($Target.method) { $Target.method } else { "HEAD" }
        $currentProtocol = [Net.ServicePointManager]::SecurityProtocol
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
        try {
            $resp = Invoke-WebRequest -Uri $Target.url -Method $method -TimeoutSec ($TimeoutMs / 1000) -UseBasicParsing -ErrorAction Stop
        } finally {
            [Net.ServicePointManager]::SecurityProtocol = $currentProtocol
        }
        $sw.Stop()
        return [PSCustomObject]@{
            Name = $Target.name; Type = "http"; Host = $Target.url
            Success = ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400)
            AvgLatency = $sw.ElapsedMilliseconds
            SentCount = 1; RecvCount = 1
            Detail = "HTTP $($resp.StatusCode)"
        }
    } catch {
        $sw.Stop()
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        return [PSCustomObject]@{
            Name = $Target.name; Type = "http"; Host = $Target.url
            Success = $false; AvgLatency = $sw.ElapsedMilliseconds
            SentCount = 1; RecvCount = 0
            Detail = "HTTP $status / $($_.Exception.Message)"
        }
    }
}

function Test-Target-Tcp {
    param($Target, [int]$TimeoutMs = 3000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.BeginConnect($Target.host, $Target.port, $null, $null)
        $success = $connect.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($success) {
            $client.EndConnect($connect)
            $sw.Stop()
            return [PSCustomObject]@{
                Name = $Target.name; Type = "tcp"; Host = "$($Target.host):$($Target.port)"
                Success = $true; AvgLatency = $sw.ElapsedMilliseconds
                SentCount = 1; RecvCount = 1; Detail = "Connected"
            }
        } else {
            $sw.Stop()
            return [PSCustomObject]@{
                Name = $Target.name; Type = "tcp"; Host = "$($Target.host):$($Target.port)"
                Success = $false; AvgLatency = -1
                SentCount = 1; RecvCount = 0; Detail = "Connection timeout"
            }
        }
    } catch {
        $sw.Stop()
        return [PSCustomObject]@{
            Name = $Target.name; Type = "tcp"; Host = "$($Target.host):$($Target.port)"
            Success = $false; AvgLatency = -1
            SentCount = 1; RecvCount = 0; Detail = $_.Exception.Message
        }
    } finally {
        $client.Close()
    }
}

# ========== 并行探测 ==========

function Test-Targets {
    param($Targets, $Config)
    $workers = [math]::Max(1, $Config.parallel_workers)
    if ($workers -eq 1 -or $Targets.Count -eq 1) {
        return Test-Targets-Serial -Targets $Targets -Config $Config
    }

    # 内联探测脚本块，用于在 RunspacePool 中执行
    $probeScript = {
        param($target, $pingCount, $pingTimeout, $retryCount)
        switch ($target.type) {
            "ping" {
                $latencies = @(); $success = $false; $sent = 0; $recv = 0
                $ping = New-Object System.Net.NetworkInformation.Ping
                try {
                    for ($r = 0; $r -le $retryCount; $r++) {
                        $ok = 0
                        for ($i = 0; $i -lt $pingCount; $i++) {
                            $sent++
                            try {
                                $reply = $ping.Send($target.host, $pingTimeout)
                                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                                    $latencies += $reply.RoundtripTime; $ok++; $recv++
                                }
                            } catch {}
                        }
                        if ($ok -gt 0) { $success = $true; break }
                        if ($r -lt $retryCount) { Start-Sleep -Milliseconds 200 }
                    }
                } finally { $ping.Dispose() }
                $avg = if ($latencies.Count -gt 0) { ($latencies | Measure-Object -Average).Average } else { -1 }
                return [PSCustomObject]@{
                    Name = $target.name; Type = "ping"; Host = $target.host
                    Success = $success; AvgLatency = $avg
                    SentCount = $sent; RecvCount = $recv
                    Detail = if ($success) { "OK, $recv/$sent replies" } else { "No reply" }
                }
            }
            "dns" {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    if ($target.server) {
                        $result = Resolve-DnsName -Name $target.host -Server $target.server -ErrorAction Stop
                    } else {
                        $result = Resolve-DnsName -Name $target.host -ErrorAction Stop
                    }
                    $sw.Stop()
                    return [PSCustomObject]@{
                        Name = $target.name; Type = "dns"; Host = $target.host
                        Success = $true; AvgLatency = $sw.ElapsedMilliseconds
                        SentCount = 1; RecvCount = 1
                        Detail = "Resolved to $($result[0].IPAddress)"
                    }
                } catch {
                    $sw.Stop()
                    return [PSCustomObject]@{
                        Name = $target.name; Type = "dns"; Host = $target.host
                        Success = $false; AvgLatency = -1
                        SentCount = 1; RecvCount = 0
                        Detail = $_.Exception.Message
                    }
                }
            }
            "http" {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    $method = if ($target.method) { $target.method } else { "HEAD" }
                    $currentProtocol = [Net.ServicePointManager]::SecurityProtocol
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
                    try {
                        $resp = Invoke-WebRequest -Uri $target.url -Method $method -TimeoutSec ($pingTimeout / 1000) -UseBasicParsing -ErrorAction Stop
                    } finally {
                        [Net.ServicePointManager]::SecurityProtocol = $currentProtocol
                    }
                    $sw.Stop()
                    return [PSCustomObject]@{
                        Name = $target.name; Type = "http"; Host = $target.url
                        Success = ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400)
                        AvgLatency = $sw.ElapsedMilliseconds
                        SentCount = 1; RecvCount = 1
                        Detail = "HTTP $($resp.StatusCode)"
                    }
                } catch {
                    $sw.Stop()
                    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                    return [PSCustomObject]@{
                        Name = $target.name; Type = "http"; Host = $target.url
                        Success = $false; AvgLatency = $sw.ElapsedMilliseconds
                        SentCount = 1; RecvCount = 0
                        Detail = "HTTP $status / $($_.Exception.Message)"
                    }
                }
            }
            "tcp" {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $client = New-Object System.Net.Sockets.TcpClient
                try {
                    $connect = $client.BeginConnect($target.host, $target.port, $null, $null)
                    $success = $connect.AsyncWaitHandle.WaitOne($pingTimeout, $false)
                    if ($success) {
                        $client.EndConnect($connect)
                        $sw.Stop()
                        return [PSCustomObject]@{
                            Name = $target.name; Type = "tcp"; Host = "$($target.host):$($target.port)"
                            Success = $true; AvgLatency = $sw.ElapsedMilliseconds
                            SentCount = 1; RecvCount = 1; Detail = "Connected"
                        }
                    } else {
                        $sw.Stop()
                        return [PSCustomObject]@{
                            Name = $target.name; Type = "tcp"; Host = "$($target.host):$($target.port)"
                            Success = $false; AvgLatency = -1
                            SentCount = 1; RecvCount = 0; Detail = "Connection timeout"
                        }
                    }
                } catch {
                    $sw.Stop()
                    return [PSCustomObject]@{
                        Name = $target.name; Type = "tcp"; Host = "$($target.host):$($target.port)"
                        Success = $false; AvgLatency = -1
                        SentCount = 1; RecvCount = 0; Detail = $_.Exception.Message
                    }
                } finally { $client.Close() }
            }
            default {
                $hostStr = if ($target.host) { $target.host } elseif ($target.url) { $target.url } else { "unknown" }
                return [PSCustomObject]@{
                    Name = $target.name; Type = $target.type; Host = $hostStr
                    Success = $false; AvgLatency = -1
                    SentCount = 1; RecvCount = 0
                    Detail = "Unknown type: $($target.type)"
                }
            }
        }
    }

    $pool = [runspacefactory]::CreateRunspacePool(1, $workers)
    $pool.Open()
    $runspaces = @()
    foreach ($t in $Targets) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($probeScript).AddArgument($t).AddArgument($Config.ping_count).AddArgument($Config.ping_timeout).AddArgument($Config.retry_count)
        $runspaces += @{ Pipe = $ps; Status = $ps.BeginInvoke() }
    }

    $results = @()
    foreach ($rs in $runspaces) {
        try {
            $output = $rs.Pipe.EndInvoke($rs.Status)
            if ($output -and $output.Count -gt 0) { $results += $output[0] }
        } catch {
            Write-Log "探测任务异常: $_" -Level "WARNING"
        } finally {
            $rs.Pipe.Dispose()
        }
    }

    $pool.Close()
    $pool.Dispose()
    return $results
}

function Test-Targets-Serial {
    param($Targets, $Config)
    $results = @()
    foreach ($t in $Targets) {
        switch ($t.type) {
            "ping" { $r = Test-Target-Ping -Target $t -Count $Config.ping_count -TimeoutMs $Config.ping_timeout -RetryCount $Config.retry_count }
            "dns"  { $r = Test-Target-Dns -Target $t }
            "http" { $r = Test-Target-Http -Target $t -TimeoutMs $Config.ping_timeout }
            "tcp"  { $r = Test-Target-Tcp -Target $t -TimeoutMs $Config.ping_timeout }
            default {
                $hostStr = if ($t.host) { $t.host } elseif ($t.url) { $t.url } else { "unknown" }
                $r = [PSCustomObject]@{ Name = $t.name; Type = $t.type; Host = $hostStr; Success = $false; AvgLatency = -1; SentCount = 1; RecvCount = 0; Detail = "Unknown type: $($t.type)" }
            }
        }
        $results += $r
    }
    return $results
}

# ========== Web 状态面板 ==========

function Get-WebPanelHtml {
    param([hashtable]$Status)
    $s = $Status
    $statusColor = if ($s.isConnected) { "#4caf50" } else { "#f44336" }
    $statusText = if ($s.isConnected) { "✅ 网络正常" } else { "❌ 网络断开" }
    $adapterHtml = if ($s.adapter) { "<div class='card'><h3>出网网卡</h3><p><b>$($s.adapter.Name)</b></p><p>IP: $($s.adapter.IPAddress)</p><p>类型: $($s.adapter.Type)</p></div>" } else { "" }
    $wifiHtml = if ($s.wifi) {
        $wifiText = if ($s.wifi.Connected) { "已连接 ($($s.wifi.SSID))<br>信号: $($s.wifi.Signal)" } else { $s.wifi.State }
        "<div class='card'><h3>WiFi</h3><p>$wifiText</p></div>"
    } else { "" }
    $probeRows = ""
    if ($s.probes) {
        foreach ($p in $s.probes) {
            $c = if ($p.Success) { "#4caf50" } else { "#f44336" }
            $probeRows += "<tr><td>$($p.Name)</td><td>$($p.Type)</td><td style='color:$c'>$(if($p.Success){'OK'}else{'FAIL'})</td><td>$($p.AvgLatency)</td><td>$($p.Detail)</td></tr>"
        }
    }
    $html = @"
<!DOCTYPE html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="5">
<title>网络监控状态</title>
<style>
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#1a1a2e;color:#eee;margin:0;padding:20px;}
.container{max-width:900px;margin:0 auto;}
.header{text-align:center;padding:20px;background:#16213e;border-radius:12px;margin-bottom:20px;}
.status-badge{font-size:32px;font-weight:bold;color:$statusColor;}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:15px;margin-bottom:20px;}
.card{background:#16213e;border-radius:12px;padding:15px;}
.card h3{margin-top:0;color:#e94560;font-size:14px;text-transform:uppercase;}
table{width:100%;border-collapse:collapse;background:#16213e;border-radius:12px;overflow:hidden;}
th,td{padding:10px 15px;text-align:left;border-bottom:1px solid #2a2a4a;}
th{background:#0f3460;color:#e94560;font-size:12px;text-transform:uppercase;}
tr:hover{background:#1a1a3e;}
.footer{text-align:center;color:#888;margin-top:20px;font-size:12px;}
</style></head><body>
<div class="container">
<div class="header">
<div class="status-badge">$statusText</div>
<p>最后更新: $($s.lastUpdate)</p>
<p>今日断网: $($s.disconnectCount) 次 | 累计断网时长: $($s.totalDownTime)</p>
</div>
<div class="grid">
$adapterHtml
$wifiHtml
<div class="card"><h3>统计</h3><p>平均延迟: $($s.avgLatency) ms</p><p>丢包率: $($s.packetLoss)%</p><p>探测间隔: $($s.interval)s</p></div>
</div>
<table><thead><tr><th>目标</th><th>类型</th><th>状态</th><th>延迟(ms)</th><th>详情</th></tr></thead><tbody>
$probeRows
</tbody></table>
<div class="footer">网络监控程序 v$script:Version | 自动刷新 5s</div>
</div></body></html>
"@
    return $html
}

function Update-WebStatus {
    param([hashtable]$Status)
    if (-not $config.enable_web_panel) { return }
    try {
        $html = Get-WebPanelHtml -Status $Status
        $written = $false
        $filePath = [System.IO.Path]::GetFullPath($config.web_status_file)
        for ($i = 0; $i -lt 5; $i++) {
            try {
                [System.IO.File]::WriteAllText($filePath, $html, [System.Text.Encoding]::UTF8)
                $written = $true
                break
            } catch {
                if ($i -lt 4) { Start-Sleep -Milliseconds 50 }
            }
        }
        if (-not $written) {
            Write-Log "更新 Web 状态文件失败: 文件持续被占用 ($($config.web_status_file))" -Level "WARNING"
        }
    } catch {
        Write-Log "更新 Web 状态文件失败: $_" -Level "WARNING"
    }
}

# ========== 日报 ==========

function Generate-Report {
    param([string]$DateStr)
    if (-not $DateStr) { $DateStr = Get-Date -Format "yyyy-MM-dd" }
    $baseFile = $config.event_log_file -replace '\.jsonl$', ''
    $logPath = "$baseFile`_$DateStr.jsonl"

    if (-not (Test-Path $logPath)) {
        Write-Host "未找到 $DateStr 的事件日志: $logPath" -ForegroundColor Yellow
        return
    }

    $events = @(Get-Content $logPath | ForEach-Object { $_ | ConvertFrom-Json })
    $disconnects = @($events | Where-Object { $_.type -eq "disconnect" })
    $recovers = @($events | Where-Object { $_.type -eq "recover" })
    $probes = @($events | Where-Object { $_.type -eq "probe" })
    $adapterChanges = @($events | Where-Object { $_.type -eq "adapter_change" })
    $latencyAlerts = @($events | Where-Object { $_.type -eq "latency_alert" })

    $totalDisconnects = $disconnects.Count
    $totalDownTimeSec = 0
    foreach ($r in $recovers) { if ($r.data.durationSec) { $totalDownTimeSec += $r.data.durationSec } }
    $avgLatency = ($probes | ForEach-Object { $_.data.avgLatency } | Where-Object { $_ -gt 0 } | Measure-Object -Average).Average

    Write-Host ""
    Write-Host "========== 网络监控日报 ($DateStr) ==========" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  断网次数:        $totalDisconnects" -ForegroundColor White
    $ts = [TimeSpan]::FromSeconds($totalDownTimeSec)
    Write-Host "  累计断网时长:    $($ts.ToString('hh\:mm\:ss'))" -ForegroundColor White
    Write-Host "  网卡切换次数:    $($adapterChanges.Count)" -ForegroundColor White
    Write-Host "  延迟预警次数:    $($latencyAlerts.Count)" -ForegroundColor White
    if ($avgLatency) { Write-Host "  平均延迟:        $([math]::Round($avgLatency, 1)) ms" -ForegroundColor White }

    Write-Host ""
    Write-Host "  各目标探测统计:" -ForegroundColor Cyan
    $targetStats = @{}
    foreach ($p in $probes) {
        foreach ($t in $p.data.targets) {
            $name = $t.Name
            if (-not $targetStats[$name]) { $targetStats[$name] = @{ Total = 0; Success = 0 } }
            $targetStats[$name].Total++
            if ($t.Success) { $targetStats[$name].Success++ }
        }
    }
    foreach ($name in $targetStats.Keys | Sort-Object) {
        $s = $targetStats[$name]
        $rate = if ($s.Total -gt 0) { [math]::Round(($s.Success / $s.Total) * 100, 1) } else { 0 }
        $color = if ($rate -ge 95) { "Green" } elseif ($rate -ge 80) { "Yellow" } else { "Red" }
        Write-Host "    $name : $rate% ($($s.Success)/$($s.Total))" -ForegroundColor $color
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
}

# ========== 主监控循环 ==========

function Monitor-Network {
    $global:config = Load-Config
    $global:config = Test-Config -Config $global:config

    # 加载密钥和 Webhook
    $script:dingtalkSecret = Get-DingtalkSecret -Config $config
    $script:dingtalkWebhook = Get-DingtalkWebhook -Config $config
    # 将 webhook 注入 config 供通知函数使用
    $config | Add-Member -NotePropertyName dingtalk_webhook -NotePropertyValue $script:dingtalkWebhook -Force

    # 命令行覆盖
    if ($PingInterval -gt 0) {
        $config.ping_interval = $PingInterval
        Write-Log "检测间隔已临时覆盖为 $PingInterval 秒" -Level "INFO"
    }

    if (-not $Silent) {
        Write-Log "网络监控程序 v$script:Version 启动" -Level "INFO"
        Write-Log "探测目标: $($config.targets.Count) 个 (并行工作线程: $($config.parallel_workers))" -Level "INFO"
        foreach ($t in $config.targets) {
            $dest = if ($t.host) { $t.host } elseif ($t.url) { $t.url } elseif ($t.port) { "$($t.host):$($t.port)" } else { "unknown" }
            Write-Log "  [$($t.type)] $($t.name) -> $dest" -Level "INFO"
        }
        Write-Log "丢包阈值: $($config.packet_loss_threshold)%" -Level "INFO"
        Write-Log "延迟警告阈值: $($config.latency_warning_threshold)ms" -Level "INFO"
        Write-Log "钉钉通知: $(if ($config.dingtalk_webhook) { "已配置" } else { "未配置" })" -Level "INFO"
        $dndEnabled = $config.do_not_disturb -and $config.do_not_disturb.enabled
        Write-Log "勿扰模式: $(if ($dndEnabled) { "启用 ($($config.do_not_disturb.start_time) ~ $($config.do_not_disturb.end_time))" } else { "禁用" })" -Level "INFO"
        Write-Log "网卡监控: $(if ($config.monitor_adapter_switch) { "启用" } else { "禁用" })" -Level "INFO"
        Write-Log "Web面板: $(if ($config.enable_web_panel) { "启用 ($($config.web_status_file))" } else { "禁用" })" -Level "INFO"
        Write-Log "事件日志: $(if ($config.enable_event_log) { "启用 (保留 $($config.event_log_max_age_days) 天)" } else { "禁用" })" -Level "INFO"
    }

    # 初始化状态
    $isConnected = $true
    $lastDisconnectTime = $null
    $disconnectCount = 0
    $totalDownTimeSec = 0
    $packetLossHistory = @()
    $latencyHistory = @()
    $lastAlertTime = 0
    $lastLatencyAlertTime = 0
    $script:lastDndState = $false
    $script:pendingMessages = @()
    $script:lastConfigModified = (Get-Item $ConfigFile).LastWriteTime
    $script:lastAdapter = $null
    $lastAdapterAlertTime = 0
    $monitorAdapter = $config.monitor_adapter_switch

    # Web 面板状态
    $script:webStatus = @{
        isConnected = $true
        lastUpdate = (Get-Date -Format "HH:mm:ss")
        disconnectCount = 0
        totalDownTime = "00:00:00"
        avgLatency = 0
        packetLoss = 0
        interval = $config.ping_interval
        adapter = @{ Name = ""; IPAddress = ""; Type = "" }
        wifi = @{ Connected = $false; SSID = ""; Signal = ""; State = "" }
        probes = @()
    }
    if ($config.enable_web_panel) {
        Update-WebStatus -Status $script:webStatus
        Write-Log "Web 状态文件: $($config.web_status_file)" -Level "INFO"
    }

    # 启动时清理过期事件日志（避免每次写入时扫描）
    if ($config.enable_event_log) {
        Clean-OldEventLogs -BaseFile $config.event_log_file -MaxAgeDays $config.event_log_max_age_days
    }

    # 初始化网卡缓存
    $adapterInfo = Get-CachedAdapterInfo -ForceRefresh $true
    $script:lastAdapter = $adapterInfo.Adapter

    while (-not $script:StopRequested) {
        # 检查配置文件热重载
        try {
            $currentModified = (Get-Item $ConfigFile).LastWriteTime
            if ($currentModified -gt $script:lastConfigModified) {
                # 防抖：确保文件非空且写入完成
                $fileInfo = Get-Item $ConfigFile
                if ($fileInfo.Length -gt 0) {
                    Write-Log "检测到配置文件更新，正在重新加载..." -Level "WARNING"
                    $oldConfig = $global:config
                    try {
                        $newConfig = Get-Content $ConfigFile -Raw | ConvertFrom-Json
                        $newConfig = Test-Config -Config $newConfig
                        $global:config = $newConfig
                        $script:dingtalkSecret = Get-DingtalkSecret -Config $config
                        $script:dingtalkWebhook = Get-DingtalkWebhook -Config $config
                        $config | Add-Member -NotePropertyName dingtalk_webhook -NotePropertyValue $script:dingtalkWebhook -Force
                        $script:lastConfigModified = (Get-Item $ConfigFile).LastWriteTime
                        if ($PingInterval -gt 0) { $config.ping_interval = $PingInterval }
                        if (-not $Silent -and ($config.targets | ConvertTo-Json) -ne ($oldConfig.targets | ConvertTo-Json)) {
                            Write-Log "探测目标已更新" -Level "INFO"
                        }
                    } catch {
                        Write-Log "配置文件热重载失败，继续使用旧配置: $_" -Level "WARNING"
                        $global:config = $oldConfig
                        $script:lastConfigModified = (Get-Item $ConfigFile).LastWriteTime
                    }
                }
            }
        } catch {
            Write-Log "配置文件检查失败: $_" -Level "WARNING"
        }

        # 执行并行探测
        $probeResults = Test-Targets -Targets $config.targets -Config $config
        $successCount = ($probeResults | Where-Object { $_.Success }).Count
        $totalTargets = $config.targets.Count
        $currentLatencies = $probeResults | Where-Object { $_.Success } | Select-Object -ExpandProperty AvgLatency
        $avgLatency = if ($currentLatencies) { ($currentLatencies | Measure-Object -Average).Average } else { -1 }

        # 延迟告警只看 ping 类型
        $pingLatencies = $probeResults | Where-Object { $_.Success -and $_.Type -eq "ping" } | Select-Object -ExpandProperty AvgLatency
        $avgPingLatency = if ($pingLatencies) { ($pingLatencies | Measure-Object -Average).Average } else { -1 }

        # 丢包率：只统计 ping 类型的真实丢包率
        $pingResults = $probeResults | Where-Object { $_.Type -eq "ping" }
        $totalSent = ($pingResults | Measure-Object -Property SentCount -Sum).Sum
        $totalRecv = ($pingResults | Measure-Object -Property RecvCount -Sum).Sum
        $packetLoss = if ($totalSent -gt 0) { (($totalSent - $totalRecv) / $totalSent) * 100 } else { 0 }

        $packetLossHistory += $packetLoss
        if ($avgPingLatency -ge 0) { $latencyHistory += $avgPingLatency }
        if ($packetLossHistory.Count -gt 10) { $packetLossHistory = $packetLossHistory | Select-Object -Skip 1 }
        if ($latencyHistory.Count -gt 10) { $latencyHistory = $latencyHistory | Select-Object -Skip 1 }

        $avgLoss = ($packetLossHistory | Measure-Object -Average).Average
        $avgHistoryLatency = if ($latencyHistory) { ($latencyHistory | Measure-Object -Average).Average } else { -1 }
        $currentTime = [int64](Get-Date -UFormat %s)

        # 写入事件日志
        $targetEvents = @()
        foreach ($r in $probeResults) {
            $targetEvents += @{ Name = $r.Name; Type = $r.Type; Success = $r.Success; AvgLatency = $r.AvgLatency }
        }
        Write-EventLog -Type "probe" -Data @{
            targets = $targetEvents
            avgLatency = $avgLatency
            packetLoss = $packetLoss
        }

        # 检查勿扰时段
        $currentDnd = Test-DoNotDisturb -DndConfig $config.do_not_disturb
        if ($script:lastDndState -and -not $currentDnd -and $script:pendingMessages.Count -gt 0) {
            Write-Log "勿扰时段结束，发送延迟通知摘要..." -Level "INFO"
            Send-Summary
        }
        $script:lastDndState = $currentDnd

        # 检测网卡变化（使用缓存，30秒刷新一次）
        $adapterInfo = Get-CachedAdapterInfo
        $currentAdapter = $adapterInfo.Adapter
        $wifiStatus = $adapterInfo.Wifi
        $adapterSummary = Get-AdapterSummary -Adapter $currentAdapter -Wifi $wifiStatus

        if ($monitorAdapter -and $script:lastAdapter -and $currentAdapter.Name -ne $script:lastAdapter.Name) {
            $changeMsg = "🔄 出网网卡切换`n$($script:lastAdapter.Name) ($($script:lastAdapter.IPAddress)) → $($currentAdapter.Name) ($($currentAdapter.IPAddress))"
            if ($wifiStatus.Connected) { $changeMsg += "`nWiFi: $($wifiStatus.SSID) 信号 $($wifiStatus.Signal)" }
            elseif ($script:lastAdapter.Name -match "WiFi|WLAN|无线" -or $currentAdapter.Name -match "WiFi|WLAN|无线") { $changeMsg += "`nWiFi 状态: $($wifiStatus.State)" }
            Write-Log $changeMsg -Level "WARNING"
            Show-Notification -Title "网卡切换" -Message $changeMsg

            Write-EventLog -Type "adapter_change" -Data @{ from = $script:lastAdapter.Name; to = $currentAdapter.Name }

            # 过滤 ZeroTier 网卡切换，避免钉钉通知轰炸
            $isZeroTierChange = $currentAdapter.Name -match "ZeroTier|zerotier|Zero Tier" -or
                               $script:lastAdapter.Name -match "ZeroTier|zerotier|Zero Tier"

            if ($isZeroTierChange) {
                Write-Log "[过滤] ZeroTier 网卡切换，已拦截钉钉通知" -Level "INFO"
            } elseif ($currentDnd) {
                $script:pendingMessages += [PSCustomObject]@{ Type = "adapter_change"; Timestamp = Get-Date; FromName = $script:lastAdapter.Name; ToName = $currentAdapter.Name }
                Write-Log "[勿扰] 网卡切换通知已延迟发送" -Level "INFO"
            } elseif ($currentTime - $lastAdapterAlertTime -ge $config.alert_cooldown) {
                Send-DingtalkMessage-Async -Webhook $config.dingtalk_webhook -Secret $script:dingtalkSecret -Message $changeMsg
                $lastAdapterAlertTime = $currentTime
            }
        }
        $script:lastAdapter = $currentAdapter

        # 检测网络断开
        if ($avgLoss -ge $config.packet_loss_threshold -and $isConnected) {
            $isConnected = $false
            $lastDisconnectTime = Get-Date
            $disconnectCount++

            $message = "⚠️ 网络连接断开!`n时间: $($lastDisconnectTime.ToString('yyyy-MM-dd HH:mm:ss'))`n平均丢包率: $($avgLoss.ToString('F1'))%`n$adapterSummary"
            Write-Log $message -Level "WARNING"
            Play-Sound -Enable $config.enable_sound
            Show-Notification -Title "网络断开" -Message $message

            Write-EventLog -Type "disconnect" -Data @{ avgLoss = $avgLoss; adapter = $currentAdapter.Name }

            if ($currentDnd) {
                $script:pendingMessages += [PSCustomObject]@{ Type = "disconnect"; Timestamp = $lastDisconnectTime; Loss = $avgLoss; AdapterInfo = "$($currentAdapter.Name) ($($currentAdapter.IPAddress))" }
                Write-Log "[勿扰] 网络断开通知已延迟发送" -Level "INFO"
            } elseif ($currentTime - $lastAlertTime -ge $config.alert_cooldown) {
                Send-DingtalkMessage-Async -Webhook $config.dingtalk_webhook -Secret $script:dingtalkSecret -Message $message
                $lastAlertTime = $currentTime
            }
        }
        # 检测网络恢复
        elseif (($avgLoss -lt $config.packet_loss_threshold -or $successCount -eq $totalTargets) -and -not $isConnected) {
            $isConnected = $true
            $duration = (Get-Date) - $lastDisconnectTime
            $durationSec = [math]::Floor($duration.TotalSeconds)
            $durationStr = "{0:hh\:mm\:ss}" -f $duration
            $totalDownTimeSec += $durationSec

            $message = "✅ 网络已恢复!`n断开时长: $durationStr`n累计断开次数: $disconnectCount 次`n$adapterSummary"
            Write-Log $message -Level "INFO"
            Show-Notification -Title "网络恢复" -Message $message

            Write-EventLog -Type "recover" -Data @{ durationSec = $durationSec; durationStr = $durationStr; adapter = $currentAdapter.Name }

            if ($currentDnd) {
                $script:pendingMessages += [PSCustomObject]@{ Type = "recover"; Timestamp = Get-Date; Duration = $durationStr; AdapterInfo = "$($currentAdapter.Name) ($($currentAdapter.IPAddress))" }
                Write-Log "[勿扰] 网络恢复通知已延迟发送" -Level "INFO"
            } elseif ($currentTime - $lastAlertTime -ge $config.alert_cooldown) {
                Send-DingtalkMessage-Async -Webhook $config.dingtalk_webhook -Secret $script:dingtalkSecret -Message $message
                $lastAlertTime = $currentTime
            }
        }
        # 网络不稳定预警
        elseif ($isConnected -and $avgLoss -gt $config.unstable_threshold) {
            Write-Log "⚠️ 网络不稳定，平均丢包率: $($avgLoss.ToString('F1'))%" -Level "WARNING"
            if ($currentDnd) {
                $lastUnstable = $script:pendingMessages | Where-Object { $_.Type -eq "unstable" } | Select-Object -Last 1
                if (-not $lastUnstable -or ((Get-Date) - $lastUnstable.Timestamp).TotalSeconds -ge $config.alert_cooldown) {
                    $script:pendingMessages += [PSCustomObject]@{ Type = "unstable"; Timestamp = Get-Date; Loss = $avgLoss }
                    Write-Log "[勿扰] 不稳定预警已延迟发送" -Level "INFO"
                }
            } elseif ($currentTime - $lastAlertTime -ge $config.alert_cooldown) {
                $message = "⚠️ 网络预警`n时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n平均丢包率: $($avgLoss.ToString('F1'))%`n建议检查网络连接"
                Send-DingtalkMessage-Async -Webhook $config.dingtalk_webhook -Secret $script:dingtalkSecret -Message $message
                $lastAlertTime = $currentTime
            }
        }

        # 延迟过高预警（仅基于 ping 类型延迟，使用独立 cooldown）
        if ($isConnected -and $avgHistoryLatency -ge $config.latency_warning_threshold -and $avgHistoryLatency -gt 0) {
            Write-Log "⚠️ 网络延迟过高（Ping），平均延迟: $($avgHistoryLatency.ToString('F0'))ms" -Level "WARNING"
            Write-EventLog -Type "latency_alert" -Data @{ latency = $avgHistoryLatency; threshold = $config.latency_warning_threshold }
            if ($currentDnd) {
                $lastLatency = $script:pendingMessages | Where-Object { $_.Type -eq "latency" } | Select-Object -Last 1
                if (-not $lastLatency -or ((Get-Date) - $lastLatency.Timestamp).TotalSeconds -ge $config.latency_alert_cooldown) {
                    $script:pendingMessages += [PSCustomObject]@{ Type = "latency"; Timestamp = Get-Date; Latency = $avgHistoryLatency }
                    Write-Log "[勿扰] 延迟预警已延迟发送" -Level "INFO"
                }
            } elseif ($currentTime - $lastLatencyAlertTime -ge $config.latency_alert_cooldown) {
                $message = "⏱️ 延迟预警（Ping）`n时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n平均延迟: $($avgHistoryLatency.ToString('F0'))ms`n阈值: $($config.latency_warning_threshold)ms"
                Send-DingtalkMessage-Async -Webhook $config.dingtalk_webhook -Secret $script:dingtalkSecret -Message $message
                $lastLatencyAlertTime = $currentTime
            }
        }

        # 更新 Web 面板状态
        $script:webStatus = @{
            isConnected = $isConnected
            lastUpdate = (Get-Date -Format "HH:mm:ss")
            disconnectCount = $disconnectCount
            totalDownTime = [TimeSpan]::FromSeconds($totalDownTimeSec).ToString('hh\:mm\:ss')
            avgLatency = if ($avgHistoryLatency -gt 0) { [math]::Round($avgHistoryLatency, 1) } else { 0 }
            packetLoss = [math]::Round($avgLoss, 1)
            interval = $config.ping_interval
            adapter = $currentAdapter
            wifi = $wifiStatus
            probes = $probeResults | ForEach-Object { @{ Name = $_.Name; Type = $_.Type; Success = $_.Success; AvgLatency = $_.AvgLatency; Detail = $_.Detail } }
        }
        Update-WebStatus -Status $script:webStatus

        # 日志滚动
        Rotate-Log -LogFile $config.log_file -MaxSizeMB $config.log_max_size_mb -MaxBackups $config.log_max_backups

        # 清理已完成的异步 Job
        Get-Job -State Completed | Remove-Job -ErrorAction SilentlyContinue
        Get-Job -State Failed | Remove-Job -ErrorAction SilentlyContinue

        # 分段睡眠以支持快速响应停止请求
        $sleepRemain = $config.ping_interval
        while ($sleepRemain -gt 0 -and -not $script:StopRequested) {
            $chunk = [Math]::Min($sleepRemain, 1)
            Start-Sleep -Seconds $chunk
            $sleepRemain -= $chunk
        }
    }
}

# ========== 启动入口 ==========

try {
    if ($Report -ne "") {
        $global:config = Load-Config
        $global:config = Test-Config -Config $global:config
        $dateStr = if ($Report -eq "today") { Get-Date -Format "yyyy-MM-dd" } else { $Report }
        Generate-Report -DateStr $dateStr
        exit 0
    }

    Monitor-Network
} finally {
    $script:NormalExit = $true
    if ($script:mutex) {
        try { $script:mutex.ReleaseMutex() } catch {}
        $script:mutex.Dispose()
    }
    Set-NormalExitFlag
    try { [Console]::remove_CancelKeyPress($cancelEvent) } catch {}
}
exit 0
