$ignored = @("PSPath", "PSParentPath", "PSChildName", "PSDrive", "PSProvider", "PSAttachSvcGroup")

Write-Host "=================================================="
Write-Host "           Remote PC Diagnostic Report             "
Write-Host "=================================================="
$os = Get-WmiObject Win32_OperatingSystem
Write-Host "Hostname: $env:COMPUTERNAME"
Write-Host "User: $env:USERDOMAIN\$env:USERNAME"
Write-Host "OS: $($os.Caption) ($($os.Version))"
Write-Host "Local Time: $(Get-Date)"
Write-Host "=================================================="
Write-Host ""

# 1. CPU
Write-Host "--- [1.1 CPU Top Processes] ---"
Get-Process | Where-Object {$_.CPU -ne $null} | Sort-Object CPU -Descending | Select-Object -First 5 | ForEach-Object {
    Write-Host "$($_.Name) (PID: $($_.Id)) - CPU: $([Math]::Round($_.CPU, 1))%"
}
Write-Host ""

# 2. Memory
Write-Host "--- [1.2 Memory Info] ---"
$totalMem = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
$freeMem = [Math]::Round($os.FreePhysicalMemory / 1MB, 2)
$usedMem = $totalMem - $freeMem
Write-Host "Total Memory: $totalMem GB"
Write-Host "Free Memory : $freeMem GB ($([Math]::Round(($freeMem/$totalMem)*100, 1))% free)"
Write-Host ""
Write-Host "--- Memory Top Processes ---"
Get-Process | Sort-Object WorkingSet -Descending | Select-Object -First 5 | ForEach-Object {
    Write-Host "$($_.Name) (PID: $($_.Id)) - WS: $([Math]::Round($_.WorkingSet / 1MB, 1)) MB"
}
Write-Host ""

# 3. Disk Space & Health
Write-Host "--- [2.1 Disk Space & Health] ---"
Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    $size = [Math]::Round($_.Size / 1GB, 2)
    $free = [Math]::Round($_.FreeSpace / 1GB, 2)
    $pctFree = [Math]::Round(($free / $size) * 100, 1)
    Write-Host "$($_.DeviceID) ($($_.VolumeName)) - Free: $free GB / Total: $size GB ($pctFree% free)"
}
Write-Host ""
Write-Host "--- Disk SMART Status ---"
Get-WmiObject -Namespace root\wmi -Class MSStorageDriver_FailurePredictStatus -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "Disk Instance: $($_.InstanceName) - Failure Predict Active: $($_.PredictFailure)"
}
Write-Host ""

# 4. Temperature & CPU Clock
Write-Host "--- [1.4 CPU Clock & Temperature] ---"
$cpu = Get-WmiObject Win32_Processor
Write-Host "CPU Name: $($cpu.Name)"
Write-Host "Max Clock Speed: $($cpu.MaxClockSpeed) MHz"
Write-Host "Current Clock Speed: $($cpu.CurrentClockSpeed) MHz"
$temp = Get-WmiObject -Namespace root\wmi -ClassName MsAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue
if ($temp) {
    ForEach ($t in $temp) {
        $celsius = ($t.CurrentTemperature / 10) - 273.15
        Write-Host "Thermal Zone $($t.InstanceName): $([Math]::Round($celsius, 1)) C"
    }
} else {
    Write-Host "CPU Temperature: (WMI MsAcpi_ThermalZoneTemperature not supported/accessible)"
}
Write-Host ""

# 5. Power Plan
Write-Host "--- [1.5 Power Plan] ---"
powercfg /list
Write-Host ""

# 6. SSD Trim Status
Write-Host "--- [2.2 SSD Trim Status] ---"
fsutil behavior query DisableDeleteNotify
Write-Host ""

