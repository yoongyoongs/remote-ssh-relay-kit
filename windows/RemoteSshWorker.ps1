param(
    [string]$ConfigPath,
    [string]$RuntimeRoot,
    [string]$SessionId,
    [string]$Mode = "worker",
    [string]$DeviceKeyPath = "",
    [string]$RelayHost = "",
    [int]$RelaySshPort = 22,
    [string]$RelayUser = "",
    [string]$RemoteBindAddress = "",
    [int]$RemotePort = 0,
    [string]$LocalHost = "127.0.0.1",
    [int]$LocalPort = 22,
    [int]$RetrySeconds = 5
)

$ErrorActionPreference = "Stop"

if (-not $PSScriptRoot) {
    $PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Path
}
if (-not $PSCommandPath) {
    $PSCommandPath = $MyInvocation.MyCommand.Path
}

if (-not $PSScriptRoot) {
    $PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Path
}
if (-not $PSCommandPath) {
    $PSCommandPath = $MyInvocation.MyCommand.Path
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

    # 釜底抽薪：除了白名单中允许的字典、集合、简单值和异常外，其他任何复杂类型一律禁止进行反射，直接降级返回为字符串，彻底断绝循环引用
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

function Get-ConfigFlag {
    param(
        [hashtable]$Config,
        [string]$Key,
        [bool]$DefaultValue = $false
    )
    $defaultText = if ($DefaultValue) { "true" } else { "false" }
    return ((Get-ConfigValue -Config $Config -Key $Key -DefaultValue $defaultText).ToLowerInvariant() -eq "true")
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Use-LiveRelayInDryRun {
    return ($script:DryRun -and (Get-ConfigFlag -Config $script:Config -Key "DRY_RUN_USE_LIVE_RELAY"))
}

function Use-BootstrapMode {
    $hasManualEnrollCode = ((($script:Config["ENROLL_CODE"]) -match "\S") -and $script:Config["ENROLL_CODE"] -notlike "*CHANGE-ME*")
    $hasManualAdminKey = ((($script:Config["ADMIN_PUBLIC_KEY"]) -match "\S") -and $script:Config["ADMIN_PUBLIC_KEY"] -notlike "*CHANGE-ME*")
    if ($hasManualEnrollCode -and $hasManualAdminKey) {
        return $false
    }
    return $true
}

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "s"), $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -Encoding utf8
}

function Set-DetailLogPath {
    param([string]$Path)
    $script:Status.detail_log_path = $Path
    Save-Status
}

function Save-Status {
    $script:Status | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:StatusPath -Encoding utf8
}

function Set-StepState {
    param(
        [string]$Id,
        [string]$State,
        [string]$Message
    )
    foreach ($step in $script:Status.steps) {
        if ($step.id -eq $Id) {
            $step.status = $State
            $step.message = $Message
            if ($State -eq "running" -and -not $step.started_at) {
                $step.started_at = (Get-Date).ToUniversalTime().ToString("s") + "Z"
            }
            if (@("success", "failed", "skipped") -contains $State) {
                $step.finished_at = (Get-Date).ToUniversalTime().ToString("s") + "Z"
            }
            break
        }
    }
    $script:Status.current_step = $Id
    $script:Status.overall_status = if ($State -eq "failed") { "failed" } else { "running" }
    Save-Status
    Write-Log "$Id [$State] $Message"
}

function Finish-Run {
    param(
        [bool]$Ok,
        [hashtable]$Payload
    )
    $script:Status.overall_status = if ($Ok) { "success" } else { "failed" }
    try {
        Save-Status
    } catch {}
    
    $Payload["ok"] = $Ok
    try {
        $Payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ResultPath -Encoding utf8
    } catch {
        # 如果序列化失败，使用硬编码的 JSON 字符串作为最终保底，防止进程无声崩溃并让主程序在1秒内检测到
        $msg = if ($Payload.ContainsKey("message")) { $Payload["message"] } else { $_.Exception.Message }
        $userMsg = if ($Payload.ContainsKey("user_message")) { $Payload["user_message"] } else { "后台任务没有正常启动。" }
        $escapedMsg = $msg -replace '"', '\\"' -replace "\r?\n", " "
        $escapedUserMsg = $userMsg -replace '"', '\\"' -replace "\r?\n", " "
        $okText = if ($Ok) { "true" } else { "false" }
        $rawJson = '{"ok":' + $okText + ',"error_code":"WORKER_FAILED","message":"' + $escapedMsg + '","user_message":"' + $escapedUserMsg + '"}'
        [System.IO.File]::WriteAllText($script:ResultPath, $rawJson, [System.Text.Encoding]::UTF8)
    }
    exit
}

function Invoke-Step {
    param(
        [string]$Id,
        [string]$Message,
        [scriptblock]$Action
    )
    Set-StepState -Id $Id -State "running" -Message $Message
    try {
        & $Action
    } catch {
        Set-StepState -Id $Id -State "failed" -Message $_.Exception.Message
        throw
    }
}

