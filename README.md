# 网络监控程序 (PowerShell 版本)

一款轻量级的网络监控工具，支持 Windows 系统，无需安装 Python。

## ✨ 功能特性

- **智能网络检测**：多目标 ping 检测，计算平均丢包率
- **本地通知**：网络断开时播放声音 + 系统弹窗提醒（不依赖网络）
- **钉钉通知**：网络恢复后自动发送通知（解决断网无法通知的悖论）
- **预警机制**：网络不稳定时提前预警
- **日志记录**：所有事件记录到日志文件
- **首次配置向导**：首次启动自动引导输入钉钉配置

## 🚀 快速开始

### 1. 双击运行

直接双击 `启动网络监控.bat`：
- **首次启动**：PowerShell 会自动提示输入钉钉 Webhook 地址和 Secret，输入后自动保存配置
- **后续启动**：直接读取已保存的配置启动监控

### 2. 手动运行（高级）

```powershell
powershell -ExecutionPolicy Bypass -File "NetworkMonitor.ps1"
```

> 手动运行同样支持首次配置向导。

## ⚙️ 配置说明

配置文件为 `config.json`（首次启动时自动生成）：

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| `ping_targets` | `["www.baidu.com", "8.8.8.8", "1.1.1.1"]` | 要检测的目标列表 |
| `ping_interval` | `3` | 检测间隔（秒） |
| `packet_loss_threshold` | `50` | 网络断开阈值（%） |
| `unstable_threshold` | `30` | 网络不稳定预警阈值（%） |
| `alert_cooldown` | `300` | 钉钉通知冷却时间（秒） |
| `dingtalk_webhook` | `""` | 钉钉机器人 Webhook 地址 |
| `dingtalk_secret` | `""` | 钉钉机器人密钥（加签用） |
| `enable_sound` | `true` | 是否启用声音警报 |
| `log_file` | `"network_monitor.log"` | 日志文件路径 |

### 修改配置

直接编辑 `config.json`，或删除该文件后重新运行 `启动网络监控.bat` 进行重新配置。

## 📁 项目结构

```
windows-powershell/
├── NetworkMonitor.ps1      # 主程序
├── 启动网络监控.bat        # 双击启动脚本（含配置向导）
├── config.example.json     # 配置示例（不含敏感信息，可提交 GitHub）
├── config.json             # 本地配置文件（含敏感信息，已加入 .gitignore）
├── .gitignore              # Git 忽略配置
└── README.md               # 说明文档
```

## 🛡️ GitHub 安全上传

上传到 GitHub 时，请确保：

1. **不要提交 `config.json`**（已在 `.gitignore` 中排除，包含你的钉钉机器人密钥）
2. **只提交 `config.example.json`**（不含敏感信息，作为配置模板）
3. **首次克隆后**，运行 `启动网络监控.bat` 输入自己的钉钉配置即可使用

### 关于文件编码（避免中文乱码）

本项目涉及中文显示，不同文件使用了不同的编码策略以确保在 Windows 下不乱码：

| 文件 | 编码 | 原因 |
|------|------|------|
| `启动网络监控.bat` | **ASCII** | 仅包含英文命令，彻底避免编码问题；所有中文交互由 PowerShell 处理 |
| `NetworkMonitor.ps1` | **UTF-8 with BOM** | PowerShell 识别 BOM 后可正确处理中文 |
| `config.json` | **UTF-8 with BOM** | 确保中文配置内容正确读写 |
| `config.example.json` | **UTF-8 with BOM** | 确保示例中的中文说明正确显示 |

**注意**：如果你用编辑器修改了这些文件，请务必保持上述编码格式，否则可能出现中文乱码。

### 安全提示

- `config.json` 包含你的钉钉机器人密钥，**切勿泄露**
- 如果不小心提交了 `config.json`，请立即：
  1. 在钉钉后台重新生成机器人 Secret
  2. 从 Git 历史中删除该文件（可使用 `git filter-repo` 或 BFG Repo-Cleaner）

## 📝 使用场景

1. **远程服务器监控**：部署在服务器上，网络异常时及时通知
2. **家庭网络监控**：监控家庭网络状态
3. **办公网络监控**：确保办公网络稳定

## 📧 工作原理

```
网络正常 → 持续 ping 检测 → 丢包率上升 → 发送预警（钉钉）
       ↓
网络断开 → 本地声音+弹窗提醒 → 持续检测 → 网络恢复 → 发送恢复通知（钉钉）
```

## 📄 许可证

MIT License
