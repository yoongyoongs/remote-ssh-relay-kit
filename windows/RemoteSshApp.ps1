param(
    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Stop"

# 1. 毫秒级轻量检测管理员权限，决定是否提前提示提权
function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$global:isParentAdmin = Test-IsAdministrator

if (-not $global:isParentAdmin) {
    Write-Host "正在请求管理员权限，请在随后的系统弹窗中选择 [是/允许]..." -ForegroundColor Yellow
}

# 2. 进行 QuickEdit 禁用编译与调用（必须在 UAC 弹出前执行以防点击死锁）
try {
    $typeDefinition = @"
    using System;
    using System.Runtime.InteropServices;
    public class ConsoleHelper {
        const int STD_INPUT_HANDLE = -10;
        const uint ENABLE_QUICK_EDIT_MODE = 0x0040;
        const uint ENABLE_EXTENDED_FLAGS = 0x0080;
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr GetStdHandle(int nStdHandle);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
        public static void DisableQuickEdit() {
            try {
                IntPtr hStdin = GetStdHandle(STD_INPUT_HANDLE);
                uint mode;
                if (GetConsoleMode(hStdin, out mode)) {
                    mode &= ~ENABLE_QUICK_EDIT_MODE;
                    mode |= ENABLE_EXTENDED_FLAGS;
                    SetConsoleMode(hStdin, mode);
                }
            } catch {}
        }
    }
"@
    Add-Type -TypeDefinition $typeDefinition -ErrorAction SilentlyContinue
    [ConsoleHelper]::DisableQuickEdit()
} catch {}

if (-not $PSScriptRoot) {
    $PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Path
}
if (-not $PSCommandPath) {
    $PSCommandPath = $MyInvocation.MyCommand.Path
}

if ((($ConfigPath) -match "^\s*$")) {
    $ConfigPath = Join-Path $PSScriptRoot "config.ini"
}

function Get-ContentRaw {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    return [System.IO.File]::ReadAllText($Path)
}

function Convert-DictionaryToPSObject {
    param($InputObject)
    if ($InputObject -is [System.Collections.IDictionary]) {
        $customObj = New-Object PSCustomObject
        foreach ($key in $InputObject.Keys) {
            $value = Convert-DictionaryToPSObject -InputObject $InputObject[$key]
            $customObj | Add-Member -MemberType NoteProperty -Name $key -Value $value -Force
        }
        return $customObj
    }
    elseif ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $InputObject) {
            $list.Add((Convert-DictionaryToPSObject -InputObject $item)) | Out-Null
        }
        return ,($list.ToArray())
    }
    return $InputObject
}

function Test-IsJsonSimpleValue {
    param($Value)
    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) { return $true }
    if ($Value -is [ValueType]) { return $true }
    return $false
}

function Convert-PSObjectToDictionary {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $dict = @{}
        foreach ($key in $InputObject.Keys) {
            $keyStr = $key.ToString()
            $dict[$keyStr] = Convert-PSObjectToDictionary -InputObject $InputObject[$key]
        }
        return $dict
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $InputObject) {
            $list.Add((Convert-PSObjectToDictionary -InputObject $item)) | Out-Null
        }
        return ,($list.ToArray())
    }

    if ($InputObject -is [string] -or $InputObject -is [ValueType] -or $null -eq $InputObject) {
        return $InputObject
    }

    if ($InputObject -is [System.Exception]) {
        return $InputObject.Message
    }

    $typeStr = $InputObject.GetType().FullName
    if ($typeStr -like "System.Management.Automation.*" -and $typeStr -ne "System.Management.Automation.PSCustomObject") {
        return $InputObject.ToString()
    }

    $dict = @{}
    try {
        $props = $InputObject.PSObject.Properties
        if ($null -ne $props) {
            foreach ($prop in $props) {
                $propType = $prop.GetType().FullName
                if ($propType -like "*PSParameterizedProperty*" -or $propType -like "*PSMethod*") {
                    continue
                }
                if ($prop.MemberType -eq "NoteProperty" -or $prop.MemberType -eq "Property") {
                    try {
                        $val = $prop.Value
                        $dict[$prop.Name] = Convert-PSObjectToDictionary -InputObject $val
                    } catch {
                        $dict[$prop.Name] = $_.Exception.Message
                    }
                }
            }
        }
    } catch {
        return $InputObject.ToString()
    }

    if ($dict.Count -gt 0) {
        return $dict
    }

    return $InputObject.ToString()
}

