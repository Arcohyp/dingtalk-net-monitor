<#
网络监控程序 - PowerShell 版本
无需安装 Python，直接在 Windows 上运行

配置文件: config.json (首次启动时会自动引导创建)
#>

param(
    [string]$ConfigFile = "config.json",
    [switch]$Silent,
    [switch]$NoSound,
    [int]$PingInterval = 0,
    [switch]$Help
)

# 统一错误处理
function Invoke-SafeAction {
    param(
        [scriptblock]$Action,
        [string]$ErrorMessage,
        [bool]$ContinueOnError = $false
    )

    try {
        & $Action
    } catch {
        if ($ErrorMessage) {
            Write-Host "错误: $ErrorMessage - $_" -ForegroundColor Red
        } else {
            Write-Host "错误: $_" -ForegroundColor Red
        }
        if (-not $ContinueOnError) {
            exit 1
        }
    }
}

# 显示帮助信息
if ($Help) {
    Write-Host ""
    Write-Host "网络监控程序 - 使用帮助"
    Write-Host "======================="
    Write-Host ""
    Write-Host "用法: powershell -ExecutionPolicy Bypass -File NetworkMonitor.ps1 [参数]"
    Write-Host ""
    Write-Host "参数:"
    Write-Host "  -ConfigFile <路径>    指定配置文件路径（默认: config.json）"
    Write-Host "  -Silent               静默模式，不显示启动信息"
    Write-Host "  -NoSound              禁用声音警报"
    Write-Host "  -PingInterval <秒>    临时覆盖检测间隔"
    Write-Host "  -Help                 显示此帮助信息"
    Write-Host ""
    Write-Host "示例:"
    Write-Host '  powershell -File NetworkMonitor.ps1 -Silent -NoSound'
    Write-Host '  powershell -File NetworkMonitor.ps1 -ConfigFile "myconfig.json"'
    Write-Host ""
    exit 0
}

# 首次配置向导
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
        ping_targets = @("www.baidu.com", "8.8.8.8", "1.1.1.1")
        ping_interval = 3
        ping_count = 3
        ping_timeout = 1000
        retry_count = 2
        packet_loss_threshold = 50
        unstable_threshold = 30
        latency_warning_threshold = 200
        alert_cooldown = 300
        dingtalk_webhook = $webhook
        dingtalk_secret = $secret
        enable_sound = $true
        log_file = "network_monitor.log"
        log_max_size_mb = 10
        log_max_backups = 5
        do_not_disturb = @{
            enabled = $true
            start_time = "22:00"
            end_time = "08:00"
        }
    }

    Invoke-SafeAction -Action {
        $config | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigFile -Encoding UTF8
        Write-Host ""
        Write-Host "配置已保存到 $ConfigFile"
        if (-not $webhook) {
            Write-Host "提示: 未配置钉钉，将仅使用本地通知"
        }
        Write-Host ""
        Start-Sleep -Seconds 1
        return $config
    } -ErrorMessage "无法保存配置文件"
}

