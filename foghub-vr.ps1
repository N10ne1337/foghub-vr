[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('save', 'setup')]
    [string]$Mode = 'setup',

    [string]$AlvrClientName = '',
    [string]$AlvrClientIp = '',
    [string]$ZeroTierNetworkId = '88c5b1f339f8da7d',
    [switch]$NoBundle
)

if ($AlvrClientIp -and -not $AlvrClientName) {
    $AlvrClientName = 'client'
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
}

$Root = $PSScriptRoot
if (-not $Root) {
    $Root = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$Files = Join-Path $Root 'files'
$AlvrRoot = 'C:\FogHubVR\ALVR'
$AlvrRootParent = 'C:\FogHubVR'
$PackageZip = Join-Path $Root 'foghub-vr-package.zip'
$SessionInPackage = Join-Path $Files 'alvr-session.json'
$StreamerZipLocal = Join-Path $Files 'alvr_streamer_windows.zip'
$ZeroTierMsiLocal = Join-Path $Files 'ZeroTierOne.msi'
$ZeroTierData = 'C:\ProgramData\ZeroTier\One'
$ZeroTierService = 'ZeroTierOneService'
$RuleName = 'SteamVR ALVR vrserver'

function Write-Step {
    param([string]$Text)
    Write-Host ''
    Write-Host "== $Text =="
}

function Test-Admin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal -ArgumentList $identity
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Get-LocalAppData {
    $path = $env:LOCALAPPDATA
    if (-not $path) {
        $path = [Environment]::GetFolderPath('LocalApplicationData')
    }
    return $path
}

function Get-OpenVrPaths {
    $local = Get-LocalAppData
    if (-not $local) {
        return $null
    }
    $path = Join-Path $local 'openvr\openvrpaths.vrpath'
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }
    try {
        return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Find-AlvrSessionRoot {
    $all = New-Object System.Collections.Generic.List[string]
    if ($env:ALVR_ROOT) {
        $all.Add($env:ALVR_ROOT)
    }

    $ovr = Get-OpenVrPaths
    if ($ovr -and $ovr.external_drivers) {
        foreach ($entry in @($ovr.external_drivers)) {
            if ($entry) {
                $all.Add([string]$entry)
            }
        }
    }

    $local = Get-LocalAppData
    if ($local) {
        $all.Add((Join-Path $local 'ALVR'))
        $installations = Join-Path $local 'ALVR\installations'
        if (Test-Path -LiteralPath $installations) {
            Get-ChildItem -LiteralPath $installations -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $all.Add($_.FullName)
            }
        }
    }
    $all.Add('C:\Program Files\ALVR')
    $all.Add('C:\Program Files (x86)\ALVR')
    $all.Add('C:\ALVR')
    $all.Add($AlvrRoot)

    foreach ($root in $all) {
        if (-not $root) {
            continue
        }
        if (Test-Path -LiteralPath (Join-Path $root 'session.json')) {
            return $root
        }
    }
    return $null
}

function Get-SavedAlvrVersion {
    if (-not (Test-Path -LiteralPath $SessionInPackage)) {
        return $null
    }
    try {
        $json = Get-Content -Raw -LiteralPath $SessionInPackage | ConvertFrom-Json
        if ($json.server_version) {
            return [string]$json.server_version
        }
    } catch {
    }
    return $null
}

function Get-SteamExe {
    $candidates = New-Object System.Collections.Generic.List[string]
    $keys = @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )
    foreach ($key in $keys) {
        $item = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($item) {
            foreach ($name in @('SteamPath', 'InstallPath')) {
                $value = $item.$name
                if ($value) {
                    $base = ([string]$value) -replace '/', '\'
                    $candidates.Add((Join-Path $base 'steam.exe'))
                }
            }
        }
    }
    $candidates.Add('C:\Program Files (x86)\Steam\steam.exe')
    $candidates.Add('C:\Program Files\Steam\steam.exe')
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}

