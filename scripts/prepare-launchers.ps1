param(
    [Parameter(Mandatory = $true)]
    [string]$BootstrapToken,
    [string]$RelayHost = "yoong-relay.ddnsgeek.com",
    [string]$ApiHost = "",
    [int]$RelaySshPort = 22,
    [int]$ApiPort = 8787,
    [string]$OutputRoot = ""
)

$ErrorActionPreference = "Stop"

$effectiveApiHost = $ApiHost
if ([string]::IsNullOrEmpty($effectiveApiHost)) {
    $effectiveApiHost = $RelayHost
}

function Stamp-ConfigFile {
    param([string]$Path)

    $config = Get-Content -LiteralPath $Path -Raw
    $config = $config -replace 'RELAY_HOST=.*', "RELAY_HOST=$RelayHost"
    $config = $config -replace 'RELAY_SSH_PORT=.*', "RELAY_SSH_PORT=$RelaySshPort"
    $config = $config -replace 'ENROLL_API=.*', "ENROLL_API=http://$effectiveApiHost`:$ApiPort/api/enroll"
    $config = $config -replace 'BOOTSTRAP_API=.*', "BOOTSTRAP_API=http://$effectiveApiHost`:$ApiPort/api/bootstrap"
    $config = $config -replace 'BOOTSTRAP_TOKEN=.*', "BOOTSTRAP_TOKEN=$BootstrapToken"
    $config = $config -replace 'ENROLL_CODE=.*', "ENROLL_CODE="
    $config = $config -replace 'ADMIN_PUBLIC_KEY=.*', "ADMIN_PUBLIC_KEY="
    Set-Content -LiteralPath $Path -Value $config -Encoding ascii
}

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $projectRoot "release\launcher-kit"
}
$windowsSource = Join-Path $projectRoot "windows"
$macSource = Join-Path $projectRoot "mac"
$docsSource = Join-Path $projectRoot "docs"

if (Test-Path -LiteralPath $OutputRoot) {
    Remove-Item -LiteralPath $OutputRoot -Recurse -Force
}

$windowsOut = Join-Path $OutputRoot "windows"
$macOut = Join-Path $OutputRoot "mac"
$docsOut = Join-Path $OutputRoot "docs"

New-Item -ItemType Directory -Force -Path $windowsOut, $macOut, $docsOut | Out-Null
Copy-Item -Path (Join-Path $windowsSource "*") -Destination $windowsOut -Recurse -Force
Copy-Item -Path (Join-Path $macSource "*") -Destination $macOut -Recurse -Force
Copy-Item -Path (Join-Path $docsSource "*") -Destination $docsOut -Recurse -Force

Stamp-ConfigFile -Path (Join-Path $windowsOut "config.ini")
Stamp-ConfigFile -Path (Join-Path $macOut "config.ini")


Write-Host "Launcher kit prepared:"
Write-Host "  $OutputRoot"
