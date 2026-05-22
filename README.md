# 网络监控程序 v2.0.0 (PowerShell 版本)

一款轻量级的网络监控工具，支持 Windows 系统，无需安装 Python。支持多类型网络探测、网卡级状态感知、钉钉加密通知、Web 状态面板和结构化日志。

## ✨ 功能特性

### 网络探测
- **多类型探测**：支持 Ping、DNS、HTTP、TCP 四种探测方式，不只是 ICMP 通不通
- **并行化探测**：使用 RunspacePool 真正实现多目标并行探测，可配置工作线程数
- **重试机制**：探测失败自动重试，减少误判
- **延迟预警**：网络延迟过高时提前预警（仅基于 Ping 延迟，排除 HTTP/DNS 干扰）

### 网卡感知
- **出网网卡检测**：实时显示当前承担流量的网卡及其 IP
- **WiFi 状态**：检测 WiFi 连接状态、SSID、信号强度、认证状态
- **网卡切换告警**：当默认出网网卡发生变化时即时通知（例如 WiFi 掉线后切到有线）

### 通知系统
- **本地通知**：网络断开时播放声音 + 系统弹窗提醒（不依赖网络）
- **钉钉通知**：网络异常和恢复时发送钉钉消息（异步发送，不阻塞探测循环）
- **密钥加密**：钉钉 Secret 和 Webhook 均使用 Windows DPAPI 加密存储，不存明文
- **勿扰模式**：支持自定义时段，勿扰期间钉钉消息延迟发送，结束后统一摘要

### 数据与面板
- **Web 状态面板**：每轮探测后自动生成 `status.html`，浏览器打开即可查看实时状态
- **结构化事件日志**：JSON Lines 格式记录每次探测和事件，支持按日滚动、按大小分片、自动清理过期文件
- **日报功能**：一键生成指定日期的网络质量日报
- **日志记录**：所有事件记录到文本日志，支持自动滚动

### 运维便利
- **配置热重载**：修改 `config.json` 后自动生效，无需重启（含空文件保护）
- **守护进程**：确保监控程序持续运行，异常退出自动重启；正常退出（Ctrl+C）不重启
- **进程单例锁**：防止重复启动多个实例，避免文件竞争
- **首次配置向导**：首次启动自动引导输入配置
- **向后兼容**：自动迁移旧版 `ping_targets`、明文 `dingtalk_secret` 和 `dingtalk_webhook`

## 🚀 快速开始

### 1. 启动网络监控.bat（前台运行）

**适用场景：** 临时监控、开发调试、前台查看日志

直接双击 `启动网络监控.bat`：
- **首次启动**：PowerShell 会自动提示输入钉钉 Webhook 地址和 Secret，输入后自动保存配置
- **后续启动**：直接读取已保存的配置启动监控
- **实时显示**：在命令行窗口中实时显示网络状态、丢包率、延迟等日志信息
- **停止方式**：关闭窗口或按 `Ctrl+C`

**特点：**
- 前台运行，实时看到所有日志输出
- 便于调试和确认配置是否正确
- 窗口关闭后监控停止

### 2. 守护进程.bat（后台长期运行）

**适用场景：** 服务器挂机、24小时监控、无人值守、开机自启

双击 `守护进程.bat`：
- 监控程序异常退出时自动重启
- 按 `Ctrl+C` 正常退出后，守护进程也会停止（不会反复重启）
- 适合长时间无人值守运行
- 最小化窗口后可在后台持续运行

**特点：**
- 自动保活，程序崩溃/异常退出后自动重启
- 正常退出（Ctrl+C）不会重启
- 隐藏主程序窗口，通过守护进程窗口查看状态
- 适合长期挂机运行
- 按 `Ctrl+C` 停止（正常退出）

### 3. 开机自动启动（推荐）

将 `守护进程.bat` 添加为开机启动项：

**方法一：手动添加（推荐）**
1. 按 `Win + R`，输入 `shell:startup`，回车
2. 将 `守护进程.bat` 的**快捷方式**拖入该文件夹
3. 重启电脑后自动开始监控

