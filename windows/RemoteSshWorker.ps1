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
                throw "未安装 sshd 服务。"
            }
            if ($service.Status -ne "Running") {
                if (Use-LiveRelayInDryRun) {
                    throw "sshd 服务未运行，当前演练联调模式不会在没有管理员权限的情况下启动服务。"
                }
                Start-Service sshd
            }
            if (-not (Use-LiveRelayInDryRun)) {
                Set-Service -Name sshd -StartupType Automatic
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

        $rule = Get-NetFirewallRule -Name "RemoteSshRelay-OpenSSH" -ErrorAction SilentlyContinue
        if ($null -eq $rule) {
            New-NetFirewallRule `
                -Name "RemoteSshRelay-OpenSSH" `
                -DisplayName "Remote SSH Relay - OpenSSH" `
                -Direction Inbound `
                -Protocol TCP `
                -LocalPort 22 `
                -Action Allow | Out-Null
            Set-StepState -Id "configure_firewall" -State "success" -Message "已创建防火墙规则。"
        } else {
            Set-StepState -Id "configure_firewall" -State "skipped" -Message "防火墙规则已存在。"
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

        $result = Test-NetConnection 127.0.0.1 -Port 22 -WarningAction SilentlyContinue
        if (-not $result.TcpTestSucceeded) {
            throw "127.0.0.1:22 的本机 SSH 监听不可达。"
        }
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
    param([hashtable]$Config)
    Invoke-Step -Id "write_authorized_keys" -Message "正在写入管理员公钥。" -Action {
        $adminKey = $Config["ADMIN_PUBLIC_KEY"]
        if ([string]::IsNullOrWhiteSpace($adminKey) -or $adminKey -like "*CHANGE-ME*") {
            throw "未配置管理员公钥。"
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
        Set-StepState -Id "enroll_device" -State "success" -Message "已成功注册到中转服务器。"
    }
    return Get-Content -LiteralPath $responsePath -Raw | ConvertFrom-Json
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
                $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
                if ($state.status -eq "connected") {
                    $connected = $true
                    break
                }
                if (-not [string]::IsNullOrWhiteSpace($state.message)) {
                    Set-StepState -Id "start_reverse_tunnel" -State "running" -Message $state.message
                }
            }
        }

        if (-not $connected) {
            $keeperProc.Refresh()
            $keeperLogText = if (Test-Path -LiteralPath $keeperLogPath) { (Get-Content -LiteralPath $keeperLogPath -Raw).Trim() } else { "" }
            if ($keeperProc.HasExited) {
                if ([string]::IsNullOrWhiteSpace($keeperLogText)) {
                    throw "隧道守护进程启动后立即退出。"
                }
                throw ("The tunnel keeper process exited immediately: {0}" -f $keeperLogText)
            }
            if ([string]::IsNullOrWhiteSpace($keeperLogText)) {
                throw "等待反向隧道就绪超时。"
            }
            throw ("Timed out while waiting for the reverse tunnel to become ready: {0}" -f $keeperLogText)
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
        $keeperPid = Get-Content -LiteralPath $keeperPidPath -Raw
        $keeperProc = Get-Process -Id ([int]$keeperPid) -ErrorAction SilentlyContinue
        if ($null -eq $keeperProc) {
            throw "隧道守护进程已退出。"
        }
        if (-not (Test-Path -LiteralPath $statePath)) {
            throw "缺少隧道状态文件。"
        }
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
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
        $stdoutText = (Get-Content -LiteralPath $StdoutPath -Raw).Trim()
        if (-not [string]::IsNullOrWhiteSpace($stdoutText)) {
            Add-Content -LiteralPath $script:StdoutLogPath -Value $stdoutText -Encoding utf8
        }
        Remove-Item -LiteralPath $StdoutPath -Force
    }
    if (Test-Path -LiteralPath $StderrPath) {
        $stderrText = (Get-Content -LiteralPath $StderrPath -Raw).Trim()
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
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

if ($Mode -eq "tunnel_keeper") {
    Run-TunnelKeeperMode
}
$config = Read-IniFile -Path $ConfigPath
$script:RuntimeRoot = $RuntimeRoot
$script:StatusPath = Join-Path $RuntimeRoot "status.json"
$script:ResultPath = Join-Path $RuntimeRoot "result.json"
$script:LogPath = Join-Path $RuntimeRoot "worker.log"
$script:Config = $config
$script:DryRun = ((Get-ConfigValue -Config $config -Key "DRY_RUN" -DefaultValue "false").ToLowerInvariant() -eq "true")
New-Item -ItemType Directory -Force -Path $RuntimeRoot | Out-Null
Set-Content -LiteralPath $script:LogPath -Value ("[{0}] 后台执行器已启动。" -f (Get-Date -Format "s")) -Encoding utf8

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
    Set-StepState -Id "check_admin" -State "running" -Message "正在检查管理员权限。"
    if (-not $script:DryRun -and -not (Test-IsAdministrator)) {
        throw "后台执行器必须在管理员权限下运行。"
    }
    Set-StepState -Id "check_admin" -State "success" -Message $(if ($script:DryRun) { "演练模式下已跳过管理员权限检查。" } else { "已确认管理员权限。" })

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







