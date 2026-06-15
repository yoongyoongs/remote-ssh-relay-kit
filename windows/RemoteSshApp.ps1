param(
    [string]$ConfigPath = "$PSScriptRoot\config.ini"
)

$ErrorActionPreference = "Stop"

function Read-IniFile {
    param([string]$Path)
    $map = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#") -or $trimmed.StartsWith(";")) {
            continue
        }
        $parts = $trimmed -split "=", 2
        if ($parts.Count -eq 2) {
            $map[$parts[0].Trim()] = $parts[1].Trim()
        }
    }
    return $map
}

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    try {
        return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-RecentLogLines {
    param(
        [string]$Path,
        [int]$LineCount = 10
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }
    try {
        return @(Get-Content -LiteralPath $Path -Tail $LineCount -ErrorAction Stop)
    } catch {
        return @()
    }
}

function Get-StepTitle {
    param([string]$Id)
    switch ($Id) {
        "check_admin" { return "检查管理员权限" }
        "validate_config" { return "检查配置文件" }
        "fetch_connection_settings" { return "获取连接配置" }
        "check_openssh" { return "检查 OpenSSH Server" }
        "install_openssh" { return "安装 OpenSSH Server" }
        "start_sshd" { return "启动 sshd 服务" }
        "configure_firewall" { return "配置 Windows 防火墙" }
        "verify_local_ssh" { return "检查本机 SSH" }
        "generate_device_key" { return "生成设备密钥" }
        "write_authorized_keys" { return "写入管理员公钥" }
        "enroll_device" { return "注册到中转服务器" }
        "start_reverse_tunnel" { return "启动反向 SSH 隧道" }
        "verify_tunnel" { return "校验隧道状态" }
        default { return $Id }
    }
}

function Get-StepLabel {
    param([string]$Status)
    switch ($Status) {
        "success" { return "完成" }
        "failed" { return "失败" }
        "running" { return "进行中" }
        "skipped" { return "跳过" }
        default { return "等待" }
    }
}

function Get-StepMessage {
    param(
        [psobject]$Step
    )
    if ($Step.message) {
        return $Step.message
    }
    switch ($Step.status) {
        "running" {
            switch ($Step.id) {
                "install_openssh" { return "系统正在安装 OpenSSH，详细信息见下方日志" }
                "start_reverse_tunnel" { return "正在建立反向 SSH 隧道" }
                default { return "正在处理" }
            }
        }
        "success" { return "已经完成" }
        "failed" { return "执行失败" }
        "skipped" { return "已经跳过" }
        default { return "等待开始" }
    }
}

function Format-StepLine {
    param($Step)
    $label = Get-StepLabel -Status $Step.status
    $title = Get-StepTitle -Id $Step.id
    $message = Get-StepMessage -Step $Step
    return "[{0}] {1} - {2}" -f $label, $title, $message
}

function Get-ConfigValue {
    param(
        [hashtable]$Config,
        [string]$Key,
        [string]$DefaultValue
    )
    if ($Config.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace($Config[$Key])) {
        return $Config[$Key]
    }
    return $DefaultValue
}

$config = Read-IniFile -Path $ConfigPath
$runtimeRoot = Join-Path $env:LOCALAPPDATA "RemoteSshRelay\runtime"
$workerPath = Join-Path $PSScriptRoot "RemoteSshWorker.ps1"
$statusPath = Join-Path $runtimeRoot "status.json"
$resultPath = Join-Path $runtimeRoot "result.json"
$sessionId = (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + ([guid]::NewGuid().ToString("N").Substring(0, 8))
$showWorkerWindow = ((Get-ConfigValue -Config $config -Key "SHOW_WORKER_WINDOW" -DefaultValue "false").ToLowerInvariant() -eq "true")

New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
foreach ($path in @($statusPath, $resultPath, (Join-Path $runtimeRoot "worker.log"))) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

$workerArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", ('"{0}"' -f $workerPath),
    "-ConfigPath", ('"{0}"' -f $ConfigPath),
    "-RuntimeRoot", ('"{0}"' -f $runtimeRoot),
    "-SessionId", $sessionId
)

try {
    if ($showWorkerWindow) {
        Start-Process -FilePath "powershell.exe" -ArgumentList $workerArgs -Verb RunAs | Out-Null
    } else {
        Start-Process -FilePath "powershell.exe" -ArgumentList $workerArgs -Verb RunAs -WindowStyle Hidden | Out-Null
    }
} catch {
    Start-Process -FilePath "powershell.exe" -ArgumentList $workerArgs -Verb RunAs | Out-Null
}

while ($true) {
    Start-Sleep -Milliseconds 600
    $status = Read-JsonFile -Path $statusPath
    Clear-Host
    Write-Host "远程 SSH 接入工具"
    Write-Host "会话 ID: $sessionId"
    Write-Host ""

    if ($null -eq $status) {
        Write-Host "[进行中] 正在等待后台任务启动..."
    } else {
        foreach ($step in $status.steps) {
            Write-Host (Format-StepLine -Step $step)
        }
    }

    $detailLogPath = if ($null -ne $status -and $status.detail_log_path) { $status.detail_log_path } else { Join-Path $runtimeRoot "worker.log" }
    $detailLines = Get-RecentLogLines -Path $detailLogPath -LineCount 8
    Write-Host ""
    Write-Host "详细日志"
    if ($detailLines.Count -eq 0) {
        Write-Host "  正在等待日志输出..."
    } else {
        foreach ($line in $detailLines) {
            Write-Host ("  " + $line)
        }
    }

    if (Test-Path -LiteralPath $resultPath) {
        $result = Read-JsonFile -Path $resultPath
        Write-Host ""
        if ($result.ok) {
            Write-Host "连接已经准备完成。" -ForegroundColor Green
            Write-Host "请把下面这条命令发给管理员："
            Write-Host $result.connect_command -ForegroundColor Cyan
        } else {
            Write-Host "配置失败。" -ForegroundColor Red
            if ($result.user_message) {
                Write-Host $result.user_message
            }
            Write-Host $result.message
        }
        break
    }
}

Write-Host ""
Write-Host "按 Enter 键关闭窗口。"
[void][System.Console]::ReadLine()



