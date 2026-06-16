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

- `cmd`
  - 单独弹出一个 `cmd` 安装窗口
  - 主控窗口仍然显示安装日志

- `window`
  - 兼容旧配置
  - 实际效果等同于 `cmd`

如果你希望用户只盯着主窗口看，就用 `hidden`。

如果你希望安装过程单独可见，就用 `cmd`。

## 6. 主窗口会显示什么

主窗口采用结构化 ASCII 制表符边框布局，包含三部分：

### 6.1 标题状态头
- 显示系统徽标 `⚡ 远程协助连接助手 (Remote SSH)`。
- 标明本次运行生成的唯一会话 ID。

### 6.2 步骤区
例如：
- 检查管理员权限
- 检查配置文件
- 获取连接配置
- 检查 OpenSSH Server
- 安装 OpenSSH Server
- 启动 sshd 服务
- 配置 Windows 防火墙
- 启动反向 SSH 隧道
- 校验隧道状态

每一步都会以彩色符号和 Emoji 显示：
- `[  ○  ] 等待`：暗灰色，代表尚未执行。
- `[ ⏳/ ] 进行中`：亮黄色，并伴有**旋转沙漏/加载动画**（随时间交替更新，展现活跃状态）。
- `[  ✔  ] 成功`：亮绿色，勾号标识已顺利完成。
- `[  ❌ ] 失败`：亮红色，叉号警示，并中止后续操作。
- `[  ➖ ] 已跳过`：灰色，根据配置和系统状态跳过该步骤。

### 6.3 详细日志区
- 将底层的详细执行日志（如组件检测、注册进度、OpenSSH 安装包下载百分比等）封装在 `┌─ 最近活动日志 ──` 灰色边框面板内。
- 自动限制日志每行字符数，超长自动截断（`...`），保证排版绝不换行重叠。

## 7. 成功后的结果与自动复制

如果执行成功，主窗口会以绿色高亮框形式提示：

```text
========================================================================
 🎉 连接已成功建立！
========================================================================
 📋 连通命令已【自动复制】到您的剪贴板中！
 💬 请直接在聊天窗口中 粘贴 (Ctrl + V) 并发给协助您的管理员即可。
```

- **一键自动复制**：为了减轻远程人员的负担，成功后脚本会自动调用系统接口（`clip.exe`）将管理员需要连接的 SSH 命令拷贝到系统剪贴板。被协助用户无需用鼠标选中和点选复制，直接在聊天软件中按下 `Ctrl + V` 即可发送给管理员。


## 8. 配置文件说明

文件：

```text
config.ini
```

关键字段：

- `RELAY_HOST`: 中转服务器公网 IP 或域名。
- `RELAY_SSH_PORT`: 中转服务器 SSH 端口，默认为 22。
- `ENROLL_API`: 设备注册接口地址，如 `http://106.13.171.166:8787/api/enroll`。
- `BOOTSTRAP_API`: 动态引导接口地址，如 `http://106.13.171.166:8787/api/bootstrap`。
- `BOOTSTRAP_TOKEN`: 全自动 Bootstrap 模式下的引导令牌。如果填了此项，且 `ENROLL_CODE` 留空，则启动时会自动请求该接口拉取注册码与操作员公钥。
- `ENROLL_CODE`: 静态设备注册码。非 Bootstrap 模式下必须填写。若使用全自动 Bootstrap 模式，请保持留空。
- `ADMIN_PUBLIC_KEY`: 操作员/管理员的 SSH 公钥。非 Bootstrap 模式下必须填写。若使用全自动 Bootstrap 模式，请保持留空。
- `DRY_RUN`: 是否为演练模式（`true`/`false`）。若为 `true`，不会实际修改系统设置或建立隧道。
- `SHOW_WORKER_WINDOW`: 是否显示提权后的 Worker 命令行后台窗口（`true`/`false`），主要用于调试。
- `INSTALL_OPENSSH_MODE`: `hidden`（后台静默安装 OpenSSH）或 `cmd`（单独开窗口安装）。
- `FORCE_INSTALL_OPENSSH_IN_DRY_RUN`: 演练模式下是否强行模拟安装 OpenSSH。
- `DRY_RUN_USE_LIVE_RELAY`: 演练模式下是否调用真实的 API 进行注册和模拟反向隧道建立（便于联调接口）。
- `TUNNEL_RETRY_SECONDS`: 隧道断开后自动重新连接的间隔秒数。

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

### 10.4 启动提示“找不到指定模块”或“无法加载脚本”等报错

> [!IMPORTANT]
> **这通常是因为远程人员直接在 WinRAR / 360压缩 / Zip 预览窗口中双击运行了 `start-remote-ssh.bat`**。
>
> **解决方法**：
> 1. 关闭当前的运行窗口。
> 2. 鼠标右键点击 `launcher-kit-windows-v2.zip` 压缩包，选择 **“解压到当前文件夹”** 或 **“解压到 launcher-kit-windows-v2\”**。
> 3. 进入解压后的文件夹，双击运行 **`start-remote-ssh.bat`** 即可。

---

## 11. Windows 7 / PowerShell 2.0 / .NET 3.5 兼容性支持

为了支持较旧的客户端环境（如 Windows 7 SP1 默认携带的 PowerShell 2.0 和 .NET 3.5 框架），本套脚本已进行了深度兼容性适配：

* **JSON 解析与序列化模拟**：在不依赖 PowerShell 3.0+ 自带的 `ConvertFrom-Json` 和 `ConvertTo-Json` 的情况下，本程序利用了老系统自带的 .NET `JavaScriptSerializer` 重构了对应的 Mock 函数，自动处理服务端 API 的 JSON 数据交互。
* **网络请求兼容**：由于老版本没有 `Invoke-RestMethod` 模块，程序底层自动回退到 .NET `[System.Net.WebRequest]` 建立 HTTP 握手，确保顺利进行设备注册和端口绑定。
* **网络连通性模拟**：Windows 7 缺失 `Test-NetConnection` 指令，程序底层通过 .NET `[System.Net.Sockets.TcpClient]` 的连接方法对 `22` 端口建立套接字并反馈结果。
* **.NET 框架兼容**：移除了所有仅在 .NET 4.0+ 支持的 `[string]::IsNullOrWhiteSpace()` 校验，替换为底层的正则表达式匹配。
* **操作符兼容**：移除了 PowerShell 3.0 引入的 `-in` 与 `-notin` 操作符，全部重构为低版本支持的 `-contains` 与 `-notcontains`。
* **启动路径兜底**：增加了当 `$PSScriptRoot` 未定义时的自动定位兜底机制。

