<# 
================================================================================
  TM1 Orchestrator Framework - Runner Script: Run_TM1_Query.ps1 - Version 0.2 (2026-03-13)
================================================================================

 Zweck:
   - Allgemeiner Query-Runner fuer TM1 REST Abfragen
   - Unterstuetzt Cube-Infos, Single-Cell-Reads und Multi-Cell-Tabellen

 Modi:
   - CubeInfo   → gibt Cube-Metadaten aus
   - CellValue  → liest eine einzelne Zelle
   - CellTable  → liest mehrere Zellen als Tabelle

 -------------------------------------------------------------------------------
 Frameworkstruktur (relevant fuer dieses Script):
 -------------------------------------------------------------------------------

   TM1Orchestrator\
      config\        -> tm1o.json (Framework-Konfiguration)
      modules\       -> TM1O.Core.psm1, TM1O.REST.psm1, TM1O.Domain.psm1
      runners\       -> Runner-Scripts (dieses Script)
      processchains\ -> Definitionen / zusaetzliche Steuerdateien
      logs\          -> Logdateien

 Dieses Script nutzt die Module:

   modules\TM1O.Core.psm1    -> Logging, Config, Summary, Logrotation
   modules\TM1O.REST.psm1    -> REST-Aufrufe gegen TM1 / Planning Analytics
   modules\TM1O.Domain.psm1  -> Domain-Modelle / Query-bezogene Objekte

--------------------------------------------------------------------------------
 Parameteruebersicht
--------------------------------------------------------------------------------
 -Env            Environment (DEV / TEST / PROD)
 -Inst           TM1 Instanzname (z.B. KST_2026)
 -Mode           CubeInfo / CellValue / CellTable
 -CubeName       Name des Cubes
 -Coordinates    (nur CellValue)      → einzelne Koordinate
 -CoordinateSets (nur CellTable)      → mehrere Koordinaten-Sets

--------------------------------------------------------------------------------
 Unterstuetzte Eingabeformate fuer Koordinaten
--------------------------------------------------------------------------------

===========================
 1. SINGLE CELL (CellValue)
===========================

--A) Format ohne Dimensionsnamen:
    -Coordinates "P_10190","2S.GV2","Entwicklung","monatlich","Ist_EUR","Dez_25"

