<#
================================================================================
  TM1 Orchestrator Framework - Module: TM1O.Core.psm1 - Version 0.2 (2026-03-13)
================================================================================

 Bestandteil des TM1 Orchestrator Frameworks (TM1O).

 Dieses Modul befindet sich im Verzeichnis:

   TM1Orchestrator\modules\

 und stellt zentrale Basisfunktionen fuer das gesamte Framework bereit.

 -------------------------------------------------------------------------------
 Zweck dieses Moduls
 -------------------------------------------------------------------------------

   TM1O.Core.psm1 ist das Basismodul des Frameworks und kapselt zentrale
   Querschnittsfunktionen, die von Runnern und weiteren Modulen genutzt werden.

   Dazu gehoeren insbesondere:

     - Laden und Aufloesen der Framework-Konfiguration
     - Logging (Konsole + Logdatei)
     - Summary-Ausgaben
     - Logrotation und Archivierung
     - Retry-Logik fuer technische Aufrufe
     - zentrale Hilfsfunktionen fuer Framework-Bausteine

   Dieses Modul bildet die Grundlage fuer:

     - Runner Scripts
     - REST-Kommunikation
     - Domain-Logik
     - spaetere Git-Integration
     - weitere technische Erweiterungen des TM1 Orchestrator Frameworks

 -------------------------------------------------------------------------------
 Frameworkstruktur (relevant fuer dieses Modul)
 -------------------------------------------------------------------------------

   TM1Orchestrator\
      config\        -> tm1o.json (Framework-Konfiguration)
      modules\       -> TM1O.Core.psm1, TM1O.REST.psm1, TM1O.Domain.psm1
      runners\       -> Runner-Scripts
      processchains\ -> Definition der ProcessChains
      logs\          -> Logdateien

 Dieses Modul ist die zentrale technische Basis fuer alle anderen Framework-
 Bestandteile.

 -------------------------------------------------------------------------------
 Kernfunktionen dieses Moduls
 -------------------------------------------------------------------------------

   Konfiguration:
     - Laden und Aufloesen von config\tm1o.json
     - Zugriff auf Environment- und Instanz-Konfigurationen
     - Bereitstellung zentraler Framework-Einstellungen

   Logging:
     - Konsolen-Logging
     - Datei-Logging
     - Summary-Zeilen
     - Logkontext-Erzeugung

   Logverwaltung:
     - Logrotation
     - Archivierung
     - Aufbewahrungslogik (maxKeepLogs)

   Retry / Robustheit:
     - generischer Retry-Wrapper fuer technische Aufrufe
     - zentrale Fehlerbehandlung fuer wiederholbare Operationen

   Framework-Hilfsfunktionen:
     - gemeinsame Utility-Funktionen fuer Runner und Module
     - Basis fuer spaetere Git-, Deployment- und Orchestrierungslogik

 -------------------------------------------------------------------------------
 Konventionen im Framework
 -------------------------------------------------------------------------------

   Environment wird als:

      Env

   uebergeben, z.B.:

      DEV
      TEST
      PROD

   InstanceName wird als:

      Inst

   uebergeben, z.B.:

      KST_2026
      BER_26
      IFRS

 -------------------------------------------------------------------------------
 Logging-Konzept
 -------------------------------------------------------------------------------

   Das Framework verwendet ein abgestuftes Logging-Modell:

      Info
      Detail
      Debug

   Ziel ist eine konsistente technische Nachvollziehbarkeit ueber alle Runner
   und Module hinweg.

 -------------------------------------------------------------------------------
 Hinweis
 -------------------------------------------------------------------------------

   Dieses Modul ist kein eigenstaendig ausfuehrbares Script.

   Es wird ueber Import-Module von Runner-Scripts, Aggregator-Modulen
   (z.B. TM1Orchestrator.psm1) oder vom CLI Dispatcher (tm1o.ps1) geladen.

#>

# ----------------------------------------
# Zentrale Log-Level-Definition
# ----------------------------------------

