# Executed at every boot by the InputMethodFix task (SYSTEM, hidden).
# Waits for the driver autoload to finish, runs fix.bat once so WMI re-reads
# the spoofed disk serials, then kills fix.bat's restart loop.
$ErrorActionPreference = 'Continue'
$dir = $PSScriptRoot
$log = Join-Path $dir 'autoload.log'
$cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
$bat = Join-Path $dir 'fix.bat'

function Write-Log([string]$message) {
    $line = '{0} [fix] {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $message
    try { Add-Content -LiteralPath $log -Value $line -ErrorAction SilentlyContinue } catch { }
}

Write-Log 'demarrage'

$deadline = (Get-Date).AddMinutes(6)
while ((Get-Date) -lt $deadline -and
       (Get-ScheduledTask -TaskName 'HWIDSpoofer-AutoLoad' -ErrorAction SilentlyContinue).State -eq 'Running') {
    Start-Sleep -Seconds 2
}
Start-Sleep -Seconds 5

$p = $null
if (Test-Path -LiteralPath $bat) {
    $p = Start-Process -FilePath $cmd -ArgumentList ('/c ""{0}""' -f $bat) -WindowStyle Hidden -PassThru
    Write-Log ('fix.bat lance (pid {0})' -f $p.Id)
} else {
    Write-Log 'fix.bat absent'
}

$seenStopped = $false
$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline) {
    $status = (Get-Service -Name Winmgmt -ErrorAction SilentlyContinue).Status
    if ($status -eq 'Stopped') {
        $seenStopped = $true
    } elseif ($status -eq 'Running' -and $seenStopped) {
        break
    }
    if ($p -and $p.HasExited -and -not $seenStopped) {
        Write-Log 'fix.bat sorti sans redemarrer winmgmt'
        break
    }
    Start-Sleep -Milliseconds 500
}

if ($p -and -not $p.HasExited) {
    & taskkill.exe /F /T /PID $p.Id 2>$null | Out-Null
}

if (-not $seenStopped) {
    Start-Sleep -Seconds 2
    Restart-Service -Name Winmgmt -Force -ErrorAction SilentlyContinue
}

$deadline = (Get-Date).AddSeconds(45)
while ((Get-Date) -lt $deadline) {
    $status = (Get-Service -Name Winmgmt -ErrorAction SilentlyContinue).Status
    if ($status -eq 'Running') { break }
    if ($status -eq 'Stopped') { Start-Service -Name Winmgmt -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
}

Write-Log ('winmgmt {0}' -f (Get-Service -Name Winmgmt -ErrorAction SilentlyContinue).Status)
