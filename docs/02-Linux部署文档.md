# Linux 部署文档

本文档用于部署中转服务器。

当前联调服务器信息：

- 公网 IP：`106.13.171.166`
- 管理账号：`root`
- 中继登录用户：`tunnel`
- API 服务名：`remote-ssh-relay`
- API 端口：`8787`

## 1. 服务器职责

这台 Linux 服务器负责两件事：

1. 提供注册接口，给 Windows 或 macOS 目标机分配远程端口。
2. 作为 SSH 反向隧道的落点，让你从自己的电脑再 SSH 进目标机。

## 2. 部署目录

部署完成后，服务器上会出现这些路径：

- 程序目录：`/opt/remote-ssh-relay`
- 主程序：`/opt/remote-ssh-relay/server/relay-server.js`
- 环境文件：`/opt/remote-ssh-relay/relay.env`
- 状态文件：`/opt/remote-ssh-relay/state/devices.json`
- 服务文件：`/etc/systemd/system/remote-ssh-relay.service`
- 中继用户公钥表：`/home/tunnel/.ssh/authorized_keys`

## 3. 必备开放项

这一步非常重要。

除了 SSH 的 `22` 端口，还必须在云服务器控制台放行 `8787/TCP`，否则：

1. 目标机无法调用 `/api/enroll`
2. 你的本机也无法访问健康检查接口
3. Windows 一键启动会在“注册到中继服务器”这一步失败

建议至少放行：

- `22/TCP`
- `8787/TCP`
- 远程端口区间，例如 `24000-24999/TCP`

其中：

- `8787` 给启动器注册用
- `24000-24999` 给每台目标机的反向 SSH 映射端口用

## 4. 一键部署方式

本项目已经提供自动部署脚本：

```bash
node ./scripts/deploy-relay.mjs \
  --host 106.13.171.166 \
  --user root \
  --password '你的 root 密码' \
  --relay-host 106.13.171.166 \
  --relay-user tunnel \
  --api-port 8787 \
  --relay-ssh-port 22 \
  --enroll-code RLY-20260613-7R4KX9 \
  --port-start 24000 \
  --port-end 24999
```

## 5. 手工部署方式

如果你要手工部署，顺序如下：

1. 上传 `server/relay-server.js`
2. 上传 `server/install-server.sh`
3. 上传 `server/sshd_config.sample`
4. 上传 `server/relay.env.sample`
5. 执行安装脚本
6. 写入正式 `relay.env`
7. 追加 `sshd_config.sample` 中的限制配置
8. 重启 `ssh/sshd`
9. 启动 `remote-ssh-relay.service`

## 6. 当前服务配置重点

`relay.env` 里至少要确认这些值：

```ini
API_BIND=0.0.0.0
API_PORT=8787
RELAY_HOST=106.13.171.166
RELAY_SSH_PORT=22
RELAY_USER=tunnel
ENROLL_CODES=RLY-20260613-7R4KX9
PORT_RANGE_START=24000
PORT_RANGE_END=24999
STATE_PATH=/opt/remote-ssh-relay/state/devices.json
AUTH_KEYS_PATH=/home/tunnel/.ssh/authorized_keys
LEASE_HOURS=24
```

## 7. 当前已验证结果

在 2026-06-13 已确认：

1. `remote-ssh-relay.service` 正常运行。
2. `ss -lntp | grep 8787` 显示服务监听 `0.0.0.0:8787`。
3. `curl http://127.0.0.1:8787/health` 返回：

```json
{"ok":true,"service":"remote-ssh-relay"}
```

## 8. 当前未完成项

截至 2026-06-13，公网访问还存在一个外部问题：

1. `curl http://106.13.171.166:8787/health` 在服务器自身会超时
2. 你的 Windows 本机访问同一地址也会超时
3. 这更像是云安全组或云防火墙未放开 `8787/TCP`

也就是说，应用本身已经起来了，但公网入口还没完全放通。

## 9. 排障命令

查看服务状态：

```bash
systemctl --no-pager --full status remote-ssh-relay
```

查看监听端口：

```bash
ss -lntp | grep 8787
```

查看本机健康检查：

```bash
curl -i http://127.0.0.1:8787/health
```

查看公网健康检查：

```bash
curl -i http://106.13.171.166:8787/health
```

查看 SSH 是否监听：

```bash
ss -lntp | grep :22
```

## 10. 建议的下一步

1. 在云服务器控制台明确放行 `8787/TCP`
2. 放行 `24000-24999/TCP`
3. 再从 Windows 本机重新验证 `/health`
4. 通过 Windows 一键启动完成一次真实注册和反向 SSH 建链
