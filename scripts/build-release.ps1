param(
    [string]$OutputRoot = ""
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $projectRoot "release"
}
$zipPath = Join-Path $OutputRoot "remote-ssh-relay-kit.zip"
$stageRoot = Join-Path $OutputRoot "package"

if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
foreach ($name in @("server", "windows", "mac", "docs", "scripts", "README.md", "package.json")) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination $stageRoot -Recurse -Force
}

Compress-Archive -Path (Join-Path $stageRoot "*") -DestinationPath $zipPath -Force
Write-Host "Release package created:"
Write-Host "  $zipPath"
