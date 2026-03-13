<#
 TM1 Orchestrator CLI Wrapper (tm1o.ps1)

 Aufruf: tm1o <command> <environment> <instance> [weitere Parameter]

 Commands (Prozess-orientiert):
   run          -> fuehrt die Prozesskette aus (Execute mode)
   dryrun       -> zeigt nur an, was ausgefuehrt wuerde (DryRun mode)
   validate     -> prueft nur Existenz der Prozesse (ValidateOnly mode)
   run-proc     -> fuehrt einen einzelnen TM1-Prozess aus
   dryrun-proc  -> zeigt nur an, was ein einzelner Prozess tun wuerde
   validate-proc-> prueft nur Existenz eines einzelnen Prozesses

 Commands (Query-orientiert / Cube & Cells):
   cube-info    -> zeigt Basisinfos zu einem Cube (Name, Dimensionsreihenfolge)
   cell         -> liest eine einzelne Zelle (Single-Cell-Read)
   cell-table   -> liest mehrere Zellen und gibt eine Tabelle zurueck

 Commands (Metadaten & Logs):
   list-env     -> listet alle Environments aus config/tm1o.json
   list-inst    -> listet alle Instanzen fuer ein Environment
   chain        -> zeigt die Prozesskette (ProcessChain) fuer ENV/INSTANCE[/CHAIN]
   lastlog      -> zeigt letztes Logfile + SUMMARY
   status       -> zeigt die letzten Runs aus der Archiv-CSV
   help         -> zeigt diese Hilfe

 Globale Optionen (Log-Level):
   -ConsoleLogLevel Info|Detail|Debug   (Standard: Info)
   -FileLogLevel    Info|Detail|Debug   (Standard: Detail)

 Beispiele:
   Prozesse:
     tm1o run dev kst_2026
     tm1o run dev kst_2026 FULL
     tm1o run-proc dev kst_2026 S_10_Kostenstellen
     tm1o validate-proc dev kst_2026 S_10_Kostenstellen

   Cube-Queries:
     tm1o cube-info dev kst_2026 KST

     tm1o cell dev kst_2026 KST `
         Kostenstellen:P_10190 `
         Kostenarten:2S.GV2 `
         Freigabe:Entwicklung `
         Sichtweise:monatlich `
         Version:Ist_EUR `
         Zeit:Dez_25

     tm1o cell-table dev kst_2026 KST `
         "P_10190,2S.GV2,Entwicklung,monatlich,Ist_EUR,Okt_25" `
         "P_10190,2S.GV2,Entwicklung,monatlich,Ist_EUR,Nov_25"

 Hinweis:
   - ENV  = Environment in config/tm1o.json (z.B. DEV, TEST, PROD)
   - INST = Instanzname (z.B. KST_2026, BER_25, NVR_25)
   - Eingaben fuer ENV und INSTANCE werden intern in GROSSBUCHSTABEN konvertiert.
   - Intern ruft tm1o
       - 'runners/Run_TM1_Process.ps1' fuer Prozesskommandos und
       - 'runners/Run_TM1_Query.ps1'   fuer Cube/Cell-Queries
     auf. Diese Scripts nutzen das Modul 'TM1O.Core.psm1' fuer Config, Logging,
     Retry und Logrotation.
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet(
    "run",
    "dryrun",
    "validate",
    "run-proc",
    "dryrun-proc",
    "validate-proc",
    "run-chore",
    "dryrun-chore",
    "validate-chore",
    "activate-chore",
    "deactivate-chore",
    "chore-info",
    "cube-info",
    "cell",
    "cell-table",
    "list-env",
    "list-inst",
    "chain",
    "lastlog",
    "status",
    "help"
    )]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    [string]$Environment,

    [Parameter(Position = 2)]
    [string]$Instance,

    # Globale Log-Level-Optionen (nur benannt, keine Position)
    [ValidateSet("Info","Detail","Debug")]
    [string]$ConsoleLogLevel = "Info",

    [ValidateSet("Info","Detail","Debug")]
    [string]$FileLogLevel = "Detail",

    # Globaler Switch fuer Chores: Enabled-Status ignorieren
    [switch]$IgnoreDisabled,

    # WICHTIG: alle weiteren Argumente (CubeName, Koordinaten, etc.)
    [Parameter(Position = 3, ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

function Show-Help {
    Write-Host ""
    Write-Host "TM1 Orchestrator CLI (tm1o)"
    Write-Host "---------------------------------"
    Write-Host ""
    Write-Host "Syntax (Prozess-orientiert):"
    Write-Host "  tm1o run          <ENV> <INST> [CHAIN]       - Execute mode (Prozesskette)"
    Write-Host "  tm1o dryrun       <ENV> <INST> [CHAIN]       - DryRun (nur Logging)"
    Write-Host "  tm1o validate     <ENV> <INST> [CHAIN]       - ValidateOnly (Existenzpruefung Kette)"
    Write-Host ""
    Write-Host "  tm1o run-proc     <ENV> <INST> <PROC>        - Einzelnen Prozess ausfuehren"
    Write-Host "  tm1o dryrun-proc  <ENV> <INST> <PROC>        - Einzelnen Prozess nur loggen"
    Write-Host "  tm1o validate-proc<ENV> <INST> <PROC>        - Existenz eines einzelnen Prozesses pruefen"
    Write-Host ""
    Write-Host "Syntax (Chore-orientiert):"
    Write-Host "  tm1o run-chore        <ENV> <INST> <CHORE> [-IgnoreDisabled]   - Einzelne Chore ausfuehren"
    Write-Host "  tm1o dryrun-chore     <ENV> <INST> <CHORE> [-IgnoreDisabled]   - Chore nur loggen (keine Ausfuehrung)"
    Write-Host "  tm1o validate-chore   <ENV> <INST> <CHORE> [-IgnoreDisabled]   - Existenz / Status einer Chore pruefen"
    Write-Host "  tm1o activate-chore   <ENV> <INST> <CHORE>                     - Chore aktivieren (Enabled = True)"
    Write-Host "  tm1o deactivate-chore <ENV> <INST> <CHORE>                     - Chore deaktivieren (Enabled = False)"
    Write-Host "  tm1o chore-info       <ENV> <INST> <CHORE>                     - Detailinformationen zu einer Chore anzeigen"
    Write-Host ""
    Write-Host "  Optional: -IgnoreDisabled ueberspringt die Enabled-Pruefung im Chore-Runner"
    Write-Host "            (z.B. Ad-hoc-Run deaktivierter Chores oder Validate/DryRun ohne Fehler,"
    Write-Host "             auch wenn Enabled = False)."
    Write-Host ""
    Write-Host "Syntax (Query-orientiert / Cube und Cell):"
    Write-Host "  tm1o cube-info    <ENV> <INST> <CUBE>        - CubeInfos (Name, Dimensionsreihenfolge)"
    Write-Host "  tm1o cell         <ENV> <INST> <CUBE> <Koordinaten...>"
    Write-Host "     Koordinaten als:"
    Write-Host "        - reihenfolge-basiert:   'P_10190' '2S.GV2' 'Entwicklung' ..."
    Write-Host "        - oder Dim:Elem-Notation: 'Kostenstellen:P_10190' ..."
    Write-Host ""
    Write-Host "  tm1o cell-table   <ENV> <INST> <CUBE> <Set1> <Set2> ..."
    Write-Host "     Beispiel:"
    Write-Host "       tm1o cell-table dev kst_2026 KST"
    Write-Host "           \"P_10190,2S.GV2,Entwicklung,monatlich,Ist_EUR,Okt_25\""
    Write-Host "           \"P_10190,2S.GV2,Entwicklung,monatlich,Ist_EUR,Nov_25\""
    Write-Host ""
    Write-Host "Syntax (Metadaten und Logs):"
    Write-Host "  tm1o list-env                      - Liste aller Environments aus config/tm1o.json"
    Write-Host "  tm1o list-inst    <ENV>            - Liste aller Instanzen fuer ein Environment"
    Write-Host "  tm1o chain        <ENV> <INST> [CHAIN] - Zeigt Prozesskette fuer ENV/INST[/CHAIN]"
    Write-Host "  tm1o lastlog      <ENV> <INST>     - Zeigt letztes Logfile + SUMMARY"
    Write-Host "  tm1o status       <ENV> <INST>     - Zeigt letzte Runs aus der Archiv-CSV"
    Write-Host ""
    Write-Host "Globale Log-Level-Optionen:"
    Write-Host "  -ConsoleLogLevel Info|Detail|Debug   (Standard: Info)"
    Write-Host "  -FileLogLevel    Info|Detail|Debug   (Standard: Detail)"
    Write-Host ""
    Write-Host "  tm1o help                       - Hilfe anzeigen"
    Write-Host ""
    Write-Host "Hinweise:"
    Write-Host "  - ENV  = Environment in config/tm1o.json (z.B. DEV, TEST, PROD)"
    Write-Host "  - INST = Instanzname (z.B. KST_2026, BER_25, NVR_25)"
    Write-Host "  - Eingaben fuer ENV und INSTANCE werden intern in GROSSBUCHSTABEN konvertiert."
    Write-Host "  - Intern ruft tm1o:"
    Write-Host "      - Run_TM1_Process.ps1 fuer Prozess-Commands"
    Write-Host "      - Run_TM1_Query.ps1   fuer Cube/Cell-Queries"
    Write-Host ""
}

# Basisverzeichnisse und Pfade
$rootDir         = Split-Path -Parent $MyInvocation.MyCommand.Path
$runnerPath      = Join-Path $rootDir "runners\Run_TM1_Process.ps1"
$queryRunnerPath = Join-Path $rootDir "runners\Run_TM1_Query.ps1"
$choreRunnerPath = Join-Path $rootDir "runners\Run_TM1_Chore.ps1"
$configPath      = Join-Path $rootDir "config\tm1o.json"
$logsFolder      = Join-Path $rootDir "logs"
$chainFolder     = Join-Path $rootDir "processchains"
$archiveFolder   = Join-Path $logsFolder "archive"

$script:Tm1oConfigPath = $configPath

# Hilfsfunktion: config/tm1o.json laden
function Get-TM1OConfig {
    if (-not (Test-Path $configPath)) {
        Write-Host "FEHLER: config/tm1o.json wurde nicht gefunden: $configPath" -ForegroundColor Red
        return $null
    }
    try {
        return Get-Content $configPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Host "FEHLER: Konnte config/tm1o.json nicht lesen/parsen:" -ForegroundColor Red
        Write-Host ($_ | Out-String)
        return $null
    }
}

# Hilfsfunktion: Prozesskette anzeigen
function Show-Chain {
    param(
        [string]$Environment,
        [string]$Instance,
        [string]$ChainName
    )

    $env  = $Environment.ToUpper()
    $inst = $Instance.ToUpper()

    if ($ChainName) {
        $chainFileName = "{0}_{1}_{2}.json" -f $env, $inst, $ChainName.ToUpper()
    }
    else {
        $chainFileName = "{0}_{1}.json" -f $env, $inst
    }

    $chainPath = Join-Path $chainFolder $chainFileName

    if (-not (Test-Path $chainPath)) {
        Write-Host ("Keine ProcessChain-Datei gefunden fuer '{0}' / '{1}': {2}" -f $env, $inst, $chainPath) -ForegroundColor Yellow
        return
    }

    try {
        $chainJson = Get-Content $chainPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Host ("Fehler beim Lesen/Parsen von '{0}':" -f $chainPath) -ForegroundColor Red
        Write-Host ($_ | Out-String)
        return
    }

    if (-not $chainJson.ProcessChain -or $chainJson.ProcessChain.Count -eq 0) {
        Write-Host ("In '{0}' wurde keine gueltige ProcessChain gefunden." -f $chainPath) -ForegroundColor Yellow
        return
    }

    Write-Host ("ProcessChain fuer {0} / {1} (Datei: {2}):" -f $env, $inst, $chainFileName)
    $i = 1
    foreach ($step in $chainJson.ProcessChain) {
        $name   = $step.Name
        $params = $step.Parameters
        $paramInfo = "keine"
        if ($params -and $params.Count -gt 0) {
            $paramInfo = ($params | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ", "
        }
        Write-Host ("  {0}. {1}  (Parameter: {2})" -f $i, $name, $paramInfo)
        $i++
    }
}

# Hilfsfunktion: letztes Log anzeigen
function Show-LastLog {
    param(
        [string]$Environment,
        [string]$Instance
    )

    $env  = $Environment.ToUpper()
    $inst = $Instance.ToUpper()

    if (-not (Test-Path $logsFolder)) {
        Write-Host ("Log-Ordner existiert nicht: {0}" -f $logsFolder) -ForegroundColor Yellow
        return
    }

    $pattern  = "{0}_{1}_*.log" -f $env, $inst
    $logFiles = Get-ChildItem -Path $logsFolder -Filter $pattern -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending

    if (-not $logFiles -or $logFiles.Count -eq 0) {
        Write-Host ("Kein Logfile fuer '{0}' / '{1}' gefunden (Pattern: {2})." -f $env, $inst, $pattern) -ForegroundColor Yellow
        return
    }

    $file = $logFiles[0]
    Write-Host ("Letztes Logfile fuer {0} / {1}:" -f $env, $inst)
    Write-Host ("  {0}" -f $file.FullName)
    Write-Host ""

    try {
        $logLines = Get-Content $file.FullName -ErrorAction Stop
    }
    catch {
        Write-Host ("Konnte Logfile nicht lesen: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        return
    }

    $summaryLine = $logLines | Where-Object { $_ -like "*SUMMARY|*" } | Select-Object -Last 1

    if ($summaryLine) {
        Write-Host "SUMMARY:"
        Write-Host ("  {0}" -f $summaryLine)
    }
    else {
        Write-Host "Keine SUMMARY-Zeile im Log gefunden. Letzte 5 Zeilen:"
        $tail = $logLines | Select-Object -Last 5
        foreach ($l in $tail) {
            Write-Host ("  {0}" -f $l)
        }
    }
}

# Hilfsfunktion: Status aus Archiv anzeigen
function Show-Status {
    param(
        [string]$Environment,
        [string]$Instance,
        [int]$Count = 5
    )

    $env  = $Environment.ToUpper()
    $inst = $Instance.ToUpper()

    $archiveFile = Join-Path $archiveFolder ("{0}_{1}_archive.csv" -f $env, $inst)

    if (-not (Test-Path $archiveFile)) {
        Write-Host ("Keine Archiv-CSV fuer '{0}' / '{1}' gefunden: {2}" -f $env, $inst, $archiveFile) -ForegroundColor Yellow
        Write-Host "Hinweis: Archiv wird erst befuellt, wenn Logrotation stattgefunden hat (TM1O.Core)."
        return
    }

    try {
        $rows = Import-Csv $archiveFile -ErrorAction Stop
    }
    catch {
        Write-Host ("Konnte Archiv-CSV nicht lesen: {0}" -f $_.Exception.Message) -ForegroundColor Red
        return
    }

    if (-not $rows -or $rows.Count -eq 0) {
        Write-Host ("Archiv-CSV ist leer: {0}" -f $archiveFile) -ForegroundColor Yellow
        return
    }

    # Nach Start sortieren, falls Spalte vorhanden, ansonsten nach RunId
    if ($rows[0].PSObject.Properties.Name -contains "Start") {
        $rowsSorted = $rows | Sort-Object { $_.Start } -Descending
    }
    else {
        $rowsSorted = $rows | Sort-Object { $_.RunId } -Descending
    }

    $top = $rowsSorted | Select-Object -First $Count

    Write-Host ("Letzte {0} Runs fuer {1} / {2} (aus {3}):" -f $Count, $env, $inst, $archiveFile)
    foreach ($r in $top) {
        $runId   = $r.RunId
        $status  = $r.Status
        $start   = $r.Start
        $end     = $r.End
        $dur     = $r.DurationSec
        $mode    = $r.Mode
        $failed  = $r.FailedProcess

        Write-Host ("  RunId={0} | Status={1} | Mode={2} | Start={3} | End={4} | Dauer={5}s | FailedProcess={6}" -f `
            $runId, $status, $mode, $start, $end, $dur, $failed)
    }
}

# ===========================
# ARGUMENT COMPLETION (Environment / Instance)
# ===========================

try {
    Register-ArgumentCompleter -CommandName 'tm1o' -ParameterName 'Environment' -ScriptBlock {
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

        if (-not (Test-Path $script:Tm1oConfigPath)) { return }

        try {
            $cfg = Get-Content $script:Tm1oConfigPath -Raw | ConvertFrom-Json
        }
        catch {
            return
        }

        if (-not $cfg.Environments) { return }

        foreach ($env in $cfg.Environments) {
            $name = $env.Name
            if ($null -ne $name -and $name.ToUpper().StartsWith($wordToComplete.ToUpper())) {
                [System.Management.Automation.CompletionResult]::new($name, $name, 'ParameterValue', $name)
            }
        }
    } | Out-Null
}
catch {
    # Alte PowerShell-Versionen ohne Register-ArgumentCompleter einfach ignorieren
}

try {
    Register-ArgumentCompleter -CommandName 'tm1o' -ParameterName 'Instance' -ScriptBlock {
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

        if (-not (Test-Path $script:Tm1oConfigPath)) { return }

        try {
            $cfg = Get-Content $script:Tm1oConfigPath -Raw | ConvertFrom-Json
        }
        catch {
            return
        }

        if (-not $cfg.Environments) { return }

        $envName = $null
        if ($fakeBoundParameters.ContainsKey("Environment")) {
            $envName = $fakeBoundParameters["Environment"]
            if ($envName) { $envName = $envName.ToUpper() }
        }

        $instances = @()

        if ($envName) {
            $envCfg = $cfg.Environments | Where-Object { $_.Name -eq $envName }
            if ($envCfg -and $envCfg.Instances) {
                $instances = $envCfg.Instances
            }
        }
        else {
            # Falls kein Environment angegeben ist, alle Instanzen aus allen Envs vorschlagen
            foreach ($e in $cfg.Environments) {
                if ($e.Instances) {
                    $instances += $e.Instances
                }
            }
        }

        foreach ($inst in $instances) {
            $name = $inst.Name
            if ($null -ne $name -and $name.ToUpper().StartsWith($wordToComplete.ToUpper())) {
                [System.Management.Automation.CompletionResult]::new($name, $name, 'ParameterValue', $name)
            }
        }
    } | Out-Null
}
catch {
    # Ignorieren, falls Register-ArgumentCompleter nicht verfuegbar ist
}

# ===========================
# HAUPTLOGIK (nur bei normalem Aufruf, nicht beim Dot-Sourcing)
# ===========================
if ($MyInvocation.InvocationName -eq ".") {
    # Script wurde dot-gesourced -> nur Funktionen und Completer bereitstellen, keine Ausfuehrung
    return
}

if ($Environment) {
    $Environment = $Environment.Trim().ToUpper()
}
if ($Instance) {
    $Instance = $Instance.Trim().ToUpper()
}

# Name (z.B. CubeName oder ChainName) und restliche Argumente aus RemainingArgs holen
$NameFromArgs = $null
$ExtraArgs    = @()

if ($RemainingArgs -and $RemainingArgs.Count -gt 0) {
    $NameFromArgs = $RemainingArgs[0]
    if ($RemainingArgs.Count -gt 1) {
        $ExtraArgs = $RemainingArgs[1..($RemainingArgs.Count - 1)]
    }
}

Write-Host ""
Write-Host "TM1 Orchestrator CLI"
Write-Host ("Command         : {0}" -f $Command)
if ($Environment) { Write-Host ("Environment     : {0}" -f $Environment) }
if ($Instance)    { Write-Host ("Instance        : {0}" -f $Instance) }
if ($NameFromArgs){ Write-Host ("Name            : {0}" -f $NameFromArgs) }
Write-Host ("ConsoleLogLevel : {0}" -f $ConsoleLogLevel)
Write-Host ("FileLogLevel    : {0}" -f $FileLogLevel)
Write-Host ""
Write-Host ("Config          : {0}" -f $configPath)
Write-Host ("Runner          : {0}" -f $runnerPath)
Write-Host ("QueryRunner     : {0}" -f $queryRunnerPath)
Write-Host ("ChoreRunner     : {0}" -f $choreRunnerPath)
Write-Host ""

switch ($Command.ToLower()) {

    # --------------------
    # Prozess-orientierte Commands
    # --------------------
    "run" {
        if (-not (Test-Path $runnerPath)) {
            Write-Host ("FEHLER: Framework-Script 'Run_TM1_Process.ps1' wurde im Verzeichnis '{0}' nicht gefunden." -f (Join-Path $rootDir "runners")) -ForegroundColor Red
            Write-Host "Hinweis: Der Runner liegt kuenftig unter 'runners' und laedt Module aus 'modules'."
            exit 99
        }
        if (-not $Environment -or -not $Instance) {
            Write-Host "Fehler: Environment und Instance muessen angegeben werden." -ForegroundColor Red
            Show-Help
            exit 1
        }

        $chainName = $NameFromArgs
        if ($chainName) { $chainName = $chainName.Trim().ToUpper() }

        Write-Host "Starte TM1 Orchestrator (Mode: Execute)..." -ForegroundColor Cyan
        if ($chainName) {
            & $runnerPath -Env $Environment -Inst $Instance -ChainName $chainName -ConsoleLogLevel $ConsoleLogLevel -FileLogLevel $FileLogLevel
        }
        else {
            & $runnerPath -Env $Environment -Inst $Instance -ConsoleLogLevel $ConsoleLogLevel -FileLogLevel $FileLogLevel
        }
        exit $LASTEXITCODE
    }

    "dryrun" {
        if (-not (Test-Path $runnerPath)) {
            Write-Host ("FEHLER: Framework-Script 'Run_TM1_Process.ps1' wurde im Verzeichnis '{0}' nicht gefunden." -f (Join-Path $rootDir "runners")) -ForegroundColor Red
            Write-Host "Hinweis: Der Runner liegt kuenftig unter 'runners' und laedt Module aus 'modules'."
            exit 99
        }
        if (-not $Environment -or -not $Instance) {
            Write-Host "Fehler: Environment und Instance muessen angegeben werden." -ForegroundColor Red
            Show-Help
            exit 1
        }
        $chainName = $NameFromArgs
        if ($chainName) { $chainName = $chainName.Trim().ToUpper() }

        Write-Host "Starte TM1 Orchestrator (Mode: DryRun)..." -ForegroundColor Cyan
        if ($chainName) {
            & $runnerPath -Env $Environment -Inst $Instance -ChainName $chainName -DryRun -ConsoleLogLevel $ConsoleLogLevel -FileLogLevel $FileLogLevel
        }
        else {
            & $runnerPath -Env $Environment -Inst $Instance -DryRun -ConsoleLogLevel $ConsoleLogLevel -FileLogLevel $FileLogLevel
        }
        exit $LASTEXITCODE
    }

    "validate" {
        if (-not (Test-Path $runnerPath)) {
            Write-Host ("FEHLER: Framework-Script 'Run_TM1_Process.ps1' wurde im Verzeichnis '{0}' nicht gefunden." -f (Join-Path $rootDir "runners")) -ForegroundColor Red
            Write-Host "Hinweis: Der Runner liegt kuenftig unter 'runners' und laedt Module aus 'modules'."
            exit 99
        }
        if (-not $Environment -or -not $Instance) {
            Write-Host "Fehler: Environment und Instance muessen angegeben werden." -ForegroundColor Red
            Show-Help
            exit 1
        }
        $chainName = $NameFromArgs
        if ($chainName) { $chainName = $chainName.Trim().ToUpper() }

        Write-Host "Starte TM1 Orchestrator (Mode: ValidateOnly)..." -ForegroundColor Cyan
        if ($chainName) {
            & $runnerPath -Env $Environment -Inst $Instance -ChainName $chainName -ValidateOnly -ConsoleLogLevel $ConsoleLogLevel -FileLogLevel $FileLogLevel
        }
        else {
            & $runnerPath -Env $Environment -Inst $Instance -ValidateOnly -ConsoleLogLevel $ConsoleLogLevel -FileLogLevel $FileLogLevel
        }
        exit $LASTEXITCODE
    }

    "run-proc" {
        if (-not (Test-Path $runnerPath)) {
            Write-Host ("FEHLER: Framework-Script 'Run_TM1_Process.ps1' wurde im Verzeichnis '{0}' nicht gefunden." -f (Join-Path $rootDir "runners")) -ForegroundColor Red
            Write-Host "Hinweis: Der Runner liegt kuenftig unter 'runners' und laedt Module aus 'modules'."
            exit 99
        }
        if (-not $Environment -or -not $Instance -or -not $NameFromArgs) {
            Write-Host "Fehler: Bitte ENV, INSTANCE und PROC angeben. Beispiel:" -ForegroundColor Red
            Write-Host "  tm1o run-proc DEV KST_2026 S_10_Kostenstellen"
            exit 1
        }
        $procName = $NameFromArgs
        Write-Host ("Starte TM1 Orchestrator Single-Process (Execute) fuer Prozess '{0}'..." -f $procName) -ForegroundColor Cyan
        & $runnerPath -Env $Environment -Inst $Instance -ProcessName $procName -ConsoleLogLevel $ConsoleLogLevel -FileLogLevel $FileLogLevel
        exit $LASTEXITCODE
    }

    "dryrun-proc" {
        if (-not (Test-Path $runnerPath)) {
            Write-Host ("FEHLER: Framework-Script 'Run_TM1_Process.ps1' wurde im Verzeichnis '{0}' nicht gefunden." -f (Join-Path $rootDir "runners")) -ForegroundColor Red
            Write-Host "Hinweis: Der Runner liegt kuenftig unter 'runners' und laedt Module aus 'modules'."
            exit 99
        }
        if (-not $Environment -or -not $Instance -or -not $NameFromArgs) {
            Write-Host "Fehler: Bitte ENV, INSTANCE und PROC angeben. Beispiel:" -ForegroundColor Red
            Write-Host "  tm1o dryrun-proc DEV KST_2026 S_10_Kostenstellen"
            exit 1
        }
        $procName = $NameFromArgs
        Write-Host ("Starte TM1 Orchestrator Single-Process (DryRun) fuer Prozess '{0}'..." -f $procName) -ForegroundColor Cyan
        & $runnerPath -Env $Environment -Inst $Instance -ProcessName $procName -DryRun -ConsoleLogLevel $ConsoleLogLevel -FileLogLevel $FileLogLevel
        exit $LASTEXITCODE
    }

    "validate-proc" {
        if (-not (Test-Path $runnerPath)) {
            Write-Host ("FEHLER: Framework-Script 'Run_TM1_Process.ps1' wurde im Verzeichnis '{0}' nicht gefunden." -f (Join-Path $rootDir "runners")) -ForegroundColor Red
            Write-Host "Hinweis: Der Runner liegt kuenftig unter 'runners' und laedt Module aus 'modules'."
            exit 99
        }
        if (-not $Environment -or -not $Instance -or -not $NameFromArgs) {
            Write-Host "Fehler: Bitte ENV, INSTANCE und PROC angeben. Beispiel:" -ForegroundColor Red
            Write-Host "  tm1o validate-proc DEV KST_2026 S_10_Kostenstellen"
            exit 1
        }
        $procName = $NameFromArgs
        Write-Host ("Starte TM1 Orchestrator Single-Process (ValidateOnly) fuer Prozess '{0}'..." -f $procName) -ForegroundColor Cyan
        & $runnerPath -Env $Environment -Inst $Instance -ProcessName $procName -ValidateOnly -ConsoleLogLevel $ConsoleLogLevel -FileLogLevel $FileLogLevel
        exit $LASTEXITCODE
    }

    # --------------------
    # Chore-orientierte Commands
    # --------------------

    "run-chore" {
        if (-not (Test-Path $choreRunnerPath)) {
            Write-Host ("FEHLER: Framework-Script 'Run_TM1_Chore.ps1' wurde im Verzeichnis '{0}' nicht gefunden." -f (Join-Path $rootDir "runners")) -ForegroundColor Red
            Write-Host "Hinweis: Der Chore-Runner erwartet die Module 'TM1O.Core.psm1' und 'TM1O.REST.psm1' im Unterordner /runners/."
            exit 99
        }
        if (-not $Environment -or -not $Instance -or -not $NameFromArgs) {
            Write-Host "Fehler: Bitte ENV, INSTANCE und CHORE angeben. Beispiel:" -ForegroundColor Red
            Write-Host "  tm1o run-chore DEV KST_2026 CH_Import_KST"
            exit 1
        }

        $choreName = $NameFromArgs
        Write-Host ("Starte TM1 Orchestrator Chore (Execute) fuer Chore '{0}'..." -f $choreName) -ForegroundColor Cyan

        if ($IgnoreDisabled) {
            Write-Host "Hinweis: IgnoreDisabled ist gesetzt - Enabled-Status der Chore wird im Runner ignoriert." -ForegroundColor Yellow
            & $choreRunnerPath -Env $Environment -Inst $Instance -ChoreName $choreName -IgnoreDisabled -ConsoleLogLevel $ConsoleLogLevel -FileLogLevel $FileLogLevel
        }
        else {
            & $choreRunnerPath -Env $Environment -Inst $Instance -ChoreName $choreName -ConsoleLogLevel $ConsoleLogLevel -FileLogLevel $FileLogLevel
        }

        exit $LASTEXITCODE
    }

    "dryrun-chore" {
        if (-not (Test-Path $choreRunnerPath)) {
            Write-Host ("FEHLER: Framework-Script 'Run_TM1_Chore.ps1' wurde im Verzeichnis '{0}' nicht gefunden." -f (Join-Path $rootDir "runners")) -ForegroundColor Red
            Write-Host "Hinweis: Der Chore-Runner erwartet die Module 'TM1O.Core.psm1' und 'TM1O.REST.psm1' im Unterordner /runners/."
            exit 99
        }
        if (-not $Environment -or -not $Instance -or -not $NameFromArgs) {
            Write-Host "Fehler: Bitte ENV, INSTANCE und CHORE angeben. Beispiel:" -ForegroundColor Red
            Write-Host "  tm1o dryrun-chore DEV KST_2026 CH_Import_KST"
            exit 1
        }

        $choreName = $NameFromArgs
        Write-Host ("Starte TM1 Orchestrator Chore (DryRun) fuer Chore '{0}'..." -f $choreName) -ForegroundColor Cyan

        if ($IgnoreDisabled) {
            Write-Host "Hinweis: IgnoreDisabled ist gesetzt - DryRun simuliert Ausfuehrung auch fuer deaktivierte Chores." -ForegroundColor Yellow
            & $choreRunnerPath -Env $Environment -Inst $Instance -ChoreName $choreName -DryRun -IgnoreDisabled -ConsoleLogLevel $ConsoleLogLevel -FileLogLevel $FileLogLevel
        }
        else {
            & $choreRunnerPath -Env $Environment -Inst $Instance -ChoreName $choreName -DryRun -ConsoleLogLevel $ConsoleLogLevel -FileLogLevel $FileLogLevel
        }

        exit $LASTEXITCODE
    }

    "validate-chore" {
        if (-not (Test-Path $choreRunnerPath)) {
            Write-Host ("FEHLER: Framework-Script 'Run_TM1_Chore.ps1' wurde im Verzeichnis '{0}' nicht gefunden." -f (Join-Path $rootDir "runners")) -ForegroundColor Red
            Write-Host "Hinweis: Der Chore-Runner erwartet die Module 'TM1O.Core.psm1' und 'TM1O.REST.psm1' im Unterordner /runners/."
            exit 99
        }
        if (-not $Environment -or -not $Instance -or -not $NameFromArgs) {
            Write-Host "Fehler: Bitte ENV, INSTANCE und CHORE angeben. Beispiel:" -ForegroundColor Red
            Write-Host "  tm1o validate-chore DEV KST_2026 CH_Import_KST"
            exit 1
        }

        $choreName = $NameFromArgs
        Write-Host ("Starte TM1 Orchestrator Chore (ValidateOnly) fuer Chore '{0}'..." -f $choreName) -ForegroundColor Cyan

        if ($IgnoreDisabled) {
            Write-Host "Hinweis: IgnoreDisabled ist gesetzt  Validate laesst deaktivierte Chores als OK durch." -ForegroundColor Yellow
            & $choreRunnerPath -Env $Environment -Inst $Instance -ChoreName $choreName -ValidateOnly -IgnoreDisabled -ConsoleLogLevel $ConsoleLogLevel -FileLogLevel $FileLogLevel
        }
        else {
            & $choreRunnerPath -Env $Environment -Inst $Instance -ChoreName $choreName -ValidateOnly -ConsoleLogLevel $ConsoleLogLevel -FileLogLevel $FileLogLevel
        }

        exit $LASTEXITCODE
    }

    "activate-chore" {
        if (-not (Test-Path $choreRunnerPath)) {
            Write-Host ("FEHLER: Framework-Script 'Run_TM1_Chore.ps1' wurde im Verzeichnis '{0}' nicht gefunden." -f (Join-Path $rootDir "runners")) -ForegroundColor Red
            Write-Host "Hinweis: Der Chore-Runner erwartet die Module 'TM1O.Core.psm1' und 'TM1O.REST.psm1' im Unterordner /runners/."
            exit 99
        }
        if (-not $Environment -or -not $Instance -or -not $NameFromArgs) {
            Write-Host "Fehler: Bitte ENV, INSTANCE und CHORE angeben. Beispiel:" -ForegroundColor Red
            Write-Host "  tm1o activate-chore DEV KST_2026 CH_Import_KST"
            exit 1
        }

        $choreName = $NameFromArgs
        Write-Host ("Starte TM1 Orchestrator Chore (Activate) fuer Chore '{0}'..." -f $choreName) -ForegroundColor Cyan
        & $choreRunnerPath -Env $Environment -Inst $Instance -ChoreName $choreName -Activate -ConsoleLogLevel $ConsoleLogLevel -FileLogLevel $FileLogLevel
        exit $LASTEXITCODE
    }

    "deactivate-chore" {
        if (-not (Test-Path $choreRunnerPath)) {
            Write-Host ("FEHLER: Framework-Script 'Run_TM1_Chore.ps1' wurde im Verzeichnis '{0}' nicht gefunden." -f (Join-Path $rootDir "runners")) -ForegroundColor Red
            Write-Host "Hinweis: Der Chore-Runner erwartet die Module 'TM1O.Core.psm1' und 'TM1O.REST.psm1' im Unterordner /runners/."
            exit 99
        }
        if (-not $Environment -or -not $Instance -or -not $NameFromArgs) {
            Write-Host "Fehler: Bitte ENV, INSTANCE und CHORE angeben. Beispiel:" -ForegroundColor Red
            Write-Host "  tm1o deactivate-chore DEV KST_2026 CH_Import_KST"
            exit 1
        }

        $choreName = $NameFromArgs
        Write-Host ("Starte TM1 Orchestrator Chore (Deactivate) fuer Chore '{0}'..." -f $choreName) -ForegroundColor Cyan
        & $choreRunnerPath -Env $Environment -Inst $Instance -ChoreName $choreName -Deactivate -ConsoleLogLevel $ConsoleLogLevel -FileLogLevel $FileLogLevel
        exit $LASTEXITCODE
    }

    "chore-info" {
        if (-not (Test-Path $choreRunnerPath)) {
            Write-Host ("FEHLER: Framework-Script 'Run_TM1_Chore.ps1' wurde im Verzeichnis '{0}' nicht gefunden." -f (Join-Path $rootDir "runners")) -ForegroundColor Red
            Write-Host "Hinweis: Der Chore-Runner erwartet die Module 'TM1O.Core.psm1' und 'TM1O.REST.psm1' im Unterordner /runners/."
            exit 99
        }
        if (-not $Environment -or -not $Instance -or -not $NameFromArgs) {
            Write-Host "Fehler: Bitte ENV, INSTANCE und CHORE angeben. Beispiel:" -ForegroundColor Red
            Write-Host "  tm1o chore-info DEV KST_2026 CH_Import_KST"
            exit 1
        }

        $choreName = $NameFromArgs
        Write-Host ("Starte TM1 Orchestrator ChoreInfo fuer Chore '{0}'..." -f $choreName) -ForegroundColor Cyan

        & $choreRunnerPath -Env $Environment -Inst $Instance -ChoreName $choreName -ChoreInfo -ConsoleLogLevel $ConsoleLogLevel -FileLogLevel $FileLogLevel

        exit $LASTEXITCODE
    }

    # --------------------
    # Query-orientierte Commands (Cube und Cells)
    # --------------------

    "cube-info" {
        if (-not (Test-Path $queryRunnerPath)) {
            Write-Host ("FEHLER: Framework-Script 'Run_TM1_Query.ps1' wurde im Verzeichnis '{0}' nicht gefunden." -f (Join-Path $rootDir "runners")) -ForegroundColor Red
            Write-Host "Hinweis: Der Query-Runner erwartet die Module 'TM1O.Core.psm1' und 'TM1O.REST.psm1' im Unterordner /runners/."
            exit 99
        }
        if (-not $Environment -or -not $Instance -or -not $NameFromArgs) {
            Write-Host "Fehler: Bitte ENV, INSTANCE und CUBE angeben. Beispiel:" -ForegroundColor Red
            Write-Host "  tm1o cube-info DEV KST_2026 KST"
            exit 1
        }
        $cubeName = $NameFromArgs
        Write-Host ("Starte TM1 Query (CubeInfo) fuer Cube '{0}'..." -f $cubeName) -ForegroundColor Cyan
        & $queryRunnerPath -Env $Environment -Inst $Instance -Mode CubeInfo -CubeName $cubeName -ConsoleLogLevel $ConsoleLogLevel -FileLogLevel $FileLogLevel
        exit $LASTEXITCODE
    }

    "cell" {
        if (-not (Test-Path $queryRunnerPath)) {
            Write-Host ("FEHLER: Framework-Script 'Run_TM1_Query.ps1' wurde im Verzeichnis '{0}' nicht gefunden." -f (Join-Path $rootDir "runners")) -ForegroundColor Red
            Write-Host "Hinweis: Der Query-Runner erwartet die Module 'TM1O.Core.psm1' und 'TM1O.REST.psm1' im Unterordner /runners/."
            exit 99
        }
        if (-not $Environment -or -not $Instance -or -not $NameFromArgs) {
            Write-Host "Fehler: Bitte ENV, INSTANCE und CUBE angeben. Beispiel:" -ForegroundColor Red
            Write-Host "  tm1o cell DEV KST_2026 KST Kostenstellen:P_10190 ..."
            exit 1
        }

        $cubeName = $NameFromArgs

        if (-not $ExtraArgs -or $ExtraArgs.Count -eq 0) {
            Write-Host "Fehler: Fuer 'cell' muessen mindestens eine oder mehrere Koordinaten angegeben werden." -ForegroundColor Red
            Write-Host "Beispiel:"
            Write-Host "  tm1o cell DEV KST_2026 KST Kostenstellen:P_10190 Kostenarten:2S.GV2 ..."
            exit 1
        }

        $coordinates = @()
        foreach ($c in $ExtraArgs) {
            if ($null -ne $c -and $c.Trim().Length -gt 0) {
                $coordinates += $c.Trim()
            }
        }

        Write-Host ("Starte TM1 Query (CellValue) fuer Cube '{0}'..." -f $cubeName) -ForegroundColor Cyan
        & $queryRunnerPath -Env $Environment -Inst $Instance -Mode CellValue -CubeName $cubeName -Coordinates $coordinates -ConsoleLogLevel $ConsoleLogLevel -FileLogLevel $FileLogLevel
        exit $LASTEXITCODE
    }

    "cell-table" {
        if (-not (Test-Path $queryRunnerPath)) {
            Write-Host ("FEHLER: Framework-Script 'Run_TM1_Query.ps1' wurde im Verzeichnis '{0}' nicht gefunden." -f (Join-Path $rootDir "runners")) -ForegroundColor Red
            Write-Host "Hinweis: Der Query-Runner erwartet die Module 'TM1O.Core.psm1' und 'TM1O.REST.psm1' im Unterordner /runners/."
            exit 99
        }
        if (-not $Environment -or -not $Instance -or -not $NameFromArgs) {
            Write-Host "Fehler: Bitte ENV, INSTANCE und CUBE angeben. Beispiel:" -ForegroundColor Red
            Write-Host "  tm1o cell-table DEV KST_2026 KST \"P_10190,2S.GV2,...\" \"...\""
            exit 1
        }

        $cubeName = $NameFromArgs

        if (-not $ExtraArgs -or $ExtraArgs.Count -eq 0) {
            Write-Host "Fehler: Fuer 'cell-table' muessen mindestens ein Koordinatenset angegeben werden." -ForegroundColor Red
            Write-Host "Beispiel:"
            Write-Host "  tm1o cell-table DEV KST_2026 KST"
            Write-Host "      \"P_10190,2S.GV2,Entwicklung,monatlich,Ist_EUR,Okt_25\""
            Write-Host "      \"P_10190,2S.GV2,Entwicklung,monatlich,Ist_EUR,Nov_25\""
            exit 1
        }

        $coordinateSets = @()

        foreach ($setString in $ExtraArgs) {
            if ([string]::IsNullOrWhiteSpace($setString)) { continue }

            # Ein ExtraArg kann mehrere Sets mit ';' enthalten
            $setChunks = $setString.Split(";", [System.StringSplitOptions]::RemoveEmptyEntries)

            foreach ($chunk in $setChunks) {
                $chunkTrim = $chunk.Trim()
                if ($chunkTrim.Length -eq 0) { continue }

                # Innerhalb eines Sets per Komma trennen
                $parts = $chunkTrim.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries) |
                         ForEach-Object { $_.Trim() } |
                         Where-Object { $_.Length -gt 0 }

                if ($parts.Count -gt 0) {
                    # EIN Koordinatenset als string[]
                    $coordinateSets += ,$parts
                }
            }
        }

        if ($coordinateSets.Count -eq 0) {
            Write-Host "Fehler: Aus den uebergebenen Koordinatensets konnten keine gueltigen Koordinaten gelesen werden." -ForegroundColor Red
            exit 1
        }

        Write-Host ("Starte TM1 Query (CellTable) fuer Cube '{0}'..." -f $cubeName) -ForegroundColor Cyan
        & $queryRunnerPath `
            -Env $Environment `
            -Inst $Instance `
            -Mode CellTable `
            -CubeName $cubeName `
            -CoordinateSets $coordinateSets `
            -ConsoleLogLevel $ConsoleLogLevel

        exit $LASTEXITCODE
    }

    # --------------------
    # Metadaten / Logs
    # --------------------

    "list-env" {
        $cfg = Get-TM1OConfig
        if (-not $cfg) { exit 1 }

        if (-not $cfg.Environments) {
            Write-Host "Keine Environments in config/tm1o.json gefunden."
            exit 0
        }

        Write-Host "Verfuegbare Environments in config/tm1o.json:"
        foreach ($env in $cfg.Environments) {
            if ($env.Name) {
                Write-Host ("  {0}" -f $env.Name)
            }
        }
        exit 0
    }

    "list-inst" {
        if (-not $Environment) {
            Write-Host "Fehler: Bitte Environment angeben. Beispiel:" -ForegroundColor Red
            Write-Host "  tm1o list-inst DEV"
            exit 1
        }

        $cfg = Get-TM1OConfig
        if (-not $cfg) { exit 1 }

        $envCfg = $cfg.Environments | Where-Object { $_.Name -eq $Environment }
        if (-not $envCfg) {
            Write-Host ("Environment '{0}' wurde in config/tm1o.json nicht gefunden." -f $Environment) -ForegroundColor Red
            exit 1
        }

        if (-not $envCfg.Instances -or $envCfg.Instances.Count -eq 0) {
            Write-Host ("Keine Instanzen fuer Environment '{0}' definiert." -f $Environment)
            exit 0
        }

        Write-Host ("Instanzen in Environment '{0}':" -f $Environment)
        foreach ($inst in $envCfg.Instances) {
            if ($inst.Name) {
                Write-Host ("  {0}" -f $inst.Name)
            }
        }
        exit 0
    }

    "chain" {
        if (-not $Environment -or -not $Instance) {
            Write-Host "Fehler: Bitte Environment und Instance angeben. Beispiel:" -ForegroundColor Red
            Write-Host "  tm1o chain DEV KST_2026 [CHAIN]"
            exit 1
        }
        $chainName = $NameFromArgs
        Show-Chain -Environment $Environment -Instance $Instance -ChainName $chainName
        exit 0
    }

    "lastlog" {
        if (-not $Environment -or -not $Instance) {
            Write-Host "Fehler: Bitte Environment und Instance angeben. Beispiel:" -ForegroundColor Red
            Write-Host "  tm1o lastlog DEV KST_2026"
            exit 1
        }
        Show-LastLog -Environment $Environment -Instance $Instance
        exit 0
    }

    "status" {
        if (-not $Environment -or -not $Instance) {
            Write-Host "Fehler: Bitte Environment und Instance angeben. Beispiel:" -ForegroundColor Red
            Write-Host "  tm1o status DEV KST_2026"
            exit 1
        }
        Show-Status -Environment $Environment -Instance $Instance -Count 5
        exit 0
    }

    "help" {
        Show-Help
        exit 0
    }

    default {
        Write-Host ("Unbekanntes Command: {0}" -f $Command) -ForegroundColor Red
        Show-Help
        exit 1
    }
}