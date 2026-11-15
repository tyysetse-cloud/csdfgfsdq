@echo off
setlocal EnableExtensions
set "DIR=%~dp0"

rem Lance a chaque demarrage (tache InputMethodFix), apres le mapping de hidir.sys.
rem winmgmt a enumere le firmware au boot, avant le driver : on jette sa copie
rem cachee puis on le relance pour que la nouvelle enumeration lise la SMBIOS patchee.

net stop winmgmt /y >nul 2>&1
for %%V in (AcpiData BiosData RegistersData SMBiosData) do (
    reg delete "HKLM\SYSTEM\CurrentControlSet\Services\mssmbios\Data" /v %%V /f >nul 2>&1
)
sc config winmgmt start= auto >nul 2>&1
net start winmgmt >nul 2>&1

>>"%LOG%" echo %date% %time% [fix.bat] winmgmt relance, cache SMBIOS purge
exit /b 0
