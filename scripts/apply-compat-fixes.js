const fs = require('fs');
const path = require('path');

const HELPERS = `
function Get-ContentRaw {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "" }
    return [System.IO.File]::ReadAllText($Path)
}

function Convert-DictionaryToPSObject {
    param($InputObject)
    if ($InputObject -is [System.Collections.IDictionary]) {
        $customObj = New-Object PSObject
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

function Convert-PSObjectToDictionary {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $dict = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $dict[$prop.Name] = Convert-PSObjectToDictionary -InputObject $prop.Value
        }
        return $dict
    }
    elseif ($InputObject -is [System.Collections.IDictionary]) {
        $dict = @{}
        foreach ($key in $InputObject.Keys) {
            $dict[$key] = Convert-PSObjectToDictionary -InputObject $InputObject[$key]
        }
        return $dict
    }
    elseif ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $InputObject) {
            $list.Add((Convert-PSObjectToDictionary -InputObject $item)) | Out-Null
        }
        return ,($list.ToArray())
    }
    return $InputObject
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
            $json = ""
        }
        process {
            $json += $InputObject
        }
        end {
            if ($json -match '^\\s*$') { return $null }
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
            $connection = $tcp.ConnectAsync($ComputerName, $Port)
            if ($connection.Wait(1500) -and $tcp.Connected) {
                $connected = $true
            }
        } catch {}
        finally {
            $tcp.Close()
        }
        return New-Object PSObject -Property @{ TcpTestSucceeded = $connected }
    }
}
`;

function fixFile(filePath) {
    console.log(`Fixing file ${path.basename(filePath)}...`);
    let content = fs.readFileSync(filePath, 'utf8');

    // 1. Replace [string]::IsNullOrWhiteSpace(xxx) with (xxx -match '^\s*$')
    // And -not [string]::IsNullOrWhiteSpace(xxx) with (xxx -match '\S')
    content = content.replace(/-not\s+\[string\]::IsNullOrWhiteSpace\((.+?)\)/g, '(($1) -match "\\S")');
    content = content.replace(/!\s*\[string\]::IsNullOrWhiteSpace\((.+?)\)/g, '(($1) -match "\\S")');
    content = content.replace(/\[string\]::IsNullOrWhiteSpace\((.+?)\)/g, '(($1) -match "^\\s*$")');

    // 2. Replace Get-Content ... -Raw with (Get-ContentRaw -Path ...)
    content = content.replace(/Get-Content\s+-LiteralPath\s+(.+?)\s+-Raw/g, '(Get-ContentRaw -Path $1)');

    // 3. Replace -notin with -notcontains, and -in with -contains
    content = content.replace(/(\$\S+?)\s+-notin\s+@\((.+?)\)/g, '@($2) -notcontains $1');
    content = content.replace(/(\$\S+?)\s+-in\s+@\((.+?)\)/g, '@($2) -contains $1');

    // 3.5. PowerShell 2.0 Compatibility & Robustness Fixes
    content = content.replace(/\[guid\]::NewGuid\(\)/g, '[System.Guid]::NewGuid()');
    content = content.replace(/\$parts\s*=\s*\$trimmed\s*-split\s*"=",\s*2/g, '$parts = @($trimmed -split "=", 2)');

    // 4. Inject Helpers
    const fileName = path.basename(filePath);
    if (fileName === 'RemoteSshApp.ps1') {
        // First add the param block and PSScriptRoot fallback logic
        content = content.replace(/param\([\s\S]*?\[string\]\$ConfigPath\s*=\s*"\$PSScriptRoot\\config\.ini"[\s\S]*?\)/g, 
`param(
    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Stop"

if (-not $PSScriptRoot) {
    $PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Path
}
if (-not $PSCommandPath) {
    $PSCommandPath = $MyInvocation.MyCommand.Path
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot "config.ini"
}`);

        // Replace detailLines.Count -eq 0 check
        content = content.replace(/if\s*\(\$detailLines\.Count\s*-eq\s*0\)/g, 'if (-not $detailLines)');

        // Replace Start-Process block with robust UAC and redirection logic
        content = content.replace(/try\s*\{\s*if\s*\(\$showWorkerWindow\)[\s\S]*?\}\s*\}\s*catch\s*\{\s*Start-Process[\s\S]*?RunAs\s+\|\s+Out-Null\s*\}/g,
`function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$isParentAdmin = Test-IsAdministrator
$startupLog = Join-Path $runtimeRoot "worker-startup.log"

try {
    if ($isParentAdmin) {
        if ($showWorkerWindow) {
            Start-Process -FilePath "powershell.exe" -ArgumentList $workerArgs | Out-Null
        } else {
            Start-Process -FilePath "powershell.exe" -ArgumentList $workerArgs -WindowStyle Hidden -RedirectStandardError $startupLog | Out-Null
        }
    } else {
        if ($showWorkerWindow) {
            Start-Process -FilePath "powershell.exe" -ArgumentList $workerArgs -Verb RunAs | Out-Null
        } else {
            Start-Process -FilePath "powershell.exe" -ArgumentList $workerArgs -Verb RunAs -WindowStyle Hidden | Out-Null
        }
    }
} catch {
    Start-Process -FilePath "powershell.exe" -ArgumentList $workerArgs -Verb RunAs | Out-Null
}`);
    } else if (fileName === 'RemoteSshWorker.ps1') {
        // Add PSScriptRoot fallback for Worker script right after param block
        content = content.replace(/\)\s*\n\s*\$ErrorActionPreference\s*=\s*"Stop"/g, 
`)\n\n$ErrorActionPreference = "Stop"\n\nif (-not $PSScriptRoot) {\n    $PSScriptRoot = Split-Path -Parent -Path $MyInvocation.MyCommand.Path\n}\nif (-not $PSCommandPath) {\n    $PSCommandPath = $MyInvocation.MyCommand.Path\n}`);
    }

    // Now apply IsNullOrWhiteSpace replacement (so it also covers our new code in App script)
    content = content.replace(/-not\s+\[string\]::IsNullOrWhiteSpace\((.+?)\)/g, '(($1) -match "\\S")');
    content = content.replace(/!\s*\[string\]::IsNullOrWhiteSpace\((.+?)\)/g, '(($1) -match "\\S")');
    content = content.replace(/\[string\]::IsNullOrWhiteSpace\((.+?)\)/g, '(($1) -match "^\\s*$")');

    // Inject helpers before Read-IniFile function
    if (fileName === 'RemoteSshApp.ps1' || fileName === 'RemoteSshWorker.ps1') {
        const marker = 'function Read-IniFile {';
        if (content.includes(marker)) {
            content = content.replace(marker, () => HELPERS + '\n' + marker);
        } else {
            console.warn(`Could not find marker in ${fileName}`);
        }
    }

    // Strip existing BOM to prevent double BOM issues
    if (content.startsWith('\ufeff')) {
        content = content.slice(1);
    }

    // Write back with UTF-8 with BOM (0xEF 0xBB 0xBF)
    const bom = Buffer.from([0xEF, 0xBB, 0xBF]);
    const fileContent = Buffer.concat([bom, Buffer.from(content, 'utf8')]);
    fs.writeFileSync(filePath, fileContent);
}

function main() {
    const windowsDir = 'D:\\code\\remote-ssh-relay-kit\\windows';
    fixFile(path.join(windowsDir, 'RemoteSshApp.ps1'));
    fixFile(path.join(windowsDir, 'RemoteSshWorker.ps1'));
    fixFile(path.join(windowsDir, 'InstallOpenSsh.ps1'));
    console.log('All compatibility fixes successfully applied!');
}

main();
