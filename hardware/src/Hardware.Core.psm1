Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-HardwareCompatibility([string]$BoardProduct, [string]$CpuName, [string]$Mode, [bool]$AllowUnidentifiedHardware = $false, [bool]$DailyReporting = $false) {
    if ($CpuName -notmatch '\bi7-11700\b') { throw 'Unsupported CPU: this pilot is limited to the newer i7-11700 devices.' }
    if ($AllowUnidentifiedHardware -and $Mode -ne 'Observe' -and -not $DailyReporting) { throw 'Unidentified hardware requires the reviewed daily reporting policy before sending.' }
    if ($BoardProduct.Trim() -eq 'HJS-OPSH510A04') { return 'HJS-OPSH510A04' }
    $placeholder = $BoardProduct.Trim() -match '^(Default string|To be filled by O\.E\.M\.|Unknown|Not Specified)?$'
    if ($AllowUnidentifiedHardware -and ($Mode -eq 'Observe' -or $DailyReporting) -and $placeholder) { return 'unidentified-i7-11700' }
    throw 'Motherboard is not the tested HJS model. Placeholder firmware IDs require -ObserveUnidentifiedHardware for a local-only capability test.'
}

function New-HardwareSettings {
    # Provisional pilot limits, not manufacturer failure specifications.
    [pscustomobject]@{
        sampleSeconds = 3600; warmupSeconds = 0; confirmSeconds = 0
        criticalConfirmSeconds = 0; recoverySeconds = 0; maximumGapSeconds = 5400
        hotC = 85; criticalC = 95; recoveryC = 80
        rapidRiseC = 15; rapidRiseMinimumC = 75
        fanDropFraction = 0.5; fanMinimumBaselineRpm = 500; fanTemperatureC = 65
        minimumBaselineSamples = 6; baselineMinutes = 1440
        fanIdentifier = '/lpc/it8613e/0/fan/1'
        cpuUsageHighPercent = 85
    }
}

function New-HardwareState([string]$ScreenId, [datetimeoffset]$At) {
    $rules = [ordered]@{}
    foreach ($name in @('temperatureHigh','temperatureCritical','temperatureRise','fanDrop','sensorUnavailable','cpuUsageHigh')) {
        $rules[$name] = [pscustomobject]@{ since = $null; clearSince = $null; incident = $null; openedAt = $null; referenceC = $null; referenceFan = $null }
    }
    [pscustomobject]@{
        schemaVersion = 1; screenId = $ScreenId; startedAt = $At.ToString('o'); lastSampleAt = $null
        lastDailyKey = ''; recent = @(); hours = @(); pending = @(); rules = [pscustomobject]$rules
        latest = $null; latestSsd = $null; lastSsdAttemptAt = $null; lastAttemptAt = $null
        retryAfter = $null; failures = 0; lastError = $null; lastDeliveredAt = $null
    }
}

function Save-HardwareState($State, [string]$Path) {
    $State | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath ($Path + '.new') -Encoding UTF8
    Move-Item -LiteralPath ($Path + '.new') -Destination $Path -Force
}