# 7. Temp Directory Size
Write-Host "--- [2.3 Temp Files Size] ---"
$tempPath = $env:TEMP
if (Test-Path $tempPath) {
    $tempFiles = Get-ChildItem -Path $tempPath -Recurse -ErrorAction SilentlyContinue
    $tempSize = ($tempFiles | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
    Write-Host "User Temp Size: $([Math]::Round($tempSize / 1MB, 2)) MB ($tempPath)"
}
$sysTempPath = "C:\Windows\Temp"
if (Test-Path $sysTempPath) {
    $sysTempFiles = Get-ChildItem -Path $sysTempPath -Recurse -ErrorAction SilentlyContinue
    $sysTempSize = ($sysTempFiles | Measure-Object -Property Length -Sum -ErrorAction SilentlyContinue).Sum
    Write-Host "System Temp Size: $([Math]::Round($sysTempSize / 1MB, 2)) MB ($sysTempPath)"
}
Write-Host ""

# 8. Startup Programs
Write-Host "--- [3.1 Startup Registry Entries] ---"
Write-Host "HKLM Run:"
Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Run -ErrorAction SilentlyContinue | Get-Member -MemberType NoteProperty | Where-Object { $ignored -notcontains $_.Name } | ForEach-Object {
    $name = $_.Name
    $val = (Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Run).$name
    Write-Host "  $name = $val"
}
Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Run -ErrorAction SilentlyContinue | Get-Member -MemberType NoteProperty | Where-Object { $ignored -notcontains $_.Name } | ForEach-Object {
    $name = $_.Name
    $val = (Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Run).$name
    Write-Host "  $name (32bit) = $val"
}
Write-Host "HKCU Run:"
Get-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\Run -ErrorAction SilentlyContinue | Get-Member -MemberType NoteProperty | Where-Object { $ignored -notcontains $_.Name } | ForEach-Object {
    $name = $_.Name
    $val = (Get-ItemProperty HKCU:\Software\Microsoft\Windows\CurrentVersion\Run).$name
    Write-Host "  $name = $val"
}
Write-Host "Startup Folder items:"
Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup" -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $($_.Name)" }
Get-ChildItem "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup" -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $($_.Name)" }
Write-Host ""

# 9. Third-party running services
Write-Host "--- [3.2 Running Non-Microsoft Services] ---"
Get-WmiObject Win32_Service | Where-Object {$_.State -eq "Running" -and $_.PathName -notmatch "svchost.exe" -and $_.PathName -notmatch "windows" -and $_.PathName -notmatch "microsoft"} | Select-Object Name, DisplayName | ForEach-Object {
    Write-Host "  $($_.DisplayName) ($($_.Name))"
}
Write-Host ""

# 10. Scheduled Tasks (Non-Microsoft)
Write-Host "--- [3.3 Scheduled Tasks] ---"
schtasks /query /fo csv | ConvertFrom-Csv -ErrorAction SilentlyContinue | Where-Object {$_."TaskName" -notmatch "^\\Microsoft\\"} | Select-Object -First 15 | ForEach-Object {
    Write-Host "  $($_."TaskName") - Status: $($_."Status")"
}
Write-Host ""

# 11. Security Software
Write-Host "--- [4.1 Registered AntiVirus Products] ---"
Get-WmiObject -Namespace root\SecurityCenter2 -Class AntiVirusProduct -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "  $($_.displayName) (Path: $($_.pathToSignedReportingExe))"
}
Write-Host ""

# 12. Installed Programs (Suspected bloatware or antivirus/cleanup)
Write-Host "--- [4.2 Installed Programs (Sample)] ---"
$keys = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
$apps = Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object {$_.DisplayName -ne $null} | Select-Object DisplayName, Publisher | Sort-Object DisplayName -Unique
$apps | Select-Object -First 30 | ForEach-Object {
    Write-Host "  $($_.DisplayName) - $($_.Publisher)"
}
Write-Host "... Total installed applications found: $($apps.Count)"
Write-Host ""

# 13. Hosts & Proxy
Write-Host "--- [4.3 Hosts File & Proxy Settings] ---"
$hostsPath = "C:\Windows\System32\drivers\etc\hosts"
if (Test-Path $hostsPath) {
    $hosts = Get-Content $hostsPath | Where-Object { $_ -match "^[^#]" -and $_.Trim() -ne "" }
    if ($hosts) {
        Write-Host "Hosts Entries:"
        $hosts | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host "Hosts File: default (no custom entries)"
    }
}
$regSettings = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue
Write-Host "Proxy Enabled: $($regSettings.ProxyEnable)"
if ($regSettings.ProxyEnable -eq 1) {
    Write-Host "Proxy Server : $($regSettings.ProxyServer)"
}
Write-Host ""

# 14. Event Logs (Recent Errors)
Write-Host "--- [5.4 Recent System Event Log Errors (Last 10)] ---"
Get-EventLog -LogName System -EntryType Error -Newest 10 -ErrorAction SilentlyContinue | ForEach-Object {
    $msg = $_.Message
    if ($msg.Length -gt 120) {
        $msg = $msg.SubString(0, 120) + "..."
    }
    $msg = $msg.Replace("`r`n", " ").Replace("`n", " ")
    Write-Host "  [$($_.TimeGenerated)] $($_.Source) : $msg"
}
Write-Host ""
