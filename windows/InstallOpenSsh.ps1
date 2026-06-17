param(
    [Parameter(Mandatory = $true)]
    [string]$LogPath
)

$ErrorActionPreference = "Stop"
$capabilityName = "OpenSSH.Server~~~~0.0.1.0"

function Resolve-FriendlyErrorMessage {
    param([string]$Message)

    if ((($Message) -match "^\s*$")) {
        return "发生未知错误。"
    }
    if ($Message -match "requires elevation") {
        return "当前安装操作需要管理员权限，请通过主程序启动，或使用管理员权限重新运行。"
    }
    return $Message
}

function Write-InstallLog {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "s"), $Level, $Message
    if (-not (Test-Path -LiteralPath $LogPath)) {
        Set-Content -LiteralPath $LogPath -Value $line -Encoding utf8
    } else {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
    }
    Write-Host $line
}

function Get-CapabilityState {
    if ($null -eq (Get-Command "Get-WindowsCapability" -ErrorAction SilentlyContinue)) {
        throw "当前系统不支持通过 Windows 可选功能自动安装 OpenSSH Server。Windows 7 通常需要先手工安装 Win32-OpenSSH，并确认 sshd 服务存在后再运行本工具。"
    }
    $capability = Get-WindowsCapability -Online -Name $capabilityName -ErrorAction Stop
    return $capability.State
}

function Run-DismFallback {
    $stdoutPath = Join-Path ([System.IO.Path]::GetDirectoryName($LogPath)) "install-openssh-dism.stdout.log"
    $stderrPath = Join-Path ([System.IO.Path]::GetDirectoryName($LogPath)) "install-openssh-dism.stderr.log"
    foreach ($path in @($stdoutPath, $stderrPath)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }

    Write-InstallLog "准备改用 DISM.exe 安装 OpenSSH Server。" "WARN"
    $args = @(
        "/Online",
        "/Add-Capability",
        "/CapabilityName:$capabilityName",
        "/NoRestart"
    )
    if ($null -eq (Get-Command "dism.exe" -ErrorAction SilentlyContinue)) {
        throw "当前系统找不到 DISM.exe，无法自动安装 OpenSSH Server。"
    }
    $proc = Start-Process -FilePath "dism.exe" -ArgumentList $args -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if (Test-Path -LiteralPath $stdoutPath) {
        foreach ($line in Get-Content -LiteralPath $stdoutPath) {
            if ((($line) -match "\S")) {
                Write-InstallLog $line
            }
        }
    }
    if (Test-Path -LiteralPath $stderrPath) {
        foreach ($line in Get-Content -LiteralPath $stderrPath) {
            if ((($line) -match "\S")) {
                Write-InstallLog $line "WARN"
            }
        }
    }
    if ($proc.ExitCode -ne 0) {
        throw ("DISM.exe 安装失败，退出码：{0}" -f $proc.ExitCode)
    }
}

try {
    Write-InstallLog "OpenSSH 安装器已启动。"
    $state = Get-CapabilityState
    Write-InstallLog "当前 OpenSSH Server 组件状态：$state"
    if ($state -eq "Installed") {
        Write-InstallLog "系统已经安装 OpenSSH Server，无需重复安装。"
        exit 0
    }

    Write-InstallLog "开始调用 Windows 可选功能安装 OpenSSH Server，这一步可能持续几分钟。"
    try {
        $result = Add-WindowsCapability -Online -Name $capabilityName -ErrorAction Stop
        Write-InstallLog ("安装命令返回状态：RestartNeeded={0}" -f $result.RestartNeeded)
    } catch {
        Write-InstallLog ("Add-WindowsCapability 执行失败：{0}" -f (Resolve-FriendlyErrorMessage -Message $_.Exception.Message)) "WARN"
        Run-DismFallback
    }

    Start-Sleep -Seconds 2
    $state = Get-CapabilityState
    Write-InstallLog "安装结束后再次检查组件状态。"
    Write-InstallLog "当前 OpenSSH Server 组件状态：$state"
    if ($state -ne "Installed") {
        throw "OpenSSH Server 安装完成后状态仍然不是 Installed。"
    }

    Write-InstallLog "OpenSSH Server 安装完成。"
} catch {
    Write-InstallLog ("OpenSSH 安装失败：{0}" -f (Resolve-FriendlyErrorMessage -Message $_.Exception.Message)) "ERROR"
    throw
}