function Get-ValidReading($Value, [double]$Minimum, [double]$Maximum) {
    if ($null -eq $Value -or [string]$Value -eq '') { return $null }
    $n = 0.0
    if (-not [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) { return $null }
    if ([double]::IsNaN($n) -or [double]::IsInfinity($n) -or $n -lt $Minimum -or $n -gt $Maximum) { return $null }
    return $n
}

function Get-HardwareMedian([object[]]$Values) {
    $sorted = @($Values | Where-Object { $null -ne $_ } | Sort-Object { [double]$_ })
    if (-not $sorted.Count) { return $null }
    $middle = [int][math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2) { return [double]$sorted[$middle] }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2
}

function Add-HardwareEvent($State, [string]$Rule, [string]$Phase, [string]$Incident, [datetimeoffset]$At, $Sample) {
    # Transitions update local state silently. Only daily summaries leave the device.
    return $true
}

function Initialize-HardwareDailyPolicy($State) {
    if (-not $State.rules.PSObject.Properties['cpuUsageHigh']) {
        $State.rules | Add-Member -NotePropertyName cpuUsageHigh -NotePropertyValue ([pscustomobject]@{ since=$null;clearSince=$null;incident=$null;openedAt=$null;referenceC=$null;referenceFan=$null })
    }
    # Earlier versions queued immediate opens/recoveries. They must never be emailed by the new policy.
    $State.pending = @($State.pending | Where-Object { $_.reportType -eq 'hardwareDaily' })
    $State | Add-Member -NotePropertyName reportingPolicy -NotePropertyValue 'daily-v1' -Force
    return $State
}

function Update-HardwareRule($State, [string]$Name, $Condition, [bool]$Recovered,
    [int]$ConfirmSeconds, [int]$RecoverySeconds, [datetimeoffset]$At, $Sample) {
    $rule = $State.rules.$Name
    if ($null -eq $Condition) {
        # Missing evidence neither establishes a fault nor establishes recovery.
        $rule.since = $null; $rule.clearSince = $null
        return
    }
    if ([bool]$Condition) {
        $rule.clearSince = $null
        if (-not $rule.since) {
            $rule.since = $At.ToString('o')
            if (-not $rule.incident) { $rule.referenceC = $Sample.baselineC; $rule.referenceFan = $Sample.baselineFanRpm }
        }
        if (-not $rule.incident -and ($At - [datetimeoffset]::Parse($rule.since)).TotalSeconds -ge $ConfirmSeconds) {
            $id = $State.screenId + ':' + [guid]::NewGuid().ToString('N')
            if (Add-HardwareEvent $State $Name 'open' $id $At $Sample) { $rule.incident = $id; $rule.openedAt = $At.ToString('o') }
        }
    } else {
        $rule.since = $null
        if ($rule.incident -and $Recovered) {
            if (-not $rule.clearSince) { $rule.clearSince = $At.ToString('o') }
            if (($At - [datetimeoffset]::Parse($rule.clearSince)).TotalSeconds -ge $RecoverySeconds) {
                if (Add-HardwareEvent $State $Name 'recovered' $rule.incident $At $Sample) { $rule.incident = $null; $rule.openedAt = $null; $rule.clearSince = $null }
            }
        } else { $rule.clearSince = $null }
    }
}

function Add-HardwareSample($State, $Sample, [datetimeoffset]$At, $Settings) {
    $State = Initialize-HardwareDailyPolicy $State
    $cpu = Get-ValidReading $Sample.cpuC 5 125
    $fan = Get-ValidReading $Sample.fanRpm 0 20000
    $load = Get-ValidReading $Sample.cpuLoad 0 100
    $fans = @()
    if ($Sample.PSObject.Properties['fans']) {
        foreach ($channel in @($Sample.fans)) {
            $rpm = Get-ValidReading $channel.rpm 0 20000
            $fans += [pscustomobject]@{ identifier = [string]$channel.identifier; name = [string]$channel.name; rpm = $rpm; status = $(if ($null -ne $rpm) { 'ok' } else { [string]$channel.status }) }
        }
    }
    $sampleNow = [pscustomobject]@{ at = $At.ToString('o'); cpuC = $cpu; fanRpm = $fan; cpuLoad = $load; fans = $fans }
    if ($Sample.PSObject.Properties['primaryFanIdentifier']) {
        $sampleNow | Add-Member -NotePropertyName primaryFanIdentifier -NotePropertyValue $Sample.primaryFanIdentifier
    }
    $State.latest = $sampleNow
    $gap = $State.lastSampleAt -and ($At - [datetimeoffset]::Parse($State.lastSampleAt)).TotalSeconds -gt $Settings.maximumGapSeconds
    if ($State.lastSampleAt -and $At -le [datetimeoffset]::Parse($State.lastSampleAt)) { throw 'Sample timestamps must increase.' }
    if ($gap) {
        # Keep open incident identities across restart; discard stale confirmation evidence/baselines.
        $State.startedAt = $At.ToString('o'); $State.recent = @()
        foreach ($r in $State.rules.PSObject.Properties) { $r.Value.since = $null; $r.Value.clearSince = $null }
    }
    $State.lastSampleAt = $At.ToString('o')
    $State.recent = @($State.recent | Where-Object { [datetimeoffset]::Parse($_.at) -ge $At.AddMinutes(-$Settings.baselineMinutes) })
    # Exclude the newest two minutes from the reference baseline.
    $reference = @($State.recent | Where-Object { [datetimeoffset]::Parse($_.at) -le $At.AddSeconds(-$Settings.confirmSeconds) })
    $cpuRef = @($reference | Where-Object { $null -ne $_.cpuC } | ForEach-Object { $_.cpuC })
    $fanRef = @($reference | Where-Object { $null -ne $_.fanRpm } | ForEach-Object { $_.fanRpm })
    $baselineC = if ($cpuRef.Count -ge $Settings.minimumBaselineSamples) { Get-HardwareMedian $cpuRef } else { $null }
    $baselineFan = if ($fanRef.Count -ge $Settings.minimumBaselineSamples) { Get-HardwareMedian $fanRef } else { $null }
    $sampleNow | Add-Member -NotePropertyName baselineC -NotePropertyValue $baselineC
    $sampleNow | Add-Member -NotePropertyName baselineFanRpm -NotePropertyValue $baselineFan

    if (($At - [datetimeoffset]::Parse($State.startedAt)).TotalSeconds -ge $Settings.warmupSeconds) {
        $high = if ($null -ne $cpu) { $cpu -ge $Settings.hotC } else { $null }
        $critical = if ($null -ne $cpu) { $cpu -ge $Settings.criticalC } else { $null }
        $riseRule = $State.rules.temperatureRise; $fanRule = $State.rules.fanDrop
        $riseReference = if ($riseRule.since -or $riseRule.incident) { $riseRule.referenceC } else { $baselineC }
        $fanReference = if ($fanRule.since -or $fanRule.incident) { $fanRule.referenceFan } else { $baselineFan }
        $rise = if ($null -ne $cpu -and $null -ne $riseReference) { $cpu -ge $Settings.rapidRiseMinimumC -and $cpu - $riseReference -ge $Settings.rapidRiseC } else { $null }
        $drop = if ($null -ne $cpu -and $null -ne $fan -and $null -ne $fanReference -and $fanReference -ge $Settings.fanMinimumBaselineRpm) {
            $fan -lt ($fanReference * $Settings.fanDropFraction) -and $cpu -ge $Settings.fanTemperatureC
        } else { $null }
        Update-HardwareRule $State 'temperatureHigh' $high ($null -ne $cpu -and $cpu -lt $Settings.recoveryC) $Settings.confirmSeconds $Settings.recoverySeconds $At $sampleNow
        Update-HardwareRule $State 'temperatureCritical' $critical ($null -ne $cpu -and $cpu -lt $Settings.hotC) $Settings.criticalConfirmSeconds $Settings.recoverySeconds $At $sampleNow
        Update-HardwareRule $State 'temperatureRise' $rise ($null -ne $cpu -and $cpu -lt 70) $Settings.confirmSeconds $Settings.recoverySeconds $At $sampleNow
        Update-HardwareRule $State 'fanDrop' $drop ($null -ne $fan -and $null -ne $fanReference -and $fan -ge $fanReference * 0.75) $Settings.confirmSeconds $Settings.recoverySeconds $At $sampleNow
        Update-HardwareRule $State 'sensorUnavailable' ($null -eq $cpu -or $null -eq $fan) ($null -ne $cpu -and $null -ne $fan) $Settings.confirmSeconds $Settings.recoverySeconds $At $sampleNow
        $usageHigh = if ($null -ne $load) { $load -ge $Settings.cpuUsageHighPercent } else { $null }
        Update-HardwareRule $State 'cpuUsageHigh' $usageHigh ($null -ne $load -and $load -lt $Settings.cpuUsageHighPercent) $Settings.confirmSeconds $Settings.recoverySeconds $At $sampleNow
    }
    # Freeze each rule's original baseline while its confirmation/incident is active.
    $active = @($State.rules.PSObject.Properties | Where-Object { $_.Value.since -or $_.Value.incident }).Count -gt 0
    if (-not $active -and $null -ne $cpu -and $null -ne $fan) { $State.recent = @($State.recent) + @($sampleNow) }

    $dubai = [TimeZoneInfo]::ConvertTime($At, [TimeZoneInfo]::FindSystemTimeZoneById('Arabian Standard Time'))
    $key = $dubai.ToString('yyyy-MM-ddTHH:00zzz')
    $buckets = @($State.hours | Where-Object { $_.hour -eq $key })
    if ($buckets.Count) { $bucket = $buckets[0] } else {
        $bucket = [pscustomobject]@{ hour = $key; attempts = 0; cpuCount = 0; cpuSum = 0.0; cpuMin = $null; cpuMax = $null; fanCount = 0; fanSum = 0.0; fanMin = $null; fanMax = $null; loadCount = 0; loadSum = 0.0; loadMin = $null; loadMax = $null }
        $State.hours = @($State.hours) + @($bucket)
    }
    $bucket.attempts++
    foreach ($name in @('loadCount','loadSum','loadMin','loadMax')) {
        if (-not $bucket.PSObject.Properties[$name]) { $bucket | Add-Member -NotePropertyName $name -NotePropertyValue $(if ($name -in @('loadCount','loadSum')) { 0 } else { $null }) }
    }
    foreach ($pair in @(@('cpu',$cpu),@('fan',$fan),@('load',$load))) {
        $prefix = $pair[0]; $value = $pair[1]
        if ($null -ne $value) {
            $bucket.($prefix + 'Count')++; $bucket.($prefix + 'Sum') += $value
            if ($null -eq $bucket.($prefix + 'Min') -or $value -lt $bucket.($prefix + 'Min')) { $bucket.($prefix + 'Min') = $value }
            if ($null -eq $bucket.($prefix + 'Max') -or $value -gt $bucket.($prefix + 'Max')) { $bucket.($prefix + 'Max') = $value }
        }
    }
    # Append the new per-channel data without rewriting any legacy bucket totals.
    # Attempts start at migration: old samples cannot be reconstructed as two fans.
    if (-not $bucket.PSObject.Properties['fans']) { $bucket | Add-Member -NotePropertyName fans -NotePropertyValue @() }
    foreach ($channel in $fans) {
        $matches = @($bucket.fans | Where-Object { $_.identifier -ceq $channel.identifier })
        if ($matches.Count) { $fanBucket = $matches[0] } else {
            $fanBucket = [pscustomobject]@{ identifier = $channel.identifier; name = $channel.name; attempts = 0; count = 0; sum = 0.0; min = $null; max = $null; zeroCount = 0; unavailableCount = 0 }
            $bucket.fans = @($bucket.fans) + @($fanBucket)
        }
        $fanBucket.attempts++
        if ($null -eq $channel.rpm) { $fanBucket.unavailableCount++ } else {
            $fanBucket.count++; $fanBucket.sum += $channel.rpm
            if ($channel.rpm -eq 0) { $fanBucket.zeroCount++ }
            if ($null -eq $fanBucket.min -or $channel.rpm -lt $fanBucket.min) { $fanBucket.min = $channel.rpm }
            if ($null -eq $fanBucket.max -or $channel.rpm -gt $fanBucket.max) { $fanBucket.max = $channel.rpm }
        }
    }
    $State.hours = @($State.hours | Where-Object { [datetimeoffset]::Parse($_.hour) -ge $At.AddDays(-7) })
    return $State
}

function Add-HardwareDaily($State, [datetimeoffset]$At, [string]$UploadTime) {
    $local = [TimeZoneInfo]::ConvertTime($At, [TimeZoneInfo]::FindSystemTimeZoneById('Arabian Standard Time'))
    $slot = [timespan]::ParseExact($UploadTime, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture)
    if ($local.TimeOfDay -lt $slot) { return }
    $date = $local.AddDays(-1).ToString('yyyy-MM-dd')
    if ($State.lastDailyKey -eq $date) { return }
    if (@($State.pending).Count -ge 128) { $State.lastError = 'Hardware outbox full; daily report deferred.'; return }
    $hours = @($State.hours | Where-Object { $_.hour.StartsWith($date) })
    $State.pending = @($State.pending) + @([pscustomobject]@{
        version = 4; reportType = 'hardwareDaily'; screenId = $State.screenId
        hardwareVersion = 'v9'; fanSchemaVersion = 2
        reportId = ($State.screenId + ':hardware:' + $date); reportDate = $date
        sentAt = $At.ToString('o'); hardwareType = $(if ($State.PSObject.Properties['hardwareType']) { $State.hardwareType } else { 'HJS-OPSH510A04' })
        hours = $hours; latest = $State.latest; ssd = $State.latestSsd
    })
    $State.lastDailyKey = $date
}

function Send-HardwarePending($State, [string]$Endpoint, [string]$Token, [datetimeoffset]$At, [scriptblock]$Sender) {
    if ($State.retryAfter -and $At -lt [datetimeoffset]::Parse($State.retryAfter)) { return }
    $attempts = 0
    $State = Initialize-HardwareDailyPolicy $State
    $queue = @($State.pending | Sort-Object reportDate)
    foreach ($item in $queue) {
        if ($attempts -ge 2) { break }
        $attempts++; $State.lastAttemptAt = $At.ToString('o')
        $payload = [ordered]@{}
        foreach ($p in $item.PSObject.Properties) { $payload[$p.Name] = $p.Value }
        $payload.token = $Token
        try {
            $result = if ($Sender) { & $Sender $Endpoint $payload } else {
                Invoke-RestMethod -Uri $Endpoint -Method Post -ContentType 'text/plain; charset=utf-8' -Body ($payload | ConvertTo-Json -Depth 25 -Compress) -UseBasicParsing -TimeoutSec 15
            }
            if (-not $result -or -not $result.PSObject.Properties['accepted'] -or -not $result.PSObject.Properties['reportId'] -or -not $result.PSObject.Properties['ok'] -or $result.ok -ne $true -or $result.accepted -ne $true -or [string]$result.reportId -ne [string]$item.reportId -or ($result.PSObject.Properties['dryRun'] -and $result.dryRun)) {
                throw 'Receiver did not acknowledge this exact report; retaining it.'
            }
            $State.pending = @($State.pending | Where-Object { $_.reportId -ne $item.reportId })
            $State.failures = 0; $State.retryAfter = $null; $State.lastError = $null; $State.lastDeliveredAt = $At.ToString('o')
        } catch {
            $State.failures = [math]::Min(10, $State.failures + 1)
            $delay = [math]::Min(900, 30 * [math]::Pow(2, $State.failures - 1))
            $State.retryAfter = $At.AddSeconds($delay).ToString('o')
            # Do not persist exception text: remote errors can echo credentials.
            $State.lastError = 'Hardware delivery failed; report retained for retry.'
            break
        }
    }
}

Export-ModuleMember -Function *
