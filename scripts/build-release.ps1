param(
    [string]$OutputRoot = "",
    [string]$Version = ""
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $projectRoot "release"
}

$suffix = if ($Version) { "-$Version" } else { "" }
$zipPath = Join-Path $OutputRoot "remote-ssh-relay-kit$suffix.zip"
$stageRoot = Join-Path $OutputRoot "package"

# 1. 打包主源码发布包
if (Test-Path -LiteralPath $stageRoot) {
    try {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
    } catch {}
}
if (Test-Path -LiteralPath $zipPath) {
    try {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    } catch {}
}

New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
foreach ($name in @("server", "windows", "mac", "docs", "scripts", "README.md", "package.json")) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination $stageRoot -Recurse -Force
}

Compress-Archive -Path (Join-Path $stageRoot "*") -DestinationPath $zipPath -Force
Write-Host "Release package created:"
Write-Host "  $zipPath"

# 2. 如果存在 launcher-kit 暂存目录，则自动打包并覆盖指定版本的 launcher zips
$launcherKitPath = Join-Path $OutputRoot "launcher-kit"
if (Test-Path -LiteralPath $launcherKitPath) {
    Write-Host "Packaging launcher kits with version suffix: $Version"
    
    $winZip = Join-Path $OutputRoot "launcher-kit-windows$suffix.zip"
    $macZip = Join-Path $OutputRoot "launcher-kit-mac$suffix.zip"
    $allZip = Join-Path $OutputRoot "launcher-kit$suffix.zip"
    
    foreach ($p in @($winZip, $macZip, $allZip)) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    
    Compress-Archive -Path (Join-Path $launcherKitPath "windows\*") -DestinationPath $winZip -Force
    Compress-Archive -Path (Join-Path $launcherKitPath "mac\*") -DestinationPath $macZip -Force
    Compress-Archive -Path (Join-Path $launcherKitPath "*") -DestinationPath $allZip -Force
    
    Write-Host "Launcher packages created:"
    Write-Host "  $winZip"
    Write-Host "  $macZip"
    Write-Host "  $allZip"
}