function Get-SteamVrRoot {
    $ovr = Get-OpenVrPaths
    if ($ovr -and $ovr.runtime) {
        foreach ($entry in @($ovr.runtime)) {
            if (-not $entry) {
                continue
            }
            $root = [string]$entry
            if (Test-Path -LiteralPath (Join-Path $root 'bin\win64\vrserver.exe')) {
                return $root
            }
        }
    }

    $roots = New-Object System.Collections.Generic.List[string]
    $steam = Get-SteamExe
    if ($steam) {
        $steamRoot = Split-Path -Parent $steam
        $roots.Add((Join-Path $steamRoot 'steamapps\common\SteamVR'))
        $libraryFile = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $libraryFile) {
            try {
                $libraryText = Get-Content -Raw -LiteralPath $libraryFile
                $pathMatches = [regex]::Matches($libraryText, '"path"\s+"([^"]+)"')
                if ($pathMatches.Count -eq 0) {
                    $pathMatches = [regex]::Matches($libraryText, '"\d+"\s+"([A-Za-z]:[^"]*)"')
                }
                foreach ($pathMatch in $pathMatches) {
                    $library = $pathMatch.Groups[1].Value.Replace('\\', '\')
                    $roots.Add((Join-Path $library 'steamapps\common\SteamVR'))
                }
            } catch {
            }
        }
    }
    $roots.Add('C:\Program Files (x86)\Steam\steamapps\common\SteamVR')
    $roots.Add('C:\Program Files\Steam\steamapps\common\SteamVR')
    foreach ($root in $roots) {
        if (Test-Path -LiteralPath (Join-Path $root 'bin\win64\vrserver.exe')) {
            return $root
        }
    }
    return $null
}

