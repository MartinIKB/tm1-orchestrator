powershell -ExecutionPolicy Bypass -File "%~dp0Run_TM1_Chore.ps1" -Env "DEV" -Inst "KST_2026" -ChoreName "J_20_Gesamtprozess" -IgnoreDisabled -ConsoleLogLevel "Detail"

pause