**方法二：通过项目脚本添加**
运行项目根目录下的 `添加到开机启动.bat`，自动创建快捷方式。

**取消开机启动：**
1. 按 `Win + R`，输入 `shell:startup`，回车
2. 删除其中的 `网络监控守护进程.lnk` 快捷方式

### 4. 命令行参数

```powershell
powershell -ExecutionPolicy Bypass -File "NetworkMonitor.ps1" [参数]
```

| 参数 | 说明 |
|------|------|
| `[日期]` | 生成日报，如 `2026-05-11` 或 `today` |
| `-ConfigFile <路径>` | 指定配置文件路径（默认: config.json） |
| `-Silent` | 静默模式，不显示启动信息 |
| `-NoSound` | 禁用声音警报 |
| `-PingInterval <秒>` | 临时覆盖检测间隔 |
| `-Help` | 显示帮助信息 |

**示例：**
```powershell
# 静默模式运行，禁用声音
powershell -ExecutionPolicy Bypass -File "NetworkMonitor.ps1" -Silent -NoSound

# 使用自定义检测间隔
powershell -ExecutionPolicy Bypass -File "NetworkMonitor.ps1" -PingInterval 5

# 生成今日日报
powershell -ExecutionPolicy Bypass -File "NetworkMonitor.ps1" today

# 生成指定日期日报
powershell -ExecutionPolicy Bypass -File "NetworkMonitor.ps1" 2026-05-11

# 显示帮助
powershell -ExecutionPolicy Bypass -File "NetworkMonitor.ps1" -Help
```

## ⚙️ 配置说明

配置文件为 `config.json`（首次启动时自动生成）。

### 探测目标配置

```json
"targets": [
    { "name": "百度Ping", "type": "ping", "host": "www.baidu.com" },
    { "name": "GoogleDNS-Ping", "type": "ping", "host": "8.8.8.8" },
    { "name": "百度HTTP", "type": "http", "url": "https://www.baidu.com", "method": "HEAD" },
    { "name": "DNS测试", "type": "dns", "host": "www.baidu.com", "server": "8.8.8.8" },
    { "name": "TCP测试", "type": "tcp", "host": "1.1.1.1", "port": 53 }
]
```

| 类型 | 必需字段 | 可选字段 | 说明 |
|------|----------|----------|------|
| `ping` | `host` | — | 传统 ICMP ping |
| `dns` | `host` | `server` | DNS 解析测试，可指定 DNS 服务器 |
| `http` | `url` | `method` | HTTP 请求测试，默认 HEAD |
| `tcp` | `host`, `port` | — | TCP 连接测试 |

### 完整配置项

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `targets` | 见上方示例 | 探测目标列表（旧版 `ping_targets` 自动迁移） |
| `ping_interval` | `3` | 检测间隔（秒） |
| `ping_count` | `3` | 每次 ping 发送的包数量 |
| `ping_timeout` | `1000` | 探测超时时间（毫秒） |
| `retry_count` | `2` | 探测失败重试次数 |
| `packet_loss_threshold` | `50` | 网络断开阈值（%） |
| `unstable_threshold` | `30` | 网络不稳定预警阈值（%） |
| `latency_warning_threshold` | `200` | Ping 延迟警告阈值（毫秒） |
| `alert_cooldown` | `300` | 断网/不稳定告警冷却时间（秒） |
| `latency_alert_cooldown` | `3600` | 延迟告警独立冷却时间（秒） |
| `dingtalk_webhook` | `""` | 钉钉机器人 Webhook 地址（首次加载后自动加密迁移） |
| `dingtalk_secret_file` | `".dingtalk_secret"` | 加密密钥存储文件路径 |
| `enable_sound` | `true` | 是否启用声音警报 |
| `log_file` | `"network_monitor.log"` | 日志文件路径 |
| `log_max_size_mb` | `10` | 日志文件最大大小（MB） |
| `log_max_backups` | `5` | 保留的日志备份数量 |
| `do_not_disturb.enabled` | `true` | 是否启用勿扰模式 |
| `do_not_disturb.start_time` | `"22:00"` | 勿扰开始时间 |
| `do_not_disturb.end_time` | `"08:00"` | 勿扰结束时间 |
| `monitor_adapter_switch` | `true` | 是否监控网卡切换 |
| `enable_web_panel` | `false` | 是否生成 Web 状态面板 |
| `web_status_file` | `"status.html"` | Web 状态面板文件路径 |
| `enable_event_log` | `true` | 是否启用结构化事件日志 |
| `event_log_file` | `"network_events.jsonl"` | 事件日志基础文件名 |
| `parallel_workers` | `4` | 并行探测工作线程数（1 = 串行） |
| `event_log_max_age_days` | `30` | 事件日志保留天数（超过自动删除） |
| `event_log_max_size_mb` | `50` | 单日事件日志大小上限（MB） |