function Validate-Config {
    param([hashtable]$Config)

    Invoke-Step -Id "validate_config" -Message "正在检查配置文件。" -Action {
        $missingItems = @()
        $bootstrapMode = Use-BootstrapMode

        if ((($Config["RELAY_HOST"]) -match "^\s*$")) {
            $missingItems += "RELAY_HOST"
        }
        if ((($Config["ENROLL_API"]) -match "^\s*$")) {
            $missingItems += "ENROLL_API"
        }
        if ($bootstrapMode) {
            if ((($Config["BOOTSTRAP_API"]) -match "^\s*$")) {
                $missingItems += "BOOTSTRAP_API"
            }
            if ((($Config["BOOTSTRAP_TOKEN"]) -match "^\s*$") -or $Config["BOOTSTRAP_TOKEN"] -like "*CHANGE-ME*") {
                $missingItems += "BOOTSTRAP_TOKEN"
            }
        } else {
            if ((($Config["ENROLL_CODE"]) -match "^\s*$") -or $Config["ENROLL_CODE"] -like "*CHANGE-ME*") {
                $missingItems += "ENROLL_CODE"
            }
            if ((($Config["ADMIN_PUBLIC_KEY"]) -match "^\s*$") -or $Config["ADMIN_PUBLIC_KEY"] -like "*CHANGE-ME*") {
                $missingItems += "ADMIN_PUBLIC_KEY"
            }
        }

        if ($missingItems.Count -gt 0) {
            throw ("配置文件缺少必要内容，请先补全：{0}" -f ($missingItems -join "、"))
        }

        if ($bootstrapMode) {
            Set-StepState -Id "validate_config" -State "success" -Message "配置文件检查通过，将自动向服务器获取连接配置。"
        } else {
            Set-StepState -Id "validate_config" -State "success" -Message "配置文件检查通过。"
            Set-StepState -Id "fetch_connection_settings" -State "skipped" -Message "当前使用手动配置，无需向服务器申请连接配置。"
        }
    }
}

function Resolve-ConnectionSettings {
    param([hashtable]$Config)

    if (-not (Use-BootstrapMode)) {
        $script:ConnectionSettings = @{
            enroll_code = $Config["ENROLL_CODE"]
            admin_public_key = $Config["ADMIN_PUBLIC_KEY"]
        }
        Set-StepState -Id "fetch_connection_settings" -State "skipped" -Message "当前使用手动配置，无需向服务器申请连接配置。"
        return
    }

    Invoke-Step -Id "fetch_connection_settings" -Message "正在向服务器获取连接配置。" -Action {
        $settingsPath = Join-Path $script:RuntimeRoot "connection-settings.json"
        if ($script:DryRun -and -not (Use-LiveRelayInDryRun)) {
            $response = @{
                ok = $true
                enroll_code = "AUTO-DRYRUN"
                admin_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDryRunAdminKey remote-ssh-relay-admin"
                relay_host = $Config["RELAY_HOST"]
                relay_ssh_port = [int](Get-ConfigValue -Config $Config -Key "RELAY_SSH_PORT" -DefaultValue "22")
                relay_user = "tunnel"
                expires_at = (Get-Date).AddMinutes(10).ToUniversalTime().ToString("s") + "Z"
            }
        } else {
            $body = @{
                bootstrap_token = $Config["BOOTSTRAP_TOKEN"]
                device_name = $env:COMPUTERNAME
                os_type = "windows"
                local_user = $env:USERNAME
                launcher_version = "0.1.0"
            }
            $response = Invoke-RestMethod `
                -Method Post `
                -Uri $Config["BOOTSTRAP_API"] `
                -ContentType "application/json" `
                -Body ($body | ConvertTo-Json)
        }

        if (-not $response.ok) {
            throw "服务器没有返回有效的连接配置。"
        }
        if ((($response.enroll_code) -match "^\s*$") -or (($response.admin_public_key) -match "^\s*$")) {
            throw "服务器返回的连接配置不完整。"
        }

        $script:ConnectionSettings = @{
            enroll_code = $response.enroll_code
            admin_public_key = $response.admin_public_key
            relay_host = $response.relay_host
            relay_ssh_port = $response.relay_ssh_port
            relay_user = $response.relay_user
            expires_at = $response.expires_at
        }
        $script:ConnectionSettings | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $settingsPath -Encoding utf8
        Set-StepState -Id "fetch_connection_settings" -State "success" -Message "服务器已返回连接配置。"
    }
}

