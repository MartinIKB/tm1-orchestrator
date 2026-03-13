<#
================================================================================
  TM1 Orchestrator Framework - Runner Script: Run_TM1_Process.ps1 - Version 0.2 (2026-03-13)
================================================================================

 Bestandteil des TM1 Orchestrator Frameworks (TM1O).

 Dieses Script befindet sich im Verzeichnis:

   TM1Orchestrator\runners\

 und wird typischerweise ueber den CLI-Dispatcher

   tm1o.ps1

 oder direkt ueber PowerShell / .bat Wrapper aufgerufen.

 -------------------------------------------------------------------------------
 Beispielaufrufe (z.B. in einer .bat-Datei):
 -------------------------------------------------------------------------------

   powershell -ExecutionPolicy Bypass -File "runners\Run_TM1_Process.ps1" -Env "DEV" -Inst "KST_2026"

      --> Mode: Execute
          Normale Ausfuehrung der konfigurierten ProcessChain inkl. REST-Ausfuehrung.

   powershell -ExecutionPolicy Bypass -File "runners\Run_TM1_Process.ps1" -Env "DEV" -Inst "KST_2026" -DryRun

      --> Mode: DryRun
          Nur Logging / Simulation der ProcessChain, keine REST-Ausfuehrung.

   powershell -ExecutionPolicy Bypass -File "runners\Run_TM1_Process.ps1" -Env "DEV" -Inst "KST_2026" -ValidateOnly

      --> Mode: ValidateOnly
          Nur Validierung der referenzierten TM1 Prozesse, keine Ausfuehrung.

 -------------------------------------------------------------------------------
 Parametrisierung:
 -------------------------------------------------------------------------------

 Parameter:

   -Env   Environment (z.B. DEV, TEST, PROD)
   -Inst  TM1 Instanz (z.B. KST_2026)

 Aliase (Rueckwaertskompatibilitaet):

   -Environment   -> Alias fuer -Env
   -InstanceName  -> Alias fuer -Inst

 -------------------------------------------------------------------------------
 Frameworkstruktur (relevant fuer dieses Script):
 -------------------------------------------------------------------------------

   TM1Orchestrator\
      config\        -> tm1o.json (Framework-Konfiguration)
      modules\       -> TM1O.Core.psm1, TM1O.REST.psm1, TM1O.Domain.psm1
      runners\       -> Runner-Scripts (dieses Script)
      processchains\ -> Definition der ProcessChains
      logs\          -> Logdateien

 Dieses Script nutzt die Module:

   modules\TM1O.Core.psm1   -> Logging, Config, Summary, Logrotation
   modules\TM1O.REST.psm1   -> REST-Aufrufe gegen TM1 / Planning Analytics

 -------------------------------------------------------------------------------
 Hinweis:
 -------------------------------------------------------------------------------

   Dieses Script kann entweder

   - direkt ueber PowerShell
   - ueber einen .bat Wrapper
   - oder ueber den CLI Dispatcher "tm1o.ps1"

   aufgerufen werden.
#>

param(
    [Alias("Environment")]
    [string]$Env  = "DEV",       # DEV / TEST / PROD

    [Alias("InstanceName","Instance")]
    [string]$Inst = "KST_2026",  # TM1-Servername / Datenbank

    [string]$ChainName,          # Optional: Name der Prozesskette (z.B. DEFAULT, FULL, DELTA)
    [string]$ProcessName,        # Optional: Single-Prozess-Name (Single-Process-Mode)

    [switch]$ValidateOnly,       # Nur pruefen, ob Prozesse existieren (keine Ausfuehrung)
    [switch]$DryRun,             # Nur loggen, keine REST-Ausfuehrung

    [ValidateSet("Info","Detail","Debug")]
    [string]$ConsoleLogLevel = "Info"   # Steuert Lautstaerke in der Konsole
)

# ===========================
# EXIT CODES
# ===========================

$EXIT_SUCCESS             = 0
$EXIT_CONFIG_ERROR        = 2
$EXIT_HEALTHCHECK_FAILED  = 3
$EXIT_VALIDATION_FAILED   = 4
$EXIT_PROCESSCHAIN_FAILED = 5