$script:TM1O_LogLevels = @{
    Info   = 1
    Detail = 2
    Debug  = 3
}

# ----------------------------------------
# Scriptweite Caches
# ----------------------------------------

$script:TM1O_ConfigCache = @{}

# ----------------------------------------
# CONFIG-FUNKTIONEN
# ----------------------------------------

function Get-TM1OConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    if (-not (Test-Path $ConfigPath)) {
        throw "config/tm1o.json wurde nicht gefunden: $ConfigPath"
    }

    if ($script:TM1O_ConfigCache.ContainsKey($ConfigPath)) {
        return $script:TM1O_ConfigCache[$ConfigPath]
    }

    try {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Fehler beim Lesen oder Parsen von '$ConfigPath': $($_.Exception.Message)"
    }

    if (-not $cfg.Environments) {
        throw "In '$ConfigPath' wurde kein 'Environments'-Array gefunden."
    }

    $script:TM1O_ConfigCache[$ConfigPath] = $cfg
    return $cfg
}

function Get-TM1OEnvironmentConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Env
    )

    $envNorm = $Env.Trim().ToUpper()
    $envCfg  = $Config.Environments | Where-Object { $_.Name -eq $envNorm }

    if (-not $envCfg) {
        throw "Environment '$envNorm' wurde in config/tm1o.json nicht gefunden."
    }

    return $envCfg
}

function Get-TM1OInstanceConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Env,

        [Parameter(Mandatory = $true)]
        [string]$Inst
    )

    $envCfg = Get-TM1OEnvironmentConfig -Config $Config -Env $Env

    if (-not $envCfg.Instances) {
        throw "Environment '$($envCfg.Name)' enthaelt kein 'Instances'-Array."
    }

    $instNorm = $Inst.Trim().ToUpper()
    $instCfg  = $envCfg.Instances | Where-Object { $_.Name -eq $instNorm }

    if (-not $instCfg) {
        throw "In Environment '$($envCfg.Name)' wurde keine Instanz mit Name '$instNorm' gefunden."
    }

    return $instCfg
}

function Get-TM1ORetrySettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    $retry = $Config.RetrySettings
    if (-not $retry) {
        throw "In config/tm1o.json fehlen die RetrySettings."
    }

    if (-not $retry.MaxRetries -or -not $retry.RetryDelaySec -or -not $retry.TimeoutSec) {
        throw "RetrySettings sind unvollstaendig (MaxRetries / RetryDelaySec / TimeoutSec)."
    }

    return [PSCustomObject]@{
        MaxRetries    = [int]$retry.MaxRetries
        RetryDelaySec = [int]$retry.RetryDelaySec
        TimeoutSec    = [int]$retry.TimeoutSec
    }
}

function Get-TM1OMaxKeepLogs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Config
    )

    if ($null -eq $Config.maxKeepLogs) {
        throw "In config/tm1o.json fehlt der Parameter 'maxKeepLogs'."
    }

    return [int]$Config.maxKeepLogs
}

# ----------------------------------------
# LOGGING & LOG-KONTEXT
# ----------------------------------------

