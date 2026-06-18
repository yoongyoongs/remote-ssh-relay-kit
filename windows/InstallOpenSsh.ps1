param(
    [Parameter(Mandatory = $true)]
    [string]$LogPath
)

$ErrorActionPreference = "Stop"
$capabilityName = "OpenSSH.Server~~~~0.0.1.0"

# Fallback definition for $PSScriptRoot on PowerShell 2.0
if ($null -eq $script:PSScriptRoot -or (($script:PSScriptRoot) -match "^\s*$")) {
    if ($null -ne $PSScriptRoot -and -not (($PSScriptRoot) -match "^\s*$")) {
        $script:PSScriptRoot = $PSScriptRoot
    } else {
        $script:PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
    }
}
if ($null -eq $script:PSScriptRoot -or (($script:PSScriptRoot) -match "^\s*$")) {
    $script:PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Path
}
if ($null -eq $script:PSScriptRoot -or (($script:PSScriptRoot) -match "^\s*$")) {
    $script:PSScriptRoot = [System.IO.Path]::GetFullPath((Get-Location))
}

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
    $proc = Start-Process -FilePath "dism.exe" -ArgumentList $args -PassThru -Wait -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
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

function Install-Win32OpenSSH-Fallback {
    # 1. 强制启用 TLS 1.2，避免下载时握手失败
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType](3072 -bor 768 -bor 192)
    } catch {}

    # 2. 判断系统架构 (64位 or 32位)
    $is64 = [Environment]::Is64BitOperatingSystem
    if ($null -eq $is64) {
        $is64 = ($env:PROCESSOR_ARCHITECTURE -eq "AMD64") -or ($env:PROCESSOR_ARCHITEW6432 -eq "AMD64")
    }
    $archText = "32位 (x86)"
    if ($is64) {
        $archText = "64位 (x64)"
    }
    Write-InstallLog "系统架构检测：$archText"

    # 3. 停止已有的 sshd 和 ssh-agent 服务，避免文件被占用导致复制失败
    try {
        $existingSshd = Get-Service -Name sshd -ErrorAction SilentlyContinue
        if ($null -ne $existingSshd) {
            Write-InstallLog "检测到系统已注册 sshd 服务。当前状态: $($existingSshd.Status)。"
            if ($existingSshd.Status -eq "Running") {
                Write-InstallLog "正在停止 sshd 服务以解除文件占用..."
                Stop-Service -Name sshd -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
        }
        $existingAgent = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
        if ($null -ne $existingAgent) {
            Write-InstallLog "检测到系统已注册 ssh-agent 服务。当前状态: $($existingAgent.Status)。"
            if ($existingAgent.Status -eq "Running") {
                Write-InstallLog "正在停止 ssh-agent 服务以解除文件占用..."
                Stop-Service -Name ssh-agent -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            }
        }
    } catch {
        Write-InstallLog "停止已有服务时发生警告：$($_.Exception.Message)" "WARN"
    }

    # 4. 准备下载链接
    if ($is64) {
        $zipUrl = "https://github.com/PowerShell/Win32-OpenSSH/releases/download/v8.9.0.0p1-Beta/OpenSSH-Win64.zip"
        $mirrors = @(
            "https://ghproxy.net/https://github.com/PowerShell/Win32-OpenSSH/releases/download/v8.9.0.0p1-Beta/OpenSSH-Win64.zip",
            "https://kkgithub.com/PowerShell/Win32-OpenSSH/releases/download/v8.9.0.0p1-Beta/OpenSSH-Win64.zip"
        )
    } else {
        $zipUrl = "https://github.com/PowerShell/Win32-OpenSSH/releases/download/v8.9.0.0p1-Beta/OpenSSH-Win32.zip"
        $mirrors = @(
            "https://ghproxy.net/https://github.com/PowerShell/Win32-OpenSSH/releases/download/v8.9.0.0p1-Beta/OpenSSH-Win32.zip",
            "https://kkgithub.com/PowerShell/Win32-OpenSSH/releases/download/v8.9.0.0p1-Beta/OpenSSH-Win32.zip"
        )
    }

    # 5. 获取本地离线安装包路径
    $localZipName = "OpenSSH-Win32.zip"
    if ($is64) {
        $localZipName = "OpenSSH-Win64.zip"
    }
    $localZipPath = Join-Path (Join-Path $script:PSScriptRoot "dep") $localZipName
    
    $tempZip = Join-Path $env:TEMP "OpenSSH.zip"
    if (Test-Path -LiteralPath $tempZip) {
        try { Remove-Item -LiteralPath $tempZip -Force } catch {}
    }

    $downloaded = $false
    
    # 优先使用本地离线包
    if (Test-Path -LiteralPath $localZipPath) {
        Write-InstallLog "检测到本地内置的离线安装包：$localZipPath，将直接使用进行离线安装。"
        try {
            Copy-Item -LiteralPath $localZipPath -Destination $tempZip -Force
            if (Test-Path -LiteralPath $tempZip) {
                $downloaded = $true
                Write-InstallLog "离线安装包成功加载并复制到临时目录。"
            }
        } catch {
            Write-InstallLog "复制本地安装包失败：$($_.Exception.Message)" "WARN"
        }
    }

    # 如果没有本地包，则通过网络下载
    if (-not $downloaded) {
        Write-InstallLog "未找到本地离线包或加载失败，开始尝试在线下载..."
        $webClient = New-Object System.Net.WebClient
        $webClient.Proxy = New-Object System.Net.WebProxy
        $urls = @()
        foreach ($m in $mirrors) { $urls += $m }
        $urls += $zipUrl

        foreach ($url in $urls) {
            Write-InstallLog "正在从下载源拉取包: $url"
            try {
                $webClient.DownloadFile($url, $tempZip)
                if (Test-Path -LiteralPath $tempZip) {
                    $downloaded = $true
                    Write-InstallLog "包下载成功。"
                    break
                }
            } catch {
                Write-InstallLog "连接该源失败: $($_.Exception.Message)" "WARN"
            }
        }
    }

    if (-not $downloaded) {
        throw "无法获取 OpenSSH 安装包（本地加载与所有在线下载源均失败）。"
    }

    # 6. 解压压缩包 (使用 Shell.Application)
    $tempExtractDir = Join-Path $env:TEMP "OpenSSH_extracted"
    if (Test-Path -LiteralPath $tempExtractDir) {
        try { Remove-Item -LiteralPath $tempExtractDir -Recurse -Force } catch {}
    }
    New-Item -ItemType Directory -Force -Path $tempExtractDir | Out-Null

    Write-InstallLog "正在静解压缩 OpenSSH 包..."
    $shell = New-Object -ComObject Shell.Application
    $zipFolder = $shell.NameSpace($tempZip)
    $targetFolder = $shell.NameSpace($tempExtractDir)
    if ($null -ne $zipFolder -and $null -ne $targetFolder) {
        $targetFolder.CopyHere($zipFolder.Items(), 16)
    } else {
        throw "创建解压命名空间失败。"
    }

    # 等待解压完成
    $attempts = 0
    $targetFileFound = $false
    while ($attempts -lt 40) {
        $found = Get-ChildItem -Path $tempExtractDir -Filter "install-sshd.ps1" -Recurse
        if ($found) {
            $targetFileFound = $true
            Start-Sleep -Seconds 3
            break
        }
        Start-Sleep -Seconds 1
        $attempts++
    }
    if (-not $targetFileFound) {
        throw "解压超时，未在解压目录中找到 install-sshd.ps1。"
    }
    Write-InstallLog "解压已完成。"

    # 7. 定位解压出来的目录并复制到 Program Files
    $extractedFolder = Join-Path $tempExtractDir "OpenSSH-Win64"
    if (-not (Test-Path -LiteralPath $extractedFolder)) {
        $extractedFolder = Join-Path $tempExtractDir "OpenSSH-Win32"
    }
    if (-not (Test-Path -LiteralPath $extractedFolder)) {
        $installScript = Get-ChildItem -Path $tempExtractDir -Filter "install-sshd.ps1" -Recurse | Select-Object -First 1
        if ($installScript) {
            $extractedFolder = $installScript.Directory.FullName
        }
    }

    if (-not (Test-Path -LiteralPath $extractedFolder)) {
        throw "未能在解压内容中定位到有效的 OpenSSH 目录。"
    }

    $destDir = "C:\Program Files\OpenSSH"
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    }

    Write-InstallLog "正在复制 OpenSSH 二进制文件至安装路径 $destDir..."
    Copy-Item -Path (Join-Path $extractedFolder "*") -Destination $destDir -Force -Recurse

    # 复制 VC++ 运行时 DLL 以解决 Windows 7 缺失依赖导致程序崩溃的问题
    $dllSuffix = "x86"
    if ($is64) {
        $dllSuffix = "x64"
    }
    $depDir = Join-Path $script:PSScriptRoot "dep"
    $vcruntimeSrc = Join-Path $depDir "vcruntime140_$dllSuffix.dll"
    $msvcpSrc = Join-Path $depDir "msvcp140_$dllSuffix.dll"

    if (Test-Path -LiteralPath $vcruntimeSrc) {
        Write-InstallLog "检测到内置 VC++ 运行时 vcruntime140_$dllSuffix.dll，正在复制到安装路径以解决加载依赖..."
        try {
            Copy-Item -LiteralPath $vcruntimeSrc -Destination (Join-Path $destDir "vcruntime140.dll") -Force
        } catch {
            Write-InstallLog "复制 vcruntime140.dll 失败：$($_.Exception.Message)" "WARN"
        }
    }
    if (Test-Path -LiteralPath $msvcpSrc) {
        Write-InstallLog "检测到内置 VC++ 运行时 msvcp140_$dllSuffix.dll，正在复制到安装路径以解决加载依赖..."
        try {
            Copy-Item -LiteralPath $msvcpSrc -Destination (Join-Path $destDir "msvcp140.dll") -Force
        } catch {
            Write-InstallLog "复制 msvcp140.dll 失败：$($_.Exception.Message)" "WARN"
        }
    }

    # 8. 运行安装脚本并进行服务兜底注册
    Write-InstallLog "正在调用 install-sshd.ps1 脚本注册 OpenSSH 服务..."
    $installScriptPath = Join-Path $destDir "install-sshd.ps1"
    $installOutputLog = Join-Path $destDir "install-sshd-run.log"
    
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScriptPath > $installOutputLog 2>&1
    
    # 验证并实施手动 SC 兜底注册
    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        Write-InstallLog "官方脚本注册 sshd 服务未成功，启动 sc.exe 兜底注册流。" "WARN"
        $sshdPath = Join-Path $destDir "sshd.exe"
        if (Test-Path -LiteralPath $sshdPath) {
            cmd.exe /c "sc.exe create sshd binPath= `"$sshdPath`" start= auto displayName= `"OpenSSH SSH Server`""
            cmd.exe /c "sc.exe description sshd `"OpenSSH SSH Server`""
            Start-Sleep -Seconds 1
        }
    }
    
    $agentService = Get-Service -Name ssh-agent -ErrorAction SilentlyContinue
    if ($null -eq $agentService) {
        Write-InstallLog "检测并补充注册 ssh-agent 服务..."
        $agentPath = Join-Path $destDir "ssh-agent.exe"
        if (Test-Path -LiteralPath $agentPath) {
            cmd.exe /c "sc.exe create ssh-agent binPath= `"$agentPath`" start= auto displayName= `"OpenSSH Authentication Agent`""
            cmd.exe /c "sc.exe description ssh-agent `"OpenSSH Authentication Agent`""
            Start-Sleep -Seconds 1
        }
    }

    # 再次验证服务是否已经存在
    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        $logDetails = (Get-ContentRaw -Path $installOutputLog)
        throw "sshd 服务注册失败，无法建立系统服务。详细安装日志：$logDetails"
    }

    Write-InstallLog "OpenSSH Server 服务已成功在系统中注册。"

    # 9. 自动将 C:\Program Files\OpenSSH 添加到系统 PATH 环境变量中
    try {
        $pathEnv = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if ($pathEnv -notlike "*C:\Program Files\OpenSSH*") {
            Write-InstallLog "正在将 OpenSSH 安装目录追加到系统的 PATH 环境变量中..."
            $newPath = $pathEnv
            if (-not $newPath.EndsWith(";")) { $newPath += ";" }
            $newPath += "C:\Program Files\OpenSSH;"
            [Environment]::SetEnvironmentVariable("Path", $newPath, "Machine")
            $env:Path += ";C:\Program Files\OpenSSH"
            Write-InstallLog "系统 PATH 环境变量追加成功。"
        }
    } catch {
        Write-InstallLog "向系统 PATH 追加环境变量失败（非致命）：$($_.Exception.Message)" "WARN"
    }

    # 清理临时文件
    try {
        Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    } catch {}
}

try {
    Write-InstallLog "OpenSSH 安装器已启动。"

    # 检测操作系统版本，如果是 Win7/Win8 则使用备用下载安装流
    $isWindows10OrLater = $true
    try {
        $os = Get-WmiObject Win32_OperatingSystem
        $version = [version]$os.Version
        if ($version.Major -lt 10) {
            $isWindows10OrLater = $false
        }
    } catch {
        if ($null -eq (Get-Command "Get-WindowsCapability" -ErrorAction SilentlyContinue)) {
            $isWindows10OrLater = $false
        }
    }

    if (-not $isWindows10OrLater) {
        Write-InstallLog "检测到当前系统为 Windows 7/8 (低于 Windows 10)，启动 Win32-OpenSSH 自动下载与安装流程。" "WARN"
        Install-Win32OpenSSH-Fallback
        exit 0
    }

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