if ($null -eq (Get-Command "ConvertFrom-Json" -ErrorAction SilentlyContinue)) {
    function ConvertFrom-Json {
        param(
            [Parameter(ValueFromPipeline = $true)]
            [string]$InputObject
        )
        begin {
            [void][System.Reflection.Assembly]::LoadWithPartialName("System.Web.Extensions")
            $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $serializer.MaxJsonLength = 2147483647
            $json = ""
        }
        process {
            $json += $InputObject
        }
        end {
            if ($json -match '^\s*$') { return $null }
            $obj = $serializer.DeserializeObject($json)
            return Convert-DictionaryToPSObject -InputObject $obj
        }
    }
}

if ($null -eq (Get-Command "ConvertTo-Json" -ErrorAction SilentlyContinue)) {
    function ConvertTo-Json {
        param(
            [Parameter(ValueFromPipeline = $true)]
            $InputObject,
            [int]$Depth = 0
        )
        begin {
            [void][System.Reflection.Assembly]::LoadWithPartialName("System.Web.Extensions")
            $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $serializer.MaxJsonLength = 2147483647
        }
        process {
            $cleanObj = Convert-PSObjectToDictionary -InputObject $_
            Write-Output $serializer.Serialize($cleanObj)
        }
    }
}

if ($null -eq (Get-Command "Invoke-RestMethod" -ErrorAction SilentlyContinue)) {
    function Invoke-RestMethod {
        param(
            [string]$Uri,
            [string]$Method = "Get",
            [string]$ContentType = "application/json",
            [string]$Body = ""
        )
        $request = [System.Net.WebRequest]::Create($Uri)
        $request.Method = $Method
        $request.ContentType = $ContentType
        $request.Timeout = 15000
        $request.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
        
        if ($Method -eq "Post" -and -not [string]::IsNullOrEmpty($Body)) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
            $request.ContentLength = $bytes.Length
            $requestStream = $request.GetRequestStream()
            $requestStream.Write($bytes, 0, $bytes.Length)
            $requestStream.Close()
        }
        
        try {
            $response = $request.GetResponse()
            $responseStream = $response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($responseStream, [System.Text.Encoding]::UTF8)
            $responseText = $reader.ReadToEnd()
            $reader.Close()
            $responseStream.Close()
            $response.Close()
            
            return ConvertFrom-Json -InputObject $responseText
        } catch {
            if ($_.Exception -and $_.Exception.InnerException -is [System.Net.WebException]) {
                $webEx = $_.Exception.InnerException
            } elseif ($_.Exception -is [System.Net.WebException]) {
                $webEx = $_.Exception
            } else {
                throw $_
            }
            
            if ($null -ne $webEx.Response) {
                $responseStream = $webEx.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($responseStream, [System.Text.Encoding]::UTF8)
                $errorText = $reader.ReadToEnd()
                $reader.Close()
                $responseStream.Close()
                try {
                    $errObj = ConvertFrom-Json -InputObject $errorText
                    if ($null -ne $errObj) { return $errObj }
                } catch {}
            }
            throw $_
        }
    }
}

if ($null -eq (Get-Command "Test-NetConnection" -ErrorAction SilentlyContinue)) {
    function Test-NetConnection {
        param(
            [string]$ComputerName = "127.0.0.1",
            [int]$Port = 22,
            $WarningAction
        )
        $tcp = New-Object System.Net.Sockets.TcpClient
        $connected = $false
        try {
            $asyncResult = $tcp.BeginConnect($ComputerName, $Port, $null, $null)
            if ($asyncResult.AsyncWaitHandle.WaitOne(1500, $false) -and $tcp.Connected) {
                $tcp.EndConnect($asyncResult)
                $connected = $true
            }
        } catch {}
        finally {
            $tcp.Close()
        }
        return New-Object PSObject -Property @{ TcpTestSucceeded = $connected }
    }
}

function Read-IniFile {
    param([string]$Path)
    $map = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#") -or $trimmed.StartsWith(";")) {
            continue
        }
        $parts = @($trimmed -split "=", 2)
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
        return (Get-ContentRaw -Path $Path) | ConvertFrom-Json
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