function New-TM1OLogContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BasePath,

        [Parameter(Mandatory = $true)]
        [string]$Env,

        [Parameter(Mandatory = $true)]
        [string]$Inst,

        [Parameter(Mandatory = $true)]
        [string]$ChainFileName,

        [ValidateSet("Info","Detail","Debug")]
        [string]$ConsoleLogLevel = "Info",

        [ValidateSet("Info","Detail","Debug")]
        [string]$FileLogLevel = "Debug"
    )

    $envNorm  = $Env.Trim().ToUpper()
    $instNorm = $Inst.Trim().ToUpper()

    $logsFolder    = Join-Path $BasePath "logs"
    $archiveFolder = Join-Path $logsFolder "archive"

    if (-not (Test-Path $logsFolder)) {
        New-Item -ItemType Directory -Path $logsFolder | Out-Null
    }
    if (-not (Test-Path $archiveFolder)) {
        New-Item -ItemType Directory -Path $archiveFolder | Out-Null
    }

    $chainBaseName = [System.IO.Path]::GetFileNameWithoutExtension($ChainFileName)
    $timestamp     = Get-Date -Format "yyyyMMdd_HHmmss"
    $logFileName   = "{0}_{1}_{2}_{3}.log" -f $envNorm, $instNorm, $chainBaseName, $timestamp
    $logFilePath   = Join-Path $logsFolder $logFileName

    return [PSCustomObject]@{
        Environment      = $envNorm
        InstanceName     = $instNorm
        LogsFolder       = $logsFolder
        ArchiveFolder    = $archiveFolder
        ChainBaseName    = $chainBaseName
        LogFile          = $logFilePath
        ConsoleLogLevel  = $ConsoleLogLevel
        FileLogLevel     = $FileLogLevel
    }
}