# ===========================
# SECURE FILE NAMES FUNCTION
# ===========================

function ConvertTo-SafeFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    # Ungueltige Zeichen fuer Windows-Dateinamen durch Unterstrich ersetzen
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $safe = -join ($Name.ToCharArray() | ForEach-Object {
        if ($invalid -contains $_) { '_' } else { $_ }
    })
    return $safe
}

# ===========================
# BASIS-SETUP & CORE-MODUL LADEN
# ===========================

# Eingaben normalisieren (Trim + ToUpper fuer Env/Inst, ChainName)
if ($Env)       { $Env       = $Env.Trim().ToUpper() }
if ($Inst)      { $Inst      = $Inst.Trim().ToUpper() }
if ($ChainName) { $ChainName = $ChainName.Trim().ToUpper() }

if ([string]::IsNullOrWhiteSpace($Env) -or [string]::IsNullOrWhiteSpace($Inst)) {
    Write-Host "Fehler: Parameter 'Env' und 'Inst' duerfen nicht leer sein." -ForegroundColor Red
    exit $EXIT_CONFIG_ERROR
}

$Environment  = $Env
$InstanceName = $Inst

# Single-Process-Mode?
$script:IsSingleProcessMode = -not [string]::IsNullOrWhiteSpace($ProcessName)
if ($script:IsSingleProcessMode -and $ChainName) {
    Write-Host "Hinweis: ProcessName wurde angegeben -> Single-Process-Mode. ChainName '$ChainName' wird ignoriert." -ForegroundColor Yellow
}

$scriptRoot          = $PSScriptRoot
$rootDir             = Split-Path -Parent $scriptRoot
$frameworkModulePath = Join-Path $rootDir "modules\TM1Orchestrator.psm1"

if (-not (Test-Path $frameworkModulePath)) {
    Write-Host "FEHLER: TM1 Orchestrator Framework-Modul wurde nicht gefunden: $frameworkModulePath" -ForegroundColor Red
    exit $EXIT_CONFIG_ERROR
}

try {
    Import-Module $frameworkModulePath -Force -DisableNameChecking
}
catch {
    Write-Host "FEHLER: Konnte TM1 Orchestrator Framework-Modul nicht laden: $($_.Exception.Message)" -ForegroundColor Red
    exit $EXIT_CONFIG_ERROR
}

# Scriptweite Variablen fuer Core-Nutzung
$script:LogContext    = $null
$script:RetrySettings = $null
$script:MaxKeepLogs   = $null
$script:RunMode       = "Execute"

# ===========================
# HILFSFUNKTIONEN FUER LOGGING (WRAPPER UM TM1O.Core)
# ===========================

function Log {
    param(
        [string]$Message,
        [ValidateSet("Info","Detail","Debug")]
        [string]$Level = "Info"
    )

    if ($script:LogContext) {
        Write-TM1OLog -Context $script:LogContext -Message $Message -Level $Level
    }
    else {
        # Fallback, falls LogContext noch nicht gesetzt
        $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
        Write-Host $line
    }
}

function LogColor {
    param(
        [string]$Message,
        [ConsoleColor]$Color = "Green",
        [ValidateSet("Info","Detail","Debug")]
        [string]$Level = "Info"
    )

    if ($script:LogContext) {
        Write-TM1OLogColor -Context $script:LogContext -Message $Message -Color $Color -Level $Level
    }
    else {
        $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
        Write-Host $line -ForegroundColor $Color
    }
}

