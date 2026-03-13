@echo off
REM TM1 Orchestrator CLI Wrapper (CMD)
REM Leitet alle Argumente an tm1o.ps1 weiter
TITLE TM1 Orchestrator - Comand Line Interface (CLI)

powershell -ExecutionPolicy Bypass -File "%~dp0tm1o.ps1" %*
