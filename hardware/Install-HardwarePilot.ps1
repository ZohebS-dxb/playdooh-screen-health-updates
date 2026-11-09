[CmdletBinding()]
param([switch]$EnableSending, [switch]$ObserveUnidentifiedHardware)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$identity = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run Windows PowerShell as Administrator.' }
if (-not [Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -ne 'Desktop') { throw 'Use 64-bit Windows PowerShell 5.1.' }
$board = Get-CimInstance Win32_BaseBoard; $cpu = Get-CimInstance Win32_Processor
Import-Module (Join-Path $PSScriptRoot 'src\Hardware.Core.psm1') -Force
$mode = if ($EnableSending) { 'Send' } else { 'Observe' }
$hardwareType = Get-HardwareCompatibility ([string]$board.Product) ([string]$cpu.Name) $mode ([bool]$ObserveUnidentifiedHardware)
if ($hardwareType -eq 'unidentified-i7-11700') { Write-Host 'Firmware IDs are placeholders. This is a local-only sensor capability test, not confirmation of the HJS motherboard.' }
$existingPath = Join-Path $env:ProgramData 'PlayDooh\ScreenHealth\config.json'
if (-not (Test-Path -LiteralPath $existingPath)) { throw 'Screen Health config is not at the expected location on this PC. Choose a PC with the current Screen Health agent installed.' }
$existing = Get-Content -LiteralPath $existingPath -Raw | ConvertFrom-Json
if ($existing.screenId -notmatch '^\d{4}$') { throw 'Install the existing Screen Health agent with a valid Screen ID first.' }
if ($EnableSending -and ([uri]$existing.endpoint).Scheme -ne 'https') { throw 'Receiver must use HTTPS.' }
$root = Join-Path $env:ProgramData 'PlayDooh\HardwarePilot'
$taskName = 'PlayDooh Screen Health - Hardware Pilot'
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { throw 'Pilot already installed. Stop it and use the documented reinstall procedure first.' }
New-Item -ItemType Directory -Path $root -Force | Out-Null
# Protect state/tools with the same administrative boundary as the existing agent.
$acl = New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true,$false)
foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
    $rule = New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl','ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $root -AclObject $acl
Copy-Item -Path (Join-Path $PSScriptRoot 'src\*') -Destination $root -Force
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$tools = Join-Path $root 'tools'; New-Item -ItemType Directory -Path $tools -Force | Out-Null
function Download-Verified([string]$Url,[string]$File,[string]$Hash) {
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $File -TimeoutSec 180
    if ((Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash -ne $Hash) { throw 'Tool download checksum mismatch; installation stopped.' }
}
$lhmZip = Join-Path $tools 'LibreHardwareMonitor.zip'
Download-Verified 'https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases/download/v0.9.6/LibreHardwareMonitor.zip' $lhmZip '086d9f1b5a99e643edc2cfaaac16051685b551e4c5ac0b32a57c58c0e529c001'
Expand-Archive -LiteralPath $lhmZip -DestinationPath (Join-Path $tools 'LibreHardwareMonitor') -Force
$pawn = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PawnIO' -ErrorAction SilentlyContinue
if (-not $pawn -or [version]$pawn.DisplayVersion -lt [version]'2.0') {
    $setup = Join-Path $tools 'PawnIO_setup.exe'
    Download-Verified 'https://github.com/namazso/PawnIO.Setup/releases/download/2.2.0/PawnIO_setup.exe' $setup '1f519a22e47187f70a1379a48ca604981c4fcf694f4e65b734aaa74a9fba3032'
    if ((Get-AuthenticodeSignature -LiteralPath $setup).Status -ne 'Valid') { throw 'PawnIO signature invalid; installation stopped.' }
    Write-Host 'Installing the signed sensor driver silently...'
    $p = Start-Process -FilePath $setup -ArgumentList '-install -silent' -WindowStyle Hidden -PassThru
    $null = $p.Handle
    if (-not $p.WaitForExit(120000)) { $p.Kill(); throw 'Sensor driver installation timed out. No automatic restart was requested by the pilot.' }
    if ($p.ExitCode -notin @(0,3010)) { throw 'Sensor driver installation did not finish successfully.' }
    if ($p.ExitCode -eq 3010) { throw 'Sensor driver reports a restart is needed. Restart during a maintenance window, then rerun setup.' }
    $pawnInstalled = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\PawnIO' -ErrorAction SilentlyContinue
    if (-not $pawnInstalled -or [version]$pawnInstalled.DisplayVersion -lt [version]'2.0') { throw 'Sensor driver installation could not be verified. Setup stopped.' }
}
$setup = Join-Path $tools 'smartmontools-setup.exe'
Download-Verified 'https://github.com/smartmontools/smartmontools/releases/download/RELEASE_7_5/smartmontools-7.5.win32-setup.exe' $setup '896337fcc253220614cf8cdbd5cf2321c5aa326a37a04160a672a281e6104c70'
$p = Start-Process -FilePath $setup -ArgumentList ('/S /SO smartctl,drivedb,doc /D=' + (Join-Path $tools 'smartmontools')) -WindowStyle Hidden -PassThru
$null = $p.Handle
if (-not $p.WaitForExit(60000)) { $p.Kill(); throw 'smartctl extraction timed out.' }
if ($p.ExitCode -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $tools 'smartmontools\bin\smartctl.exe'))) { throw 'smartctl extraction failed.' }
[pscustomobject]@{ screenId = $existing.screenId; mode = $mode; existingConfigPath = $existingPath; observeUnidentifiedHardware = [bool]$ObserveUnidentifiedHardware; hardwareType = $hardwareType } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'config.json') -Encoding UTF8
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $root 'Hardware.Pilot.ps1'))
$triggers = @()
# Reuse the safe minute already assigned to connectivity checks, outside the 04:30 restart gap.
$minute = [int]$existing.checkMinute
if ($minute -lt 0 -or $minute -gt 59 -or ($minute -ge 15 -and $minute -le 44)) { throw 'Existing check minute is not safe for the restart window.' }
foreach ($hour in 0..23) { $triggers += New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours($hour).AddMinutes($minute)) }
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Host "Hardware pilot installed for $($existing.screenId), mode: $mode. Existing Screen Health tasks are unchanged."
Write-Host 'One brief check per hour; the collector exits between checks. SSD health is read once per 24 hours.'
if (-not $EnableSending) { Write-Host 'Observe mode: local collection only; no hardware data or notifications are sent.' }
