param(
    [Parameter(Mandatory = $true)]
    [string]$LogPath
)

$ErrorActionPreference = "Stop"
$capabilityName = "OpenSSH.Server~~~~0.0.1.0"

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

    Write-InstallLog "鍑嗗鏀圭敤 DISM.exe 瀹夎 OpenSSH Server銆? "WARN"
    $args = @(
        "/Online",
        "/Add-Capability",
        "/CapabilityName:$capabilityName",
        "/NoRestart"
    )
    $proc = Start-Process -FilePath "dism.exe" -ArgumentList $args -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    if (Test-Path -LiteralPath $stdoutPath) {
        foreach ($line in Get-Content -LiteralPath $stdoutPath) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-InstallLog $line
            }
        }
    }
    if (Test-Path -LiteralPath $stderrPath) {
        foreach ($line in Get-Content -LiteralPath $stderrPath) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-InstallLog $line "WARN"
            }
        }
    }
    if ($proc.ExitCode -ne 0) {
        throw "DISM.exe 瀹夎澶辫触锛岄€€鍑虹爜锛?($proc.ExitCode)"
    }
}

try {
    Write-InstallLog "OpenSSH 瀹夎鍣ㄥ凡鍚姩銆?
    $state = Get-CapabilityState
    Write-InstallLog "褰撳墠 OpenSSH Server 缁勪欢鐘舵€侊細$state"
    if ($state -eq "Installed") {
        Write-InstallLog "绯荤粺宸茬粡瀹夎 OpenSSH Server锛屾棤闇€閲嶅瀹夎銆?
        exit 0
    }

    Write-InstallLog "寮€濮嬭皟鐢?Windows 鍙€夊姛鑳藉畨瑁?OpenSSH Server锛岃繖涓€姝ュ彲鑳芥寔缁嚑鍒嗛挓銆?
    try {
        $result = Add-WindowsCapability -Online -Name $capabilityName -ErrorAction Stop
        Write-InstallLog ("瀹夎鍛戒护杩斿洖鐘舵€侊細RestartNeeded={0}" -f $result.RestartNeeded)
    } catch {
        Write-InstallLog ("Add-WindowsCapability 鎵ц澶辫触锛歿0}" -f $_.Exception.Message) "WARN"
        Run-DismFallback
    }

    Start-Sleep -Seconds 2
    $state = Get-CapabilityState
    Write-InstallLog "瀹夎缁撴潫鍚庡啀娆℃鏌ョ粍浠剁姸鎬併€?
    Write-InstallLog "褰撳墠 OpenSSH Server 缁勪欢鐘舵€侊細$state"
    if ($state -ne "Installed") {
        throw "OpenSSH Server 瀹夎瀹屾垚鍚庣姸鎬佷粛鐒朵笉鏄?Installed銆?
    }

    Write-InstallLog "OpenSSH Server 瀹夎瀹屾垚銆?
} catch {
    Write-InstallLog ("OpenSSH 瀹夎澶辫触锛歿0}" -f $_.Exception.Message) "ERROR"
    throw
}

