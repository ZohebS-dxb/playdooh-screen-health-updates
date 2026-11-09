# Run with Windows PowerShell 5.1: powershell.exe -NoProfile -File .\tests\Test-HardwareFans.ps1
# No Pester, DLLs, real sensors, credentials, network, or elevated permissions required.
[CmdletBinding()]
param([string]$SourceRoot = (Join-Path $PSScriptRoot '..\hardware\src'))
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
foreach ($file in Get-ChildItem -LiteralPath (Split-Path $SourceRoot -Parent) -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') }) {
    $tokens = $null; $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count) { throw ('PowerShell parse failure: ' + $file.Name + ': ' + ($parseErrors | Out-String)) }
}
Import-Module (Join-Path $SourceRoot 'Hardware.Core.psm1') -Force
Import-Module (Join-Path $SourceRoot 'Hardware.Readings.psm1') -Force
$script:Passed = 0
$script:Failed = 0
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($null -eq $Expected) { Assert-True ($null -eq $Actual) ($Message + ': expected null'); return }
    Assert-True ($null -ne $Actual -and $Actual -ceq $Expected) ($Message + ': expected [' + $Expected + '], got [' + $Actual + ']')
}
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:Passed++; Write-Host ('PASS: ' + $Name) }
    catch { $script:Failed++; Write-Host ('FAIL: ' + $Name + ': ' + $_.Exception.Message) -ForegroundColor Red }
}
function Fan([string]$Id, $Rpm, [string]$Name = 'Fan') {
    [pscustomobject]@{ hardwareType='SuperIO'; name=$Name; type='Fan'; value=$Rpm; identifier=$Id }
}
function Rows([object[]]$Fans) {
    @([pscustomobject]@{hardwareType='Cpu';name='CPU Package';type='Temperature';value=50;identifier='/cpu/temp/0'},
      [pscustomobject]@{hardwareType='Cpu';name='CPU Total';type='Load';value=25;identifier='/cpu/load/0'}) + @($Fans)
}
function Sample([object[]]$Fans, [object[]]$Known = @()) {
    Read-HardwareSensorRows -Rows (Rows $Fans) -FanIdentifier '/board/fan/1' -KnownFans $Known
}
function Channel($Channels, [string]$Id) {
    $found = @($Channels | Where-Object { $_.identifier -ceq $Id })
    Assert-Equal $found.Count 1 ('Channel count for ' + $Id)
    $found[0]
}
$script:At = [datetimeoffset]::Parse('2026-11-08T10:00:00+00:00')
$script:Settings = New-HardwareSettings

