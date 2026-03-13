@echo off
REM Aufruf des PowerShell-Skripts, das die REST-Calls macht
:: Parameter für den Execute-Mode: 
:: -DryRun
:: -ValidateOnly
:: Ohne Parameter = Execute

:: Parameter für die Umgebung (DEV/TEST/PROD)
:: -Environment "DEV"

:: Parameter für die Datenbank/Instanz (KST_2026/BER_25/NVR_25)
:: -InstanceName "KST_2026"

powershell -ExecutionPolicy Bypass -File "%~dp0Run_TM1_Process.ps1" -Env "DEV" -Inst "KST_2026" -ConsoleLogLevel "Info"

pause