# 配置校验与修正
function Test-Config {
    param($Config)

    $warnings = @()

    # 检查并补全新增配置项
    if (-not $Config.ping_count -or $Config.ping_count -lt 1) {
        $Config | Add-Member -NotePropertyName ping_count -NotePropertyValue 3 -Force
    }
    if (-not $Config.ping_timeout -or $Config.ping_timeout -lt 100) {
        $Config | Add-Member -NotePropertyName ping_timeout -NotePropertyValue 1000 -Force
    }
    if (-not $Config.retry_count -or $Config.retry_count -lt 0) {
        $Config | Add-Member -NotePropertyName retry_count -NotePropertyValue 2 -Force
    }
    if (-not $Config.latency_warning_threshold -or $Config.latency_warning_threshold -lt 1) {
        $Config | Add-Member -NotePropertyName latency_warning_threshold -NotePropertyValue 200 -Force
    }
    if (-not $Config.log_max_size_mb -or $Config.log_max_size_mb -lt 1) {
        $Config | Add-Member -NotePropertyName log_max_size_mb -NotePropertyValue 10 -Force
    }
    if (-not $Config.log_max_backups -or $Config.log_max_backups -lt 1) {
        $Config | Add-Member -NotePropertyName log_max_backups -NotePropertyValue 5 -Force
    }
    if (-not $Config.do_not_disturb) {
        $Config | Add-Member -NotePropertyName do_not_disturb -NotePropertyValue (@{
            enabled = $true
            start_time = "22:00"
            end_time = "08:00"
        }) -Force
    }

    # 检查阈值合理性
    if ($Config.packet_loss_threshold -le 0) {
        $warnings += "packet_loss_threshold 无效，已自动调整为 50"
        $Config.packet_loss_threshold = 50
    }

    if ($Config.unstable_threshold -le 0) {
        $warnings += "unstable_threshold 无效，已自动调整为 30"
        $Config.unstable_threshold = 30
    }

    if ($Config.unstable_threshold -ge $Config.packet_loss_threshold) {
        $warnings += "unstable_threshold 应小于 packet_loss_threshold，已自动调整"
        $Config.unstable_threshold = [math]::Max(1, [math]::Floor($Config.packet_loss_threshold * 0.6))
    }

    if ($Config.ping_interval -lt 1) {
        $warnings += "ping_interval 无效，已自动调整为 3"
        $Config.ping_interval = 3
    }

    # 检查日志配置
    if (-not $Config.log_max_size_mb -or $Config.log_max_size_mb -lt 1) {
        $Config.log_max_size_mb = 10
    }

    # 检查重试配置
    if (-not $Config.retry_count -or $Config.retry_count -lt 0) {
        $Config.retry_count = 2
    }

    # 检查 ping 配置
    if (-not $Config.ping_count -or $Config.ping_count -lt 1) {
        $Config.ping_count = 3
    }

    # 检查延迟阈值
    if (-not $Config.latency_warning_threshold) {
        $Config.latency_warning_threshold = 200
    }

    # 检查 ping_targets
    if (-not $Config.ping_targets -or $Config.ping_targets.Count -eq 0) {
        $Config.ping_targets = @("www.baidu.com", "8.8.8.8", "1.1.1.1")
        $warnings += "未配置 ping 目标，使用默认值"
    }

    if ($warnings.Count -gt 0) {
        Write-Host ""
        Write-Host "配置警告:" -ForegroundColor Yellow
        foreach ($w in $warnings) {
            Write-Host "  - $w" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    return $Config
}

# 加载配置
function Load-Config {
    if (-not (Test-Path $ConfigFile)) {
        return Initialize-Config
    }

    Invoke-SafeAction -Action {
        $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        return $config
    } -ErrorMessage "配置文件格式无效"
}

# 日志滚动
function Rotate-Log {
    param(
        [string]$LogFile,
        [int]$MaxSizeMB = 10,
        [int]$MaxBackups = 5
    )

    if (-not (Test-Path $LogFile)) { return }

    $fileInfo = Get-Item $LogFile
    $fileSizeMB = $fileInfo.Length / 1MB

    if ($fileSizeMB -ge $MaxSizeMB) {
        # 删除最旧的备份
        $oldestBackup = "$LogFile.$MaxBackups"
        if (Test-Path $oldestBackup) {
            Remove-Item $oldestBackup -Force
        }

        # 重命名现有备份
        for ($i = $MaxBackups - 1; $i -ge 1; $i--) {
            $oldFile = "$LogFile.$i"
            $newFile = "$LogFile.$($i + 1)"
            if (Test-Path $oldFile) {
                Rename-Item $oldFile $newFile -Force
            }
        }

        # 重命名当前日志
        Rename-Item $LogFile "$LogFile.1" -Force
        Write-Log "日志文件滚动完成" -Level "INFO"
    }
}

# 写日志
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    # 颜色映射
    $colorMap = @{
        "INFO" = "White"
        "WARNING" = "Yellow"
        "ERROR" = "Red"
    }
    $consoleColor = $colorMap[$Level]
    if (-not $consoleColor) { $consoleColor = "White" }

    Add-Content -Path $config.log_file -Value $logEntry -Encoding utf8
    Write-Host $logEntry -ForegroundColor $consoleColor
}

# 生成钉钉签名
function Get-DingtalkSignature {
    param(
        [string]$Secret
    )

    if (-not $Secret) {
        return ""
    }

    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $stringToSign = "$timestamp`n$Secret"

    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($Secret)
    $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($stringToSign))
    $sign = [System.Convert]::ToBase64String($hash)
    $sign = [System.Uri]::EscapeDataString($sign)

    return "&timestamp=$timestamp&sign=$sign"
}