function Fix-TM1OEncodingIssues {
    param(
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $Name
    }

    # Kaputt encodierte Sequenzen (UTF8 bytes als Latin1 interpretiert)
    $brokenAe  = [string][char]195 + [string][char]164   # "Ã¤"
    $brokenOe  = [string][char]195 + [string][char]182   # "Ã¶"
    $brokenUe  = [string][char]195 + [string][char]188   # "Ã¼"
    $brokenAeC = [string][char]195 + [string][char]132   # "Ã„"
    $brokenOeC = [string][char]195 + [string][char]150   # "Ã–"
    $brokenUeC = [string][char]195 + [string][char]156   # "Ãœ"
    $brokenSz  = [string][char]195 + [string][char]159   # "ÃŸ"

    # Ziel: echte Umlaute (per charcode, keine Sonderzeichen im Script)
    $realAe  = [string][char]228  # "ae Umlaut"
    $realOe  = [string][char]246  # "oe Umlaut"
    $realUe  = [string][char]252  # "ue Umlaut"
    $realAeC = [string][char]196  # "Ae Umlaut"
    $realOeC = [string][char]214  # "Oe Umlaut"
    $realUeC = [string][char]220  # "Ue Umlaut"
    $realSz  = [string][char]223  # "scharfes s"

    $fixed = $Name

    $fixed = $fixed.Replace($brokenAe,  $realAe)
    $fixed = $fixed.Replace($brokenOe,  $realOe)
    $fixed = $fixed.Replace($brokenUe,  $realUe)
    $fixed = $fixed.Replace($brokenAeC, $realAeC)
    $fixed = $fixed.Replace($brokenOeC, $realOeC)
    $fixed = $fixed.Replace($brokenUeC, $realUeC)
    $fixed = $fixed.Replace($brokenSz,  $realSz)

    return $fixed
}

# ===========================
# CONFIG AUS JSON LADEN
# ===========================

$ConfigPath = Join-Path $rootDir "config\tm1o.json"

try {
    $configJson = Get-TM1OConfig -ConfigPath $ConfigPath
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit $EXIT_CONFIG_ERROR
}

try {
    $envConfig = Get-TM1OEnvironmentConfig -Config $configJson -Env $Environment
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit $EXIT_CONFIG_ERROR
}

try {
    $instance = Get-TM1OInstanceConfig -Config $configJson -Env $Environment -Inst $InstanceName
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit $EXIT_CONFIG_ERROR
}

$TM1RestBase  = $instance.TM1RestBase
$CAMNamespace = $envConfig.CAMNamespace
$ApiKey       = $envConfig.ApiKey

if ([string]::IsNullOrWhiteSpace($TM1RestBase) -or
    [string]::IsNullOrWhiteSpace($CAMNamespace) -or
    [string]::IsNullOrWhiteSpace($ApiKey)) {
    Write-Host "Environment '$Environment' / Instanz '$InstanceName' ist unvollstaendig (TM1RestBase / CAMNamespace / ApiKey)." -ForegroundColor Red
    exit $EXIT_CONFIG_ERROR
}

# RetrySettings & maxKeepLogs aus Core lesen
try {
    $script:RetrySettings = Get-TM1ORetrySettings -Config $configJson
    $script:MaxKeepLogs   = Get-TM1OMaxKeepLogs   -Config $configJson
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit $EXIT_CONFIG_ERROR
}

# ===========================
# PROCESSCHAIN / SINGLE-PROCESS INITIALISIERUNG
# ===========================

$chainFolder = Join-Path $rootDir "processchains"