--B) Format MIT Dimensionsnamen:
    -Coordinates `
        "Kostenstellen:P_10190",
        "Kostenarten:2S.GV2",
        "Freigabe:Entwicklung",
        "Sichtweise:monatlich",
        "Version:Ist_EUR",
        "Zeit:Dez_25"

 Beide Varianten werden automatisch normalisiert.


===========================
 2. MULTI CELL (CellTable)
===========================

Es werden mehrere Koordinaten-Sets akzeptiert.  
Alle folgenden Varianten sind gueltig:

-------------------------------------------------------------------------------
 A) EIN String mit Semikolon-getrennten Sets  (EMPFOHLEN fuer CMD/BAT)
-------------------------------------------------------------------------------
 -CoordinateSets "P_10190,2S.GV2,Entwicklung,monatlich,Ist_EUR,Okt_25;P_10190,2S.GV2,Entwicklung,monatlich,Ist_EUR,Nov_25"

==> WICHTIG: Die Reihenfolge der Dimenionen MUSS ZWINGEND der Reihenfolge im Cube entsprechen, da keine Dimensionsnamen angegeben werden.

 Mit Dimensionsnamen:
 -CoordinateSets "Kostenstellen:P_10190,Kostenarten:2S.GV2,Freigabe:Entwicklung,Sichtweise:monatlich,Version:Ist_EUR,Zeit:Okt_25;Kostenstellen:P_10190,Kostenarten:2S.GV2,Freigabe:Entwicklung,Sichtweise:monatlich,Version:Ist_EUR,Zeit:Nov_25"


-------------------------------------------------------------------------------
 B) Mehrere Strings, jeweils ein Set (PowerShell-only)
-------------------------------------------------------------------------------
 -CoordinateSets `
     "P_10190,2S.GV2,Entwicklung,monatlich,Ist_EUR,Okt_25" `
     "P_10190,2S.GV2,Entwicklung,monatlich,Ist_EUR,Nov_25"

 oder:
 -CoordinateSets `
     "Kostenstellen:P_10190,Kostenarten:2S.GV2,Freigabe:Entwicklung,Sichtweise:monatlich,Version:Ist_EUR,Zeit:Okt_25" `
     "Kostenstellen:P_10190,Kostenarten:2S.GV2,Freigabe:Entwicklung,Sichtweise:monatlich,Version:Ist_EUR,Zeit:Nov_25"


-------------------------------------------------------------------------------
 C) PowerShell-Array von Array-Sets (PS-Skripte, NIE aus CMD/BAT)
-------------------------------------------------------------------------------
 -CoordinateSets @(
     @("P_10190","2S.GV2","Entwicklung","monatlich","Ist_EUR","Okt_25"),
     @("P_10190","2S.GV2","Entwicklung","monatlich","Ist_EUR","Nov_25")
 )


--------------------------------------------------------------------------------
 WICHTIGER HINWEIS FUER CMD / BATCH
--------------------------------------------------------------------------------
 CMD trennt Parameter ausschliesslich nach Leerzeichen.
 Darum MUSS bei CellTable aus einem BAT-File folgendes Format verwendet werden:

   EIN EINZIGER STRING:
   -CoordinateSets "Set1;Set2"

 Alle anderen Varianten funktionieren NUR in interaktiver PowerShell,
 NICHT jedoch in .BAT / Windows Scheduler Umgebungen.


--------------------------------------------------------------------------------
 Aufrufbeispiele (ohne ^)
--------------------------------------------------------------------------------

-- CubeInfo:
powershell -ExecutionPolicy Bypass -File "Run_TM1_Query.ps1" -Env DEV -Inst KST_2026 -Mode CubeInfo -CubeName KST

-- CellValue:
powershell -ExecutionPolicy Bypass -File "Run_TM1_Query.ps1" -Env DEV -Inst KST_2026 -Mode CellValue -CubeName KST -Coordinates "Kostenstellen:P_10190","Kostenarten:2S.GV2","Freigabe:Entwicklung","Sichtweise:monatlich","Version:Ist_EUR","Zeit:Dez_25"

-- CellTable (CMD-sicher):
powershell -ExecutionPolicy Bypass -File "Run_TM1_Query.ps1" -Env DEV -Inst KST_2026 -Mode CellTable -CubeName KST -CoordinateSets "P_10190,2S.GV2,Entwicklung,monatlich,Ist_EUR,Okt_25;P_10190,2S.GV2,Entwicklung,monatlich,Ist_EUR,Nov_25"

================================================================================
#>

param(
    [Alias("Environment")]
    [string]$Env  = "DEV",        # DEV / TEST / PROD

    [Alias("InstanceName","Instance")]
    [string]$Inst = "KST_2026",   # TM1-Servername / Datenbank

    [Parameter(Mandatory = $true)]
    [ValidateSet("CubeInfo","CellValue","CellTable")]
    [string]$Mode,                # Art der Query

    [string]$CubeName,            # Pflicht fuer alle Modi

    [string[]]$Coordinates,       # fuer Mode=CellValue

    [object[]]$CoordinateSets,    # fuer Mode=CellTable

    [ValidateSet("Info","Detail","Debug")]
    [string]$ConsoleLogLevel = "Info",   # LogLevel in der Konsole

    [ValidateSet("Info","Detail","Debug")]
    [string]$FileLogLevel = "Detail"     # LogLevel im Logfile
)

# ===========================
# EXIT CODES
# ===========================

$EXIT_SUCCESS            = 0
$EXIT_CONFIG_ERROR       = 2
$EXIT_HEALTHCHECK_FAILED = 3
$EXIT_QUERY_ERROR        = 6

# ===========================
# BASIS-SETUP & MODULE LADEN
# ===========================

# Eingaben normalisieren (Env/Inst gross schreiben)
if ($Env)  { $Env  = $Env.Trim().ToUpper() }
if ($Inst) { $Inst = $Inst.Trim().ToUpper() }

if ([string]::IsNullOrWhiteSpace($Env) -or [string]::IsNullOrWhiteSpace($Inst)) {
    Write-Host "Fehler: Parameter 'Env' und 'Inst' duerfen nicht leer sein." -ForegroundColor Red
    exit $EXIT_CONFIG_ERROR
}

# Mode-spezifische Pflichtparameter pruefen (Basis, Details dann nach Normalisierung)
switch ($Mode) {
    "CubeInfo" {
        if ([string]::IsNullOrWhiteSpace($CubeName)) {
            Write-Host "Fehler: Fuer Mode=CubeInfo muss -CubeName angegeben werden." -ForegroundColor Red
            exit $EXIT_CONFIG_ERROR
        }
    }
    "CellValue" {
        if ([string]::IsNullOrWhiteSpace($CubeName)) {
            Write-Host "Fehler: Fuer Mode=CellValue muss -CubeName angegeben werden." -ForegroundColor Red
            exit $EXIT_CONFIG_ERROR
        }
        if (-not $Coordinates -or $Coordinates.Count -eq 0) {
            Write-Host "Fehler: Fuer Mode=CellValue muessen -Coordinates angegeben werden." -ForegroundColor Red
            exit $EXIT_CONFIG_ERROR
        }
    }
    "CellTable" {
        if ([string]::IsNullOrWhiteSpace($CubeName)) {
            Write-Host "Fehler: Fuer Mode=CellTable muss -CubeName angegeben werden." -ForegroundColor Red
            exit $EXIT_CONFIG_ERROR
        }
        if (-not $CoordinateSets -or $CoordinateSets.Count -eq 0) {
            Write-Host "Fehler: Fuer Mode=CellTable muessen -CoordinateSets angegeben werden." -ForegroundColor Red
            exit $EXIT_CONFIG_ERROR
        }
    }
}

$Environment  = $Env
$InstanceName = $Inst

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

# ===========================
# NORMALISIERUNGS-FUNKTIONEN
# ===========================

function Normalize-TM1Coordinates {
    param(
        [object[]]$Coordinates
    )

    $result = @()

    foreach ($c in $Coordinates) {
        if ($null -eq $c) { continue }

        $s = [string]$c
        if ([string]::IsNullOrWhiteSpace($s)) { continue }

        $parts = $s.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries)

        foreach ($p in $parts) {
            $trimmed = $p.Trim()
            if ($trimmed.Length -gt 0) {
                $result += $trimmed
            }
        }
    }

    return ,$result
}

function Normalize-TM1CoordinateSets {
    param(
        [object[]]$CoordinateSets
    )

    $result = @()

    # SPEZIALFALL: Ein einzelner String mit mehreren Sets, getrennt durch ';'
    # -> Nur anwenden, wenn das erste Element KEIN Array ist
    if ($CoordinateSets -and
        $CoordinateSets.Count -eq 1 -and
        -not ($CoordinateSets[0] -is [System.Array])) {

        $single = [string]$CoordinateSets[0]
        if (-not [string]::IsNullOrWhiteSpace($single) -and $single.Contains(";")) {

            $rows = $single.Split(";", [System.StringSplitOptions]::RemoveEmptyEntries)
            foreach ($row in $rows) {
                $rowTrim = $row.Trim()
                if ($rowTrim.Length -eq 0) { continue }

                # Erst nach Komma splitten (Standard-Format)
                $parts = $rowTrim.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries) |
                         ForEach-Object { $_.Trim() } |
                         Where-Object { $_.Length -gt 0 }

                # FALLBACK: Wenn keine Kommas vorhanden waren,
                # versuche whitespace-getrennte Koordinaten (z.B. aus tm1o)
                if ($parts.Count -eq 1 -and $rowTrim.Contains(" ")) {
                    $parts = $rowTrim.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries) |
                             ForEach-Object { $_.Trim() } |
                             Where-Object { $_.Length -gt 0 }
                }

                if ($parts.Count -gt 0) {
                    # Ein Set = ein string[]
                    $result += ,$parts
                }
            }

            return ,$result
        }
    }

    # Standardfall: Mehrere Argumente oder bereits Arrays
    foreach ($row in $CoordinateSets) {
        if ($null -eq $row) { continue }

        if ($row -is [System.Array]) {
            # Schon ein Array (z.B. aus tm1o oder PowerShell)
            $parts = @()
            foreach ($elem in $row) {
                $s = [string]$elem
                if (-not [string]::IsNullOrWhiteSpace($s)) {
                    $parts += $s.Trim()
                }
            }
            if ($parts.Count -gt 0) {
                $result += ,$parts
            }
        }
        else {
            # Einzelner String: ein Set
            $s = [string]$row
            if ([string]::IsNullOrWhiteSpace($s)) { continue }

            $parts = $s.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries) |
                     ForEach-Object { $_.Trim() } |
                     Where-Object { $_.Length -gt 0 }

            # Fallback: keine Kommas -> whitespace-getrennte Tokens
            if ($parts.Count -eq 1 -and $s.Contains(" ")) {
                $parts = $s.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries) |
                         ForEach-Object { $_.Trim() } |
                         Where-Object { $_.Length -gt 0 }
            }

            if ($parts.Count -gt 0) {
                $result += ,$parts
            }
        }
    }

    return ,$result
}

# ===========================
# CONFIG & RETRY LADEN
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

try {
    $retrySettings = Get-TM1ORetrySettings -Config $configJson
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit $EXIT_CONFIG_ERROR
}

# ===========================
# LOGKONTEXT
# ===========================

try {
    $logContext = New-TM1OLogContext -BasePath $rootDir `
                                     -Env $Environment `
                                     -Inst $InstanceName `
                                     -ChainFileName "QUERY_${Environment}_${InstanceName}.json" `
                                     -ConsoleLogLevel $ConsoleLogLevel `
                                     -FileLogLevel $FileLogLevel
}
catch {
    Write-Host "WARNUNG: Konnte LogContext nicht erstellen: $($_.Exception.Message)" -ForegroundColor Yellow
    $logContext = $null
}

