param(
    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Stop"

if (-not $PSScriptRoot) {
    $PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Path
}
if (-not $PSCommandPath) {
    $PSCommandPath = $MyInvocation.MyCommand.Path
}

if ((($ConfigPath) -match "^\s*$")) {
    $ConfigPath = Join-Path $PSScriptRoot "config.ini"
}

$ErrorActionPreference = "Stop"


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

function Convert-PSObjectToDictionary {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $dict = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $dict[$prop.Name] = Convert-PSObjectToDictionary -InputObject $prop.Value
        }
        return $dict
    }
    elseif ($InputObject -is [System.Collections.IDictionary]) {
        $dict = @{}
        foreach ($key in $InputObject.Keys) {
            $dict[$key] = Convert-PSObjectToDictionary -InputObject $InputObject[$key]
        }
        return $dict
    }
    elseif ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $InputObject) {
            $list.Add((Convert-PSObjectToDictionary -InputObject $item)) | Out-Null
        }
        return ,($list.ToArray())
    }
    return $InputObject
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
            $connection = $tcp.ConnectAsync($ComputerName, $Port)
            if ($connection.Wait(1500) -and $tcp.Connected) {
                $connected = $true
            }
        } catch {}
        finally {
            $tcp.Close()
        }
        return [PSCustomObject]@{ TcpTestSucceeded = $connected }
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
    if ($Config.ContainsKey($Key) -and (($Config[$Key]) -match "\S")) {
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