if (-not $script:IsSingleProcessMode) {
    # --- Chain-Mode: Prozesskette aus Datei laden ---

    if ($ChainName) {
        # Mehrere Chains pro Env/Inst: ENV_INST_CHAIN.json
        $chainFileName = "{0}_{1}_{2}.json" -f $Environment, $InstanceName, $ChainName
    }
    else {
        # Legacy / Default: eine Chain pro Env/Inst: ENV_INST.json
        $chainFileName = "{0}_{1}.json" -f $Environment, $InstanceName
    }

    $chainPath = Join-Path $chainFolder $chainFileName

    if (-not (Test-Path $chainPath)) {
        Write-Host "Processchain-Datei wurde nicht gefunden: $chainPath" -ForegroundColor Red
        if ($ChainName) {
            Write-Host "Hinweis: Es wurde explizit ChainName='$ChainName' angegeben. Erwartete Datei: $chainFileName" -ForegroundColor Yellow
        }
        exit $EXIT_CONFIG_ERROR
    }

    try {
        $chainJson = Get-Content $chainPath -Raw | ConvertFrom-Json

            # Neue Zeilen: Prozessnamen aus der ProcessChain reparieren (Umlaute)
            if ($chainJson -and $chainJson.ProcessChain) {
                foreach ($step in $chainJson.ProcessChain) {
            if ($step.Name) {
                $step.Name = Fix-TM1OEncodingIssues -Name $step.Name
            }
            }
        }
        
        $ProcessChain = $chainJson.ProcessChain
    }
    catch {
        Write-Host "Fehler beim Lesen oder Parsen der Processchain-Datei '$chainPath':" -ForegroundColor Red
        Write-Host ($_ | Out-String)
        exit $EXIT_CONFIG_ERROR
    }

    if (-not $ProcessChain -or $ProcessChain.Count -eq 0) {
        Write-Host "In '$chainPath' wurde keine gueltige ProcessChain gefunden." -ForegroundColor Red
        exit $EXIT_CONFIG_ERROR
    }
}
else {
    # --- Single-Process-Mode: Keine Chain-Datei, nur ein einzelner Prozess ---

    if ([string]::IsNullOrWhiteSpace($ProcessName)) {
        Write-Host "Fehler: Single-Process-Mode aktiv, aber ProcessName ist leer." -ForegroundColor Red
        exit $EXIT_CONFIG_ERROR
    }

    # Pseudo-Dateiname nur fuer Logging / Log-Namen
    $chainFileName = "PROC_{0}.json" -f (ConvertTo-SafeFileName -Name $ProcessName)
    $chainPath     = "<SingleProcess: $ProcessName>"

    # Kuenstliche ProcessChain mit genau einem Schritt
    $ProcessChain = @(
        [PSCustomObject]@{
            Name       = $ProcessName
            Parameters = @()
        }
    )
}

# ===========================
# RUN MODE FESTLEGEN
# ===========================

if ($ValidateOnly) {
    $script:RunMode = "ValidateOnly"
}
elseif ($DryRun) {
    $script:RunMode = "DryRun"
}
else {
    $script:RunMode = "Execute"   # normale Ausfuehrung mit Berechnung
}

# ===========================
# LOGGING-KONTEXT INITIALISIEREN (TM1O.Core)
# ===========================

try {
    $logContext = New-TM1OLogContext -BasePath $rootDir `
                                 -Env $Environment `
                                 -Inst $InstanceName `
                                 -ChainFileName $chainFileName `
                                 -ConsoleLogLevel $ConsoleLogLevel
}
catch {
    Write-Host "FEHLER: Konnte Logkontext nicht erstellen: $($_.Exception.Message)" -ForegroundColor Red
    exit $EXIT_CONFIG_ERROR
}

$script:LogContext = $logContext

$chainBaseName = $logContext.ChainBaseName
$logFilePath   = $logContext.LogFile

Log "------------------------------------------------------------"
Log "TM1 REST Prozesskette gestartet."
Log "Environment : $Environment"
Log "Instance    : $InstanceName"
Log "TM1RestBase : $TM1RestBase"
Log "Config      : $ConfigPath"
Log "ProcessChain: $chainPath"
Log "Logfile     : $logFilePath"

if ($script:IsSingleProcessMode) {
    Log ("Mode        : SINGLE PROCESS")
    Log ("ProcessName : {0}" -f $ProcessName)
}
else {
    Log ("Mode        : CHAIN")
    if ($ChainName) {
        Log ("ChainName   : {0}" -f $ChainName)
    }
    else {
        Log "ChainName   : (Standard / Legacy Datei ENV_INST.json)"
    }
}