function Write-TM1OLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Context,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [ValidateSet("Info","Detail","Debug")]
        [string]$Level = "Info"
    )

    if ($null -eq $Context) {
        $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
        Write-Host $line
        return
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line      = "[{0}] {1}" -f $timestamp, $Message

    $fileLevelName = if ($Context.PSObject.Properties.Name -contains "FileLogLevel" -and $Context.FileLogLevel) {
        $Context.FileLogLevel
    }
    else {
        "Debug"
    }

    $fileLevel = $script:TM1O_LogLevels[$fileLevelName]
    if (-not $fileLevel) { $fileLevel = 3 }

    $msgLevel = $script:TM1O_LogLevels[$Level]
    if (-not $msgLevel) { $msgLevel = 1 }

    $logFile = $Context.LogFile
    if ($logFile -and $fileLevel -ge $msgLevel) {
        try {
            [System.IO.File]::AppendAllText(
                $logFile,
                $line + [System.Environment]::NewLine,
                [System.Text.Encoding]::UTF8
            )
        }
        catch {
            Write-Host "WARNUNG (TM1O.Core): Konnte nicht ins Logfile schreiben: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    $consoleLevelName = if ($Context.PSObject.Properties.Name -contains "ConsoleLogLevel" -and $Context.ConsoleLogLevel) {
        $Context.ConsoleLogLevel
    }
    else {
        "Info"
    }

    $consoleLevel = $script:TM1O_LogLevels[$consoleLevelName]
    if (-not $consoleLevel) { $consoleLevel = 1 }

    if ($consoleLevel -ge $msgLevel) {
        Write-Host $line
    }
}

function Write-TM1OLogColor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Context,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ConsoleColor]$Color = "Green",

        [ValidateSet("Info","Detail","Debug")]
        [string]$Level = "Info"
    )

    if ($null -eq $Context) {
        $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
        Write-Host $line -ForegroundColor $Color
        return
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line      = "[{0}] {1}" -f $timestamp, $Message

    $fileLevelName = if ($Context.PSObject.Properties.Name -contains "FileLogLevel" -and $Context.FileLogLevel) {
        $Context.FileLogLevel
    }
    else {
        "Debug"
    }

    $fileLevel = $script:TM1O_LogLevels[$fileLevelName]
    if (-not $fileLevel) { $fileLevel = 3 }

    $msgLevel = $script:TM1O_LogLevels[$Level]
    if (-not $msgLevel) { $msgLevel = 1 }

    $logFile = $Context.LogFile
    if ($logFile -and $fileLevel -ge $msgLevel) {
        try {
            [System.IO.File]::AppendAllText(
                $logFile,
                $line + [System.Environment]::NewLine,
                [System.Text.Encoding]::UTF8
            )
        }
        catch {
            Write-Host "WARNUNG (TM1O.Core): Konnte nicht ins Logfile schreiben: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    $consoleLevelName = if ($Context.PSObject.Properties.Name -contains "ConsoleLogLevel" -and $Context.ConsoleLogLevel) {
        $Context.ConsoleLogLevel
    }
    else {
        "Info"
    }

    $consoleLevel = $script:TM1O_LogLevels[$consoleLevelName]
    if (-not $consoleLevel) { $consoleLevel = 1 }

    if ($consoleLevel -ge $msgLevel) {
        Write-Host $line -ForegroundColor $Color
    }
}

function Write-TM1ORunSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Context,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$FailedProcess = "",

        [Parameter(Mandatory = $true)]
        [datetime]$StartTime,

        [Parameter(Mandatory = $true)]
        [datetime]$EndTime,

        [Parameter(Mandatory = $true)]
        [string]$RunMode
    )

    $durationSec = [math]::Round(($EndTime - $StartTime).TotalSeconds)

    $summaryLine = "SUMMARY|Status={0};Environment={1};Instance={2};Chain={3};Start={4};End={5};DurationSec={6};FailedProcess={7};Mode={8}" -f `
        $Status,
        $Context.Environment,
        $Context.InstanceName,
        $Context.ChainBaseName,
        $StartTime.ToString("s"),
        $EndTime.ToString("s"),
        $durationSec,
        $FailedProcess,
        $RunMode

    Write-TM1OLog -Context $Context -Message $summaryLine -Level "Info"
}

# ----------------------------------------
# LOG ROTATION & ARCHIV
# ----------------------------------------

function Rotate-TM1OLogs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Context,

        [Parameter(Mandatory = $true)]
        [int]$MaxKeepLogs
    )

    $logsFolder    = $Context.LogsFolder
    $archiveFolder = $Context.ArchiveFolder
    $env           = $Context.Environment
    $inst          = $Context.InstanceName

    if (-not (Test-Path $logsFolder)) {
        return
    }

    if (-not (Test-Path $archiveFolder)) {
        New-Item -ItemType Directory -Path $archiveFolder | Out-Null
    }

    $pattern  = "{0}_{1}_*.log" -f $env, $inst
    $logFiles = Get-ChildItem -Path $logsFolder -Filter $pattern -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending

    if (-not $logFiles -or $logFiles.Count -le $MaxKeepLogs) {
        Write-TM1OLog -Context $Context -Message ("Logrotation: {0} Logdatei(en) fuer {1}/{2}, nichts zu archivieren (MaxKeepLogs={3})." -f ($logFiles.Count), $env, $inst, $MaxKeepLogs) -Level "Detail"
        return
    }

    $toArchive = $logFiles | Select-Object -Skip $MaxKeepLogs

    Write-TM1OLog -Context $Context -Message ("Logrotation: {0} Logdatei(en) gefunden, {1} werden archiviert, {2} bleiben." -f $logFiles.Count, $toArchive.Count, $MaxKeepLogs) -Level "Detail"

    $archiveFile = Join-Path $archiveFolder ("{0}_{1}_archive.csv" -f $env, $inst)
    if (-not (Test-Path $archiveFile)) {
        "RunId,Status,Environment,Instance,Chain,Start,End,DurationSec,FailedProcess,Mode,LogFile" | Out-File -FilePath $archiveFile -Encoding UTF8
    }

    foreach ($file in $toArchive) {
        try {
            $logLines = Get-Content $file.FullName -ErrorAction Stop
        }
        catch {
            Write-Host "WARNUNG (TM1O.Core): Konnte Logdatei '$($file.FullName)' nicht lesen: $($_.Exception.Message)" -ForegroundColor Yellow
            continue
        }

        $summaryLine = $logLines | Where-Object { $_ -like "*SUMMARY|*" } | Select-Object -Last 1

        $runId       = [System.IO.Path]::GetFileNameWithoutExtension($file.Name).Split("_")[-1]
        $status      = "UNKNOWN"
        $chain       = ""
        $start       = ""
        $end         = ""
        $durationSec = ""
        $failedProc  = ""
        $mode        = ""
        $logFileName = $file.Name

        if ($summaryLine) {
            $parts = $summaryLine.Split("|", 2)
            if ($parts.Count -ge 2) {
                $kvPart = $parts[1]

                $fields = @{}
                foreach ($item in $kvPart.Split(";", [System.StringSplitOptions]::RemoveEmptyEntries)) {
                    $kv = $item.Split("=", 2)
                    if ($kv.Count -eq 2) {
                        $key   = $kv[0].Trim()
                        $value = $kv[1].Trim()
                        $fields[$key] = $value
                    }
                }

                if ($fields.ContainsKey("Status"))        { $status      = $fields["Status"] }
                if ($fields.ContainsKey("Environment"))   { $env         = $fields["Environment"] }
                if ($fields.ContainsKey("Instance"))      { $inst        = $fields["Instance"] }
                if ($fields.ContainsKey("Chain"))         { $chain       = $fields["Chain"] }
                if ($fields.ContainsKey("Start"))         { $start       = $fields["Start"] }
                if ($fields.ContainsKey("End"))           { $end         = $fields["End"] }
                if ($fields.ContainsKey("DurationSec"))   { $durationSec = $fields["DurationSec"] }
                if ($fields.ContainsKey("FailedProcess")) { $failedProc  = $fields["FailedProcess"] }
                if ($fields.ContainsKey("Mode"))          { $mode        = $fields["Mode"] }
            }
        }
        else {
            $nameParts = [System.IO.Path]::GetFileNameWithoutExtension($file.Name).Split("_")
            if ($nameParts.Length -ge 4) {
                $env   = $nameParts[0]
                $inst  = $nameParts[1]
                $chain = $nameParts[2]
                $runId = $nameParts[3]
            }
        }

        $csvLine = '{0},{1},{2},{3},{4},{5},{6},{7},{8},{9},{10}' -f `
            $runId,$status,$env,$inst,$chain,$start,$end,$durationSec,$failedProc,$mode,$logFileName

        try {
            [System.IO.File]::AppendAllText(
                $archiveFile,
                $csvLine + [System.Environment]::NewLine,
                [System.Text.Encoding]::UTF8
            )
        }
        catch {
            Write-Host "WARNUNG (TM1O.Core): Konnte nicht in Archivdatei schreiben: $($_.Exception.Message)" -ForegroundColor Yellow
        }

        try {
            Remove-Item $file.FullName -ErrorAction SilentlyContinue
            Write-TM1OLog -Context $Context -Message ("Logrotation: Logdatei '{0}' wurde archiviert und geloescht." -f $file.Name) -Level "Detail"
        }
        catch {
            Write-Host "WARNUNG (TM1O.Core): Konnte Logdatei '$($file.FullName)' nicht loeschen: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# ----------------------------------------
# INTERNE HELPER: TIMEOUT ERKENNEN
# ----------------------------------------

function _TM1O_IsTimeoutException {
    param(
        [Parameter(Mandatory = $true)]
        $ErrorRecord
    )

    try {
        $msg = ""
        if ($ErrorRecord -and $ErrorRecord.Exception) {
            $msg = [string]$ErrorRecord.Exception.Message
        }
        elseif ($ErrorRecord) {
            $msg = [string]$ErrorRecord.ToString()
        }

        if ([string]::IsNullOrWhiteSpace($msg)) { return $false }

        if ($msg -match "timed out") { return $true }
        if ($msg -match "Zeit.*ueberschritten") { return $true }
        if ($msg -match "Timeout") { return $true }

        return $false
    }
    catch {
        return $false
    }
}

# ----------------------------------------
# GENERISCHER RETRY-WRAPPER
# ----------------------------------------

function Invoke-TM1ORetry {
    <#
    .SYNOPSIS
        Fuehrt eine Aktion mit Retry-Logik aus (z.B. REST-Call).

    .PARAMETER RetrySettings
        Objekt mit MaxRetries, RetryDelaySec (Ergebnis von Get-TM1ORetrySettings).

    .PARAMETER Context
        Logkontext-Objekt (optional, fuer Logging).

    .PARAMETER Action
        Scriptblock, der die eigentliche Aktion ausfuehrt. Wird bei Erfolg
        nicht erneut aufgerufen.

    .PARAMETER ActionDescription
        Beschreibung fuer's Logging.

    .PARAMETER NoRetryOnTimeout
        Wenn gesetzt: Timeout-Fehler fuehren sofort zum Abbruch (kein Retry).

    .PARAMETER NoRetryOnAnyError
        Wenn gesetzt: Jeder Fehler fuehrt sofort zum Abbruch (kein Retry).
        Default: false (keine Verhaltensaenderung).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$RetrySettings,

        [Parameter(Mandatory = $false)]
        [object]$Context,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action,

        [Parameter(Mandatory = $false)]
        [string]$ActionDescription = "Aktion",

        [Parameter(Mandatory = $false)]
        [switch]$NoRetryOnTimeout,

        [Parameter(Mandatory = $false)]
        [switch]$NoRetryOnAnyError
    )

    $maxRetries    = $RetrySettings.MaxRetries
    $retryDelay    = $RetrySettings.RetryDelaySec

    $result        = $null
    $callSucceeded = $false
    $errorObj      = $null

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {

        if ($Context) {
            Write-TM1OLog -Context $Context -Message ("{0}: Versuch {1} von {2}" -f $ActionDescription, $attempt, $maxRetries) -Level "Detail"
        }
        else {
            Write-Host ("{0}: Versuch {1} von {2}" -f $ActionDescription, $attempt, $maxRetries)
        }

        try {
            $result        = & $Action
            $callSucceeded = $true
            break
        }
        catch {
            $errorObj = $_

            $isTimeout = _TM1O_IsTimeoutException -ErrorRecord $errorObj

            if ($Context) {
                Write-TM1OLog -Context $Context -Message ("Fehler in {0}, Versuch {1}: {2}" -f $ActionDescription, $attempt, $errorObj.Exception.Message) -Level "Detail"
                if ($isTimeout) {
                    Write-TM1OLog -Context $Context -Message ("Hinweis: Fehler wurde als Timeout erkannt (NoRetryOnTimeout={0})." -f $NoRetryOnTimeout.IsPresent) -Level "Detail"
                }
            }
            else {
                Write-Host ("Fehler in {0}, Versuch {1}: {2}" -f $ActionDescription, $attempt, $errorObj.Exception.Message)
            }

            if ($NoRetryOnAnyError) {
                if ($Context) {
                    Write-TM1OLog -Context $Context -Message ("NoRetryOnAnyError ist aktiv. Abbruch ohne weitere Retries.") -Level "Detail"
                }
                throw $errorObj
            }

            if ($NoRetryOnTimeout -and $isTimeout) {
                if ($Context) {
                    Write-TM1OLog -Context $Context -Message ("NoRetryOnTimeout ist aktiv. Abbruch ohne weitere Retries.") -Level "Detail"
                }
                throw $errorObj
            }

            if ($attempt -lt $maxRetries) {
                if ($Context) {
                    Write-TM1OLog -Context $Context -Message ("Warte {0} Sekunden und versuche es erneut..." -f $retryDelay) -Level "Detail"
                }
                Start-Sleep -Seconds $retryDelay
            }
        }
    }

    if (-not $callSucceeded -and $errorObj) {
        throw $errorObj
    }

    return $result
}

# ----------------------------------------
# Exporte
# ----------------------------------------

Export-ModuleMember -Function `
    Get-TM1OConfig, `
    Get-TM1OEnvironmentConfig, `
    Get-TM1OInstanceConfig, `
    Get-TM1ORetrySettings, `
    Get-TM1OMaxKeepLogs, `
    New-TM1OLogContext, `
    Write-TM1OLog, `
    Write-TM1OLogColor, `
    Write-TM1ORunSummary, `
    Rotate-TM1OLogs, `
    Invoke-TM1ORetry