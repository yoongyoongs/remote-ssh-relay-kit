# Windows 使用文档

## 1. 适用对象

本文档用于指导目标用户在 Windows 电脑上使用一键启动程序。

目标用户需要做的事情很少：

1. 双击启动文件
2. 在管理员权限弹窗中点允许
3. 等待主窗口提示完成
4. 把最终显示出来的 SSH 命令发给管理员

## 2. 现在的启动体验

这版 Windows 启动器不是“点了以后黑盒运行”，而是：

1. 会出现一个主控窗口
2. 主控窗口会显示中文步骤状态
3. 主控窗口下方会显示详细日志
4. 如果系统没有 `OpenSSH Server`，会自动进入安装流程
5. 安装时日志会持续刷新在主控窗口里

## 3. 启动方式

双击：

```text
start-remote-ssh.bat
```

程序会拉起一个 PowerShell 主控窗口。

## 4. 程序会自动做什么

启动后，程序会按顺序执行：

1. 检查管理员权限
2. 检查系统是否安装 `OpenSSH Server`
3. 如未安装，自动安装 `OpenSSH Server`
4. 启动 `sshd`
5. 配置 Windows 防火墙
6. 检查本机 `127.0.0.1:22`
7. 生成设备密钥
8. 写入管理员公钥
9. 向中转服务器注册
10. 启动反向 SSH 隧道
11. 输出最终连接命令

## 5. OpenSSH 安装模式

通过 `config.ini` 控制：

```ini
INSTALL_OPENSSH_MODE=hidden
```

可选值：

- `hidden`
  - 在后台安装 OpenSSH
  - 主控窗口显示安装日志

- `window`
  - 单独弹出一个安装窗口
  - 主控窗口仍然显示安装日志

如果你希望用户只盯着主窗口看，就用 `hidden`。

如果你希望安装过程单独可见，就用 `window`。

## 6. 主窗口会显示什么

主窗口包含两部分：

### 6.1 步骤区

例如：

- 检查管理员权限
- 检查 OpenSSH Server
- 安装 OpenSSH Server
- 启动 sshd 服务
- 配置 Windows 防火墙
- 启动反向 SSH 隧道

每一步都会显示：

- 等待
- 进行中
- 完成
- 跳过
- 失败

### 6.2 详细日志区

当没有进入安装阶段时，这里显示后台执行器日志。

当进入 OpenSSH 安装阶段时，这里会切换显示安装日志，例如：

- 安装器已启动
- 正在检查组件状态
- 正在安装 OpenSSH Server
- 安装完成

## 7. 成功后的结果

如果执行成功，主窗口会提示：

```text
连接已经准备完成。
请把下面这条命令发给管理员：
ssh -p 24001 用户名@106.13.171.166
```

目标用户只需要把这条命令发给管理员即可。

## 8. 配置文件说明

文件：

```text
config.ini
```

关键字段：

- `RELAY_HOST`
- `RELAY_SSH_PORT`
- `ENROLL_API`
- `ENROLL_CODE`
- `ADMIN_PUBLIC_KEY`
- `DRY_RUN`
- `SHOW_WORKER_WINDOW`
- `INSTALL_OPENSSH_MODE`
- `FORCE_INSTALL_OPENSSH_IN_DRY_RUN`

## 9. 演练模式

如果只是想演示流程，不改系统，可以设置：

```ini
DRY_RUN=true
```

如果还想强制演示“系统未安装 OpenSSH 时的安装界面”，可以再加：

```ini
FORCE_INSTALL_OPENSSH_IN_DRY_RUN=true
```

这样即使当前电脑已经安装过 OpenSSH，也会模拟安装流程，并把安装日志显示出来。

## 10. 常见问题

### 10.1 点击后没反应

先确认是否弹出了管理员权限确认窗口。

### 10.2 安装阶段卡很久

这通常说明系统正在处理 Windows 可选功能，属于正常现象，主窗口下方日志会继续更新。

### 10.3 最终失败了

主窗口会提示失败，并建议把日志或截图发给管理员。

日志位置默认在：

```text
%LOCALAPPDATA%\RemoteSshRelay\runtime\
```

常见文件包括：

- `status.json`
- `result.json`
- `worker.log`
- `install-openssh.log`