Test-Case 'recursive inventory includes motherboard child tachometers and updates each node' {
    $child = [pscustomobject]@{ HardwareType='SuperIO'; Sensors=@(
        [pscustomobject]@{Name='Fan #1';SensorType='Fan';Value=1000;Identifier='/board/fan/1'},
        [pscustomobject]@{Name='Fan #2';SensorType='Fan';Value=1300;Identifier='/board/fan/2'}
    ); SubHardware=@(); UpdateCount=0 }
    $child | Add-Member -MemberType ScriptMethod -Name Update -Value { $this.UpdateCount++ }
    $board = [pscustomobject]@{ HardwareType='Motherboard'; Sensors=@(); SubHardware=@($child); UpdateCount=0 }
    $board | Add-Member -MemberType ScriptMethod -Name Update -Value { $this.UpdateCount++ }
    $computer = [pscustomobject]@{ Hardware=@($board) }
    $inventory = @(Get-HardwareSensorInventory $computer)
    Assert-Equal $inventory.Count 2 'recursive inventory'
    Assert-Equal $board.UpdateCount 1 'parent update'; Assert-Equal $child.UpdateCount 1 'child update'
    $channels = @(Get-HardwareFanChannels $inventory)
    Assert-Equal (Channel $channels '/board/fan/2').rpm 1300 'child tachometer'
}
Test-Case 'all exposed channels are independent, including equal names and RPMs' {
    $s = Sample @((Fan '/board/fan/1' 1200 'CPU'), (Fan '/board/fan/2' 1200 'CPU'), (Fan '/board/fan/3' 700 'Aux'))
    Assert-Equal @($s.fans).Count 3 'fan count'
    Assert-Equal (Channel $s.fans '/board/fan/2').rpm 1200 'second RPM'
    Assert-Equal $s.fanRpm 1200 'legacy RPM'
    Assert-Equal $s.cpuC 50 'temperature unchanged'
    Assert-Equal $s.cpuLoad 25 'CPU usage unchanged'
}
Test-Case 'reordered rows and RPM crossover do not swap fan identities' {
    $a = Sample @((Fan '/board/fan/1' 500), (Fan '/board/fan/2' 1500))
    $b = Sample @((Fan '/board/fan/2' 400), (Fan '/board/fan/1' 1800)) $a.fans
    Assert-Equal (Channel $b.fans '/board/fan/1').rpm 1800 'first identity'
    Assert-Equal (Channel $b.fans '/board/fan/2').rpm 400 'second identity'
    Assert-Equal $b.fanRpm 1800 'legacy stays first'
}
Test-Case 'missing secondary and primary are null and never substituted' {
    $a = Sample @((Fan '/board/fan/1' 1000), (Fan '/board/fan/2' 1400))
    $b = Sample @((Fan '/board/fan/2' 1400)) $a.fans
    Assert-Equal $b.fanRpm $null 'missing primary'
    Assert-Equal (Channel $b.fans '/board/fan/1').rpm $null 'missing RPM'
    Assert-Equal (Channel $b.fans '/board/fan/1').status 'missing' 'missing status'
    $c = Sample @((Fan '/board/fan/1' 1000)) $a.fans
    Assert-Equal (Channel $c.fans '/board/fan/2').status 'missing' 'secondary missing'
}
Test-Case 'no fans and one fan remain supported without invented channels' {
    Assert-Equal @(Get-HardwareFanChannels -Inventory @()).Count 0 'empty'
    $s = Sample @((Fan '/board/fan/1' 900))
    Assert-Equal @($s.fans).Count 1 'single fan'
}
Test-Case 'null, invalid, NaN, infinity and out-of-range RPM never become zero' {
    foreach ($value in @($null, '', 'bad', -1, 20001, [double]::NaN, [double]::PositiveInfinity)) {
        $s = Sample @((Fan '/board/fan/1' $value))
        Assert-Equal $s.fans[0].rpm $null 'invalid RPM'
        Assert-Equal $s.fans[0].status 'unavailable' 'invalid status'
    }
    foreach ($value in @(0, 20000, '1250.5')) {
        $s = Sample @((Fan '/board/fan/1' $value))
        Assert-Equal $s.fans[0].rpm ([double]$value) 'valid RPM'
    }
}
Test-Case 'duplicate identifiers are ambiguous rather than arbitrarily selected' {
    $s = Sample @((Fan '/board/fan/1' 1000), (Fan '/board/fan/1' 1500))
    Assert-Equal @($s.fans).Count 1 'duplicate collapsed'
    Assert-Equal $s.fans[0].rpm $null 'duplicate null'
    Assert-Equal $s.fans[0].status 'ambiguous' 'duplicate status'
    Assert-Equal $s.fanRpm $null 'legacy duplicate null'
}
Test-Case 'non-fan sensors and blank identifiers do not create fan channels' {
    $rows = Rows @((Fan '' 900), (Fan ' ' 800), (Fan '/board/fan/1' 1100))
    Assert-Equal @(Get-HardwareFanChannels $rows).Count 1 'only valid identifier'
}
Test-Case 'identifier comparison is consistently case-sensitive' {
    $s = Sample @((Fan '/board/fan/A' 1000), (Fan '/board/fan/a' 1500))
    Assert-Equal @($s.fans).Count 2 'case-distinct identifiers'
    Assert-Equal (Channel $s.fans '/board/fan/A').rpm 1000 'uppercase ID'
    Assert-Equal (Channel $s.fans '/board/fan/a').rpm 1500 'lowercase ID'
}
Test-Case 'hour buckets keep separate sums, ranges, zeroes, and missing counts' {
    $state = New-HardwareState 'test' $At
    $s1 = Sample @((Fan '/board/fan/1' 1000), (Fan '/board/fan/2' 2000))
    $state = Add-HardwareSample $state $s1 $At $Settings
    $s2 = Sample @((Fan '/board/fan/2' 0), (Fan '/board/fan/1' 1200)) $s1.fans
    $state = Add-HardwareSample $state $s2 ($At.AddMinutes(10)) $Settings
    $s3 = Sample @((Fan '/board/fan/1' 1400)) $s2.fans
    $state = Add-HardwareSample $state $s3 ($At.AddMinutes(20)) $Settings
    $h = $state.hours[0]
    $a = Channel $h.fans '/board/fan/1'; $b = Channel $h.fans '/board/fan/2'
    Assert-Equal $a.sum 3600 'first sum'; Assert-Equal $a.count 3 'first count'
    Assert-Equal $a.min 1000 'first min'; Assert-Equal $a.max 1400 'first max'
    Assert-Equal $b.attempts 3 'second attempts'; Assert-Equal $b.count 2 'second valid count'
    Assert-Equal $b.sum 2000 'second sum'; Assert-Equal $b.min 0 'second min'
    Assert-Equal $b.zeroCount 1 'reported zero'; Assert-Equal $b.unavailableCount 1 'missing count'
    Assert-Equal $h.fanSum 3600 'legacy sum'; Assert-Equal $h.fanCount 3 'legacy count'
    Assert-Equal $state.rules.fanDrop.incident $null 'zero auxiliary header is not a fan-failure diagnosis'
    Assert-Equal $state.rules.sensorUnavailable.incident $null 'missing auxiliary header is not primary failure'
}
Test-Case 'all unavailable hour retains null range and zero valid count' {
    $state = New-HardwareState 'test' $At
    $state = Add-HardwareSample $state (Sample @((Fan '/board/fan/1' $null), (Fan '/board/fan/2' $null))) $At $Settings
    $b = Channel $state.hours[0].fans '/board/fan/2'
    Assert-Equal $b.count 0 'no readings'; Assert-Equal $b.min $null 'null min'; Assert-Equal $b.max $null 'null max'
    Assert-Equal $b.zeroCount 0 'no invented zero'; Assert-Equal $b.unavailableCount 1 'unavailable'
}
Test-Case 'v8 migration adds only new fan samples and preserves legacy history and outbox' {
    $state = New-HardwareState 'test' $At
    $legacy = [pscustomobject]@{cpuC=50;fanRpm=1100;cpuLoad=25}
    $state = Add-HardwareSample $state $legacy $At $Settings
    # Simulate a deserialized old state without any multi-fan properties.
    $state.latest.PSObject.Properties.Remove('fans')
    $state.hours[0].PSObject.Properties.Remove('fans')
    $state.pending = @([pscustomobject]@{reportType='hardwareDaily';reportId='test:hardware:old';reportDate='2026-11-07';hardwareVersion='v8';hours=@()})
    $oldPending = $state.pending | ConvertTo-Json -Depth 25 -Compress
    $state = $state | ConvertTo-Json -Depth 25 | ConvertFrom-Json
    $state = Add-HardwareSample $state (Sample @((Fan '/board/fan/1' 1300), (Fan '/board/fan/2' 1700))) ($At.AddMinutes(10)) $Settings
    Assert-Equal $state.hours[0].fanCount 2 'legacy count preserved'
    Assert-Equal $state.hours[0].fanSum 2400 'legacy sum preserved'
    Assert-Equal (Channel $state.hours[0].fans '/board/fan/1').count 1 'no fabricated history'
    Assert-Equal (Channel $state.hours[0].fans '/board/fan/2').count 1 'new secondary begins now'
    Assert-Equal ($state.pending | ConvertTo-Json -Depth 25 -Compress) $oldPending 'old pending report unchanged'
}
Test-Case 'daily payload and save reload preserve identities, nulls and arrays' {
    $state = New-HardwareState 'test' $At
    $s = Sample @((Fan '/board/fan/1' 1000), (Fan '/board/fan/2' $null))
    $state = Add-HardwareSample $state $s $At $Settings
    $state | Add-Member -NotePropertyName fanCatalog -NotePropertyValue @($s.fans | Select-Object identifier,name)
    Add-HardwareDaily $state ($At.AddDays(1)) '00:00'
    Add-HardwareDaily $state ($At.AddDays(1).AddMinutes(1)) '00:00'
    Assert-Equal @($state.pending).Count 1 'daily report idempotence'
    Assert-Equal $state.pending[0].hardwareVersion 'v9' 'hardware version'
    Assert-Equal $state.pending[0].fanSchemaVersion 2 'fan schema'
    $path = Join-Path ([IO.Path]::GetTempPath()) ('hardware-fan-test-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        Save-HardwareState $state $path
        $loaded = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        Assert-Equal @($loaded.latest.fans).Count 2 'array survives'
        Assert-Equal (Channel $loaded.latest.fans '/board/fan/2').rpm $null 'null survives'
        Assert-Equal @($loaded.fanCatalog).Count 2 'catalog survives'
        $missing = @(Get-HardwareFanChannels -Inventory @() -KnownFans $loaded.fanCatalog)
        Assert-Equal $missing.Count 2 'restart missing IDs retained'
        Assert-Equal (Channel $missing '/board/fan/2').status 'missing' 'restart missing status'
    } finally {
        foreach ($f in @($path, ($path + '.new'))) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
    }
}
Write-Host ('Tests: ' + $script:Passed + ' passed, ' + $script:Failed + ' failed.')
if ($script:Failed -gt 0) { throw ('Multi-fan regression suite failed: ' + $script:Failed + ' failure(s).') }