Log ("RetrySettings: MaxRetries={0}, RetryDelaySec={1}, TimeoutSec={2}, MaxKeepLogs={3}" -f `
    $script:RetrySettings.MaxRetries,
    $script:RetrySettings.RetryDelaySec,
    $script:RetrySettings.TimeoutSec,
    $script:MaxKeepLogs) "Detail"
Log ("RunMode     : {0}" -f $script:RunMode)
if ($ValidateOnly -and $DryRun) {
    Log "Hinweis: ValidateOnly wurde priorisiert, DryRun wird ignoriert."
}
elseif ($ValidateOnly) {
    Log "Hinweis: ValidateOnly (nur Existenzpruefung, keine Ausfuehrung)."
}
elseif ($DryRun) {
    Log "Hinweis: DryRun (nur Logging, keine Ausfuehrung)."
}
Log "------------------------------------------------------------"

# ===========================
# HTTP-HEADER
# ===========================

$Headers = @{
    "Authorization" = "CAMNamespace $ApiKey"
    "CAMNamespace"  = $CAMNamespace
    "Content-Type"  = "application/json"
}

# ===========================
# HEALTH CHECK FUNKTION
# ===========================

function Test-TM1Connection {
    param(
        [int]$TimeoutSec = 30
    )

    # Logging bleibt im Runner (klare Semantik)
    Log "HealthCheck: starte REST HealthCheck fuer TM1-Instanz ..."
    $result = Test-TM1RestConnection -BaseUrl $TM1RestBase `
                                     -Headers $Headers `
                                     -TimeoutSec $TimeoutSec `
                                     -LogContext $script:LogContext
    return $result
}

# ===========================
# VALIDATEONLY: PROZESS-EXISTENZ PRUEFEN
# ===========================

function Test-TM1ProcessExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProcessName
    )

    Log ("ValidateOnly: pruefe Existenz von Prozess '{0}' ..." -f $ProcessName)

    $result = Test-TM1RestProcessExists -BaseUrl $TM1RestBase `
                                        -Headers $Headers `
                                        -ProcessName $ProcessName `
                                        -TimeoutSec 60 `
                                        -LogContext $script:LogContext
    return $result
}

# ===========================
# FUNKTION: EINEN PROZESS AUSFUEHREN (mit Core-Retry)
# ===========================

function Invoke-TM1Process {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProcessName,

        [Parameter(Mandatory = $false)]
        [array]$Parameters = @()
    )

    Log ""
    Log "Starte TM1-Prozess '$ProcessName' in '$Environment' / '$InstanceName' ..."

    # Die eigentliche REST-Logik (Body, URL, Retry, Statuscode-Auswertung)
    # liegt jetzt im TM1O.REST-Modul:
    $result = Invoke-TM1RestProcessExecute -BaseUrl $TM1RestBase `
                                           -Headers $Headers `
                                           -ProcessName $ProcessName `
                                           -Parameters $Parameters `
                                           -RetrySettings $script:RetrySettings `
                                           -LogContext $script:LogContext

    return $result
}

# ===========================
# HAUPTLOGIK: KETTE AUSFUEHREN / VALIDIEREN / DRYRUN
# ===========================

$overallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$startTime        = Get-Date
$runStatus        = "SUCCESS"
$failedProcess    = ""

Log "Gesamtlauf Start: $startTime"

# 1) HEALTH CHECK
if (-not (Test-TM1Connection)) {
    $overallStopwatch.Stop()
    $endTime       = Get-Date
    $runStatus     = "FAILED"
    $failedProcess = "HealthCheck"

    Log "HealthCheck fehlgeschlagen, Prozesskette wird nicht gestartet."

    Write-TM1ORunSummary -Context $script:LogContext `
                         -Status $runStatus `
                         -FailedProcess $failedProcess `
                         -StartTime $startTime `
                         -EndTime $endTime `
                         -RunMode $script:RunMode

    Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs

    Log "------------------------------------------------------------"
    exit $EXIT_HEALTHCHECK_FAILED
}

