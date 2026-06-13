param(
    [string]$ConfigPath,
    [string]$RuntimeRoot,
    [string]$SessionId
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

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Use-LiveRelayInDryRun {
    return ($script:DryRun -and ((Get-ConfigValue -Config $script:Config -Key "DRY_RUN_USE_LIVE_RELAY" -DefaultValue "false").ToLowerInvariant() -eq "true"))
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
            if ($State -in @("success", "failed", "skipped")) {
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
    Save-Status
    $Payload["ok"] = $Ok
    $Payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ResultPath -Encoding utf8
    exit
}

function Invoke-Step {
    param(
        [string]$Id,
        [string]$Message,
        [scriptblock]$Action
    )
    Set-StepState -Id $Id -State "running" -Message $Message
    & $Action
}

function Ensure-ServiceInstalled {
    $forceInstallInDryRun = ((Get-ConfigValue -Config $script:Config -Key "FORCE_INSTALL_OPENSSH_IN_DRY_RUN" -DefaultValue "false").ToLowerInvariant() -eq "true")
    $mode = (Get-ConfigValue -Config $script:Config -Key "INSTALL_OPENSSH_MODE" -DefaultValue "hidden").ToLowerInvariant()
    if ($mode -eq "window") {
        $mode = "cmd"
    }
    if ($mode -notin @("hidden", "cmd")) {
        $mode = "hidden"
    }
    $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($null -ne $service -and -not ($script:DryRun -and $forceInstallInDryRun)) {
        Set-StepState -Id "check_openssh" -State "success" -Message "OpenSSH Server is already installed."
        Set-StepState -Id "install_openssh" -State "skipped" -Message "Installation is not required."
        return
    }

    Set-StepState -Id "check_openssh" -State "success" -Message "OpenSSH Server is missing."
    Invoke-Step -Id "install_openssh" -Message "Installing OpenSSH Server." -Action {
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
                Set-StepState -Id "install_openssh" -State "running" -Message ("Installing OpenSSH Server. {0}" -f $line)
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
                            Set-StepState -Id "install_openssh" -State "running" -Message ("Installing OpenSSH Server. {0}" -f $newLastLine)
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
                throw "OpenSSH installer process failed."
            }

            Start-Sleep -Seconds 2
            $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
            if ($null -eq $service) {
                throw "OpenSSH Server install completed, but sshd service is still missing."
            }
            Set-DetailLogPath -Path $script:LogPath
        }
        Set-StepState -Id "install_openssh" -State "success" -Message "OpenSSH Server installed."
    }
}

function Ensure-SshdRunning {
    Invoke-Step -Id "start_sshd" -Message "Starting sshd service." -Action {
        if ($script:DryRun -and -not (Use-LiveRelayInDryRun)) {
            Start-Sleep -Milliseconds 500
        } else {
            $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
            if ($null -eq $service) {
                throw "sshd service is not installed."
            }
            if ($service.Status -ne "Running") {
                if (Use-LiveRelayInDryRun) {
                    throw "sshd service is not running, and live dry-run mode will not start services without administrator rights."
                }
                Start-Service sshd
            }
            if (-not (Use-LiveRelayInDryRun)) {
                Set-Service -Name sshd -StartupType Automatic
            }
        }
        Set-StepState -Id "start_sshd" -State "success" -Message "sshd service is running."
    }
}

function Ensure-FirewallRule {
    Invoke-Step -Id "configure_firewall" -Message "Configuring Windows Firewall." -Action {
        if ($script:DryRun) {
            Start-Sleep -Milliseconds 300
            Set-StepState -Id "configure_firewall" -State "success" -Message "Firewall rule simulated in dry run."
            return
        }

        $rule = Get-NetFirewallRule -Name "RemoteSshRelay-OpenSSH" -ErrorAction SilentlyContinue
        if ($null -eq $rule) {
            New-NetFirewallRule `
                -Name "RemoteSshRelay-OpenSSH" `
                -DisplayName "Remote SSH Relay - OpenSSH" `
                -Direction Inbound `
                -Protocol TCP `
                -LocalPort 22 `
                -Action Allow | Out-Null
            Set-StepState -Id "configure_firewall" -State "success" -Message "Firewall rule created."
        } else {
            Set-StepState -Id "configure_firewall" -State "skipped" -Message "Firewall rule already exists."
        }
    }
}