# 发送钉钉消息
function Send-DingtalkMessage {
    param(
        [string]$Webhook,
        [string]$Secret,
        [string]$Message
    )

    if (-not $Webhook) {
        Write-Log "钉钉 Webhook 未配置，跳过发送" -Level "WARNING"
        return $false
    }

    try {
        $signature = Get-DingtalkSignature -Secret $Secret
        $url = $Webhook + $signature

        $body = @{
            msgtype = "text"
            text = @{
                content = $Message
            }
        } | ConvertTo-Json -Compress

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

# 判断当前是否在勿扰时段
function Test-DoNotDisturb {
    param($DndConfig)

    if (-not $DndConfig -or -not $DndConfig.enabled) {
        return $false
    }

    $now = Get-Date
    $currentTime = $now.ToString("HH:mm")

    $start = $DndConfig.start_time
    $end = $DndConfig.end_time

    if ($start -le $end) {
        # 不跨天，如 09:00 ~ 18:00
        return ($currentTime -ge $start -and $currentTime -le $end)
    } else {
        # 跨天，如 22:00 ~ 08:00
        return ($currentTime -ge $start -or $currentTime -le $end)
    }
}

# 获取当前默认出网网卡信息
function Get-DefaultAdapter {
    try {
        # 获取 IPv4 默认路由，按 RouteMetric 排序取最优
        $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -and $_.NextHop -ne "0.0.0.0" } |
            Sort-Object @{Expression = { if ($_.InterfaceMetric) { $_.InterfaceMetric } else { 9999 } } } |
            Select-Object -First 1

        if (-not $route) {
            return @{ Name = "无"; InterfaceAlias = "无"; Status = "Down"; IPAddress = ""; Type = "" }
        }

        $adapter = Get-NetAdapter -InterfaceIndex $route.InterfaceIndex -ErrorAction SilentlyContinue
        if (-not $adapter) {
            return @{ Name = "未知"; InterfaceAlias = "未知"; Status = "Unknown"; IPAddress = ""; Type = "" }
        }

        $ip = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty IPAddress

        return @{
            Name = $adapter.Name
            InterfaceAlias = $adapter.InterfaceAlias
            Status = $adapter.Status
            IPAddress = $ip
            Type = $adapter.InterfaceDescription
        }
    } catch {
        return @{ Name = "获取失败"; InterfaceAlias = "获取失败"; Status = "Error"; IPAddress = ""; Type = "" }
    }
}

# 获取 WiFi 连接状态（使用 netsh）
function Get-WifiStatus {
    try {
        $output = netsh wlan show interfaces 2>$null
        if ($output -match "没有连接任何无线网络" -or $output -match "There is no wireless interface") {
            return @{ Connected = $false; SSID = ""; Signal = ""; State = "未连接" }
        }

        $ssid = ""
        $signal = ""
        $state = ""

        foreach ($line in $output) {
            if ($line -match "\s*SSID\s*:\s*(.+)") { $ssid = $matches[1].Trim() }
            if ($line -match "\s*Signal\s*:\s*(.+)") { $signal = $matches[1].Trim() }
            if ($line -match "\s*状态\s*:\s*(.+)") { $state = $matches[1].Trim() }
            if ($line -match "\s*State\s*:\s*(.+)") { if (-not $state) { $state = $matches[1].Trim() } }
        }

        return @{
            Connected = ($ssid -ne "")
            SSID = $ssid
            Signal = $signal
            State = if ($state) { $state } else { "未知" }
        }
    } catch {
        return @{ Connected = $false; SSID = ""; Signal = ""; State = "获取失败" }
    }
}

# 构建网卡信息摘要文本
function Get-AdapterSummary {
    param(
        [hashtable]$Adapter,
        [hashtable]$Wifi
    )

    $summary = "当前出网网卡: $($Adapter.Name) ($($Adapter.IPAddress))`n"
    $summary += "网卡类型: $($Adapter.Type)`n"

    if ($Wifi) {
        if ($Wifi.Connected) {
            $summary += "WiFi 状态: 已连接 ($($Wifi.SSID)) 信号: $($Wifi.Signal)`n"
        } else {
            $summary += "WiFi 状态: $($Wifi.State)`n"
        }
    }

    return $summary.TrimEnd()
}

# 发送勿扰时段摘要
function Send-Summary {
    if ($script:pendingMessages.Count -eq 0) { return }

    $dndStart = $script:lastDndStartTime
    $dndEnd = Get-Date

    $disconnects = $script:pendingMessages | Where-Object { $_.Type -eq "disconnect" }
    $unstables = $script:pendingMessages | Where-Object { $_.Type -eq "unstable" }
    $latencies = $script:pendingMessages | Where-Object { $_.Type -eq "latency" }
    $adapterChanges = $script:pendingMessages | Where-Object { $_.Type -eq "adapter_change" }

    $summary = "🌙 勿扰时段网络事件汇总`n"
    $summary += "时间: $($dndStart.ToString('MM-dd HH:mm')) ~ $($dndEnd.ToString('MM-dd HH:mm'))`n`n"

    if ($adapterChanges.Count -gt 0) {
        $summary += "🔄 网卡切换 $($adapterChanges.Count) 次`n"
        foreach ($ac in $adapterChanges) {
            $summary += "   $($ac.Timestamp.ToString('HH:mm:ss')): $($ac.FromName) → $($ac.ToName)`n"
        }
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
    Send-DingtalkMessage -Webhook $config.dingtalk_webhook -Secret $config.dingtalk_secret -Message $summary

    $script:pendingMessages = @()
}

# 播放声音
function Play-Sound {
    param(
        [bool]$Enable
    )

    if (-not $Enable -or $NoSound) { return }

    try {
        [console]::Beep(1000, 500)
        Start-Sleep -Milliseconds 200
        [console]::Beep(1000, 500)
    } catch {
        Write-Log "播放声音失败: $_" -Level "WARNING"
    }
}

# 显示系统通知
function Show-Notification {
    param(
        [string]$Title,
        [string]$Message
    )

    if ($Silent) { return }

    try {
        Add-Type -AssemblyName System.Windows.Forms
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Information
        $notify.Visible = $true
        $notify.ShowBalloonTip(10000, $Title, $Message, [System.Windows.Forms.ToolTipIcon]::None)
        Start-Sleep -Seconds 1
        $notify.Dispose()
    } catch {
        Write-Log "显示通知失败: $_" -Level "WARNING"
    }
}

# 并行 Ping 测试
function Test-Ping-Parallel {
    param(
        [string[]]$Targets,
        [int]$Count = 3,
        [int]$TimeoutMs = 1000,
        [int]$RetryCount = 2
    )

    $results = @()

    foreach ($target in $Targets) {
        $success = $false
        $latencies = @()
        
        for ($retry = 0; $retry -le $RetryCount; $retry++) {
            try {
                $ping = New-Object System.Net.NetworkInformation.Ping
                $pingCount = 0
                $successCount = 0
                
                for ($i = 0; $i -lt $Count; $i++) {
                    $reply = $ping.Send($target, $TimeoutMs)
                    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        $latencies += $reply.RoundtripTime
                        $successCount++
                    }
                    $pingCount++
                }
                
                # 只要有成功的ping就认为目标可达
                if ($successCount -gt 0) {
                    $success = $true
                    break
                }
            } catch {
                # Ping 失败，继续重试
            }
            
            if ($retry -lt $RetryCount) {
                Start-Sleep -Milliseconds 200
            }
        }

        $avgLatency = if ($latencies.Count -gt 0) { ($latencies | Measure-Object -Average).Average } else { -1 }
        
        $results += [PSCustomObject]@{
            Target = $target
            Success = $success
            AvgLatency = $avgLatency
            Latencies = $latencies
        }
    }

    return $results
}

# 主监控函数
function Monitor-Network {
    $global:config = Load-Config
    $global:config = Test-Config -Config $global:config

    # 应用命令行参数覆盖
    if ($PingInterval -gt 0) {
        $config.ping_interval = $PingInterval
        Write-Log "检测间隔已临时覆盖为 $PingInterval 秒" -Level "INFO"
    }

    if (-not $Silent) {
        Write-Log "网络监控程序启动" -Level "INFO"
        Write-Log "Ping 目标: $($config.ping_targets -join ', ')" -Level "INFO"
        Write-Log "丢包阈值: $($config.packet_loss_threshold)%" -Level "INFO"
        Write-Log "延迟警告阈值: $($config.latency_warning_threshold)ms" -Level "INFO"
        if ($config.dingtalk_webhook) {
            Write-Log "钉钉通知: 已配置" -Level "INFO"
        } else {
            Write-Log "钉钉通知: 未配置" -Level "INFO"
        }
        $dndEnabled = $config.do_not_disturb -and $config.do_not_disturb.enabled
        Write-Log "勿扰模式: $(if ($dndEnabled) { "启用 ($($config.do_not_disturb.start_time) ~ $($config.do_not_disturb.end_time))" } else { "禁用" })" -Level "INFO"
    }

    $isConnected = $true
    $lastDisconnectTime = $null
    $disconnectCount = 0
    $packetLossHistory = @()
    $latencyHistory = @()
    $lastAlertTime = 0
    $lastLatencyAlertTime = 0
    $script:lastDndState = $false
    $script:pendingMessages = @()
    $script:lastConfigModified = (Get-Item $ConfigFile).LastWriteTime

    # 网卡状态追踪
    $script:lastAdapter = $null
    $lastAdapterAlertTime = 0
    $monitorAdapter = if ($config.PSObject.Properties['monitor_adapter_switch']) { $config.monitor_adapter_switch } else { $true }

    while ($true) {
        # 检查配置文件是否更新
        try {
            $currentModified = (Get-Item $ConfigFile).LastWriteTime
            if ($currentModified -gt $script:lastConfigModified) {
                Write-Log "检测到配置文件更新，正在重新加载..." -Level "WARNING"
                $oldConfig = $global:config
                $global:config = Load-Config
                $global:config = Test-Config -Config $global:config
                $script:lastConfigModified = $currentModified
                
                # 保持命令行覆盖
                if ($PingInterval -gt 0) {
                    $config.ping_interval = $PingInterval
                }
                
                if (-not $Silent) {
                    if ($config.ping_targets -ne $oldConfig.ping_targets) {
                        Write-Log "Ping 目标已更新: $($config.ping_targets -join ', ')" -Level "INFO"
                    }
                }
            }
        } catch {
            Write-Log "配置文件检查失败: $_" -Level "WARNING"
        }

        # 执行并行 Ping 测试
        $pingResults = Test-Ping-Parallel -Targets $config.ping_targets -Count $config.ping_count -TimeoutMs $config.ping_timeout -RetryCount $config.retry_count
        
        $successCount = ($pingResults | Where-Object { $_.Success }).Count
        $totalTargets = $config.ping_targets.Count
        $currentLatencies = $pingResults | Where-Object { $_.Success } | Select-Object -ExpandProperty AvgLatency
        $avgLatency = if ($currentLatencies) { ($currentLatencies | Measure-Object -Average).Average } else { -1 }

        $packetLoss = ((($totalTargets - $successCount) / $totalTargets) * 100)
        $packetLossHistory += $packetLoss
        
        if ($avgLatency -ge 0) {
            $latencyHistory += $avgLatency
        }

        if ($packetLossHistory.Count -gt 10) {
            $packetLossHistory = $packetLossHistory[1..$packetLossHistory.Count]
        }
        if ($latencyHistory.Count -gt 10) {
            $latencyHistory = $latencyHistory[1..$latencyHistory.Count]
        }

        $avgLoss = ($packetLossHistory | Measure-Object -Average).Average
        $avgHistoryLatency = if ($latencyHistory) { ($latencyHistory | Measure-Object -Average).Average } else { -1 }
        $currentTime = [int64](Get-Date -UFormat %s)

        # 检查勿扰时段状态
        $currentDnd = Test-DoNotDisturb -DndConfig $config.do_not_disturb
        if ($script:lastDndState -and -not $currentDnd -and $script:pendingMessages.Count -gt 0) {
            Write-Log "勿扰时段结束，发送延迟通知摘要..." -Level "INFO"
            Send-Summary
        }
        $script:lastDndState = $currentDnd

        # 检测网卡变化
        $currentAdapter = Get-DefaultAdapter
        $wifiStatus = Get-WifiStatus
        $adapterSummary = Get-AdapterSummary -Adapter $currentAdapter -Wifi $wifiStatus

        if ($monitorAdapter -and $script:lastAdapter -and $currentAdapter.Name -ne $script:lastAdapter.Name) {
            $changeMsg = "🔄 出网网卡切换`n$($script:lastAdapter.Name) ($($script:lastAdapter.IPAddress)) → $($currentAdapter.Name) ($($currentAdapter.IPAddress))"
            if ($wifiStatus.Connected) {
                $changeMsg += "`nWiFi: $($wifiStatus.SSID) 信号 $($wifiStatus.Signal)"
            } elseif ($script:lastAdapter.Name -match "WiFi|WLAN|无线" -or $currentAdapter.Name -match "WiFi|WLAN|无线") {
                $changeMsg += "`nWiFi 状态: $($wifiStatus.State)"
            }
            Write-Log $changeMsg -Level "WARNING"
            Show-Notification -Title "网卡切换" -Message $changeMsg

            if ($currentDnd) {
                $script:pendingMessages += [PSCustomObject]@{
                    Type = "adapter_change"
                    Timestamp = Get-Date
                    FromName = $script:lastAdapter.Name
                    ToName = $currentAdapter.Name
                }
                Write-Log "[勿扰] 网卡切换通知已延迟发送" -Level "INFO"
            } elseif ($currentTime - $lastAdapterAlertTime -ge $config.alert_cooldown) {
                if (Send-DingtalkMessage -Webhook $config.dingtalk_webhook -Secret $config.dingtalk_secret -Message $changeMsg) {
                    $lastAdapterAlertTime = $currentTime
                }
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

            if ($currentDnd) {
                $script:pendingMessages += [PSCustomObject]@{
                    Type = "disconnect"
                    Timestamp = $lastDisconnectTime
                    Loss = $avgLoss
                    AdapterInfo = "$($currentAdapter.Name) ($($currentAdapter.IPAddress))"
                }
                Write-Log "[勿扰] 网络断开通知已延迟发送" -Level "INFO"
            } elseif ($currentTime - $lastAlertTime -ge $config.alert_cooldown) {
                if (Send-DingtalkMessage -Webhook $config.dingtalk_webhook -Secret $config.dingtalk_secret -Message $message) {
                    $lastAlertTime = $currentTime
                }
            }
        }
        # 检测网络恢复
        elseif (($avgLoss -lt $config.packet_loss_threshold -or $successCount -eq $totalTargets) -and -not $isConnected) {
            $isConnected = $true
            $duration = (Get-Date) - $lastDisconnectTime
            $durationStr = "{0:HH:mm:ss}" -f ([datetime]$duration.Ticks)

            $message = "✅ 网络已恢复!`n断开时长: $durationStr`n累计断开次数: $disconnectCount 次`n$adapterSummary"
            Write-Log $message -Level "INFO"
            Show-Notification -Title "网络恢复" -Message $message

            if ($currentDnd) {
                $script:pendingMessages += [PSCustomObject]@{
                    Type = "recover"
                    Timestamp = Get-Date
                    Duration = $durationStr
                    AdapterInfo = "$($currentAdapter.Name) ($($currentAdapter.IPAddress))"
                }
                Write-Log "[勿扰] 网络恢复通知已延迟发送" -Level "INFO"
            } elseif ($currentTime - $lastAlertTime -ge $config.alert_cooldown) {
                if (Send-DingtalkMessage -Webhook $config.dingtalk_webhook -Secret $config.dingtalk_secret -Message $message) {
                    $lastAlertTime = $currentTime
                }
            }
        }
        # 网络不稳定预警
        elseif ($isConnected -and $avgLoss -gt $config.unstable_threshold) {
            Write-Log "⚠️ 网络不稳定，平均丢包率: $($avgLoss.ToString('F1'))%" -Level "WARNING"

            if ($currentDnd) {
                $lastUnstable = $script:pendingMessages | Where-Object { $_.Type -eq "unstable" } | Select-Object -Last 1
                if (-not $lastUnstable -or ((Get-Date) - $lastUnstable.Timestamp).TotalSeconds -ge $config.alert_cooldown) {
                    $script:pendingMessages += [PSCustomObject]@{
                        Type = "unstable"
                        Timestamp = Get-Date
                        Loss = $avgLoss
                    }
                    Write-Log "[勿扰] 不稳定预警已延迟发送" -Level "INFO"
                }
            } elseif ($currentTime - $lastAlertTime -ge $config.alert_cooldown) {
                $message = "⚠️ 网络预警`n时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n平均丢包率: $($avgLoss.ToString('F1'))%`n建议检查网络连接"
                if (Send-DingtalkMessage -Webhook $config.dingtalk_webhook -Secret $config.dingtalk_secret -Message $message) {
                    $lastAlertTime = $currentTime
                }
            }
        }

        # 延迟过高预警
        if ($isConnected -and $avgHistoryLatency -ge $config.latency_warning_threshold -and $avgHistoryLatency -gt 0) {
            Write-Log "⚠️ 网络延迟过高，平均延迟: $($avgHistoryLatency.ToString('F0'))ms" -Level "WARNING"

            if ($currentDnd) {
                $lastLatency = $script:pendingMessages | Where-Object { $_.Type -eq "latency" } | Select-Object -Last 1
                if (-not $lastLatency -or ((Get-Date) - $lastLatency.Timestamp).TotalSeconds -ge $config.alert_cooldown) {
                    $script:pendingMessages += [PSCustomObject]@{
                        Type = "latency"
                        Timestamp = Get-Date
                        Latency = $avgHistoryLatency
                    }
                    Write-Log "[勿扰] 延迟预警已延迟发送" -Level "INFO"
                }
            } elseif ($currentTime - $lastLatencyAlertTime -ge $config.alert_cooldown) {
                $message = "⏱️ 延迟预警`n时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n平均延迟: $($avgHistoryLatency.ToString('F0'))ms`n阈值: $($config.latency_warning_threshold)ms"
                if (Send-DingtalkMessage -Webhook $config.dingtalk_webhook -Secret $config.dingtalk_secret -Message $message) {
                    $lastLatencyAlertTime = $currentTime
                }
            }
        }

        # 日志滚动检查
        Rotate-Log -LogFile $config.log_file -MaxSizeMB $config.log_max_size_mb -MaxBackups $config.log_max_backups

        Start-Sleep -Seconds $config.ping_interval
    }
}

# 启动监控
Monitor-Network
