param(
    [Parameter(Mandatory = $true)]
    [string]$EnrollCode,
    [Parameter(Mandatory = $true)]
    [string]$AdminPublicKeyPath,
    [string]$RelayHost = "106.13.171.166",
    [int]$RelaySshPort = 22,
    [int]$ApiPort = 8787,
    [string]$OutputRoot = ""
)

$ErrorActionPreference = "Stop"

function Read-TextFile {
    param([string]$Path)
    return Get-Content -LiteralPath $Path -Raw
}

function Stamp-ConfigFile {
    param(
        [string]$Path,
        [string]$PublicKey
    )

    $config = Read-TextFile -Path $Path
    $config = $config -replace 'RELAY_HOST=.*', "RELAY_HOST=$RelayHost"
    $config = $config -replace 'RELAY_SSH_PORT=.*', "RELAY_SSH_PORT=$RelaySshPort"
    $config = $config -replace 'ENROLL_API=.*', "ENROLL_API=http://$RelayHost`:$ApiPort/api/enroll"
    $config = $config -replace 'ENROLL_CODE=.*', "ENROLL_CODE=$EnrollCode"
    $config = $config -replace 'ADMIN_PUBLIC_KEY=.*', "ADMIN_PUBLIC_KEY=$PublicKey"
    Set-Content -LiteralPath $Path -Value $config -Encoding ascii
}

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $projectRoot "release\launcher-kit"
}
$windowsSource = Join-Path $projectRoot "windows"
$macSource = Join-Path $projectRoot "mac"
$docsSource = Join-Path $projectRoot "docs"
$publicKey = (Read-TextFile -Path $AdminPublicKeyPath).Trim()

if (-not $publicKey.StartsWith("ssh-")) {
    throw "The public key does not look like an SSH public key."
}

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

Stamp-ConfigFile -Path (Join-Path $windowsOut "config.ini") -PublicKey $publicKey
Stamp-ConfigFile -Path (Join-Path $macOut "config.ini") -PublicKey $publicKey

Write-Host "Launcher kit prepared:"
Write-Host "  $OutputRoot"