function Verify-LocalSsh {
    Invoke-Step -Id "verify_local_ssh" -Message "Verifying local SSH listener." -Action {
        if ($script:DryRun -and -not (Use-LiveRelayInDryRun)) {
            Start-Sleep -Milliseconds 300
            Set-StepState -Id "verify_local_ssh" -State "success" -Message "Local SSH verification simulated."
            return
        }

        $result = Test-NetConnection 127.0.0.1 -Port 22 -WarningAction SilentlyContinue
        if (-not $result.TcpTestSucceeded) {
            throw "Local SSH listener on 127.0.0.1:22 is not reachable."
        }
        Set-StepState -Id "verify_local_ssh" -State "success" -Message "Local SSH listener is reachable."
    }
}

function Ensure-DeviceKey {
    $keyPath = Join-Path $script:RuntimeRoot "device_key"
    Invoke-Step -Id "generate_device_key" -Message "Generating device key." -Action {
        if (-not (Test-Path -LiteralPath $keyPath)) {
            if ($script:DryRun) {
                Set-Content -LiteralPath $keyPath -Value "dry-run-private-key" -Encoding ascii
                Set-Content -LiteralPath ($keyPath + ".pub") -Value "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDryRunDeviceKey remote-ssh-relay" -Encoding ascii
            } else {
                & ssh-keygen -q -t ed25519 -N "" -f $keyPath | Out-Null
            }
        }
        Set-StepState -Id "generate_device_key" -State "success" -Message "Device key is ready."
    }
    return $keyPath
}

