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
$tempStageRoot = Join-Path $OutputRoot "package_temp_build"

# 1. Clean up temp staging path if it exists
if (Test-Path -LiteralPath $tempStageRoot) {
    try {
        Remove-Item -LiteralPath $tempStageRoot -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Warning "Failed to delete temp build stage: $_"
    }
}
New-Item -ItemType Directory -Force -Path $tempStageRoot | Out-Null

# 2. Copy code files to temp staging path
foreach ($name in @("server", "windows", "mac", "docs", "scripts", "README.md", "package.json")) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination $tempStageRoot -Recurse -Force
}

# 3. Compress from temp staging path to output zip
if (Test-Path -LiteralPath $zipPath) {
    try {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    } catch {}
}
Compress-Archive -Path (Join-Path $tempStageRoot "*") -DestinationPath $zipPath -Force

# 4. Clean up temp staging path
try {
    Remove-Item -LiteralPath $tempStageRoot -Recurse -Force -ErrorAction SilentlyContinue
} catch {}

# 5. Mirror files to release/package individually, avoiding locked files
if (-not (Test-Path -LiteralPath $stageRoot)) {
    New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
} else {
    # Try to clean up existing files/folders in package directory, ignoring locked ones
    Get-ChildItem -Path $stageRoot | ForEach-Object {
        try {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        } catch {}
    }
}

foreach ($name in @("server", "windows", "mac", "docs", "scripts", "README.md", "package.json")) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination $stageRoot -Recurse -Force
}
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