function Ensure-ServiceInstalled {
    $forceInstallInDryRun = ((Get-ConfigValue -Config $script:Config -Key "FORCE_INSTALL_OPENSSH_IN_DRY_RUN" -DefaultValue "false").ToLowerInvariant() -eq "true")
    $mode = (Get-ConfigValue -Config $script:Config -Key "INSTALL_OPENSSH_MODE" -DefaultValue "hidden").ToLowerInvariant()
    if ($mode -eq "window") {
        $mode = "cmd"
    }
    if (@("hidden", "cmd") -notcontains $mode) {
        $mode = "hidden"
    }
    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($null -ne $service -and -not ($script:DryRun -and $forceInstallInDryRun)) {
        Set-StepState -Id "check_openssh" -State "success" -Message "OpenSSH Server 已安装。"
        Set-StepState -Id "install_openssh" -State "skipped" -Message "当前无需安装。"
        return
    }

    Set-StepState -Id "check_openssh" -State "success" -Message "未检测到 OpenSSH Server。"
    Invoke-Step -Id "install_openssh" -Message "正在安装 OpenSSH Server。" -Action {
        if ($script:DryRun) {
            $installLogPath = Join-Path $script:RuntimeRoot "install-openssh.log"
            Set-DetailLogPath -Path $installLogPath
            $modeLine = if ($mode -eq "cmd") { "[INFO] 将通过单独的 cmd 窗口安装 OpenSSH Server（演练模式）。" } else { "[INFO] 将在后台安装 OpenSSH Server（演练模式）。" }
            $progressLine = if ($mode -eq "cmd") { "[INFO] 正在通过单独的 cmd 窗口安装 OpenSSH Server，这一步可能需要几分钟。" } else { "[INFO] 正在后台安装 OpenSSH Server，这一步可能需要几分钟。" }
            foreach ($line in @(
                "[INFO] OpenSSH 安装器已启动（演练模式）。",
                $modeLine,
                "[INFO] 正在检查系统组件状态。",
                "[INFO] 当前未安装 OpenSSH Server，准备开始安装。",
                $progressLine,
                "[INFO] OpenSSH Server 安装模拟完成。"
            )) {
                Add-Content -LiteralPath $installLogPath -Value $line -Encoding utf8
                Set-StepState -Id "install_openssh" -State "running" -Message ("正在安装 OpenSSH Server。 {0}" -f $line)
                Start-Sleep -Milliseconds 400
            }
            Set-DetailLogPath -Path $script:LogPath
        } else {
            $installerScript = Join-Path $PSScriptRoot "InstallOpenSsh.ps1"
            $installLogPath = Join-Path $script:RuntimeRoot "install-openssh.log"
            if (Test-Path -LiteralPath $installLogPath) {
                Remove-Item -LiteralPath $installLogPath -Force
            }

            Set-DetailLogPath -Path $installLogPath
            $installerArgs = @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", ('"{0}"' -f $installerScript),
                "-LogPath", ('"{0}"' -f $installLogPath)
            )

            $installer = if ($mode -eq "cmd") {
                $cmdArgs = @(
                    "/c",
                    ('title OpenSSH Installer && powershell.exe {0}' -f ($installerArgs -join " "))
                )
                Start-Process -FilePath "cmd.exe" -ArgumentList $cmdArgs -PassThru
            } else {
                Start-Process -FilePath "powershell.exe" -ArgumentList $installerArgs -PassThru -WindowStyle Hidden
            }

            $lastSeen = 0
            $lastLine = ""
            while (-not $installer.HasExited) {
                Start-Sleep -Seconds 2
                if (Test-Path -LiteralPath $installLogPath) {
                    $lines = @(Get-Content -LiteralPath $installLogPath)
                    if ($lines.Count -gt 0) {
                        $newLastLine = $lines[$lines.Count - 1]
                        if ($newLastLine -ne $lastLine) {
                            Set-StepState -Id "install_openssh" -State "running" -Message ("正在安装 OpenSSH Server。 {0}" -f $newLastLine)
                            $lastLine = $newLastLine
                        }
                        $lastSeen = $lines.Count
                    }
                }
                $installer.Refresh()
            }

            if (Test-Path -LiteralPath $installLogPath) {
                $lines = @(Get-Content -LiteralPath $installLogPath)
                if ($lines.Count -gt 0) {
                    $lastLine = $lines[$lines.Count - 1]
                }
            }

            if ($installer.ExitCode -ne 0) {
                throw "OpenSSH 安装进程执行失败。"
            }

            Start-Sleep -Seconds 2
            $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
            if ($null -eq $service) {
                throw "OpenSSH 安装完成，但仍未找到 sshd 服务。"
            }
            Set-DetailLogPath -Path $script:LogPath
        }
        Set-StepState -Id "install_openssh" -State "success" -Message "OpenSSH Server 安装完成。"
    }
}

function Ensure-SshdRunning {
    Invoke-Step -Id "start_sshd" -Message "正在启动 sshd 服务。" -Action {
        if ($script:DryRun -and -not (Use-LiveRelayInDryRun)) {
            Start-Sleep -Milliseconds 500
        } else {
            $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
            if ($null -eq $service) {
                Write-Log "error [sshd] sshd service is not registered in system."
                throw "未安装 sshd 服务。"
            }
            Write-Log "info [sshd] current service status: $($service.Status)"
            if ($service.Status -ne "Running") {
                Write-Log "info [sshd] attempting to start sshd service."
                Start-Service sshd
                Write-Log "info [sshd] start command invoked successfully."
            }
            if (-not (Use-LiveRelayInDryRun)) {
                Write-Log "info [sshd] setting startup type of sshd to Automatic..."
                $setServiceCommand = Get-Command "Set-Service" -ErrorAction SilentlyContinue
                if ($null -ne $setServiceCommand -and $setServiceCommand.Parameters.ContainsKey("StartupType")) {
                    Set-Service -Name sshd -StartupType Automatic
                    Write-Log "info [sshd] Set-Service -StartupType Automatic completed."
                } else {
                    Write-Log "info [sshd] Set-Service does not support -StartupType parameter (Win7/PS 2.0). Fallback to sc.exe..."
                    cmd.exe /c "sc.exe config sshd start= auto"
                    if ($LASTEXITCODE -ne 0) {
                        throw "通过 sc.exe 设置 sshd 为自动启动失败。"
                    }
                    Write-Log "info [sshd] sc.exe config sshd start= auto completed."
                }
            }
        }
        Set-StepState -Id "start_sshd" -State "success" -Message "sshd 服务正在运行。"
    }
}

