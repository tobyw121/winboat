@echo off
set INSTALL_DIR=C:\Program Files\WinBoat
set EXE_PATH=%INSTALL_DIR%\winboat_guest_server.exe
set NSSM_PATH=%INSTALL_DIR%\nssm.exe
set OEM_DIR=C:\OEM

:: RemoteApp tweaks must not change Winlogon: AME still needs setup autologon.
reg import "%OEM_DIR%\RDPApps.reg"

:: Create install directory if it doesn't exist
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"

:: Copy files from OEM to install directory
xcopy "%OEM_DIR%\*" "%INSTALL_DIR%\" /Y /E
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_DIR%\scripts\Install-HeliosControlPanel.ps1"

:: Install the service with NSSM
"%NSSM_PATH%" install WinBoatGuestServer "%EXE_PATH%"
"%NSSM_PATH%" set WinBoatGuestServer Start SERVICE_AUTO_START
"%NSSM_PATH%" set WinBoatGuestServer AppDirectory "%INSTALL_DIR%"
"%NSSM_PATH%" set WinBoatGuestServer Description "WinBoat Guest Server API on port 7148"
"%NSSM_PATH%" set WinBoatGuestServer ObjectName "NT AUTHORITY\SYSTEM"

:: Add firewall rule for port 7148
netsh advfirewall firewall add rule name="Allow WinBoat API 7148" dir=in action=allow protocol=TCP localport=7148

:: Start the service
"%NSSM_PATH%" start WinBoatGuestServer

:: Helios is provisioned only when explicitly selected in WinBoat.
:: AME OOBE must finish before Helios can restart Windows.
if exist "%ProgramData%\WinBoat\Atlas\oobe-mode.json" (
    del /q "%INSTALL_DIR%\atlas\oobe-credentials.json" 2>nul
    del /q "%OEM_DIR%\atlas\oobe-credentials.json" 2>nul
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_DIR%\scripts\Start-AtlasOOBE.ps1" -Register
    if errorlevel 1 exit /b 1
    exit /b 0
)
:: For ordinary installs keep the previous no-autologon policy. ISO/OOBE above
:: defers it until the observer confirms the playbook and configured user.
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f
:: Register before Helios so Atlas survives its reboots and waits for completion.
if exist "%OEM_DIR%\atlas-enabled" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_DIR%\scripts\Start-AtlasProvisioning.ps1" -Register -BundlePath "%INSTALL_DIR%\atlas"
    if errorlevel 1 exit /b 1
)
if exist "%OEM_DIR%\helios-enabled" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INSTALL_DIR%\scripts\Start-HeliosProvisioning.ps1" -BundlePath "%INSTALL_DIR%\helios"
    if errorlevel 1 exit /b 1
)
