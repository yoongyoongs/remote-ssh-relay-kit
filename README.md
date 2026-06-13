# 远程 SSH 中继工具包

这是一个面向 Windows 和 macOS 目标机器的远程 SSH 访问工具包，适用于目标机器没有公网 IP、处于家用路由器或普通 NAT 网络后的场景。

它的核心思路很简单：

1. 你先准备一台带公网 IP 的 Linux 中转服务器。
2. 目标机器主动向这台服务器建立反向 SSH 隧道。
3. 目标机器把可直接连接的 SSH 命令显示出来。
4. 你在自己的电脑上用私钥连入目标机器。

## 目录说明

- `server/`：Linux 中转服务器程序与部署脚本
- `windows/`：Windows 一键启动程序
- `mac/`：macOS 一键启动程序
- `scripts/`：打包、配置注入、自动部署辅助脚本
- `docs/`：中文文档

## 文档导航

- [总体设计文档](D:/code/remote-ssh-relay-kit/docs/01-总体设计文档.md)
- [Linux 部署文档](D:/code/remote-ssh-relay-kit/docs/02-Linux部署文档.md)
- [Windows 使用文档](D:/code/remote-ssh-relay-kit/docs/03-Windows使用文档.md)
- [macOS 使用文档](D:/code/remote-ssh-relay-kit/docs/04-macOS使用文档.md)
- [工作状态文档](D:/code/remote-ssh-relay-kit/docs/05-工作状态文档.md)

## 当前安全边界

- 客户端包内不放中转服务器的 root 密码。
- 每台目标机器都会生成自己的设备密钥，用它连接中转服务器。
- 中转服务器上的 `tunnel` 账号只用于反向端口转发，不承载业务程序。
- 你连接目标机器时使用的是你自己的 SSH 私钥，而不是服务器密码。