### 勿扰模式

在指定时间段内，本地通知（弹窗、声音）正常工作，但钉钉消息会被延迟发送，待勿扰时段结束后统一发送一条摘要。

**摘要示例：**
```
🌙 勿扰时段网络事件汇总
时间: 05-07 22:00 ~ 05-08 08:00

🔄 网卡切换 1 次
   23:15:33: WLAN → 以太网

⚠️ 网络断开 2 次
   首次: 22:15:33
   末次: 03:42:07
   出网网卡: 以太网 (192.168.1.100)

📊 不稳定预警 5 次
   平均丢包率: 33.3%

⏱️ 延迟过高预警 3 次
   平均延迟: 256ms

共 11 条事件被延迟通知
```

### Web 状态面板

启用后在项目目录生成 `status.html`，用浏览器打开即可查看：

- 当前网络状态（正常/断开）
- 出网网卡信息（名称、IP、类型）
- WiFi 连接状态（SSID、信号强度）
- 各探测目标的实时结果
- 今日断网统计

页面每 5 秒自动刷新，深色主题适合长时间开着看。

### 事件日志与日报

事件日志以 JSON Lines 格式存储，按日期自动拆分：

```
network_events_2026-05-11.jsonl
```

每行一个事件，包含 `probe`（探测）、`disconnect`（断网）、`recover`（恢复）、`adapter_change`（网卡切换）、`latency_alert`（延迟告警）等类型。

生成日报：
```powershell
powershell -ExecutionPolicy Bypass -File "NetworkMonitor.ps1" today
```

输出示例：
```
========== 网络监控日报 (2026-05-11) ==========

  断网次数:        2
  累计断网时长:    00:03:42
  网卡切换次数:    1
  延迟预警次数:    3
  平均延迟:        45.2 ms

  各目标探测统计:
    Cloudflare-Ping : 100% (120/120)
    DNS测试 : 98.3% (118/120)
    百度HTTP : 100% (120/120)
    百度Ping : 100% (120/120)

========================================
```

### 修改配置

直接编辑 `config.json`，保存后程序自动热重载，无需重启。或删除该文件后重新运行 `启动网络监控.bat` 进行重新配置。

## 📁 项目结构

```
windows-powershell/
├── NetworkMonitor.ps1          # 主程序
├── 启动网络监控.bat            # 双击启动脚本（含配置向导）
├── 守护进程.bat                # 守护进程脚本（自动重启）
├── 添加到开机启动.bat          # 一键添加到开机启动
├── config.example.json         # 配置示例（可提交 GitHub）
├── config.json                 # 本地配置文件（已加入 .gitignore）
├── .dingtalk_secret            # 加密后的钉钉密钥（已加入 .gitignore）
├── .dingtalk_webhook           # 加密后的钉钉 Webhook（已加入 .gitignore）
├── .gitignore                  # Git 忽略配置
├── .nm_normal_exit             # 正常退出标志文件（守护进程用，运行时生成）
├── status.html                 # Web 状态面板（运行时生成）
├── network_monitor.log         # 文本日志（运行时生成）
├── network_events_*.jsonl      # 结构化事件日志（运行时生成）
└── README.md                   # 说明文档
```

## 🛡️ 安全与编码

