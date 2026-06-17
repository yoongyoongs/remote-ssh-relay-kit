# Remote SSH Relay Kit

这是一个给 Windows 和 macOS 目标机使用的远程 SSH 中继工具包。

它的目标很直接：

1. 你准备一台有公网 IP 的 Linux 中转服务器。
2. 对方只要双击一个 `bat` 或 `command/sh` 文件，就能在本机拉起 SSH 服务、注册到中继服务器、建立反向隧道。
3. 程序会把最终连接命令用中文显示出来，对方复制给你，你就能从自己的电脑发起 SSH 连接。

## 当前版本重点

这一版重点补强了 Windows 端的一键启动体验：

1. 如果目标机没有安装 `OpenSSH Server`，会自动安装。
2. 安装支持两种方式：
   - 后台静默安装
   - 另开一个 `cmd` 窗口安装
3. 主程序会持续显示中文流程、步骤状态和安装日志。
4. 中继服务端改成了兼容旧版 Node.js 的 CommonJS 版本。
5. 服务端新增了坏 JSON 请求的错误兜底，避免异常请求直接把接口打成 500。

## 目录说明

- `server/`：Linux 中转服务、`sshd` 配置样例、安装脚本
- `windows/`：Windows 一键启动程序
- `mac/`：macOS 一键启动程序
- `scripts/`：自动部署和打包脚本
- `docs/`：中文设计、部署、使用、测试、交接文档

## 文档导航

- [总体设计文档](docs/01-总体设计文档.md)
- [Linux 部署文档](docs/02-Linux部署文档.md)
- [Windows 使用文档](docs/03-Windows使用文档.md)
- [macOS 使用文档](docs/04-macOS使用文档.md)
- [工作状态文档](docs/05-工作状态文档.md)
- [交接文档](docs/06-交接文档.md)

## 2026-06-15 最新状态

截至 2026-06-15，项目已完成公网打通及全自动 Bootstrap 联调测试：

1. **公网通道全线放行**：服务器 `8787/TCP` 接口及 `24000-24999/TCP` 反向 SSH 隧道端口范围已在云服务器控制台完成安全组放通，外网连通性测试全部通过。
2. **Bootstrap 全自动引导功能就绪**：Windows 与 macOS 两端均已补齐免静态配置的 Bootstrap 模式，仅需配置统一的引导 Token 即可实现多机独立注册与端口自动分发，彻底防冲突。
3. **打包构建就绪**：包含自动化配置注入的打包脚本 `scripts/prepare-launchers.ps1` 执行无误，已在 `release/` 目录下生成就绪的启动包。

详细测试记录和后续动作见：

- [工作状态文档](docs/05-工作状态文档.md)
- [交接文档](docs/06-交接文档.md)

## 2026-06-17 Windows 7 启动诊断增强

针对 Windows 7 真机验证中出现的“主窗口一直停留在等待后台任务启动”问题，本次补充了启动阶段的兼容性与诊断能力：

1. 修复 PowerShell 2.0 / .NET 3.5 环境下残留的 `PSCustomObject` 与 `TcpClient.ConnectAsync()` 兼容问题。
2. 前台主程序新增后台执行器启动失败检测与 45 秒超时兜底，避免用户界面无限等待。
3. 失败时会自动在桌面生成 `RemoteSshRelay-Diagnostics-会话ID.zip` 诊断包，并打开资源管理器选中该文件，用户只需把该文件发给管理员。
4. Windows 默认配置已改为方案 B：API 接口直连公网 IP `106.13.171.166`，SSH 中继地址继续使用域名 `yoong-relay.ddnsgeek.com`。
5. Windows 7 不支持通过 Windows 可选功能自动安装 OpenSSH Server；如系统没有 `sshd` 服务，需要先手工安装 Win32-OpenSSH 或使用已预装 SSH 服务的环境。