function Ensure-FirewallRule {
    Invoke-Step -Id "configure_firewall" -Message "正在配置 Windows 防火墙。" -Action {
        if ($script:DryRun) {
            Start-Sleep -Milliseconds 300
            Set-StepState -Id "configure_firewall" -State "success" -Message "演练模式下已模拟防火墙规则。"
            return
        }

        # 检查是否支持 Windows 8+ 防火墙 Cmdlets，如果不支持（Win7），使用 netsh 兼容写入
        $hasNetSecurity = $null -ne (Get-Command "Get-NetFirewallRule" -ErrorAction SilentlyContinue)
        if ($hasNetSecurity) {
            Write-Log "info [firewall] checking net-firewall rule for RemoteSshRelay-OpenSSH..."
            $rule = Get-NetFirewallRule -Name "RemoteSshRelay-OpenSSH" -ErrorAction SilentlyContinue
            if ($null -eq $rule) {
                Write-Log "info [firewall] rule not found, creating rule RemoteSshRelay-OpenSSH allowing inbound port 22..."
                New-NetFirewallRule `
                    -Name "RemoteSshRelay-OpenSSH" `
                    -DisplayName "Remote SSH Relay - OpenSSH" `
                    -Direction Inbound `
                    -Protocol TCP `
                    -LocalPort 22 `
                    -Action Allow | Out-Null
                Set-StepState -Id "configure_firewall" -State "success" -Message "已创建防火墙规则。"
                Write-Log "info [firewall] firewall rule created successfully."
            } else {
                Write-Log "info [firewall] firewall rule RemoteSshRelay-OpenSSH already exists."
                Set-StepState -Id "configure_firewall" -State "skipped" -Message "防火墙规则已存在。"
            }
        } else {
            Write-Log "info [firewall] NetSecurity cmdlets are unavailable (Win7). Using netsh fallback..."
            # 使用 netsh 查询规则
            $netshCheck = cmd.exe /c "netsh advfirewall firewall show rule name=`"RemoteSshRelay-OpenSSH`""
            $ruleExists = $false
            if ($LASTEXITCODE -eq 0 -and $netshCheck -match "RemoteSshRelay-OpenSSH") {
                $ruleExists = $true
            }

            if (-not $ruleExists) {
                Write-Log "info [firewall] creating firewall rule via netsh for port 22..."
                cmd.exe /c "netsh advfirewall firewall add rule name=`"RemoteSshRelay-OpenSSH`" dir=in action=allow protocol=TCP localport=22"
                if ($LASTEXITCODE -ne 0) {
                    throw "通过 netsh 添加防火墙规则失败。"
                }
                Set-StepState -Id "configure_firewall" -State "success" -Message "已创建防火墙规则 (netsh)。"
                Write-Log "info [firewall] firewall rule created successfully via netsh."
            } else {
                Write-Log "info [firewall] firewall rule RemoteSshRelay-OpenSSH already exists (netsh check)."
                Set-StepState -Id "configure_firewall" -State "skipped" -Message "防火墙规则已存在。"
            }
        }
    }
}

