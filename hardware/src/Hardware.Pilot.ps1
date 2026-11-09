[CmdletBinding()]
param([string]$PilotRoot = (Join-Path $env:ProgramData 'PlayDooh\HardwarePilot'))
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Import-Module (Join-Path $PSScriptRoot 'Hardware.Core.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Hardware.Readings.psm1') -Force
$config = Get-Content -LiteralPath (Join-Path $PilotRoot 'config.json') -Raw | ConvertFrom-Json
$existing = Get-Content -LiteralPath $config.existingConfigPath -Raw | ConvertFrom-Json
if ($existing.screenId -ne $config.screenId) { throw 'Screen ID changed. Reinstall the hardware pilot to confirm identity.' }
$board = Get-CimInstance Win32_BaseBoard
$cpu = Get-CimInstance Win32_Processor
$allowUnidentified = $config.PSObject.Properties['observeUnidentifiedHardware'] -and $config.observeUnidentifiedHardware -eq $true
$dailySending = $config.PSObject.Properties['reportingPolicy'] -and $config.reportingPolicy -eq 'daily-v1'
$hardwareType = Get-HardwareCompatibility ([string]$board.Product) ([string]$cpu.Name) ([string]$config.mode) ([bool]$allowUnidentified) ([bool]$dailySending)
$mutex = New-Object Threading.Mutex($false, 'Global\PlayDoohHardwarePilot')
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); exit 0 }
$computer = $null
$state = $null
$phase = 'state'
$path = Join-Path $PilotRoot 'state.json'
$log = Join-Path $PilotRoot 'pilot.log'
try {
    $settings = New-HardwareSettings
    $state = if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } else { New-HardwareState $config.screenId ([datetimeoffset]::Now) }
    if ($state.screenId -ne $config.screenId -or $state.schemaVersion -ne 1) { throw 'Hardware state identity/schema mismatch.' }
    $state | Add-Member -NotePropertyName hardwareType -NotePropertyValue $hardwareType -Force
    # Load Windows credential support before registering third-party DLL resolution.
    $phase = 'credential support'
    if($config.mode -eq 'Send'){
        [void][Reflection.Assembly]::Load('System.Security, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b03f5f7f11d50a3a')
        $null=[Security.Cryptography.ProtectedData]
    }
    $phase = 'sensors'
    $computer = Open-HardwareSensors (Join-Path $PilotRoot 'tools\LibreHardwareMonitor')
    # Save channel identities for review; never assume this PC has the same fan mapping.
    $inventory = @(Get-HardwareSensorInventory $computer)
    if ($state.PSObject.Properties['fanIdentifier'] -and -not [string]::IsNullOrWhiteSpace([string]$state.fanIdentifier)) {
        # Preserve the original primary channel across inventory changes and migration.
        $settings.fanIdentifier = [string]$state.fanIdentifier
    } elseif ($hardwareType -eq 'unidentified-i7-11700') {
        $settings.fanIdentifier = Get-ObservationFanIdentifier $inventory
    }
    $state | Add-Member -NotePropertyName fanIdentifier -NotePropertyValue $settings.fanIdentifier -Force
    $state | Add-Member -NotePropertyName hardwareVersion -NotePropertyValue 'v9' -Force
    $knownFans = if ($state.PSObject.Properties['fanCatalog']) { @($state.fanCatalog) } else { @() }
    $knownFans = @(Get-HardwareFanChannels $inventory $knownFans)
    $state | Add-Member -NotePropertyName fanCatalog -NotePropertyValue $knownFans -Force
    if (-not (Test-Path -LiteralPath (Join-Path $PilotRoot 'Sensor-Inventory.csv'))) {
        $inventory | Export-Csv -LiteralPath (Join-Path $PilotRoot 'Sensor-Inventory.csv') -NoTypeInformation -Encoding UTF8
    }
    # One short execution per scheduled hour; no resident polling process.
    & {
        $now = [datetimeoffset]::Now
        try {
            $null = Read-HardwareSensors $computer $settings.fanIdentifier $state.fanCatalog
            Start-Sleep -Seconds 2 # Establish a short CPU-load measurement interval.
            $sample = Read-HardwareSensors $computer $settings.fanIdentifier $state.fanCatalog
        } catch {
            $missingFans = @(Get-HardwareFanChannels @() $state.fanCatalog)
            $sample = [pscustomobject]@{ cpuC = $null; fanRpm = $null; cpuLoad = $null; fans = $missingFans; primaryFanIdentifier = $settings.fanIdentifier }
        }
        $state.fanCatalog = @($sample.fans | Select-Object identifier,name)
        $state = Add-HardwareSample $state $sample $now $settings
        if (-not $state.lastSsdAttemptAt -or ($now - [datetimeoffset]::Parse($state.lastSsdAttemptAt)).TotalHours -ge 24) {
            $state.lastSsdAttemptAt = $now.ToString('o')
            $state.latestSsd = Read-HardwareSsd (Join-Path $PilotRoot 'tools\smartmontools\bin\smartctl.exe')
        }
        Add-HardwareDaily $state $now $existing.uploadTime
        # Persist events before attempting delivery. Replayed requests have stable IDs.
        Save-HardwareState $state $path
        if ($config.mode -eq 'Send') {
            # Remove the sensor resolver before decrypting credentials or making HTTPS requests.
            $script:phase = 'sensor cleanup'
            Close-HardwareSensors $computer
            $computer = $null
            $script:phase = 'credential decryption'
            $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($existing.protectedToken), $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
            $token = [Text.Encoding]::UTF8.GetString($bytes)
            $script:phase = 'daily delivery'
            try { Send-HardwarePending $state $existing.endpoint $token $now } finally { $token = $null; [Array]::Clear($bytes,0,$bytes.Length) }
            Save-HardwareState $state $path
        }
    }
} catch {
    $failureType=$_.Exception.GetType().Name
    $failureLine=$_.InvocationInfo.ScriptLineNumber
    if($null -ne $state){$state.lastError=('Collector failed during '+$phase+' ('+$failureType+').');try{Save-HardwareState $state $path}catch{}}
    if ((Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).Length -gt 256KB) { Move-Item -LiteralPath $log -Destination ($log + '.previous') -Force }
    Add-Content -LiteralPath $log -Value ("{0:o} Collector stopped. Phase: {1}; error type: {2}; line: {3}. No credentials logged." -f [datetimeoffset]::Now,$phase,$failureType,$failureLine)
    throw
} finally {
    try { Close-HardwareSensors $computer } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}
