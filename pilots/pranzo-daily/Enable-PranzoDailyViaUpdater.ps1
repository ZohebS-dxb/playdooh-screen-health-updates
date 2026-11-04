[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Open PowerShell as administrator first.'}
$root=Join-Path $env:ProgramData 'PlayDooh\ScreenHealthUpdater'
$hardwareRoot=Join-Path $env:ProgramData 'PlayDooh\HardwarePilot'
$path=Join-Path $root 'config.json'
$config=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
$monitor=Get-Content -LiteralPath (Join-Path ([string]$config.monitorRoot) 'config.json') -Raw|ConvertFrom-Json
$hardware=Get-Content -LiteralPath (Join-Path $hardwareRoot 'config.json') -Raw|ConvertFrom-Json
if($monitor.screenId -cne '0105' -or $hardware.screenId -cne '0105'){throw 'This change is for Pranzo screen 0105 only.'}
$taskName='PlayDooh Screen Health - Updater'
$task=Get-ScheduledTask -TaskName $taskName
if($task.State -eq 'Disabled' -or $task.Principal.UserId -notin @('SYSTEM','S-1-5-18','NT AUTHORITY\SYSTEM') -or @($task.Actions).Count -ne 1 -or $task.Actions[0].Arguments -notlike ('*'+$root+'*Run-Updater.ps1*')){throw 'Existing updater task needs inspection; no settings changed.'}
Import-Module (Join-Path $root 'Updater.Core.psm1') -Force
if(Test-RestartGap (Get-Date)){throw 'Please run outside the 04:15-04:45 maintenance window.'}
$base='https://raw.githubusercontent.com/ZohebS-dxb/playdooh-screen-health-updates/codex/pranzo-updater-pilot-20261104/pilots/pranzo-daily/'
$hardwareFeed=$base+'hardware-latest.json';$updaterFeed=$base+'updater-latest.json'
$h=Get-ReleaseMetadata $hardwareFeed;$u=Get-ReleaseMetadata $updaterFeed
if($h.enabled -ne $true -or $h.enableDailyReporting -ne $true -or $h.installMissing -ne $false -or @($h.screenIds).Count -ne 1 -or $h.screenIds[0] -cne '0105' -or $h.mode -cne 'Observe' -or $h.version -cne 'v6' -or $u.version -cne 'v3'){throw 'Unexpected pilot feed; no settings changed.'}
for($i=0;$i -lt 30 -and (Get-ScheduledTask -TaskName $taskName).State -eq 'Running';$i++){Start-Sleep -Seconds 2}
if((Get-ScheduledTask -TaskName $taskName).State -eq 'Running'){throw 'Updater still busy; retry later.'}
$mutex=New-Object Threading.Mutex($false,'Global\PlayDoohScreenHealthUpdater');$held=$false
try{
    $held=$mutex.WaitOne(10000);if(-not $held){throw 'Updater busy; settings unchanged.'}
    $backup=$path+'.before-daily-feed'
    if(-not(Test-Path -LiteralPath $backup)){Copy-Item -LiteralPath $path -Destination $backup}
    $config|Add-Member -NotePropertyName hardwareMetadataUrl -NotePropertyValue $hardwareFeed -Force
    $config|Add-Member -NotePropertyName updaterMetadataUrl -NotePropertyValue $updaterFeed -Force
    $config|ConvertTo-Json -Depth 12|Set-Content -LiteralPath ($path+'.new') -Encoding UTF8
    Move-Item -LiteralPath ($path+'.new') -Destination $path -Force
}finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
foreach($pass in 1..2){
    Write-Host "Running Pranzo updater, pass $pass of 2. Please leave this window open."
    $started=Get-Date;Start-ScheduledTask -TaskName $taskName;$done=$false
    for($i=0;$i -lt 150;$i++){
        Start-Sleep -Seconds 2
        $info=Get-ScheduledTaskInfo -TaskName $taskName
        if($info.LastRunTime -ge $started.AddSeconds(-1) -and (Get-ScheduledTask -TaskName $taskName).State -ne 'Running'){$done=$true;break}
    }
    if(-not $done -or $info.LastTaskResult -ne 0){throw 'Updater did not complete successfully. Rerun the existing test CMD with option 2 and send its report.'}
}
$after=Get-Content -LiteralPath (Join-Path $hardwareRoot 'config.json') -Raw|ConvertFrom-Json
$version=(Get-Content -LiteralPath (Join-Path $root 'VERSION.txt') -Raw).Trim()
if($version -ne 'v3' -or $after.screenId -ne '0105' -or $after.mode -ne 'Send' -or -not $after.PSObject.Properties['reportingPolicy'] -or $after.reportingPolicy -ne 'daily-v1'){throw 'Daily reporting is not confirmed. Use option 2 in the existing test CMD to send the report.'}
Write-Host 'SUCCESS: Pranzo updater v3 enabled daily hardware reporting.' -ForegroundColor Green
Write-Host 'Hourly local collection, one daily summary, no recovery emails; priority rules remain temperature 2 days and CPU usage 3 days.'
Write-Host 'Mode activation is confirmed. The next accepted daily upload still needs verification.'