function Initialize-OpenVrPaths {
    param([string]$SteamVrRoot)
    $local = Get-LocalAppData
    if (-not $local) {
        return
    }
    $dir = Join-Path $local 'openvr'
    $path = Join-Path $dir 'openvrpaths.vrpath'
    if (Test-Path -LiteralPath $path) {
        return
    }

    $steamRoot = $null
    $steam = Get-SteamExe
    if ($steam) {
        $steamRoot = Split-Path -Parent $steam
    }

    $runtime = $SteamVrRoot.Replace('\', '\\')
    $configJson = '[]'
    $logJson = '[]'
    if ($steamRoot) {
        $configJson = '["' + (Join-Path $steamRoot 'config').Replace('\', '\\') + '"]'
        $logJson = '["' + (Join-Path $steamRoot 'logs').Replace('\', '\\') + '"]'
    }
    $text = @"
{
  "config": $configJson,
  "external_drivers": [],
  "jsonid": "vrpathreg",
  "log": $logJson,
  "runtime": ["$runtime"],
  "version": 1
}
"@
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Write-Utf8NoBom -Path $path -Text $text
    Write-Host "Created $path"
}

function Save-RemoteFile {
    param([string]$Uri, [string]$Destination)
    $partial = "$Destination.part"
    if (Test-Path -LiteralPath $partial) {
        Remove-Item -LiteralPath $partial -Force
    }
    Invoke-WebRequest -Uri $Uri -OutFile $partial -UseBasicParsing
    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force
    }
    Move-Item -LiteralPath $partial -Destination $Destination -Force
    if (Test-Path -LiteralPath $Destination) {
        Unblock-File -LiteralPath $Destination -ErrorAction SilentlyContinue
    }
}

function Resolve-AlvrStreamer {
    param([string]$Version)
    $headers = @{ 'User-Agent' = 'foghub-vr' }
    $repos = @(
        'https://api.github.com/repos/alvr-org/ALVR/releases',
        'https://api.github.com/repos/alvr-org/ALVR-nightly/releases'
    )
    $fallback = $null
    foreach ($repo in $repos) {
        try {
            $releases = Invoke-RestMethod -Uri $repo -Headers $headers -UseBasicParsing
        } catch {
            Write-Warning "GitHub API request failed: $($_.Exception.Message)"
            continue
        }
        foreach ($release in @($releases)) {
            $asset = @($release.assets) | Where-Object { $_.name -eq 'alvr_streamer_windows.zip' } | Select-Object -First 1
            if (-not $asset) {
                continue
            }
            $tag = [string]$release.tag_name
            $name = [string]$release.name
            $result = @{
                Url = [string]$asset.browser_download_url
                Tag = $tag
            }
            if (-not $fallback) {
                $fallback = $result
            }
            if ($Version) {
                $want = $Version.TrimStart('v')
                $have = $tag.TrimStart('v')
                if ($have -eq $want -or $name -eq "ALVR v$want" -or $name -eq "ALVR $want") {
                    return $result
                }
            }
        }
    }
    if ($Version) {
        Write-Warning "ALVR $Version was not found on GitHub; using the newest available build."
    }
    return $fallback
}

function Save-AlvrStreamer {
    param([string]$Version, [string]$Destination)
    $info = Resolve-AlvrStreamer -Version $Version
    if (-not $info -or -not $info.Url) {
        throw 'Could not find alvr_streamer_windows.zip on GitHub.'
    }
    Write-Host "Downloading ALVR streamer $($info.Tag)..."
    Save-RemoteFile -Uri $info.Url -Destination $Destination
}

function Save-ZeroTierMsi {
    param([string]$Destination)
    if (Test-Path -LiteralPath $Destination) {
        return
    }
    Write-Host 'Downloading ZeroTier One...'
    Save-RemoteFile -Uri 'https://download.zerotier.com/dist/ZeroTier%20One.msi' -Destination $Destination
}

function Copy-Tree {
    param([string]$Source, [string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    & robocopy $Source $Destination /MIR /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed with exit code $LASTEXITCODE."
    }
}

function Set-AlvrClientConfig {
    param([string]$Path)
    $json = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    if (-not $json) {
        throw "Could not parse $Path."
    }

    if (-not ($json.PSObject.Properties.Name -contains 'client_connections')) {
        $json | Add-Member -NotePropertyName 'client_connections' -NotePropertyValue (New-Object psobject)
    }
    $connections = $json.client_connections
    if (-not $connections) {
        $json.client_connections = New-Object psobject
        $connections = $json.client_connections
    }

    if ($AlvrClientIp) {
        foreach ($property in @($connections.PSObject.Properties)) {
            $remove = $false
            if ($property.Name -eq $AlvrClientName) {
                $remove = $true
            } else {
                $value = $property.Value
                if ($value) {
                    if ($value.manual_ips -and (@($value.manual_ips) -contains $AlvrClientIp)) {
                        $remove = $true
                    }
                    if ([string]$value.current_ip -eq $AlvrClientIp) {
                        $remove = $true
                    }
                }
            }
            if ($remove) {
                $connections.PSObject.Properties.Remove($property.Name)
            }
        }

        $entry = New-Object psobject
        $entry | Add-Member -NotePropertyName 'display_name' -NotePropertyValue $AlvrClientName
        $entry | Add-Member -NotePropertyName 'current_ip' -NotePropertyValue $null
        $entry | Add-Member -NotePropertyName 'manual_ips' -NotePropertyValue @($AlvrClientIp)
        $entry | Add-Member -NotePropertyName 'trusted' -NotePropertyValue $true
        $entry | Add-Member -NotePropertyName 'connection_state' -NotePropertyValue 'Disconnected'
        $connections | Add-Member -NotePropertyName $AlvrClientName -NotePropertyValue $entry
    }

    if ($json.PSObject.Properties.Name -contains 'session_settings') {
        $settings = $json.session_settings
        if ($settings -and $settings.PSObject.Properties.Name -contains 'extra') {
            $extra = $settings.extra
            if ($extra) {
                if ($extra.PSObject.Properties.Name -contains 'open_setup_wizard') {
                    $extra.open_setup_wizard = $false
                } else {
                    $extra | Add-Member -NotePropertyName 'open_setup_wizard' -NotePropertyValue $false
                }
            }
        }
    }

    Write-Utf8NoBom -Path $Path -Text ($json | ConvertTo-Json -Depth 100)
}

function New-MinimalAlvrSession {
    param([string]$Path)
    if ($AlvrClientIp) {
        $safeName = $AlvrClientName.Replace('\', '\\').Replace('"', '\"')
        $safeIp = $AlvrClientIp.Replace('\', '\\').Replace('"', '\"')
        $text = @"
{
  "client_connections": {
    "$safeName": {
      "display_name": "$safeName",
      "current_ip": null,
      "manual_ips": ["$safeIp"],
      "trusted": true,
      "connection_state": "Disconnected"
    }
  },
  "session_settings": {
    "extra": {
      "open_setup_wizard": false
    }
  }
}
"@
    } else {
        $text = @"
{
  "client_connections": {},
  "session_settings": {
    "extra": {
      "open_setup_wizard": false
    }
  }
}
"@
    }
    Write-Utf8NoBom -Path $Path -Text $text
}

function Assert-AlvrSession {
    param([string]$Path)
    $raw = Get-Content -Raw -LiteralPath $Path
    if ($AlvrClientIp) {
        $namePattern = [regex]::Escape($AlvrClientName)
        if ($raw -notmatch ('"' + $namePattern + '"\s*:\s*\{[^}]*"manual_ips"\s*:\s*\[')) {
            throw 'session.json manual_ips is not a JSON array.'
        }
    }
    $json = $raw | ConvertFrom-Json
    if (-not $json -or -not $json.client_connections) {
        throw 'session.json has no client_connections.'
    }
    if (-not $AlvrClientIp) {
        Write-Host 'Verified session.json (no client preset).'
        return
    }
    $property = $json.client_connections.PSObject.Properties[$AlvrClientName]
    if (-not $property) {
        throw "session.json has no entry for $AlvrClientName."
    }
    $value = $property.Value
    $ips = @($value.manual_ips)
    if (-not ($ips -contains $AlvrClientIp)) {
        throw "session.json does not contain $AlvrClientIp for $AlvrClientName."
    }
    if ($value.trusted -ne $true) {
        throw 'session.json client entry is not trusted.'
    }
    Write-Host "Verified session.json: $AlvrClientName -> $($ips -join ', ')"
}

function Invoke-Save {
    Write-Step 'Save ALVR and ZeroTier settings'
    if (-not (Test-Path -LiteralPath $Files)) {
        New-Item -ItemType Directory -Path $Files -Force | Out-Null
    }
    foreach ($stale in @('config-alvr', 'ALVR.msi')) {
        $stalePath = Join-Path $Files $stale
        if (Test-Path -LiteralPath $stalePath) {
            Remove-Item -LiteralPath $stalePath -Recurse -Force
        }
    }

    Write-Host 'Close ALVR and its dashboard now, if they are open.'
    Start-Sleep -Seconds 5

    Write-Step 'ALVR settings'
    $alvrSource = Find-AlvrSessionRoot
    if ($alvrSource) {
        Write-Host "Found ALVR: $alvrSource"
        Copy-Item -LiteralPath (Join-Path $alvrSource 'session.json') -Destination $SessionInPackage -Force
        $version = Get-SavedAlvrVersion
        if ($version) {
            Write-Host "ALVR version: $version"
        }
    } else {
        Write-Warning 'ALVR session.json was not found. Default settings will be used.'
        if (Test-Path -LiteralPath $SessionInPackage) {
            Remove-Item -LiteralPath $SessionInPackage -Force
        }
    }

    Write-Step 'ZeroTier identity'
    $ztBackup = Join-Path $Files 'config-zerotier'
    if (Test-Path -LiteralPath $ZeroTierData) {
        if (Test-Path -LiteralPath $ztBackup) {
            Remove-Item -LiteralPath $ztBackup -Recurse -Force
        }
        Stop-Service -Name $ZeroTierService -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        try {
            Copy-Tree -Source $ZeroTierData -Destination $ztBackup
        } finally {
            Start-Service -Name $ZeroTierService -ErrorAction SilentlyContinue
        }
        if (-not (Test-Path -LiteralPath (Join-Path $ztBackup 'identity.secret'))) {
            Write-Warning 'ZeroTier identity.secret was not copied. Stop the service and retry.'
        } else {
            Write-Host 'Saved ZeroTier identity (node ID, keys, network membership).'
        }
    } else {
        Write-Warning 'C:\ProgramData\ZeroTier\One was not found.'
        if (Test-Path -LiteralPath $ztBackup) {
            Remove-Item -LiteralPath $ztBackup -Recurse -Force
        }
    }

    Write-Step 'Installers'
    try {
        Save-ZeroTierMsi -Destination $ZeroTierMsiLocal
    } catch {
        Write-Warning "Could not download the ZeroTier MSI: $($_.Exception.Message)"
    }

    if ($NoBundle) {
        if (Test-Path -LiteralPath $StreamerZipLocal) {
            Remove-Item -LiteralPath $StreamerZipLocal -Force
        }
        Write-Host 'Skipping the ALVR streamer bundle (-NoBundle).'
    } else {
        try {
            Save-AlvrStreamer -Version (Get-SavedAlvrVersion) -Destination $StreamerZipLocal
        } catch {
            Write-Warning "Could not download the ALVR streamer: $($_.Exception.Message)"
        }
    }

    Write-Step 'Create package'
    $stage = Join-Path $env:TEMP ('foghub-package-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        foreach ($name in @('foghub-vr.cmd', 'foghub-vr.ps1')) {
            $path = Join-Path $Root $name
            if (Test-Path -LiteralPath $path) {
                Copy-Item -LiteralPath $path -Destination $stage -Force
            }
        }
        Copy-Item -LiteralPath $Files -Destination $stage -Recurse -Force
        if (Test-Path -LiteralPath $PackageZip) {
            Remove-Item -LiteralPath $PackageZip -Force
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [IO.Compression.ZipFile]::CreateFromDirectory($stage, $PackageZip, [IO.Compression.CompressionLevel]::Fastest, $false)
    } finally {
        if (Test-Path -LiteralPath $stage) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $size = [math]::Round((Get-Item -LiteralPath $PackageZip).Length / 1MB, 1)
    Write-Host "Package created: $PackageZip ($size MB)"
    Write-Host 'Keep this file private: it contains your ZeroTier identity keys.'
    try {
        Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$PackageZip`""
    } catch {
    }
}

function Install-ZeroTier {
    $service = Get-Service -Name $ZeroTierService -ErrorAction SilentlyContinue
    if ($service) {
        Write-Host 'ZeroTier One is already installed.'
        return
    }

    $msi = $ZeroTierMsiLocal
    if (-not (Test-Path -LiteralPath $msi)) {
        $msi = Join-Path $env:TEMP 'ZeroTierOne.msi'
        Save-ZeroTierMsi -Destination $msi
    }

    Write-Host 'Installing ZeroTier One...'
    Unblock-File -LiteralPath $msi -ErrorAction SilentlyContinue
    $arguments = "/i `"$msi`" /qn /norestart"
    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw "ZeroTier installation failed (exit code $($process.ExitCode))."
    }
}

function Restore-ZeroTierIdentity {
    $backup = Join-Path $Files 'config-zerotier'
    if (-not (Test-Path -LiteralPath $backup)) {
        Write-Warning 'No saved ZeroTier identity. A new node will be created.'
        return
    }

    Write-Host 'Restoring ZeroTier identity...'
    Stop-Service -Name $ZeroTierService -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    New-Item -ItemType Directory -Path $ZeroTierData -Force | Out-Null
    try {
        Copy-Tree -Source $backup -Destination $ZeroTierData
    } finally {
        Start-Service -Name $ZeroTierService -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2

    if (-not (Test-Path -LiteralPath (Join-Path $ZeroTierData 'identity.secret'))) {
        Write-Warning 'ZeroTier identity.secret was not restored.'
    }
    $service = Get-Service -Name $ZeroTierService -ErrorAction SilentlyContinue
    if (-not $service -or $service.Status -ne 'Running') {
        Write-Warning 'ZeroTier service is not running.'
    }
}

function Join-ZeroTierNetwork {
    $cli = $null
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if (-not $base) {
            continue
        }
        $candidate = Join-Path $base 'ZeroTier\One\zerotier-cli.bat'
        if (Test-Path -LiteralPath $candidate) {
            $cli = $candidate
            break
        }
    }
    if (-not $cli) {
        Write-Warning 'zerotier-cli was not found. Join the network manually.'
        return
    }

    Write-Host "Joining ZeroTier network $ZeroTierNetworkId..."
    $join = $null
    for ($i = 0; $i -lt 10; $i++) {
        $join = & cmd.exe /c "`"$cli`" join $ZeroTierNetworkId 2>&1"
        if (($join -join "`n") -match '200 join OK') {
            break
        }
        Start-Sleep -Seconds 1
    }
    $join | ForEach-Object { Write-Host $_ }

    $networks = $null
    for ($i = 0; $i -lt 15; $i++) {
        $networks = & cmd.exe /c "`"$cli`" listnetworks 2>&1"
        if (($networks -join "`n") -match '(^|\s)OK(\s|$)') {
            break
        }
        Start-Sleep -Seconds 1
    }
    if ($networks) {
        $networks | ForEach-Object { Write-Host $_ }
    }

    $flat = ''
    if ($networks) {
        $flat = $networks -join "`n"
    }
    if ($flat -notmatch [regex]::Escape($ZeroTierNetworkId)) {
        Write-Warning 'The ZeroTier network is not joined. Check the network ID.'
    } elseif ($flat -notmatch '(^|\s)OK(\s|$)') {
        Write-Warning 'ZeroTier network is joined but not authorized yet. Authorize this node in ZeroTier Central.'
    }

    $info = & cmd.exe /c "`"$cli`" info 2>&1"
    if ($info) {
        $info | ForEach-Object { Write-Host $_ }
    }
}

function Install-Alvr {
    $zip = $StreamerZipLocal
    if (-not (Test-Path -LiteralPath $zip)) {
        $zip = Join-Path $env:TEMP 'alvr_streamer_windows.zip'
        Save-AlvrStreamer -Version (Get-SavedAlvrVersion) -Destination $zip
    }
    Write-Host "ALVR package: $zip"

    Write-Host 'Stopping ALVR and SteamVR processes...'
    $processNames = @('ALVR Dashboard', 'ALVR Launcher', 'alvr_server_windows', 'vrmonitor', 'vrcompositor', 'vrdashboard', 'vrserver', 'alvr_server_x64', 'ALVR')
    foreach ($name in $processNames) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
    foreach ($name in $processNames) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1

    Unblock-File -LiteralPath $zip -ErrorAction SilentlyContinue
    $tempDir = Join-Path $env:TEMP ('foghub-alvr-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tempDir)
        $source = $tempDir
        $manifestFile = Get-ChildItem -LiteralPath $tempDir -Filter 'driver.vrdrivermanifest' -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($manifestFile) {
            $source = $manifestFile.DirectoryName
        } else {
            $dashboard = Get-ChildItem -LiteralPath $tempDir -Filter 'ALVR Dashboard.exe' -Recurse -Depth 3 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($dashboard) {
                $source = $dashboard.DirectoryName
            }
        }

        if (Test-Path -LiteralPath $AlvrRoot) {
            Remove-Item -LiteralPath $AlvrRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Path $AlvrRootParent -Force | Out-Null
        Move-Item -LiteralPath $source -Destination $AlvrRoot
    } finally {
        if (Test-Path -LiteralPath $tempDir) {
            Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    $manifest = Join-Path $AlvrRoot 'driver.vrdrivermanifest'
    if (-not (Test-Path -LiteralPath $manifest)) {
        throw 'ALVR extraction failed: driver.vrdrivermanifest is missing.'
    }
    Get-ChildItem -LiteralPath $AlvrRoot -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue
    }
    & icacls $AlvrRootParent /grant '*S-1-5-32-545:(OI)(CI)M' /T /C | Out-Null
    Write-Host "ALVR installed to $AlvrRoot"
}

function Install-AlvrSession {
    New-Item -ItemType Directory -Path $AlvrRoot -Force | Out-Null
    $target = Join-Path $AlvrRoot 'session.json'
    if (Test-Path -LiteralPath $SessionInPackage) {
        Write-Host 'Restoring saved ALVR settings...'
        Copy-Item -LiteralPath $SessionInPackage -Destination $target -Force
        try {
            Set-AlvrClientConfig -Path $target
            Assert-AlvrSession -Path $target
        } catch {
            Write-Warning "Could not update the saved ALVR settings: $($_.Exception.Message)"
            New-MinimalAlvrSession -Path $target
            Assert-AlvrSession -Path $target
        }
    } elseif ($AlvrClientIp) {
        Write-Host 'Creating default ALVR settings with the client preset...'
        New-MinimalAlvrSession -Path $target
        Assert-AlvrSession -Path $target
    } else {
        Write-Host 'No ALVR preset: ALVR will create default settings on first start.'
        Write-Host 'Add the client manually in the ALVR dashboard.'
        return
    }
    if ($AlvrClientIp) {
        Write-Host "Client preset: $AlvrClientName -> $AlvrClientIp"
    }
}

function Set-VrServerFirewallRules {
    param([string]$SteamVrRoot)
    if (-not $SteamVrRoot) {
        Write-Warning 'SteamVR was not found; firewall rules were skipped.'
        return
    }

    Write-Host 'Adding firewall rules for vrserver.exe...'
    & cmd.exe /c "netsh advfirewall firewall delete rule name=`"$RuleName`" >nul 2>&1" | Out-Null
    foreach ($relative in @('bin\win64\vrserver.exe', 'bin\win32\vrserver.exe')) {
        $path = Join-Path $SteamVrRoot $relative
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }
        & cmd.exe /c "netsh advfirewall firewall add rule name=`"$RuleName`" dir=in program=`"$path`" action=allow >nul" | Out-Null
        Write-Host "Allowed: $path"
    }
}

function Test-SamePath {
    param([string]$Left, [string]$Right)
    $trimChars = [char[]]@('\', '/')
    $leftNorm = (($Left -replace '/', '\').TrimEnd($trimChars)).ToLowerInvariant()
    $rightNorm = (($Right -replace '/', '\').TrimEnd($trimChars)).ToLowerInvariant()
    return $leftNorm -eq $rightNorm
}

function Remove-StaleAlvrDrivers {
    param([string]$VrPathReg)
    $ovr = Get-OpenVrPaths
    if (-not $ovr -or -not $ovr.external_drivers) {
        return
    }
    foreach ($entry in @($ovr.external_drivers)) {
        if (-not $entry) {
            continue
        }
        $root = [string]$entry
        if (Test-SamePath -Left $root -Right $AlvrRoot) {
            continue
        }
        $manifest = Join-Path $root 'driver.vrdrivermanifest'
        if (-not (Test-Path -LiteralPath $manifest)) {
            continue
        }
        try {
            $manifestJson = Get-Content -Raw -LiteralPath $manifest | ConvertFrom-Json
            if ($manifestJson.name -eq 'alvr_server') {
                Write-Host "Removing old ALVR driver registration: $root"
                & $VrPathReg removedriver $root | Out-Null
            }
        } catch {
        }
    }
}

function Register-AlvrDriver {
    param([string]$SteamVrRoot)
    if (-not $SteamVrRoot) {
        throw 'SteamVR was not found. Install SteamVR or run it once, then retry.'
    }

    $vrpathreg = Join-Path $SteamVrRoot 'bin\win64\vrpathreg.exe'
    if (-not (Test-Path -LiteralPath $vrpathreg)) {
        $vrpathreg = Join-Path $SteamVrRoot 'bin\win32\vrpathreg.exe'
    }
    if (-not (Test-Path -LiteralPath $vrpathreg)) {
        throw 'vrpathreg.exe was not found in the SteamVR folder.'
    }

    Remove-StaleAlvrDrivers -VrPathReg $vrpathreg
    Write-Host 'Registering the ALVR driver...'
    & $vrpathreg removedriver $AlvrRoot 2>$null | Out-Null
    & $vrpathreg adddriver $AlvrRoot | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "vrpathreg failed with exit code $LASTEXITCODE."
    }

    $ovr = Get-OpenVrPaths
    $registered = $false
    if ($ovr -and $ovr.external_drivers) {
        foreach ($entry in @($ovr.external_drivers)) {
            if ($entry -and (Test-SamePath -Left ([string]$entry) -Right $AlvrRoot)) {
                $registered = $true
                break
            }
        }
    }
    if (-not $registered) {
        throw 'ALVR driver registration did not appear in openvrpaths.vrpath.'
    }
    Write-Host 'ALVR driver registered.'
}

function Ensure-SteamRunning {
    $steam = Get-SteamExe
    if (-not $steam) {
        Write-Warning 'Steam was not found. Start SteamVR manually.'
        return
    }
    if (Get-Process -Name 'steam' -ErrorAction SilentlyContinue) {
        Write-Host 'Steam is already running.'
        return
    }

    Write-Host 'Starting Steam...'
    Start-Process -FilePath $steam -ArgumentList '-silent'
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Seconds 1
        if (Get-Process -Name 'steam' -ErrorAction SilentlyContinue) {
            return
        }
    }
    Write-Warning 'Steam did not start in time.'
}

function Launch-SteamVr {
    Write-Host 'Starting SteamVR...'
    try {
        Start-Process 'steam://rungameid/250820'
    } catch {
        $steam = Get-SteamExe
        if (-not $steam) {
            throw
        }
        Start-Process -FilePath $steam -ArgumentList '-applaunch 250820'
    }
}

function Invoke-Setup {
    Write-Step 'ZeroTier One'
    Install-ZeroTier
    Restore-ZeroTierIdentity
    Join-ZeroTierNetwork

    Write-Step 'ALVR'
    Install-Alvr
    Install-AlvrSession

    Write-Step 'SteamVR'
    $steamVr = Get-SteamVrRoot
    if (-not $steamVr) {
        Write-Warning 'SteamVR was not found on this PC.'
    } else {
        Write-Host "SteamVR: $steamVr"
        Initialize-OpenVrPaths -SteamVrRoot $steamVr
        Set-VrServerFirewallRules -SteamVrRoot $steamVr
        Ensure-SteamRunning
        Register-AlvrDriver -SteamVrRoot $steamVr
        Launch-SteamVr
    }

    Write-Step 'Done'
    if ($AlvrClientIp) {
        Write-Host "ALVR client preset: $AlvrClientName"
        Write-Host "Client ZeroTier IP: $AlvrClientIp"
        Write-Host 'Start the ALVR client on the headset. The server will connect automatically.'
    } else {
        Write-Host 'Open C:\FogHubVR\ALVR\ALVR Dashboard.exe and add the client manually.'
        Write-Host 'Enter the headset ZeroTier IP there; settings are configured in the same dashboard.'
    }
    Write-Host 'If the headset does not connect, check the ALVR dashboard log.'
}

if (-not (Test-Admin)) {
    Write-Host 'ERROR: Run this script as Administrator.'
    exit 1
}

if ($Mode -eq 'save') {
    Invoke-Save
} else {
    Invoke-Setup
}