# ===========================
# HTTP-HEADER
# ===========================

$Headers = @{
    "Authorization" = "CAMNamespace $ApiKey"
    "CAMNamespace"  = $CAMNamespace
    "Content-Type"  = "application/json"
}

# ===========================
# HEALTHCHECK
# ===========================

Write-Host ""
Write-Host "TM1 Query Runner"
Write-Host ("Environment     : {0}" -f $Environment)
Write-Host ("Instance        : {0}" -f $InstanceName)
Write-Host ("Mode            : {0}" -f $Mode)
if ($CubeName) { Write-Host ("Cube            : {0}" -f $CubeName) }
Write-Host ("Config          : {0}" -f $ConfigPath)
Write-Host ("TM1RestBase     : {0}" -f $TM1RestBase)
Write-Host ("ConsoleLogLevel : {0}" -f $ConsoleLogLevel)
Write-Host ("FileLogLevel    : {0}" -f $FileLogLevel)
Write-Host ""

Write-Host "HealthCheck: pruefe Erreichbarkeit der TM1-Instanz ..." -ForegroundColor Cyan
$healthOk = Test-TM1RestConnection -BaseUrl $TM1RestBase `
                                   -Headers $Headers `
                                   -TimeoutSec 30 `
                                   -LogContext $logContext

if (-not $healthOk) {
    Write-Host "HealthCheck fehlgeschlagen, Query wird abgebrochen." -ForegroundColor Red
    exit $EXIT_HEALTHCHECK_FAILED
}

# ===========================
# HAUPTLOGIK NACH MODE
# ===========================

try {
    switch ($Mode) {

        "CubeInfo" {
            Write-Host "Starte Query: CubeInfo ..." -ForegroundColor Cyan

            $cubeDomain = Get-TM1CubeDomain -BaseUrl $TM1RestBase `
                                            -Headers $Headers `
                                            -CubeName $CubeName `
                                            -RetrySettings $retrySettings `
                                            -LogContext $logContext

            Write-Host ""
            Write-Host ("Cube: {0}" -f $cubeDomain.CubeName)
            Write-Host "Dimensionsreihenfolge:"
            $cubeDomain.Dimensions | ForEach-Object { Write-Host ("  - {0}" -f $_) }
            Write-Host ""

            $cubeDomain
            exit $EXIT_SUCCESS
        }

        "CellValue" {
            Write-Host "Starte Query: CellValue ..." -ForegroundColor Cyan

            $effCoords = Normalize-TM1Coordinates -Coordinates $Coordinates

            if (-not $effCoords -or $effCoords.Count -eq 0) {
                Write-Host "Fehler: Nach Normalisierung sind keine gueltigen Koordinaten vorhanden." -ForegroundColor Red
                exit $EXIT_CONFIG_ERROR
            }

            Write-Host "Effektive Koordinaten:"
            $effCoords | ForEach-Object { Write-Host ("  {0}" -f $_) }

            $value = Get-TM1CellValue -BaseUrl $TM1RestBase `
                                      -Headers $Headers `
                                      -CubeName $CubeName `
                                      -Coordinates $effCoords `
                                      -RetrySettings $retrySettings `
                                      -LogContext $logContext

            Write-Host ""
            Write-Host "Ergebnis Single-Cell:"
            Write-Host ("  Cube   : {0}" -f $CubeName)
            Write-Host ("  Coords : {0}" -f ($effCoords -join ", "))
            Write-Host ("  Value  : {0}" -f $value)
            Write-Host ""

            $value
            exit $EXIT_SUCCESS
        }

        "CellTable" {
            Write-Host "Starte Query: CellTable ..." -ForegroundColor Cyan

            Write-Host ("Roh-CoordinateSets Count: {0}" -f $CoordinateSets.Count)
            foreach ($raw in $CoordinateSets) {
                Write-Host ("  RAW: [{0}]" -f ([string]$raw))
            }

            $effSets = Normalize-TM1CoordinateSets -CoordinateSets $CoordinateSets

            if (-not $effSets -or $effSets.Count -eq 0) {
                Write-Host "Fehler: Nach Normalisierung sind keine gueltigen CoordinateSets vorhanden." -ForegroundColor Red
                exit $EXIT_CONFIG_ERROR
            }

            Write-Host "Effektive Koordinaten-Sets:"
            $i = 1
            foreach ($set in $effSets) {
                Write-Host ("  Set {0}: {1}" -f $i, ($set -join ", "))
                $i++
            }

            $cubeDomain = Get-TM1CubeDomain -BaseUrl $TM1RestBase `
                                            -Headers $Headers `
                                            -CubeName $CubeName `
                                            -RetrySettings $retrySettings `
                                            -LogContext $logContext

            $dimNames = $cubeDomain.Dimensions

            $rows  = @()
            $index = 0

            foreach ($coordSet in $effSets) {
                $index++

                $coords = @()
                foreach ($c in $coordSet) {
                    $s = [string]$c
                    if (-not [string]::IsNullOrWhiteSpace($s)) {
                        $coords += $s.Trim()
                    }
                }

                $val = Get-TM1CellValue -BaseUrl $TM1RestBase `
                                        -Headers $Headers `
                                        -CubeName $CubeName `
                                        -Coordinates $coords `
                                        -RetrySettings $retrySettings `
                                        -LogContext $logContext

                $props = [ordered]@{
                    Index = $index
                    Cube  = $CubeName
                    Value = $val
                }

                $max = [Math]::Min($dimNames.Count, $coords.Count)
                for ($d = 0; $d -lt $max; $d++) {
                    $dimName    = $dimNames[$d]
                    $coordValue = $coords[$d]
                    $props[$dimName] = $coordValue
                }

                $rows += [PSCustomObject]$props
            }

            $table = $rows

            Write-Host ""
            Write-Host ("Ergebnis-Table fuer Cube {0} (Zeilen: {1}):" -f $CubeName, $table.Count)
            Write-Host ""

            $table | Format-Table -Auto

            $table
            exit $EXIT_SUCCESS
        }
    }
}
catch {
    Write-Host ""
    Write-Host ("FEHLER in Mode='{0}': {1}" -f $Mode, $_.Exception.Message) -ForegroundColor Red
    Write-Host ($_ | Out-String)
    exit $EXIT_QUERY_ERROR
}