# 2) VALIDATEONLY MODE
if ($ValidateOnly) {
    Log "ValidateOnly: Es werden keine Prozesse ausgefuehrt, nur Existenz geprueft."

    $allOk        = $true
    $firstMissing = ""

    foreach ($p in $ProcessChain) {
        $name   = $p.Name
        $exists = Test-TM1ProcessExists -ProcessName $name
        if (-not $exists) {
            $allOk = $false
            if (-not $firstMissing) {
                $firstMissing = $name
            }
        }
    }

    $overallStopwatch.Stop()
    $endTime = Get-Date

    if (-not $allOk) {
        $runStatus     = "FAILED"
        $failedProcess = $firstMissing
        Log "ValidateOnly: Mindestens ein Prozess existiert nicht oder ist nicht erreichbar."

        Write-TM1ORunSummary -Context $script:LogContext `
                             -Status $runStatus `
                             -FailedProcess $failedProcess `
                             -StartTime $startTime `
                             -EndTime $endTime `
                             -RunMode $script:RunMode

        Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs

        Log "------------------------------------------------------------"
        exit $EXIT_VALIDATION_FAILED
    }
    else {
        $runStatus     = "SUCCESS"
        $failedProcess = ""
        Log "ValidateOnly: Alle Prozesse existieren, es wurde nichts ausgefuehrt."

        Write-TM1ORunSummary -Context $script:LogContext `
                             -Status $runStatus `
                             -FailedProcess $failedProcess `
                             -StartTime $startTime `
                             -EndTime $endTime `
                             -RunMode $script:RunMode

        Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs

        Log "------------------------------------------------------------"
        exit $EXIT_SUCCESS
    }
}

# 3) DRYRUN MODE (ohne ValidateOnly)
if ($DryRun) {
    Log "DryRun: Es werden keine Prozesse ausgefuehrt, nur die Reihenfolge wird protokolliert."
    foreach ($p in $ProcessChain) {
        $name   = $p.Name
        $params = $p.Parameters
        $paramInfo = "keine"
        if ($params -and $params.Count -gt 0) {
            $paramInfo = ($params | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ", "
        }
        Log ("DryRun: Prozess '{0}' wuerde mit Parametern [{1}] ausgefuehrt." -f $name, $paramInfo)
    }

    $overallStopwatch.Stop()
    $endTime  = Get-Date
    $runStatus     = "SUCCESS"
    $failedProcess = ""

    Write-TM1ORunSummary -Context $script:LogContext `
                         -Status $runStatus `
                         -FailedProcess $failedProcess `
                         -StartTime $startTime `
                         -EndTime $endTime `
                         -RunMode $script:RunMode

    Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs

    Log "------------------------------------------------------------"
    exit $EXIT_SUCCESS
}

# 4) NORMALE PROZESSKETTE AUSFUEHREN
Log "Starte Prozesskette in '$Environment' / '$InstanceName' ..."
foreach ($p in $ProcessChain) {
    $name   = $p.Name
    $params = $p.Parameters

    Log "--------------------------------------"
    Log "Prozess in Kette: $name"
    $result = Invoke-TM1Process -ProcessName $name -Parameters $params

    if (-not $result.Success) {
        $overallStopwatch.Stop()
        $endTime       = Get-Date
        $runStatus     = "FAILED"
        $failedProcess = $name

        Log ""
        Log "Prozesskette ABGEBROCHEN wegen Fehler in '$name'."
        Log "Gesamtlauf Ende   : $endTime"
        Log ("Gesamtlauf Dauer  : {0} Sekunden" -f ($endTime - $startTime).TotalSeconds)

        Write-TM1ORunSummary -Context $script:LogContext `
                             -Status $runStatus `
                             -FailedProcess $failedProcess `
                             -StartTime $startTime `
                             -EndTime $endTime `
                             -RunMode $script:RunMode

        Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs

        Log "------------------------------------------------------------"
        exit $EXIT_PROCESSCHAIN_FAILED
    }
}

$overallStopwatch.Stop()
$endTime  = Get-Date

Log ""
Log "Alle Prozesse in der Kette wurden ERFOLGREICH ausgefuehrt."
Log "Gesamtlauf Ende   : $endTime"
Log ("Gesamtlauf Dauer  : {0} Sekunden" -f ($endTime - $startTime).TotalSeconds)

$runStatus     = "SUCCESS"
$failedProcess = ""

Write-TM1ORunSummary -Context $script:LogContext `
                     -Status $runStatus `
                     -FailedProcess $failedProcess `
                     -StartTime $startTime `
                     -EndTime $endTime `
                     -RunMode $script:RunMode

Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs

Log "------------------------------------------------------------"

exit $EXIT_SUCCESS