function Ensure-AuthorizedKey {
    param([hashtable]$Config)
    Invoke-Step -Id "write_authorized_keys" -Message "Writing admin public key." -Action {
        $adminKey = $Config["ADMIN_PUBLIC_KEY"]
        if ([string]::IsNullOrWhiteSpace($adminKey) -or $adminKey -like "*CHANGE-ME*") {
            throw "ADMIN_PUBLIC_KEY is not configured."
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
        Set-StepState -Id "write_authorized_keys" -State "success" -Message "Admin public key is present."
    }
}

function Enroll-Device {
    param(
        [hashtable]$Config,
        [string]$DeviceKeyPath
    )
    $responsePath = Join-Path $script:RuntimeRoot "enroll-response.json"
    Invoke-Step -Id "enroll_device" -Message "Registering with relay server." -Action {
        $body = @{
            enroll_code       = $Config["ENROLL_CODE"]
            device_id         = "win-" + ([guid]::NewGuid().ToString("N").Substring(0, 8))
            device_name       = $env:COMPUTERNAME
            device_public_key = (Get-Content -LiteralPath ($DeviceKeyPath + ".pub") -Raw).Trim()
            os_type           = "windows"
            local_user        = $env:USERNAME
            ssh_ready         = $true
            launcher_version  = "0.1.0"
        }

        if ($script:DryRun) {
            $response = @{
                ok               = $true
                relay_host       = $Config["RELAY_HOST"]
                relay_ssh_port   = [int](Get-ConfigValue -Config $Config -Key "RELAY_SSH_PORT" -DefaultValue "22")
                relay_user       = "tunnel"
                remote_port      = 24137
                device_record_id = "dev_dry_run"
                connect_command  = "ssh -p 24137 $($env:USERNAME)@$($Config["RELAY_HOST"])"
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
        Set-StepState -Id "enroll_device" -State "success" -Message "Relay registration succeeded."
    }
    return Get-Content -LiteralPath $responsePath -Raw | ConvertFrom-Json
}

function Start-ReverseTunnel {
    param(
        [psobject]$EnrollResponse,
        [string]$DeviceKeyPath
    )
    $pidPath = Join-Path $script:RuntimeRoot "tunnel.pid"
    Invoke-Step -Id "start_reverse_tunnel" -Message "Starting reverse SSH tunnel." -Action {
        if ($script:DryRun -and -not (Use-LiveRelayInDryRun)) {
            Set-Content -LiteralPath $pidPath -Value "99999" -Encoding ascii
            Set-StepState -Id "start_reverse_tunnel" -State "success" -Message "Dry-run tunnel simulated."
            return
        }

        $args = @(
            "-N",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=no",
            "-i", $DeviceKeyPath,
            "-p", "$($EnrollResponse.relay_ssh_port)",
            "-R", "$($EnrollResponse.tunnel_options.remote_bind_address):$($EnrollResponse.remote_port):$($EnrollResponse.tunnel_options.local_host):$($EnrollResponse.tunnel_options.local_port)",
            "$($EnrollResponse.relay_user)@$($EnrollResponse.relay_host)"
        )
        $proc = Start-Process -FilePath "ssh.exe" -ArgumentList $args -PassThru -WindowStyle Hidden
        Set-Content -LiteralPath $pidPath -Value $proc.Id -Encoding ascii
        Start-Sleep -Seconds 3
        if ($proc.HasExited) {
            throw "The reverse tunnel process exited immediately."
        }
        Set-StepState -Id "start_reverse_tunnel" -State "success" -Message "Reverse tunnel started."
    }
}

function Verify-Tunnel {
    Invoke-Step -Id "verify_tunnel" -Message "Verifying tunnel state." -Action {
        if ($script:DryRun -and -not (Use-LiveRelayInDryRun)) {
            Start-Sleep -Milliseconds 200
            Set-StepState -Id "verify_tunnel" -State "success" -Message "Dry-run tunnel verification succeeded."
            return
        }

        $pidPath = Join-Path $script:RuntimeRoot "tunnel.pid"
        $pid = Get-Content -LiteralPath $pidPath -Raw
        $proc = Get-Process -Id ([int]$pid) -ErrorAction SilentlyContinue
        if ($null -eq $proc) {
            throw "The tunnel process is no longer running."
        }
        Set-StepState -Id "verify_tunnel" -State "success" -Message "Tunnel process is alive."
    }
}

$config = Read-IniFile -Path $ConfigPath
$script:RuntimeRoot = $RuntimeRoot
$script:StatusPath = Join-Path $RuntimeRoot "status.json"
$script:ResultPath = Join-Path $RuntimeRoot "result.json"
$script:LogPath = Join-Path $RuntimeRoot "worker.log"
$script:Config = $config
$script:DryRun = ((Get-ConfigValue -Config $config -Key "DRY_RUN" -DefaultValue "false").ToLowerInvariant() -eq "true")
New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null
Set-Content -LiteralPath $script:LogPath -Value ("[{0}] Worker initialized." -f (Get-Date -Format "s")) -Encoding utf8

$script:Status = @{
    session_id = $SessionId
    current_step = ""
    overall_status = "running"
    detail_log_path = $script:LogPath
    steps = @(
        @{ id = "check_admin"; title = "Check administrator privileges"; status = "pending"; message = "Waiting"; started_at = $null; finished_at = $null },
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

try {
    Set-StepState -Id "check_admin" -State "running" -Message "Checking administrator rights."
    if (-not $script:DryRun -and -not (Test-IsAdministrator)) {
        throw "The worker must run with administrator rights."
    }
    Set-StepState -Id "check_admin" -State "success" -Message $(if ($script:DryRun) { "Administrator check bypassed in dry run." } else { "Administrator rights confirmed." })

    Ensure-ServiceInstalled
    Ensure-SshdRunning
    Ensure-FirewallRule
    Verify-LocalSsh
    $deviceKeyPath = Ensure-DeviceKey
    Ensure-AuthorizedKey -Config $config
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
    Write-Log "fatal [failed] $($_.Exception.Message)"
    Finish-Run -Ok $false -Payload @{
        error_code = "WORKER_FAILED"
        message = $_.Exception.Message
        user_message = "处理过程中发生错误，请把日志或截图发给管理员。"
    }
}