function Verify-LocalSsh {
    Invoke-Step -Id "verify_local_ssh" -Message "正在检查本机 SSH 监听。" -Action {
        if ($script:DryRun -and -not (Use-LiveRelayInDryRun)) {
            Start-Sleep -Milliseconds 300
            Set-StepState -Id "verify_local_ssh" -State "success" -Message "演练模式下已模拟本机 SSH 检查。"
            return
        }

        Write-Log "info [localssh] testing TCP connection to 127.0.0.1:22..."
        $result = Test-NetConnection 127.0.0.1 -Port 22 -WarningAction SilentlyContinue
        if (-not $result.TcpTestSucceeded) {
            Write-Log "error [localssh] TCP connection to 127.0.0.1:22 failed. Running netstat diagnostic..."
            try {
                $netstatOut = cmd.exe /c "netstat -ano"
                # 在 PowerShell 2.0 中，用 Select-String 过滤包含 :22 的行并转换输出为日志
                $netstatFiltered = @($netstatOut | Select-String -Pattern ":22\s")
                if ($netstatFiltered.Count -gt 0) {
                    Write-Log "info [localssh] netstat processes occupying port 22:`n$($netstatFiltered -join "`n")"
                } else {
                    Write-Log "info [localssh] netstat shows no active listener on port 22."
                }
            } catch {
                Write-Log "warning [localssh] failed to run netstat diagnostic: $($_.Exception.Message)"
            }
            throw "127.0.0.1:22 的本机 SSH 监听不可达。"
        }
        Write-Log "info [localssh] TCP connection to 127.0.0.1:22 succeeded."
        Set-StepState -Id "verify_local_ssh" -State "success" -Message "本机 SSH 监听可达。"
    }
}

function Ensure-DeviceKey {
    $keyPath = Join-Path $script:RuntimeRoot "device_key"
    Invoke-Step -Id "generate_device_key" -Message "正在生成设备密钥。" -Action {
        if (-not (Test-Path -LiteralPath $keyPath)) {
            if ($script:DryRun -and -not (Use-LiveRelayInDryRun)) {
                Set-Content -LiteralPath $keyPath -Value "dry-run-private-key" -Encoding ascii
                Set-Content -LiteralPath ($keyPath + ".pub") -Value "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDryRunDeviceKey remote-ssh-relay" -Encoding ascii
            } else {
                $cmd = 'ssh-keygen.exe -q -t ed25519 -N "" -f "{0}"' -f $keyPath
                cmd /c $cmd | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "生成设备密钥时 ssh-keygen 执行失败。"
                }
            }
        }
        Set-StepState -Id "generate_device_key" -State "success" -Message "设备密钥已准备完成。"
    }
    return $keyPath
}

function Ensure-AuthorizedKey {
    Invoke-Step -Id "write_authorized_keys" -Message "正在写入管理员公钥。" -Action {
        $adminKey = $script:ConnectionSettings.admin_public_key
        if ((($adminKey) -match "^\s*$") -or $adminKey -like "*CHANGE-ME*") {
            throw "服务器没有提供有效的管理员公钥。"
        }

        $sshDir = Join-Path $env:USERPROFILE ".ssh"
        $authPath = Join-Path $sshDir "authorized_keys"
        New-Item -ItemType Directory -Force -Path $sshDir | Out-Null
        if (-not (Test-Path -LiteralPath $authPath)) {
            New-Item -ItemType File -Force -Path $authPath | Out-Null
        }
        $content = Get-Content -LiteralPath $authPath -ErrorAction SilentlyContinue
        if ($content -notcontains $adminKey) {
            Add-Content -LiteralPath $authPath -Value $adminKey -Encoding utf8
        }

        if (-not $script:DryRun) {
            $adminSshDir = Join-Path $env:ProgramData "ssh"
            New-Item -ItemType Directory -Force -Path $adminSshDir | Out-Null
            $adminAuthPath = Join-Path $adminSshDir "administrators_authorized_keys"
            if (-not (Test-Path -LiteralPath $adminAuthPath)) {
                New-Item -ItemType File -Force -Path $adminAuthPath | Out-Null
            }
            $adminContent = Get-Content -LiteralPath $adminAuthPath -ErrorAction SilentlyContinue
            if ($adminContent -notcontains $adminKey) {
                Add-Content -LiteralPath $adminAuthPath -Value $adminKey -Encoding utf8
            }
            & icacls.exe $adminAuthPath /inheritance:r | Out-Null
            & icacls.exe $adminAuthPath /grant "Administrators:F" "SYSTEM:F" | Out-Null
        }
        Set-StepState -Id "write_authorized_keys" -State "success" -Message "管理员公钥已写入。"
    }
}

function Enroll-Device {
    param(
        [hashtable]$Config,
        [string]$DeviceKeyPath
    )
    $responsePath = Join-Path $script:RuntimeRoot "enroll-response.json"
    Invoke-Step -Id "enroll_device" -Message "正在注册到中转服务器。" -Action {
        $enrollCode = $script:ConnectionSettings.enroll_code
        if ((($enrollCode) -match "^\s*$") -or $enrollCode -like "*CHANGE-ME*") {
            throw "服务器没有提供有效的注册码。"
        }

        $body = @{
            enroll_code       = $enrollCode
            device_id         = "win-" + ([System.Guid]::NewGuid().ToString("N").Substring(0, 8))
            device_name       = $env:COMPUTERNAME
            device_public_key = ((Get-ContentRaw -Path ($DeviceKeyPath + ".pub"))).Trim()
            os_type           = "windows"
            local_user        = $env:USERNAME
            ssh_ready         = $true
            launcher_version  = "0.1.0"
        }

        if ($script:DryRun) {
            $resolvedRelayHost = if ($script:ConnectionSettings.relay_host) { $script:ConnectionSettings.relay_host } else { $Config["RELAY_HOST"] }
            $resolvedRelaySshPort = if ($script:ConnectionSettings.relay_ssh_port) { [int]$script:ConnectionSettings.relay_ssh_port } else { [int](Get-ConfigValue -Config $Config -Key "RELAY_SSH_PORT" -DefaultValue "22") }
            $resolvedRelayUser = if ($script:ConnectionSettings.relay_user) { $script:ConnectionSettings.relay_user } else { "tunnel" }
            $response = @{
                ok               = $true
                relay_host       = $resolvedRelayHost
                relay_ssh_port   = $resolvedRelaySshPort
                relay_user       = $resolvedRelayUser
                remote_port      = 24137
                device_record_id = "dev_dry_run"
                connect_command  = "ssh -p 24137 $($env:USERNAME)@$resolvedRelayHost"
                tunnel_options   = @{
                    remote_bind_address = "0.0.0.0"
                    local_host = "127.0.0.1"
                    local_port = 22
                }
            }
            if (Use-LiveRelayInDryRun) {
                $response = Invoke-RestMethod `
                    -Method Post `
                    -Uri $Config["ENROLL_API"] `
                    -ContentType "application/json" `
                    -Body ($body | ConvertTo-Json)
            }
        } else {
            $response = Invoke-RestMethod `
                -Method Post `
                -Uri $Config["ENROLL_API"] `
                -ContentType "application/json" `
                -Body ($body | ConvertTo-Json)
        }

        $response | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $responsePath -Encoding utf8
        Set-StepState -Id "enroll_device" -State "success" -Message "已成功注册到中转服务器。"
    }
    return (Get-ContentRaw -Path $responsePath) | ConvertFrom-Json
}

function Start-ReverseTunnel {
    param(
        [psobject]$EnrollResponse,
        [string]$DeviceKeyPath
    )
    $keeperPidPath = Join-Path $script:RuntimeRoot "tunnel-keeper.pid"
    $keeperLogPath = Join-Path $script:RuntimeRoot "tunnel-keeper.log"
    $statePath = Join-Path $script:RuntimeRoot "tunnel-state.json"
    $stopFlagPath = Join-Path $script:RuntimeRoot "tunnel.stop"
    $retrySeconds = [int](Get-ConfigValue -Config $script:Config -Key "TUNNEL_RETRY_SECONDS" -DefaultValue "5")
    Invoke-Step -Id "start_reverse_tunnel" -Message "正在启动反向 SSH 隧道。" -Action {
        if ($script:DryRun -and -not (Use-LiveRelayInDryRun)) {
            Set-Content -LiteralPath $keeperPidPath -Value "99999" -Encoding ascii
            Set-StepState -Id "start_reverse_tunnel" -State "success" -Message "演练模式下已模拟反向隧道。"
            return
        }

        foreach ($path in @(
            $keeperPidPath,
            $keeperLogPath,
            $statePath,
            $stopFlagPath,
            (Join-Path $script:RuntimeRoot "tunnel.stdout.log"),
            (Join-Path $script:RuntimeRoot "tunnel.stderr.log")
        )) {
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force
            }
        }

        $keeperScript = $PSCommandPath
        $keeperArgs = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", ('"{0}"' -f $keeperScript),
            "-Mode", "tunnel_keeper",
            "-RuntimeRoot", ('"{0}"' -f $script:RuntimeRoot),
            "-DeviceKeyPath", ('"{0}"' -f $DeviceKeyPath),
            "-RelayHost", $EnrollResponse.relay_host,
            "-RelaySshPort", "$($EnrollResponse.relay_ssh_port)",
            "-RelayUser", $EnrollResponse.relay_user,
            "-RemoteBindAddress", $EnrollResponse.tunnel_options.remote_bind_address,
            "-RemotePort", "$($EnrollResponse.remote_port)",
            "-LocalHost", $EnrollResponse.tunnel_options.local_host,
            "-LocalPort", "$($EnrollResponse.tunnel_options.local_port)",
            "-RetrySeconds", "$retrySeconds"
        )

        $keeperProc = Start-Process -FilePath "powershell.exe" -ArgumentList $keeperArgs -PassThru -WindowStyle Hidden
        Set-Content -LiteralPath $keeperPidPath -Value $keeperProc.Id -Encoding ascii
        Set-DetailLogPath -Path $keeperLogPath

        $connected = $false
        foreach ($attempt in 1..10) {
            Start-Sleep -Seconds 2
            $keeperProc.Refresh()
            if ($keeperProc.HasExited) {
                break
            }
            if (Test-Path -LiteralPath $statePath) {
                $state = (Get-ContentRaw -Path $statePath) | ConvertFrom-Json
                if ($state.status -eq "connected") {
                    $connected = $true
                    break
                }
                if ((($state.message) -match "\S")) {
                    Set-StepState -Id "start_reverse_tunnel" -State "running" -Message $state.message
                }
            }
        }

        if (-not $connected) {
            $keeperProc.Refresh()
            $keeperLogText = if (Test-Path -LiteralPath $keeperLogPath) { ((Get-ContentRaw -Path $keeperLogPath)).Trim() } else { "" }
            if ($keeperProc.HasExited) {
                if ((($keeperLogText) -match "^\s*$")) {
                    throw "隧道守护进程启动后立即退出。"
                }
                throw ("隧道守护进程启动后立即退出：{0}" -f $keeperLogText)
            }
            if ((($keeperLogText) -match "^\s*$")) {
                throw "等待反向隧道就绪超时。"
            }
            throw ("等待反向隧道就绪超时：{0}" -f $keeperLogText)
        }

        Set-StepState -Id "start_reverse_tunnel" -State "success" -Message "反向隧道已建立，守护进程正在运行。"
    }
}

function Verify-Tunnel {
    Invoke-Step -Id "verify_tunnel" -Message "正在校验隧道状态。" -Action {
        if ($script:DryRun -and -not (Use-LiveRelayInDryRun)) {
            Start-Sleep -Milliseconds 200
            Set-StepState -Id "verify_tunnel" -State "success" -Message "演练模式下隧道校验成功。"
            return
        }

        $keeperPidPath = Join-Path $script:RuntimeRoot "tunnel-keeper.pid"
        $statePath = Join-Path $script:RuntimeRoot "tunnel-state.json"
        $keeperPid = (Get-ContentRaw -Path $keeperPidPath)
        $keeperProc = Get-Process -Id ([int]$keeperPid) -ErrorAction SilentlyContinue
        if ($null -eq $keeperProc) {
            throw "隧道守护进程已退出。"
        }
        if (-not (Test-Path -LiteralPath $statePath)) {
            throw "缺少隧道状态文件。"
        }
        $state = (Get-ContentRaw -Path $statePath) | ConvertFrom-Json
        if ($state.status -ne "connected") {
            throw ("隧道当前未连接，当前状态：{0}" -f $state.status)
        }
        Set-StepState -Id "verify_tunnel" -State "success" -Message "隧道守护进程正常，隧道已连接。"
    }
}

function Write-KeeperLog {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format "s"), $Message
    Add-Content -LiteralPath $script:KeeperLogPath -Value $line -Encoding utf8
}

function Save-KeeperState {
    param(
        [string]$Status,
        [string]$Message,
        [int]$SshPid = 0
    )
    @{
        status = $Status
        message = $Message
        ssh_pid = $SshPid
        updated_at = (Get-Date).ToUniversalTime().ToString("s") + "Z"
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:StatePath -Encoding utf8
}

function Append-KeeperRunLogs {
    param(
        [string]$StdoutPath,
        [string]$StderrPath
    )
    if (Test-Path -LiteralPath $StdoutPath) {
        $stdoutText = ((Get-ContentRaw -Path $StdoutPath)).Trim()
        if ((($stdoutText) -match "\S")) {
            Add-Content -LiteralPath $script:StdoutLogPath -Value $stdoutText -Encoding utf8
        }
        Remove-Item -LiteralPath $StdoutPath -Force
    }
    if (Test-Path -LiteralPath $StderrPath) {
        $stderrText = ((Get-ContentRaw -Path $StderrPath)).Trim()
        if ((($stderrText) -match "\S")) {
            Add-Content -LiteralPath $script:StderrLogPath -Value $stderrText -Encoding utf8
            Write-KeeperLog ("ssh 输出错误信息：{0}" -f $stderrText)
        }
        Remove-Item -LiteralPath $StderrPath -Force
    }
}

function Run-TunnelKeeperMode {
    $script:KeeperLogPath = Join-Path $RuntimeRoot "tunnel-keeper.log"
    $script:StatePath = Join-Path $RuntimeRoot "tunnel-state.json"
    $script:StdoutLogPath = Join-Path $RuntimeRoot "tunnel.stdout.log"
    $script:StderrLogPath = Join-Path $RuntimeRoot "tunnel.stderr.log"
    $stopFlagPath = Join-Path $RuntimeRoot "tunnel.stop"

    New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null
    Set-Content -LiteralPath $script:KeeperLogPath -Value ("[{0}] 隧道守护进程已启动。" -f (Get-Date -Format "s")) -Encoding utf8
    if (-not (Test-Path -LiteralPath $script:StdoutLogPath)) {
        Set-Content -LiteralPath $script:StdoutLogPath -Value "" -Encoding utf8
    }
    if (-not (Test-Path -LiteralPath $script:StderrLogPath)) {
        Set-Content -LiteralPath $script:StderrLogPath -Value "" -Encoding utf8
    }

    $args = @(
        "-N",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=NUL",
        "-i", $DeviceKeyPath,
        "-p", "$RelaySshPort",
        "-R", "$RemoteBindAddress`:$RemotePort`:$LocalHost`:$LocalPort",
        "$RelayUser@$RelayHost"
    )

    while (-not (Test-Path -LiteralPath $stopFlagPath)) {
        $runStamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $runStdoutPath = Join-Path $RuntimeRoot ("tunnel-run-{0}.stdout.log" -f $runStamp)
        $runStderrPath = Join-Path $RuntimeRoot ("tunnel-run-{0}.stderr.log" -f $runStamp)

        Write-KeeperLog ("准备建立反向隧道，目标端口 {0} -> {1}:{2}" -f $RemotePort, $LocalHost, $LocalPort)
        Save-KeeperState -Status "connecting" -Message "正在建立反向 SSH 隧道。"

        $proc = Start-Process -FilePath "ssh.exe" -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardOutput $runStdoutPath -RedirectStandardError $runStderrPath
        Start-Sleep -Seconds 3
        $proc.Refresh()

        if (-not $proc.HasExited) {
            Write-KeeperLog ("反向隧道已建立，ssh 进程 PID={0}" -f $proc.Id)
            Save-KeeperState -Status "connected" -Message "反向 SSH 隧道已建立。" -SshPid $proc.Id
            while (-not $proc.HasExited) {
                if (Test-Path -LiteralPath $stopFlagPath) {
                    Write-KeeperLog "收到停止标记，准备关闭隧道进程。"
                    try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
                    break
                }
                Start-Sleep -Seconds 2
                $proc.Refresh()
            }
        }

        Append-KeeperRunLogs -StdoutPath $runStdoutPath -StderrPath $runStderrPath
        $proc.Refresh()
        $exitCode = if ($proc.HasExited) { $proc.ExitCode } else { -1 }

        if (Test-Path -LiteralPath $stopFlagPath) {
            Save-KeeperState -Status "stopped" -Message "隧道守护进程已停止。"
            Write-KeeperLog "隧道守护进程已停止。"
            break
        }

        $retryMessage = "隧道已断开，准备自动重连。"
        Write-KeeperLog ("ssh 进程已退出，退出码={0}。{1}" -f $exitCode, $retryMessage)
        Save-KeeperState -Status "retrying" -Message $retryMessage
        Start-Sleep -Seconds $RetrySeconds
    }

    exit 0
}

# 1. 预定义核心运行时路径与状态对象，防止初始化崩溃时无法记录错误结果
$script:RuntimeRoot = $RuntimeRoot
$script:ResultPath = Join-Path $RuntimeRoot "result.json"
$script:StatusPath = Join-Path $RuntimeRoot "status.json"
$script:LogPath = Join-Path $RuntimeRoot "worker.log"
$script:Status = @{
    session_id = $SessionId
    current_step = "init"
    overall_status = "running"
    detail_log_path = $script:LogPath
    steps = @()
}

if ($Mode -eq "tunnel_keeper") {
    Run-TunnelKeeperMode
}

try {
    # 创建运行目录与启动日志
    New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null
    Set-Content -LiteralPath $script:LogPath -Value ("[{0}] 后台执行器已启动。" -f (Get-Date -Format "s")) -Encoding utf8

    $config = Read-IniFile -Path $ConfigPath
    $script:Config = $config
    $script:DryRun = Get-ConfigFlag -Config $config -Key "DRY_RUN"
    $script:ConnectionSettings = @{}

    $script:Status = @{
        session_id = $SessionId
        current_step = ""
        overall_status = "running"
        detail_log_path = $script:LogPath
        steps = @(
            @{ id = "check_admin"; title = "Check administrator privileges"; status = "pending"; message = "Waiting"; started_at = $null; finished_at = $null },
            @{ id = "validate_config"; title = "Validate config"; status = "pending"; message = "Waiting"; started_at = $null; finished_at = $null },
            @{ id = "fetch_connection_settings"; title = "Fetch connection settings"; status = "pending"; message = "Waiting"; started_at = $null; finished_at = $null },
            @{ id = "check_openssh"; title = "Check OpenSSH Server"; status = "pending"; message = "Waiting"; started_at = $null; finished_at = $null },
            @{ id = "install_openssh"; title = "Install OpenSSH Server"; status = "pending"; message = "Waiting"; started_at = $null; finished_at = $null },
            @{ id = "start_sshd"; title = "Start sshd service"; status = "pending"; message = "Waiting"; started_at = $null; finished_at = $null },
            @{ id = "configure_firewall"; title = "Configure Windows Firewall"; status = "pending"; message = "Waiting"; started_at = $null; finished_at = $null },
            @{ id = "verify_local_ssh"; title = "Verify local SSH"; status = "pending"; message = "Waiting"; started_at = $null; finished_at = $null },
            @{ id = "generate_device_key"; title = "Generate device key"; status = "pending"; message = "Waiting"; started_at = $null; finished_at = $null },
            @{ id = "write_authorized_keys"; title = "Write admin public key"; status = "pending"; message = "Waiting"; started_at = $null; finished_at = $null },
            @{ id = "enroll_device"; title = "Register with relay server"; status = "pending"; message = "Waiting"; started_at = $null; finished_at = $null },
            @{ id = "start_reverse_tunnel"; title = "Start reverse SSH tunnel"; status = "pending"; message = "Waiting"; started_at = $null; finished_at = $null },
            @{ id = "verify_tunnel"; title = "Verify tunnel"; status = "pending"; message = "Waiting"; started_at = $null; finished_at = $null }
        )
    }
    Save-Status

    Set-StepState -Id "check_admin" -State "running" -Message "正在检查管理员权限。"
    if (-not $script:DryRun -and -not (Test-IsAdministrator)) {
        throw "后台执行器必须在管理员权限下运行。"
    }
    Set-StepState -Id "check_admin" -State "success" -Message $(if ($script:DryRun) { "演练模式下已跳过管理员权限检查。" } else { "已确认管理员权限。" })

    Validate-Config -Config $config
    Resolve-ConnectionSettings -Config $config
    Ensure-ServiceInstalled
    Ensure-SshdRunning
    Ensure-FirewallRule
    Verify-LocalSsh
    $deviceKeyPath = Ensure-DeviceKey
    Ensure-AuthorizedKey
    $enrollResponse = Enroll-Device -Config $config -DeviceKeyPath $deviceKeyPath
    Start-ReverseTunnel -EnrollResponse $enrollResponse -DeviceKeyPath $deviceKeyPath
    Verify-Tunnel

    Finish-Run -Ok $true -Payload @{
        connect_command = $enrollResponse.connect_command
        relay_host = $enrollResponse.relay_host
        remote_port = $enrollResponse.remote_port
        local_user = $env:USERNAME
        user_message = "连接已经准备完成，请把命令发给管理员。"
    }
} catch {
    $detailedError = $_.Exception.ToString()
    if ($_.ScriptStackTrace) {
        $detailedError += "`nScript StackTrace: " + $_.ScriptStackTrace
    }
    try {
        if ($script:LogPath) {
            Write-Log "fatal [failed] $detailedError"
        }
    } catch {}
    Finish-Run -Ok $false -Payload @{
        error_code = "WORKER_FAILED"
        message = $detailedError
        user_message = "处理过程中发生错误。请按提示检查 config.ini，或把日志和截图发给管理员。"
    }
}
















