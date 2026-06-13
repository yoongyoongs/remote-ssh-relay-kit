# Linux 部署文档

## 1. 部署目标

本项目的 Linux 部署对象，是一台带公网 IP 的中转服务器。它需要完成两件事：

1. 提供设备注册接口
2. 承接目标机器发起的反向 SSH 隧道

## 2. 环境要求

建议环境：

- Ubuntu 22.04 及以上，或其他常见 Debian 系 Linux
- 已开放公网入站端口：
  - `22`：SSH
  - `8787`：注册 API
  - `24000-24999`：目标机器反向映射端口范围

## 3. 服务器目录说明

默认安装目录：

```text
/opt/remote-ssh-relay
```

主要文件：

- `/opt/remote-ssh-relay/server/relay-server.mjs`
- `/opt/remote-ssh-relay/relay.env`
- `/opt/remote-ssh-relay/state/devices.json`
- `/home/tunnel/.ssh/authorized_keys`

## 4. 自动部署方式

本仓库提供自动部署脚本：

```powershell
cd D:\code\remote-ssh-relay-kit
npm install
node .\scripts\deploy-relay.mjs `
  --host 106.13.171.166 `
  --user root `
  --password 你的服务器密码 `
  --enroll-code 你的注册码
```

脚本会做这些事情：

1. 上传服务端文件到服务器
2. 安装或检查 Node.js
3. 创建 `tunnel` 账号
4. 生成服务目录
5. 安装 systemd 服务
6. 写入 `relay.env`
7. 合并 `sshd_config` 规则
8. 启动中转注册服务
9. 访问本机 `health` 接口做校验

## 5. 手动部署方式

如果你想手工部署，可以按这个流程来：

### 5.1 上传服务端文件

把下面几个文件传到服务器：

- `server/relay-server.mjs`
- `server/install-server.sh`
- `server/relay.env.sample`
- `server/sshd_config.sample`

### 5.2 执行安装脚本

```bash
chmod +x install-server.sh
./install-server.sh
```

### 5.3 编辑环境变量文件

编辑：

```bash
/opt/remote-ssh-relay/relay.env
```

示例：

```ini
API_BIND=0.0.0.0
API_PORT=8787
RELAY_HOST=106.13.171.166
RELAY_SSH_PORT=22
RELAY_USER=tunnel
ENROLL_CODES=CHANGE-ME
PORT_RANGE_START=24000
PORT_RANGE_END=24999
STATE_PATH=/opt/remote-ssh-relay/state/devices.json
AUTH_KEYS_PATH=/home/tunnel/.ssh/authorized_keys
LEASE_HOURS=24
```

## 6. SSH 配置

把 `server/sshd_config.sample` 中的内容合并到：

```bash
/etc/ssh/sshd_config
```

然后重启 SSH：

```bash
systemctl restart ssh || systemctl restart sshd
```

## 7. systemd 服务

安装脚本会创建：

```text
/etc/systemd/system/remote-ssh-relay.service
```

启动命令：

```bash
systemctl enable --now remote-ssh-relay
systemctl status remote-ssh-relay
```

## 8. 健康检查

服务正常后，执行：

```bash
curl http://127.0.0.1:8787/health
```

正常返回：

```json
{"ok":true,"service":"remote-ssh-relay"}
```

## 9. 防火墙与安全组

除了系统本机配置，还需要在云厂商安全组里放行：

- `22/tcp`
- `8787/tcp`
- `24000-24999/tcp`

如果安全组没有放行，客户端就算注册成功，也可能无法建立反向隧道，或者你无法从外部连接到映射端口。

## 10. 上线建议

1. 注册码按批次轮换，不要长期固定。
2. 建议单独为该服务器准备用途明确的机器，不和其他高敏感服务混用。
3. 推荐定期备份 `/opt/remote-ssh-relay/state/devices.json`。
4. 建议后续增加 HTTPS、审计日志和断线回收机制。
