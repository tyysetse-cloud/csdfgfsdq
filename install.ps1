#Requires -RunAsAdministrator
<#
    Installs an auto-start scheduled task that maps hidir.sys with UIGB.exe
    at every full boot (and after every restart).

    The driver derives every spoofed value from the seed stored in
    HKLM\SYSTEM\CurrentControlSet\Services\HWIDSpoofer\Seed, so the serials
    stay identical after a reboot instead of being regenerated.
#>
[CmdletBinding()]
param(
    [string]$MapperPath,
    [string]$DriverPath,
    [string]$InstallDir = 'C:\Windows\System32\InputMethod\SHARED',
    [string]$TaskName = 'HWIDSpoofer-AutoLoad'
)

$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot

if (-not $MapperPath) {
    $mapperCandidates = @(
        (Join-Path $InstallDir 'UIGB.exe'),
        (Join-Path $projectRoot 'UIGB.exe'),
        (Join-Path (Split-Path -Parent $projectRoot) 'UIGB.exe'),
        (Join-Path $PSScriptRoot 'UIGB.exe')
    )
    $MapperPath = $mapperCandidates |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
}

if (-not $DriverPath) {
    $driverCandidates = @(
        (Join-Path $InstallDir 'hidir.sys'),
        (Join-Path $projectRoot 'Binary\hidir.sys'),
        (Join-Path $projectRoot 'Binary\HWID_Spoofer\hidir.sys')
    )
    $DriverPath = $driverCandidates |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
}

if (-not $MapperPath -or -not (Test-Path -LiteralPath $MapperPath)) {
    throw "UIGB.exe introuvable. Placez-le dans drv\, ou utilisez -MapperPath 'C:\chemin\UIGB.exe'."
}
if (-not $DriverPath -or -not (Test-Path -LiteralPath $DriverPath)) {
    throw "hidir.sys introuvable. Compilez la solution, ou utilisez -DriverPath 'C:\chemin\hidir.sys'."
}
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'run-autoload.ps1'))) {
    throw "run-autoload.ps1 est absent du dossier autoload."
}

# Old builds either generated a fresh profile on every load or always reused
# the seed. The rotation-aware build contains both debug strings; warn instead
# of silently installing a driver with the wrong reload behaviour.
$driverAscii = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($DriverPath))
if (-not $driverAscii.Contains('seed rotated (manual load)') -or
    -not $driverAscii.Contains('seed loaded (boot load)')) {
    Write-Warning "Le hidir.sys ne contient pas la logique de rotation (BootLoad)."
    Write-Warning "Recompilez la solution avant d'installer l'autoload."
}

Write-Host "[+] Mapper  : $MapperPath"
Write-Host "[+] Driver  : $DriverPath"
Write-Host "[+] Dossier : $InstallDir"

New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

# Stop a previous instance before overwriting the files it may be using.
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

$mapperDest = Join-Path $InstallDir 'UIGB.exe'
$driverDest = Join-Path $InstallDir 'hidir.sys'
if (-not [string]::Equals((Resolve-Path -LiteralPath $MapperPath).Path, $mapperDest, 'OrdinalIgnoreCase')) {
    Copy-Item -LiteralPath $MapperPath -Destination $mapperDest -Force
}
if (-not [string]::Equals((Resolve-Path -LiteralPath $DriverPath).Path, $driverDest, 'OrdinalIgnoreCase')) {
    Copy-Item -LiteralPath $DriverPath -Destination $driverDest -Force
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'run-autoload.ps1') -Destination (Join-Path $InstallDir 'run-autoload.ps1') -Force

# Drop loader files left under their old names by a previous install.
Remove-Item -LiteralPath (Join-Path $InstallDir 'kdmapper.exe') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $InstallDir 'Driver.sys') -Force -ErrorAction SilentlyContinue

# Remove any crash-loop protection left by a previous installation.
Remove-Item -LiteralPath (Join-Path $InstallDir 'attempt.pending') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $InstallDir 'AUTOLOAD_DISABLED') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $InstallDir 'autoload.log.old') -Force -ErrorAction SilentlyContinue

# Lock the folder down: only SYSTEM and Administrators may modify the files
# that are executed as SYSTEM at boot. Existing files first, then the folder.
# Skipped under %SystemRoot%: those directories are already TrustedInstaller
# owned and re-ACLing them breaks servicing of the surrounding system files.
$underSystemRoot = $InstallDir.StartsWith($env:SystemRoot, 'OrdinalIgnoreCase')
if (-not $underSystemRoot) {
    $files = Get-ChildItem -LiteralPath $InstallDir -File -Recurse -Force
    foreach ($file in $files) {
        & icacls.exe $file.FullName /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' /C /Q | Out-Null
    }
    & icacls.exe $InstallDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "icacls a retourne le code $LASTEXITCODE ; verifiez les permissions de $InstallDir."
    }
}

$runner = Join-Path $InstallDir 'run-autoload.ps1'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoProfile -NonInteractive -NoLogo -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $runner

$action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments -WorkingDirectory $InstallDir
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
    -MultipleInstances IgnoreNew
$settings.Hidden = $true

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Maps hidir.sys at every boot with UIGB.exe.' `
    -Force | Out-Null

$seed = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\HWIDSpoofer' -Name Seed -ErrorAction SilentlyContinue).Seed
if ($null -ne $seed) {
    Write-Host ('[i] Seed existante : 0x{0:X16} (les serials resteront identiques)' -f [uint64]$seed)
} else {
    Write-Host "[i] Aucune seed pour l'instant : elle sera creee au premier chargement."
}

$blocklist = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' -Name VulnerableDriverBlocklistEnable -ErrorAction SilentlyContinue).VulnerableDriverBlocklistEnable
if ($blocklist -eq 1) {
    Write-Warning "La blocklist des drivers vulnerables est active : UIGB.exe peut echouer."
    Write-Warning "Mettez VulnerableDriverBlocklistEnable=0 dans HKLM\SYSTEM\CurrentControlSet\Control\CI\Config puis redemarrez."
}

Write-Host ''
Write-Host "[+] Tache planifiee installee : $TaskName"
Write-Host "[+] Log : $(Join-Path $InstallDir 'autoload.log')"
Write-Host "[+] Le driver sera charge automatiquement a chaque demarrage complet / redemarrage."
Write-Host "[!] Apres l'installation, redemarre le PC (ou lance la tache) une fois pour charger le driver."
Write-Host ''
Write-Host "Pour tester sans redemarrer (PowerShell administrateur) :"
Write-Host "    Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "Puis :"
Write-Host "    Get-Content '$(Join-Path $InstallDir 'autoload.log')' -Tail 40"
