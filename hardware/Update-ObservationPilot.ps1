# Updates only the already installed observation pilot; no downloads, driver installs or live sending.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$identity=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run Windows PowerShell as Administrator.'}
$root=Join-Path $env:ProgramData 'PlayDooh\HardwarePilot'
$config=Get-Content -LiteralPath (Join-Path $root 'config.json') -Raw | ConvertFrom-Json
if($config.mode -ne 'Observe' -and -not($config.mode -eq 'Send' -and $config.PSObject.Properties['reportingPolicy'] -and $config.reportingPolicy -eq 'daily-v1')){throw 'Only Observe or reviewed daily reporting mode can be updated.'}
$taskName='PlayDooh Screen Health - Hardware Pilot'
$task=Get-ScheduledTask -TaskName $taskName
$names=@('Hardware.Core.psm1','Hardware.Readings.psm1','Hardware.Pilot.ps1')
foreach($name in $names){
    $file=Join-Path $PSScriptRoot ('src\'+$name)
    if(-not(Test-Path -LiteralPath $file)){throw "Missing $name. Extract the complete package first."}
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw "Invalid source file: $name"}
}
Stop-ScheduledTask -TaskName $taskName
for($i=0;$i -lt 10 -and (Get-ScheduledTask -TaskName $taskName).State -eq 'Running';$i++){Start-Sleep -Seconds 1}
if((Get-ScheduledTask -TaskName $taskName).State -eq 'Running'){throw 'Pilot did not stop; no files replaced.'}
$backup=Join-Path $root ('backups\'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
foreach($name in $names){Copy-Item -LiteralPath (Join-Path $root $name) -Destination $backup}
try{
    foreach($name in $names){Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('src\'+$name)) -Destination (Join-Path $root $name) -Force}
}catch{
    foreach($name in $names){Copy-Item -LiteralPath (Join-Path $backup $name) -Destination (Join-Path $root $name) -Force}
    Start-ScheduledTask -TaskName $taskName
    throw 'Update failed; previous observation code restored.'
}
Start-ScheduledTask -TaskName $taskName
Write-Host 'Hardware pilot code updated. One check started now; its mode and hourly schedule are unchanged.'
Write-Host 'Use Export-PilotReport.ps1 from this new package. Its ZIP is saved in Downloads.'