### GitHub 安全上传

上传到 GitHub 时，请确保：

1. **不要提交 `config.json`**（已在 `.gitignore` 中排除）
2. **不要提交 `.dingtalk_secret`**（已在 `.gitignore` 中排除）
3. **只提交 `config.example.json`**（不含敏感信息，作为配置模板）
4. **首次克隆后**，运行 `启动网络监控.bat` 输入自己的钉钉配置即可使用

### 密钥安全

- 钉钉 Secret 和 Webhook 均不再以明文存储在 `config.json` 中
- 首次输入后，程序使用 Windows DPAPI 加密保存到 `.dingtalk_secret` 和 `.dingtalk_webhook`
- 旧版配置中的明文 Secret 和 Webhook 会在首次加载时自动迁移并删除
- 如果不小心提交了密钥文件，请立即在钉钉后台重新生成机器人 Secret

### 关于文件编码（避免中文乱码）

| 文件 | 编码 | 原因 |
|------|------|------|
| `启动网络监控.bat` | **ASCII** | 仅包含英文命令，彻底避免编码问题 |
| `守护进程.bat` | **ASCII** | 仅包含英文命令 |
| `NetworkMonitor.ps1` | **UTF-8 with BOM** | PowerShell 识别 BOM 后可正确处理中文 |
| `config.json` | **UTF-8 with BOM** | 确保中文配置内容正确读写 |
| `config.example.json` | **UTF-8 with BOM** | 确保示例中的中文说明正确显示 |

**注意**：如果你用编辑器修改了这些文件，请务必保持上述编码格式，否则可能出现中文乱码。

## 📝 使用场景

1. **多网卡环境**：明确知道当前流量走哪张网卡，WiFi 认证超时也能及时发现
2. **远程服务器监控**：部署在服务器上，网络异常时及时通知
3. **家庭/办公网络监控**：监控网络稳定性，区分"物理断网"和"DNS/HTTP 层故障"

## 📧 工作原理

```
多目标并行探测 (Ping/DNS/HTTP/TCP)
         ↓
    计算丢包率和 Ping 平均延迟
         ↓
    ┌────┴────┐
    ↓         ↓
  网卡变化   丢包过高
    ↓         ↓
  切换通知   断网告警（本地+钉钉）
    ↓         ↓
  持续探测  ← 网络恢复 → 恢复通知
```

## 🛠️ 问题排查

### 守护进程退出行为

守护进程通过 `.nm_normal_exit` 标志文件判断监控程序是正常退出还是异常退出：

- **正常退出**（Ctrl+C、脚本正常结束）：守护进程读取到标志文件，自身也退出，不再重启
- **异常退出**（崩溃、未捕获异常、进程被 kill）：标志文件不会被创建，守护进程 5 秒后自动重启监控程序

### 常见错误

| 错误信息 | 原因 | 解决方案 |
|----------|------|----------|
| "<"运算符是为将来使用而保留的 | 文件编码错误 | 使用 UTF-8 with BOM 编码重新保存 |
| 无法加载配置文件 | 配置文件格式错误或为空 | 删除 `config.json` 重新运行 |
| 钉钉通知失败 | Webhook 或 Secret 配置错误 | 检查钉钉机器人配置 |
| 文件被另一个进程占用 | 多个实例同时运行 | 确保没有重复启动守护进程 |
| 网络监控程序已经在运行中 | 全局互斥锁检测到已有实例 | 关闭已有实例后再启动 |
| 守护进程反复重启 | `.nm_normal_exit` 文件残留 | 删除该文件后再启动守护进程 |

### 调试建议

1. 使用 `-Silent` 参数可减少控制台输出（日志仍写入文件）
2. 日志文件默认保存在 `network_monitor.log`
3. 事件日志保存在 `network_events_YYYY-MM-DD.jsonl`，可用文本编辑器或 JSON 工具查看
4. 遇到问题可先运行 `powershell -ExecutionPolicy Bypass -File "NetworkMonitor.ps1" -Help` 检查语法

## 📄 许可证

MIT License
