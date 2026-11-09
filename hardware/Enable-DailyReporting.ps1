[CmdletBinding()]
param([ValidatePattern('^\d{4}$')][string]$ApprovedScreenId='0105')
$ErrorActionPreference='Stop'
$identity=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run the CMD as administrator.'}
$root=Join-Path $env:ProgramData 'PlayDooh\HardwarePilot'
$path=Join-Path $root 'config.json'
$config=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
$existing=Get-Content -LiteralPath $config.existingConfigPath -Raw | ConvertFrom-Json
if($existing.screenId -ne $config.screenId){throw 'Screen ID changed. Confirm the player identity before enabling reporting.'}
if($ApprovedScreenId -eq '0000' -or $config.screenId -cne $ApprovedScreenId){throw 'Screen identity does not match the approved daily-reporting target.'}
if(([uri]$existing.endpoint).Scheme -ne 'https' -or [string]::IsNullOrWhiteSpace([string]$existing.protectedToken)){throw 'Existing receiver endpoint/credential is invalid.'}
$module=Join-Path $root 'Hardware.Core.psm1'
if(-not (Select-String -LiteralPath $module -Pattern 'Initialize-HardwareDailyPolicy' -Quiet)){throw 'Update to v5 before enabling daily reporting.'}
Import-Module $module -Force
$board=Get-CimInstance Win32_BaseBoard;$cpu=Get-CimInstance Win32_Processor
$allow=$config.PSObject.Properties['observeUnidentifiedHardware'] -and $config.observeUnidentifiedHardware
$null=Get-HardwareCompatibility ([string]$board.Product) ([string]$cpu.Name) 'Send' ([bool]$allow) $true
$task='PlayDooh Screen Health - Hardware Pilot'
for($i=0;$i -lt 30 -and (Get-ScheduledTask -TaskName $task).State -eq 'Running';$i++){Start-Sleep -Seconds 2}
if((Get-ScheduledTask -TaskName $task).State -eq 'Running'){throw 'Pilot is still running; configuration not changed.'}
$mutex=New-Object Threading.Mutex($false,'Global\PlayDoohHardwarePilot')
$held=$false
try{
$held=$mutex.WaitOne(10000)
if(-not $held){throw 'Pilot is busy; daily activation deferred.'}
Copy-Item -LiteralPath $path -Destination ($path+'.before-daily') -Force
$config.mode='Send'
$config | Add-Member -NotePropertyName reportingPolicy -NotePropertyValue 'daily-v1' -Force
$config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ($path+'.new') -Encoding UTF8
Move-Item -LiteralPath ($path+'.new') -Destination $path -Force
}finally{if($held){$mutex.ReleaseMutex()};$mutex.Dispose()}
Start-ScheduledTask -TaskName $task
Write-Host ('Screen '+$ApprovedScreenId+': daily hardware uploads enabled. Hourly collection is unchanged.')
Write-Host 'No immediate or recovery emails. Daily summaries drive 2-day temperature and 3-day usage priority notices.'
