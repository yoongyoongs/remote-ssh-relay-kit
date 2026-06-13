# 远程 SSH 中继工具包

这是一个面向 Windows 和 macOS 目标机器的远程 SSH 接入工具包，适用于目标机器没有公网 IP、处于 NAT 或家用路由器后的场景。

它的核心思路是：

1. 你先准备一台带公网 IP 的 Linux 中转服务器。
2. 目标机器主动向中转服务器建立反向 SSH 隧道。
3. 目标机器把最终可连接的 SSH 命令显示出来。
4. 你在自己的电脑上用私钥连入目标机器。

## 目录说明

- `server/`：中转服务器程序与部署脚本
- `windows/`：Windows 一键启动程序
- `mac/`：macOS 一键启动程序
- `scripts/`：配置注入、打包、自动部署脚本
- `docs/`：中文文档

## 这次重新设计后的重点

这版重点强化了 Windows 端的启动体验：

1. 如果目标电脑没有安装 `OpenSSH Server`，程序会自动安装。
2. 用户点击一键启动后，会先看到一个主控窗口。
3. 主控窗口会显示当前流程、结果状态、以及详细日志。
4. 安装 `OpenSSH Server` 时支持两种模式：
   - 后台安装
   - 弹出单独安装窗口
5. 无论选择哪种安装模式，主控窗口都会持续显示安装信息。

## Windows 端当前结构

Windows 端由三部分组成：

- `start-remote-ssh.bat`：一键启动入口
- `RemoteSshApp.ps1`：前台主控窗口，负责显示流程与日志
- `RemoteSshWorker.ps1`：提权后的后台执行器
- `InstallOpenSsh.ps1`：仅在缺少 OpenSSH 时调用的独立安装器

## 核心配置项

Windows `config.ini` 新增了与安装行为相关的配置：

- `SHOW_WORKER_WINDOW=false`
  - 是否显示后台执行器窗口
- `INSTALL_OPENSSH_MODE=hidden`
  - `hidden`：后台安装 OpenSSH
  - `window`：弹出单独 PowerShell 窗口安装 OpenSSH
- `FORCE_INSTALL_OPENSSH_IN_DRY_RUN=false`
  - 仅用于演练测试，强制模拟“系统未安装 OpenSSH”的路径

## 文档导航

- `docs/01-总体设计文档.md`
- `docs/02-Linux部署文档.md`
- `docs/03-Windows使用文档.md`
- `docs/04-macOS使用文档.md`
- `docs/05-工作状态文档.md`
