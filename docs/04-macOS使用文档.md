# macOS 使用文档

## 1. 适用对象

本文档用于指导目标用户在 macOS 电脑上启动一键接入工具。

目标用户需要做的事情非常少：

1. 双击启动文件
2. 在需要时输入管理员密码
3. 把最后显示出来的 SSH 命令发给操作员

## 2. 启动前提

建议系统：

- macOS 12 或更高版本

程序首次运行可能会：

- 开启系统 Remote Login
- 检查本机 SSH 监听状态
- 写入操作员公钥
- 建立反向 SSH 隧道

## 3. 启动方式

双击：

```text
start-remote-ssh.command
```

如果系统因为安全策略不允许直接运行，可执行：

```bash
chmod +x start-remote-ssh.command
./start-remote-ssh.command
```

如果仍被隔离属性拦截，可以执行：

```bash
xattr -d com.apple.quarantine start-remote-ssh.command
```

## 4. 程序会做什么

macOS 启动器会依次完成：

1. 检查本机 `ssh` 客户端
2. 检查并启用 Remote Login
3. 检查本机 `127.0.0.1:22`
4. 生成设备密钥
5. 写入操作员公钥到 `~/.ssh/authorized_keys`
6. 调用中转服务器注册接口
7. 启动反向 SSH 隧道
8. 输出最终 SSH 命令

## 5. 成功后的表现

如果执行成功，终端会输出：

```text
Connection ready.
Send this command to the admin:
ssh -p 24001 用户名@106.13.171.166
```

把该命令发给操作员即可。

## 6. 配置文件说明

配置文件：

```text
config.ini
```

包含以下字段：

- `RELAY_HOST`: 中转服务器公网 IP 或域名。
- `RELAY_SSH_PORT`: 中转服务器 SSH 端口，默认为 22。
- `ENROLL_API`: 设备注册接口地址，如 `http://106.13.171.166:8787/api/enroll`。
- `BOOTSTRAP_API`: 动态引导接口地址，如 `http://106.13.171.166:8787/api/bootstrap`。
- `BOOTSTRAP_TOKEN`: 全自动 Bootstrap 模式下的引导令牌。如果填了此项，且 `ENROLL_CODE` 留空，则启动时会自动请求该接口拉取注册码与操作员公钥。
- `ENROLL_CODE`: 静态设备注册码。非 Bootstrap 模式下必须填写。若使用全自动 Bootstrap 模式，请保持留空。
- `ADMIN_PUBLIC_KEY`: 操作员/管理员的 SSH 公钥。非 Bootstrap 模式下必须填写。若使用全自动 Bootstrap 模式，请保持留空。
- `DRY_RUN`: 是否为演练模式（`true`/`false`）。若为 `true`，不会实际修改系统设置或建立隧道。

## 7. 演练模式

如果你只是想演示流程，可以设置：

```ini
DRY_RUN=true
```

这样脚本会模拟关键步骤，但不会真正修改系统 SSH 状态，也不会真正建立反向隧道。

## 8. 常见问题

### 8.1 提示没有权限开启 Remote Login

说明当前用户没有足够权限，需要用管理员账户运行，或者在系统设置里手动开启 Remote Login。

### 8.2 连接命令拿到了，但操作员仍连不上

重点排查：

1. 中转服务器映射端口是否已经放行
2. 反向 SSH 隧道是否实际建立成功
3. 本机用户名是否写对
4. 操作员私钥是否与 `ADMIN_PUBLIC_KEY` 对应

### 8.3 双击没有反应

可以直接在终端中运行脚本，便于看到报错信息。

## 9. 注意事项

1. 该工具默认依赖系统自带的 SSH/Remote Login 能力。
2. 如果目标机器不再需要远程访问，建议手动结束隧道进程并移除授权公钥。
3. 该工具更适合临时接入和排障场景。