$global:lastLineCount = 0
$global:currentLineCount = 0
$global:spinnerFrames = @("|", "/", "-", "\")
$global:spinnerIndex = 0

function Set-ClipboardText {
    param([string]$Text)
    try {
        if ($null -ne (Get-Command "Set-Clipboard" -ErrorAction SilentlyContinue)) {
            Set-Clipboard -Value $Text -ErrorAction Stop
        } else {
            $Text | clip
        }
    } catch {
        try {
            $Text | clip
        } catch {}
    }
}

function New-DiagnosticBundle {
    param(
        [string]$RuntimeRoot,
        [string]$SessionId,
        $Result
    )

    try {
        $desktop = [Environment]::GetFolderPath("DesktopDirectory")
        if ((($desktop) -match "^\s*$")) {
            $desktop = Join-Path $env:USERPROFILE "Desktop"
        }
        if (-not (Test-Path -LiteralPath $desktop)) {
            New-Item -ItemType Directory -Force -Path $desktop | Out-Null
        }

        $bundleName = "RemoteSshRelay-Diagnostics-$SessionId"
        $bundleFolder = Join-Path $desktop $bundleName
        if (Test-Path -LiteralPath $bundleFolder) {
            Remove-Item -LiteralPath $bundleFolder -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $bundleFolder | Out-Null

        $summaryPath = Join-Path $bundleFolder "README.txt"
        $summary = @(
            "远程协助启动失败诊断包",
            "会话 ID: $SessionId",
            "生成时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
            "",
            "请把这个压缩包发给协助你的管理员。",
            "",
            "错误信息:",
            "$($Result.message)",
            "",
            "原始日志目录:",
            "$RuntimeRoot"
        )
        Set-Content -LiteralPath $summaryPath -Value $summary -Encoding utf8

        $safeFileNames = @(
            "status.json",
            "result.json",
            "worker.log",
            "worker-startup.log",
            "worker-startup.out.log",
            "install-openssh.log",
            "install-openssh-dism.stdout.log",
            "install-openssh-dism.stderr.log",
            "tunnel-keeper.log",
            "tunnel-state.json",
            "tunnel.stdout.log",
            "tunnel.stderr.log",
            "enroll-response.json",
            "connection-settings.json"
        )
        foreach ($fileName in $safeFileNames) {
            $sourcePath = Join-Path $RuntimeRoot $fileName
            if (Test-Path -LiteralPath $sourcePath) {
                Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $bundleFolder $fileName) -Force
            }
        }
        foreach ($path in @(Get-ChildItem -LiteralPath $RuntimeRoot -Filter "tunnel-run-*.log" -ErrorAction SilentlyContinue)) {
            Copy-Item -LiteralPath $path.FullName -Destination (Join-Path $bundleFolder $path.Name) -Force
        }

        $zipPath = Join-Path $desktop ("$bundleName.zip")
        if (Test-Path -LiteralPath $zipPath) {
            Remove-Item -LiteralPath $zipPath -Force
        }

        try {
            [byte[]]$emptyZip = @(80, 75, 5, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            [System.IO.File]::WriteAllBytes($zipPath, $emptyZip)
            $shell = New-Object -ComObject Shell.Application
            $zipFolder = $shell.NameSpace($zipPath)
            $sourceFolder = $shell.NameSpace($bundleFolder)
            if ($null -ne $zipFolder -and $null -ne $sourceFolder) {
                $items = $sourceFolder.Items()
                $zipFolder.CopyHere($items, 16)
                $deadline = (Get-Date).AddSeconds(12)
                while ((Get-Date) -lt $deadline) {
                    Start-Sleep -Milliseconds 300
                    $zipFolder = $shell.NameSpace($zipPath)
                    if ($null -ne $zipFolder -and $zipFolder.Items().Count -ge $items.Count) {
                        break
                    }
                }
                try { Remove-Item -LiteralPath $bundleFolder -Recurse -Force } catch {}
                try { Start-Process -FilePath "explorer.exe" -ArgumentList ("/select,`"$zipPath`"") | Out-Null } catch {}
                Set-ClipboardText -Text $zipPath
                return $zipPath
            }
        } catch {}

        try { Start-Process -FilePath "explorer.exe" -ArgumentList "`"$bundleFolder`"" | Out-Null } catch {}
        Set-ClipboardText -Text $bundleFolder
        return $bundleFolder
    } catch {
        return ""
    }
}

function Set-CursorToTop {
    try {
        [Console]::SetCursorPosition(0, 0)
    } catch {
        Clear-Host
    }
}

function Reset-LineCount {
    $global:currentLineCount = 0
}

function Clear-LineRemainder {
    $width = 80
    try {
        $width = [Console]::WindowWidth
    } catch {}
    $left = 0
    try {
        $left = [Console]::CursorLeft
    } catch {}
    if ($left -lt $width) {
        Write-Host (New-Object string(' ', ($width - $left - 1))) -NoNewline
    }
    Write-Host ""
}

function Write-ConsoleLine {
    param(
        [string]$Text = "",
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray
    )
    Write-Host $Text -ForegroundColor $ForegroundColor -NoNewline
    Clear-LineRemainder
    $global:currentLineCount++
}

function Clear-RemainingLines {
    if ($global:currentLineCount -lt $global:lastLineCount) {
        $diff = $global:lastLineCount - $global:currentLineCount
        for ($i = 0; $i -lt $diff; $i++) {
            Write-Host (New-Object string(' ', 100))
        }
        try {
            [Console]::SetCursorPosition(0, [Console]::CursorTop - $diff)
        } catch {}
    }
    $global:lastLineCount = $global:currentLineCount
}

function Write-StepLine {
    param($Step)
    $title = Get-StepTitle -Id $Step.id
    
    Write-Host "  " -NoNewline
    switch ($Step.status) {
        "success" {
            Write-Host "[" -NoNewline
            Write-Host " ✔ " -ForegroundColor Green -NoNewline
            Write-Host "] " -NoNewline
            Write-Host ("{0,-28}" -f $title) -NoNewline
            Write-Host " -------------------- [ " -NoNewline
            Write-Host "成功" -ForegroundColor Green -NoNewline
            Write-Host " ]" -NoNewline
        }
        "failed" {
            Write-Host "[" -NoNewline
            Write-Host " ❌" -ForegroundColor Red -NoNewline
            Write-Host "] " -NoNewline
            Write-Host ("{0,-28}" -f $title) -NoNewline
            Write-Host " -------------------- [ " -NoNewline
            Write-Host "失败" -ForegroundColor Red -NoNewline
            Write-Host " ]" -NoNewline
        }
        "running" {
            $spinner = $global:spinnerFrames[$global:spinnerIndex]
            Write-Host "[" -NoNewline
            Write-Host " $spinner " -ForegroundColor Yellow -NoNewline
            Write-Host "] " -NoNewline
            Write-Host ("{0,-28}" -f $title) -NoNewline
            Write-Host " -------------------- [ " -NoNewline
            Write-Host "进行中" -ForegroundColor Yellow -NoNewline
            Write-Host " ]" -NoNewline
        }
        "skipped" {
            Write-Host "[" -NoNewline
            Write-Host " ➖ " -ForegroundColor Gray -NoNewline
            Write-Host "] " -NoNewline
            Write-Host ("{0,-28}" -f $title) -NoNewline
            Write-Host " -------------------- [ " -NoNewline
            Write-Host "已跳过" -ForegroundColor Gray -NoNewline
            Write-Host " ]" -NoNewline
        }
        default {
            Write-Host "[" -NoNewline
            Write-Host " ○ " -ForegroundColor DarkGray -NoNewline
            Write-Host "] " -NoNewline
            Write-Host ("{0,-28}" -f $title) -NoNewline
            Write-Host " -------------------- [ " -NoNewline
            Write-Host "等待" -ForegroundColor DarkGray -NoNewline
            Write-Host " ]" -NoNewline
        }
    }
    Clear-LineRemainder
    $global:currentLineCount++
}

function Get-ConfigValue {
    param(
        [hashtable]$Config,
        [string]$Key,
        [string]$DefaultValue
    )
    if ($Config.ContainsKey($Key) -and (($Config[$Key]) -match "\S")) {
        return $Config[$Key]
    }
    return $DefaultValue
}

try {
    $config = Read-IniFile -Path $ConfigPath
    $runtimeRoot = Join-Path $env:LOCALAPPDATA "RemoteSshRelay\runtime"
    $workerPath = Join-Path $PSScriptRoot "RemoteSshWorker.ps1"
    $statusPath = Join-Path $runtimeRoot "status.json"
    $resultPath = Join-Path $runtimeRoot "result.json"
    $sessionId = (Get-Date -Format "yyyyMMdd-HHmmss") + "-" + ([System.Guid]::NewGuid().ToString("N").Substring(0, 8))
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

    $startupLog = Join-Path $runtimeRoot "worker-startup.log"
    $startupOutLog = Join-Path $runtimeRoot "worker-startup.out.log"
    $workerProc = $null
    $workerStartTime = Get-Date

    try {
        if ($global:isParentAdmin) {
            if ($showWorkerWindow) {
                $workerProc = Start-Process -FilePath "powershell.exe" -ArgumentList $workerArgs -PassThru
            } else {
                $workerProc = Start-Process -FilePath "powershell.exe" -ArgumentList $workerArgs -WindowStyle Hidden -RedirectStandardOutput $startupOutLog -RedirectStandardError $startupLog -PassThru
            }
        } else {
            if ($showWorkerWindow) {
                Start-Process -FilePath "powershell.exe" -ArgumentList $workerArgs -Verb RunAs | Out-Null
            } else {
                Start-Process -FilePath "powershell.exe" -ArgumentList $workerArgs -Verb RunAs -WindowStyle Hidden | Out-Null
            }
        }
    } catch {
        Start-Process -FilePath "powershell.exe" -ArgumentList $workerArgs -Verb RunAs | Out-Null
    }

    function Write-StartupFailureResult {
        param([string]$Message)
        if (Test-Path -LiteralPath $resultPath) {
            return
        }
        try {
            $payload = @{
                ok = $false
                error_code = "WORKER_START_FAILED"
                message = $Message
                user_message = "后台任务没有正常启动。请把日志目录截图或打包发给管理员。"
                runtime_root = $runtimeRoot
            }
            $payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding utf8
        } catch {
            # 如果序列化失败（在 PS 2.0 上可能发生），写入硬编码的 JSON 字符串作为保底
            $escapedMsg = $Message -replace '"', '\\"' -replace "\r?\n", " "
            $rawJson = '{"ok":false,"error_code":"WORKER_START_FAILED","message":"' + $escapedMsg + '","user_message":"后台任务没有正常启动。请把日志目录截图或打包发给管理员。"}'
            [System.IO.File]::WriteAllText($resultPath, $rawJson, [System.Text.Encoding]::UTF8)
        }
    }

    while ($true) {
        Start-Sleep -Milliseconds 600
        $status = Read-JsonFile -Path $statusPath

        if ($null -eq $status) {
            if ($null -ne $workerProc) {
                try {
                    $workerProc.Refresh()
                    if ($workerProc.HasExited) {
                        Write-StartupFailureResult -Message ("后台任务启动后立即退出，退出码：{0}。请查看 worker-startup.log / worker-startup.out.log。" -f $workerProc.ExitCode)
                    }
                } catch {}
            }

            $elapsedSeconds = ((Get-Date) - $workerStartTime).TotalSeconds
            if ($elapsedSeconds -gt 45) {
                Write-StartupFailureResult -Message "等待后台任务启动超过 45 秒，未看到状态文件。可能是 UAC 未确认、PowerShell 兼容错误，或启动器被杀毒软件拦截。"
            }
        }
        
        # Increment spinner tick
        $global:spinnerIndex = ($global:spinnerIndex + 1) % $global:spinnerFrames.Count
        
        Set-CursorToTop
        Reset-LineCount
        
        Write-ConsoleLine "========================================================================" -ForegroundColor Cyan
        Write-ConsoleLine "                    ⚡ 远程协助连接助手 (Remote SSH)                    " -ForegroundColor Cyan
        Write-ConsoleLine ("  会话 ID: {0}" -f $sessionId) -ForegroundColor DarkGray
        Write-ConsoleLine "========================================================================" -ForegroundColor Cyan
        Write-ConsoleLine ""

        if ($null -eq $status) {
            Write-ConsoleLine "  [ ⏳ ] 正在等待后台任务启动..." -ForegroundColor Yellow
        } else {
            foreach ($step in $status.steps) {
                Write-StepLine -Step $step
            }
        }

        $detailLogPath = if ($null -ne $status -and $status.detail_log_path) { $status.detail_log_path } else { Join-Path $runtimeRoot "worker.log" }
        if (($null -eq $status) -and -not (Test-Path -LiteralPath $detailLogPath) -and (Test-Path -LiteralPath $startupLog)) {
            $detailLogPath = $startupLog
        }
        if (($null -eq $status) -and -not (Test-Path -LiteralPath $detailLogPath) -and (Test-Path -LiteralPath $startupOutLog)) {
            $detailLogPath = $startupOutLog
        }
        $detailLines = Get-RecentLogLines -Path $detailLogPath -LineCount 8
        
        Write-ConsoleLine ""
        Write-ConsoleLine "┌─ 最近活动日志 (Recent Logs) ──────────────────────────────────────────" -ForegroundColor DarkGray
        if (-not $detailLines) {
            Write-ConsoleLine "  正在等待日志输出..." -ForegroundColor DarkGray
        } else {
            foreach ($line in $detailLines) {
                $trimmedLine = if ($line.Length -gt 74) { $line.Substring(0, 71) + "..." } else { $line }
                Write-ConsoleLine "  $trimmedLine" -ForegroundColor DarkGray
            }
        }
        Write-ConsoleLine "└───────────────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

        if (Test-Path -LiteralPath $resultPath) {
            $result = Read-JsonFile -Path $resultPath
            Write-ConsoleLine ""
            if ($result.ok) {
                Set-ClipboardText -Text $result.connect_command
                Write-ConsoleLine "========================================================================" -ForegroundColor Green
                Write-ConsoleLine " 🎉 连接已成功建立！" -ForegroundColor Green
                Write-ConsoleLine "========================================================================" -ForegroundColor Green
                Write-ConsoleLine " 📋 连通命令已【自动复制】到您的剪贴板中！" -ForegroundColor Yellow
                Write-ConsoleLine " 💬 请直接在聊天窗口中 粘贴 (Ctrl + V) 并发给协助您的管理员即可。" -ForegroundColor Yellow
                Write-ConsoleLine ""
                Write-ConsoleLine " ℹ️ 协助命令 (如需手动复制):" -ForegroundColor DarkGray
                Write-ConsoleLine "    $($result.connect_command)" -ForegroundColor Cyan
                Write-ConsoleLine "========================================================================" -ForegroundColor Green
            } else {
                $diagnosticPath = New-DiagnosticBundle -RuntimeRoot $runtimeRoot -SessionId $sessionId -Result $result
                Write-ConsoleLine "========================================================================" -ForegroundColor Red
                Write-ConsoleLine " ❌ 配置失败" -ForegroundColor Red
                Write-ConsoleLine "========================================================================" -ForegroundColor Red
                if ((($diagnosticPath) -match "\S")) {
                    Write-ConsoleLine " 已在桌面生成诊断包，并自动打开了所在位置。" -ForegroundColor Yellow
                    Write-ConsoleLine " 请把下面这个文件发给管理员：" -ForegroundColor Yellow
                    Write-ConsoleLine " $diagnosticPath" -ForegroundColor Cyan
                    Write-ConsoleLine " 文件路径也已经复制到剪贴板。" -ForegroundColor Yellow
                } elseif ($result.user_message) {
                    Write-ConsoleLine " $($result.user_message)" -ForegroundColor Yellow
                }
                Write-ConsoleLine " 错误信息: $($result.message)" -ForegroundColor DarkGray
                Write-ConsoleLine "========================================================================" -ForegroundColor Red
            }
            Clear-RemainingLines
            break
        }
        Clear-RemainingLines
    }
} catch {
    Write-Host ""
    Write-Host "========================================================================" -ForegroundColor Red
    Write-Host " ❌ 主程序运行发生致命错误：" -ForegroundColor Red
    Write-Host " $_" -ForegroundColor Yellow
    Write-Host "========================================================================" -ForegroundColor Red
    Write-Host ""
}

Write-Host ""
Write-Host "按 Enter 键关闭窗口。"
[void][System.Console]::ReadLine()




