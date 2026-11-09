Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Open-HardwareSensors([string]$LibraryDirectory) {
    $script:LibraryDirectory = $LibraryDirectory
    $script:Resolver = [System.ResolveEventHandler]{
        param($sender,$args)
        $file = Join-Path $script:LibraryDirectory (([Reflection.AssemblyName]::new($args.Name)).Name + '.dll')
        if (Test-Path -LiteralPath $file) { return [Reflection.Assembly]::LoadFrom($file) }
        return $null
    }
    [AppDomain]::CurrentDomain.add_AssemblyResolve($script:Resolver)
    Add-Type -Path (Join-Path $LibraryDirectory 'LibreHardwareMonitorLib.dll')
    $computer = New-Object LibreHardwareMonitor.Hardware.Computer
    $computer.IsCpuEnabled = $true; $computer.IsMotherboardEnabled = $true
    $computer.Open()
    return $computer
}

function Read-HardwareTree($Hardware) {
    $Hardware.Update()
    foreach ($sensor in $Hardware.Sensors) {
        [pscustomobject]@{ hardwareType = [string]$Hardware.HardwareType; name = $sensor.Name; type = [string]$sensor.SensorType; value = $sensor.Value; identifier = [string]$sensor.Identifier }
    }
    foreach ($child in $Hardware.SubHardware) { Read-HardwareTree $child }
}

function Get-HardwareSensorInventory($Computer) {
    foreach ($h in $Computer.Hardware) { Read-HardwareTree $h }
}

function Get-HardwareFanChannels([object[]]$Inventory, [object[]]$KnownFans = @()) {
    # IDs, never labels, RPM rank or array positions, define independent tachometer channels.
    # A reported channel does not prove that a physical fan is fitted to its header.
    $uniqueIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($channel in @($KnownFans) + @($Inventory | Where-Object { $_.type -eq 'Fan' })) {
        $id = [string]$channel.identifier
        if (-not [string]::IsNullOrWhiteSpace($id)) { [void]$uniqueIds.Add($id) }
    }
    [string[]]$ids = @($uniqueIds)
    [Array]::Sort($ids, [StringComparer]::Ordinal)
    foreach ($id in $ids) {
        $rows = @($Inventory | Where-Object { $_.type -eq 'Fan' -and [string]$_.identifier -ceq $id })
        $previous = @($KnownFans | Where-Object { [string]$_.identifier -ceq $id })
        $name = if ($rows.Count) { [string]$rows[0].name } elseif ($previous.Count) { [string]$previous[0].name } else { '' }
        $rpm = $null
        $status = 'missing'
        if ($rows.Count -gt 1) { $status = 'ambiguous' }
        elseif ($rows.Count -eq 1) {
            $rpm = Get-ValidReading $rows[0].value 0 20000
            $status = if ($null -eq $rpm) { 'unavailable' } else { 'ok' }
        }
        [pscustomobject]@{ identifier = $id; name = $name; rpm = $rpm; status = $status }
    }
}

function Read-HardwareSensorRows([object[]]$Rows, [string]$FanIdentifier, [object[]]$KnownFans = @()) {
    $cpu = @($Rows | Where-Object { $_.hardwareType -eq 'Cpu' -and $_.name -eq 'CPU Package' -and $_.type -eq 'Temperature' })
    $fan = @($Rows | Where-Object { [string]$_.identifier -ceq $FanIdentifier -and $_.type -eq 'Fan' })
    $load = @($Rows | Where-Object { $_.hardwareType -eq 'Cpu' -and $_.name -eq 'CPU Total' -and $_.type -eq 'Load' })
    [pscustomobject]@{
        cpuC = $(if ($cpu.Count -eq 1) { $cpu[0].value } else { $null })
        # Legacy compatibility: do not silently substitute a different fan into its history.
        fanRpm = $(if ($fan.Count -eq 1) { $fan[0].value } else { $null })
        cpuLoad = $(if ($load.Count -eq 1) { $load[0].value } else { $null })
        fans = @(Get-HardwareFanChannels $Rows $KnownFans)
        primaryFanIdentifier = $FanIdentifier
    }
}

function Read-HardwareSensors($Computer, [string]$FanIdentifier, [object[]]$KnownFans = @()) {
    Read-HardwareSensorRows @(Get-HardwareSensorInventory $Computer) $FanIdentifier $KnownFans
}

function Get-ObservationFanIdentifier([object[]]$Inventory) {
    # Explicitly observed channels only. Do not pick the fastest fan or a channel by label alone.
    $known = @('/lpc/it8613e/0/fan/1','/lpc/nct6796dr/0/fan/1')
    $matches = @($Inventory | Where-Object { $_.type -eq 'Fan' -and $_.identifier -in $known })
    if ($matches.Count -eq 1) { return [string]$matches[0].identifier }
    return ''
}

function Read-HardwareSsd([string]$Executable) {
    # Output filenames are unique; no credentials or serial numbers are requested.
    $tempBase = Join-Path ([IO.Path]::GetDirectoryName($Executable)) ([guid]::NewGuid().ToString('N'))
    $stdout = $tempBase + '.json'; $stderr = $tempBase + '.txt'
    try {
        # This SATA device path was demonstrated on the HJS pilot. Verify returned model/protocol.
        $p = Start-Process -FilePath $Executable -ArgumentList '-a -j -q noserial -d ata /dev/sda' -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $null = $p.Handle
        if (-not $p.WaitForExit(15000)) { $p.Kill(); $p.WaitForExit(); throw 'SMART query timed out.' }
        $p.WaitForExit()
        $smart = Get-Content -LiteralPath $stdout -Raw | ConvertFrom-Json
        if (-not $smart.PSObject.Properties['model_name'] -or $smart.model_name -notmatch '^asscir\s+256GB$' -or -not $smart.PSObject.Properties['smart_status']) {
            throw 'Unexpected SSD model or inaccessible SMART response; support requires validation.'
        }
        $exitStatus = [int]$smart.smartctl.exit_status
        if (($exitStatus -band 7) -ne 0) { throw 'SMART data collection failed.' }
        $temperature = if ($smart.PSObject.Properties['temperature']) { $smart.temperature.current } else { $null }
        $hours = if ($smart.PSObject.Properties['power_on_time']) { $smart.power_on_time.hours } else { $null }
        if ($null -ne $temperature -and ($temperature -lt 5 -or $temperature -gt 100)) { $temperature = $null }
        if ($null -ne $hours -and ($hours -lt 0 -or $hours -gt 1000000)) { $hours = $null }
        [pscustomobject]@{
            at = [datetimeoffset]::Now.ToString('o'); status = $(if ($smart.smart_status.passed -eq $true) { 'passed' } else { 'failed' })
            model = [string]$smart.model_name; temperatureC = $temperature; powerOnHours = $hours
            remainingLifePercent = $null
            note = 'Vendor-specific attribute decoding is unvalidated. SMART PASSED does not guarantee future health.'
        }
    } catch {
        [pscustomobject]@{ at = [datetimeoffset]::Now.ToString('o'); status = 'unavailable'; model = ''; temperatureC = $null; powerOnHours = $null; remainingLifePercent = $null; note = 'SSD query unavailable; not an SSD failure diagnosis.' }
    } finally {
        foreach ($f in @($stdout,$stderr)) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } }
    }
}

function Close-HardwareSensors($Computer) {
    if ($Computer) { $Computer.Close() }
    if ($script:Resolver) { [AppDomain]::CurrentDomain.remove_AssemblyResolve($script:Resolver) }
}
Export-ModuleMember -Function *
