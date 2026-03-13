<#
================================================================================
  TM1 Orchestrator Framework - Runner Script: Run_TM1_Chore.ps1 - Version 0.2 (2026-03-13)
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

   powershell -ExecutionPolicy Bypass -File "runners\Run_TM1_Chore.ps1" -Env "DEV" -Inst "KST_2026" -ChoreName "J_20_Gesamtprozess" -IgnoreDisabled -ConsoleLogLevel "Detail"
  
 -------------------------------------------------------------------------------
 Parametrisierung:
 -------------------------------------------------------------------------------

 Parameter:

   -Env   Environment (z.B. DEV, TEST, PROD)
   -Inst  TM1 Instanz (z.B. KST_2026)

 Chore:

   -ChoreName "J_20_Gesamtprozess" -IgnoreDisabled

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

 Der Parameter -IgnoreDisabled führt den Chore auch dann aus, wenn er in TM1 als "disabled" markiert ist. 
 Normalerweise würde der Runner in diesem Fall die Ausführung verweigern, um unbeabsichtigte Starts zu verhindern. 
 Mit -IgnoreDisabled wird diese Sicherheitsprüfung umgangen.

 Erfolgsstates: FINISHED, FINISHED_UNOBSERVED
#>


param(
    [Alias("Environment")]
    [string]$Env  = "DEV",

    [Alias("InstanceName","Instance")]
    [string]$Inst = "KST_2026",

    [string]$ChoreName,

    [switch]$ValidateOnly,
    [switch]$DryRun,
    [switch]$IgnoreDisabled,
    [switch]$Activate,
    [switch]$Deactivate,
    [switch]$ListChores,
    [switch]$ChoreInfo,

    [ValidateSet("Info","Detail","Debug")]
    [string]$ConsoleLogLevel = "Info",

    [ValidateSet("Info","Detail","Debug")]
    [string]$FileLogLevel    = "Detail"
)

# ===========================
# EXIT CODES
# ===========================

$EXIT_SUCCESS             = 0
$EXIT_CONFIG_ERROR        = 2
$EXIT_HEALTHCHECK_FAILED  = 3
$EXIT_VALIDATION_FAILED   = 4
$EXIT_CHORE_FAILED        = 6

# ===========================
# SECURE FILE NAMES FUNCTION
# ===========================

function ConvertTo-SafeFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $safe = -join ($Name.ToCharArray() | ForEach-Object {
        if ($invalid -contains $_) { '_' } else { $_ }
    })
    return $safe
}

# ===========================
# BASIS-SETUP UND CORE-MODUL LADEN
# ===========================

if ($Env)  { $Env  = $Env.Trim().ToUpper() }
if ($Inst) { $Inst = $Inst.Trim().ToUpper() }
if ($ChoreName) { $ChoreName = $ChoreName.Trim() }

if ([string]::IsNullOrWhiteSpace($Env) -or [string]::IsNullOrWhiteSpace($Inst)) {
    Write-Host "Error: parameters 'Env' and 'Inst' must not be empty." -ForegroundColor Red
    exit $EXIT_CONFIG_ERROR
}

$Environment  = $Env
$InstanceName = $Inst

$scriptRoot          = $PSScriptRoot
$rootDir             = Split-Path -Parent $scriptRoot
$frameworkModulePath = Join-Path $rootDir "modules\TM1Orchestrator.psm1"

if (-not (Test-Path $frameworkModulePath)) {
    Write-Host "ERROR: TM1 Orchestrator framework module not found: $frameworkModulePath" -ForegroundColor Red
    exit $EXIT_CONFIG_ERROR
}

try {
    Import-Module $frameworkModulePath -Force -DisableNameChecking
}
catch {
    Write-Host "ERROR: cannot load TM1 Orchestrator framework module: $($_.Exception.Message)" -ForegroundColor Red
    exit $EXIT_CONFIG_ERROR
}

$script:LogContext    = $null
$script:RetrySettings = $null
$script:MaxKeepLogs   = $null
$script:RunMode       = "Execute"

# ===========================
# HILFSFUNKTIONEN FUER LOGGING
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

# ===========================
# SAFE INVOKER
# ===========================

function Invoke-TM1OSafeCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName,

        [Parameter(Mandatory = $true)]
        [hashtable]$Args,

        $LogContext
    )

    $cmd = Get-Command -Name $CommandName -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "REST function not found: $CommandName" }

    $safe = @{}
    foreach ($k in $Args.Keys) {
        if (-not $cmd.Parameters.ContainsKey($k)) { continue }

        $paramMeta = $cmd.Parameters[$k]
        $paramType = $paramMeta.ParameterType
        $val = $Args[$k]

        if ($paramType -eq [System.Management.Automation.SwitchParameter]) {
            if ($val -is [bool]) {
                if ($val) { $safe[$k] = $true }
            }
            elseif ($val -is [System.Management.Automation.SwitchParameter]) {
                if ($val.IsPresent) { $safe[$k] = $true }
            }
            else {
                if ($LogContext) {
                    Write-TM1OLog -Context $LogContext -Message ("SafeInvoke: switch param '{0}' skipped (incompatible value)." -f $k) -Level "Debug"
                }
            }
            continue
        }

        $safe[$k] = $val
    }

    if ($LogContext) {
        Write-TM1OLog -Context $LogContext -Message ("SafeInvoke: call {0} with params: {1}" -f $CommandName, (($safe.Keys | Sort-Object) -join ",")) -Level "Debug"
    }

    return & $CommandName @safe
}

# ===========================
# CONFIG AUS JSON LADEN
# ===========================

$ConfigPath = Join-Path $rootDir "config\tm1o.json"

try { $configJson = Get-TM1OConfig -ConfigPath $ConfigPath }
catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit $EXIT_CONFIG_ERROR }

try { $envConfig = Get-TM1OEnvironmentConfig -Config $configJson -Env $Environment }
catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit $EXIT_CONFIG_ERROR }

try { $instance = Get-TM1OInstanceConfig -Config $configJson -Env $Environment -Inst $InstanceName }
catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit $EXIT_CONFIG_ERROR }

$TM1RestBase  = $instance.TM1RestBase
$CAMNamespace = $envConfig.CAMNamespace
$ApiKey       = $envConfig.ApiKey

if ([string]::IsNullOrWhiteSpace($TM1RestBase) -or
    [string]::IsNullOrWhiteSpace($CAMNamespace) -or
    [string]::IsNullOrWhiteSpace($ApiKey)) {
    Write-Host "Environment '$Environment' / instance '$InstanceName' incomplete (TM1RestBase / CAMNamespace / ApiKey)." -ForegroundColor Red
    exit $EXIT_CONFIG_ERROR
}

try {
    $script:RetrySettings = Get-TM1ORetrySettings -Config $configJson
    $script:MaxKeepLogs   = Get-TM1OMaxKeepLogs   -Config $configJson
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit $EXIT_CONFIG_ERROR
}

# ===========================
# RUN MODE FESTLEGEN
# ===========================

if ($ListChores) {
    $script:RunMode = "ListChores"
}
elseif ($ChoreInfo) {
    $script:RunMode = "ChoreInfo"
}
else {
    if ($Activate -and $Deactivate) {
        Write-Host "Error: -Activate and -Deactivate cannot be used together." -ForegroundColor Red
        exit $EXIT_CONFIG_ERROR
    }

    if ($Activate) { $script:RunMode = "Activate" }
    elseif ($Deactivate) { $script:RunMode = "Deactivate" }
    elseif ($ValidateOnly) { $script:RunMode = "ValidateOnly" }
    elseif ($DryRun) { $script:RunMode = "DryRun" }
    else { $script:RunMode = "Execute" }
}

# ===========================
# CHAIN METADATEN FUER LOGGING
# ===========================

if ($ListChores) {
    $chainFileName = "CHORE_LIST.json"
    $chainPath     = "<ChoreList>"
}
elseif ($ChoreInfo) {
    $chainFileName = "CHORE_INFO_{0}.json" -f (ConvertTo-SafeFileName -Name $ChoreName)
    $chainPath     = "<ChoreInfo: $ChoreName>"
}
else {
    $chainFileName = "CHORE_{0}.json" -f (ConvertTo-SafeFileName -Name $ChoreName)
    $chainPath     = "<SingleChore: $ChoreName>"
}

# ===========================
# LOGGING KONTEXT INITIALISIEREN
# ===========================

try {
    $logContext = New-TM1OLogContext -BasePath $rootDir `
                                    -Env $Environment `
                                    -Inst $InstanceName `
                                    -ChainFileName $chainFileName `
                                    -ConsoleLogLevel $ConsoleLogLevel `
                                    -FileLogLevel $FileLogLevel
}
catch {
    Write-Host "ERROR: cannot create log context: $($_.Exception.Message)" -ForegroundColor Red
    exit $EXIT_CONFIG_ERROR
}

$script:LogContext = $logContext
$logFilePath = $logContext.LogFile

Log "------------------------------------------------------------"
Log "TM1 REST Chore-Runner started."
Log "Environment : $Environment"
Log "Instance    : $InstanceName"
Log "TM1RestBase : $TM1RestBase"
Log "Config      : $ConfigPath"
if ($ListChores) { Log "Chore       : <ListChores mode>" }
elseif ($ChoreInfo) { Log "Chore       : <ChoreInfo mode> ($ChoreName)" }
else { Log "Chore       : $ChoreName" }
Log "ChainMeta   : $chainPath"
Log "Logfile     : $logFilePath"
Log ("ConsoleLogLevel : {0}" -f $ConsoleLogLevel) "Detail"
Log ("FileLogLevel    : {0}" -f $FileLogLevel)    "Detail"
Log ("RetrySettings: MaxRetries={0}, RetryDelaySec={1}, TimeoutSec={2}, MaxKeepLogs={3}" -f `
    $script:RetrySettings.MaxRetries,
    $script:RetrySettings.RetryDelaySec,
    $script:RetrySettings.TimeoutSec,
    $script:MaxKeepLogs) "Detail"
Log ("RunMode     : {0}" -f $script:RunMode)
Log "------------------------------------------------------------"

# ===========================
# HTTP-HEADER
# ===========================

$Headers = @{
    "Authorization" = "CAMNamespace $ApiKey"
    "CAMNamespace"  = $CAMNamespace
    "Content-Type"  = "application/json"
    "Accept"        = "application/json"
}

# ===========================
# HEALTH CHECK
# ===========================

function Test-TM1Connection {
    param([int]$TimeoutSec = 30)

    Log "HealthCheck: start REST healthcheck..."
    return Test-TM1RestConnection -BaseUrl $TM1RestBase `
                                  -Headers $Headers `
                                  -TimeoutSec $TimeoutSec `
                                  -LogContext $script:LogContext
}

# ===========================
# CHORE-EXISTENZ / INFO
# ===========================

function Get-TM1ChoreInfo {
    param([Parameter(Mandatory = $true)][string]$ChoreName)

    Log ("Reading chore info for '{0}'..." -f $ChoreName) "Detail"

    return Get-TM1RestChoreInfo -BaseUrl $TM1RestBase `
                                -Headers $Headers `
                                -ChoreName $ChoreName `
                                -TimeoutSec 60 `
                                -LogContext $script:LogContext
}

function Test-TM1ChoreExists {
    param([Parameter(Mandatory = $true)][string]$ChoreName)

    Log ("ValidateOnly: checking existence for chore '{0}'..." -f $ChoreName)

    $info = Get-TM1ChoreInfo -ChoreName $ChoreName
    if (-not $info) { Log ("Chore '{0}' info is null." -f $ChoreName); return $false }
    if ($info.Exists -ne $true) { Log ("Chore '{0}' does not exist." -f $ChoreName); return $false }

    Log ("Chore '{0}' exists. Enabled={1}, NextRun={2}" -f $info.Name, $info.Enabled, $info.NextRun) "Detail"
    return $true
}

# ===========================
# CHORE AUSFUEHREN
# ===========================

function Invoke-TM1Chore {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChoreName,

        [Parameter(Mandatory = $false)]
        [string[]]$ProcessNames = $null
    )

    Log ""
    Log ("Starting TM1 chore '{0}' in '{1}' / '{2}'..." -f $ChoreName, $Environment, $InstanceName)

    return Invoke-TM1RestChoreExecute -BaseUrl $TM1RestBase `
                                      -Headers $Headers `
                                      -ChoreName $ChoreName `
                                      -RetrySettings $script:RetrySettings `
                                      -TimeoutSec 60 `
                                      -ProcessNames $ProcessNames `
                                      -WaitForCompletion `
                                      -MaxWaitSec 7200 `
                                      -PollSec 10 `
                                      -NoMatchConfirmCount 2 `
                                      -StartDetectTimeoutSec 10 `
                                      -StartDetectPollSec 1 `
                                      -GracePeriodSec 3 `
                                      -NoMatchConfirmPollSec 1 `
                                      -LogContext $script:LogContext
}

# ===========================
# CHORES LISTEN
# ===========================

function Get-TM1ChoreList {
    Log "Reading list of all chores..." "Detail"
    return Get-TM1RestChores -BaseUrl $TM1RestBase `
                             -Headers $Headers `
                             -TimeoutSec 60 `
                             -LogContext $script:LogContext
}

# ===========================
# FIX2: Robust result parsing (hashtable or object)
# ===========================

function Get-ResultStateSuccess {
    param([Parameter(Mandatory=$true)]$Result)

    $state = $null
    $success = $false
    $message = $null

    if ($Result -is [hashtable]) {
        if ($Result.ContainsKey("State"))   { $state = [string]$Result["State"] }
        if ($Result.ContainsKey("Success")) { $success = [bool]$Result["Success"] }
        if ($Result.ContainsKey("Message")) { $message = [string]$Result["Message"] }
    }
    elseif ($null -ne $Result) {
        if ($Result.PSObject.Properties.Name -contains "State")   { $state = [string]$Result.State }
        if ($Result.PSObject.Properties.Name -contains "Success") { $success = [bool]$Result.Success }
        if ($Result.PSObject.Properties.Name -contains "Message") { $message = [string]$Result.Message }
    }

    if ($state) { $state = $state.Trim().ToUpperInvariant() }

    return [PSCustomObject]@{
        State   = $state
        Success = $success
        Message = $message
    }
}

# ===========================
# HAUPTLOGIK
# ===========================

$overallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$startTime = Get-Date
$runStatus = "SUCCESS"
$failedChore = ""

Log ("Overall start: {0}" -f $startTime)

# 1) HEALTH CHECK
if (-not (Test-TM1Connection)) {
    $overallStopwatch.Stop()
    $endTime = Get-Date
    $runStatus = "FAILED"
    $failedChore = "HealthCheck"

    LogColor "HealthCheck failed. No chore actions will be started." -Color Red

    Write-TM1ORunSummary -Context $script:LogContext `
                         -Status $runStatus `
                         -FailedProcess $failedChore `
                         -StartTime $startTime `
                         -EndTime $endTime `
                         -RunMode $script:RunMode

    Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs
    Log "------------------------------------------------------------"
    exit $EXIT_HEALTHCHECK_FAILED
}

# 2) LISTCHORES MODE
if ($script:RunMode -eq "ListChores") {
    Log "ListChores: no execution, printing chore list."
    $chores = Get-TM1ChoreList

    $overallStopwatch.Stop()
    $endTime = Get-Date

    if (-not $chores -or $chores.Count -eq 0) {
        $runStatus = "FAILED"
        $failedChore = "ListChores"
        LogColor "ListChores: no chores found or list not readable." -Color Red
    }
    else {
        $runStatus = "SUCCESS"
        $failedChore = ""
        Log "Chore list:"
        foreach ($c in $chores) {
            Log ("  Name={0} | Enabled={1} | NextRun={2}" -f $c.Name, $c.Enabled, $c.NextRun)
        }
    }

    Write-TM1ORunSummary -Context $script:LogContext `
                         -Status $runStatus `
                         -FailedProcess $failedChore `
                         -StartTime $startTime `
                         -EndTime $endTime `
                         -RunMode $script:RunMode

    Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs
    Log "------------------------------------------------------------"

    if ($runStatus -eq "SUCCESS") { exit $EXIT_SUCCESS } else { exit $EXIT_CHORE_FAILED }
}

# Ab hier: Modi, die eine konkrete Chore benoetigen
if ([string]::IsNullOrWhiteSpace($ChoreName)) {
    LogColor "Error: parameter ChoreName must not be empty for this mode." -Color Red
    $overallStopwatch.Stop()
    $endTime = Get-Date

    $runStatus = "FAILED"
    $failedChore = "Config"

    Write-TM1ORunSummary -Context $script:LogContext `
                         -Status $runStatus `
                         -FailedProcess $failedChore `
                         -StartTime $startTime `
                         -EndTime $endTime `
                         -RunMode $script:RunMode

    Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs
    Log "------------------------------------------------------------"
    exit $EXIT_CONFIG_ERROR
}

# 3) CHOREINFO MODE
if ($script:RunMode -eq "ChoreInfo") {
    Log "ChoreInfo: no execution, printing chore details."
    $info = Get-TM1ChoreInfo -ChoreName $ChoreName

    $overallStopwatch.Stop()
    $endTime = Get-Date

    if (-not $info -or $info.Exists -ne $true) {
        $runStatus = "FAILED"
        $failedChore = $ChoreName
        LogColor "ChoreInfo: chore does not exist or not readable." -Color Red

        Write-TM1ORunSummary -Context $script:LogContext `
                             -Status $runStatus `
                             -FailedProcess $failedChore `
                             -StartTime $startTime `
                             -EndTime $endTime `
                             -RunMode $script:RunMode

        Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs
        Log "------------------------------------------------------------"
        exit $EXIT_VALIDATION_FAILED
    }

    Log "Chore details:"
    Log ("  Name    : {0}" -f $info.Name)
    Log ("  Enabled : {0}" -f $info.Enabled)
    Log ("  NextRun : {0}" -f $info.NextRun)
    Log ("  LastRun : {0}" -f $info.LastRun)

    if ($info.Processes -and $info.Processes.Count -gt 0) {
        Log "  Processes:"
        $idx = 1
        foreach ($p in $info.Processes) {
            Log ("    {0}. {1}" -f $idx, $p)
            $idx++
        }
    }

    $runStatus = "SUCCESS"
    $failedChore = ""

    Write-TM1ORunSummary -Context $script:LogContext `
                         -Status $runStatus `
                         -FailedProcess $failedChore `
                         -StartTime $startTime `
                         -EndTime $endTime `
                         -RunMode $script:RunMode

    Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs
    Log "------------------------------------------------------------"
    exit $EXIT_SUCCESS
}

# 4) ACTIVATE / DEACTIVATE MODE
if ($script:RunMode -eq "Activate" -or $script:RunMode -eq "Deactivate") {
    Log ("{0}: no execution, only changing status." -f $script:RunMode)

    $info = Get-TM1ChoreInfo -ChoreName $ChoreName
    if (-not $info -or -not $info.Exists) {
        $overallStopwatch.Stop()
        $endTime = Get-Date
        $runStatus = "FAILED"
        $failedChore = $ChoreName

        LogColor ("{0}: chore '{1}' does not exist. Cannot change status." -f $script:RunMode, $ChoreName) -Color Red

        Write-TM1ORunSummary -Context $script:LogContext `
                             -Status $runStatus `
                             -FailedProcess $failedChore `
                             -StartTime $startTime `
                             -EndTime $endTime `
                             -RunMode $script:RunMode

        Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs
        Log "------------------------------------------------------------"
        exit $EXIT_VALIDATION_FAILED
    }

    $args = @{
        BaseUrl       = $TM1RestBase
        Headers       = $Headers
        ChoreName     = $ChoreName
        RetrySettings = $script:RetrySettings
        LogContext    = $script:LogContext
    }

    if ($script:RunMode -eq "Activate") {
        $result = Invoke-TM1OSafeCommand -CommandName "Invoke-TM1RestChoreActivate" -Args $args -LogContext $script:LogContext
    }
    else {
        $result = Invoke-TM1OSafeCommand -CommandName "Invoke-TM1RestChoreDeactivate" -Args $args -LogContext $script:LogContext
    }

    $overallStopwatch.Stop()
    $endTime = Get-Date

    $parsed = Get-ResultStateSuccess -Result $result
    if (-not $parsed.Success) {
        $runStatus = "FAILED"
        $failedChore = $ChoreName
        LogColor ("{0}: failed changing chore '{1}'. Message: {2}" -f $script:RunMode, $ChoreName, $parsed.Message) -Color Red

        Write-TM1ORunSummary -Context $script:LogContext `
                             -Status $runStatus `
                             -FailedProcess $failedChore `
                             -StartTime $startTime `
                             -EndTime $endTime `
                             -RunMode $script:RunMode

        Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs
        Log "------------------------------------------------------------"
        exit $EXIT_CHORE_FAILED
    }

    $runStatus = "SUCCESS"
    $failedChore = ""
    Log ("{0}: chore '{1}' status changed successfully." -f $script:RunMode, $ChoreName)

    Write-TM1ORunSummary -Context $script:LogContext `
                         -Status $runStatus `
                         -FailedProcess $failedChore `
                         -StartTime $startTime `
                         -EndTime $endTime `
                         -RunMode $script:RunMode

    Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs
    Log "------------------------------------------------------------"
    exit $EXIT_SUCCESS
}

# 5) VALIDATEONLY MODE
if ($ValidateOnly) {
    Log "ValidateOnly: no execution, only validate existence/status."

    $exists = Test-TM1ChoreExists -ChoreName $ChoreName

    $overallStopwatch.Stop()
    $endTime = Get-Date

    if (-not $exists) {
        $runStatus = "FAILED"
        $failedChore = $ChoreName
        LogColor "ValidateOnly: chore does not exist or not readable." -Color Red

        Write-TM1ORunSummary -Context $script:LogContext `
                             -Status $runStatus `
                             -FailedProcess $failedChore `
                             -StartTime $startTime `
                             -EndTime $endTime `
                             -RunMode $script:RunMode

        Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs
        Log "------------------------------------------------------------"
        exit $EXIT_VALIDATION_FAILED
    }

    $info = Get-TM1ChoreInfo -ChoreName $ChoreName
    if ($info.Enabled -ne $true -and -not $IgnoreDisabled) {
        $runStatus = "FAILED"
        $failedChore = $ChoreName
        LogColor "ValidateOnly: chore exists but is disabled and IgnoreDisabled is not set." -Color Red

        Write-TM1ORunSummary -Context $script:LogContext `
                             -Status $runStatus `
                             -FailedProcess $failedChore `
                             -StartTime $startTime `
                             -EndTime $endTime `
                             -RunMode $script:RunMode

        Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs
        Log "------------------------------------------------------------"
        exit $EXIT_VALIDATION_FAILED
    }

    $runStatus = "SUCCESS"
    $failedChore = ""

    Log ("ValidateOnly: chore '{0}' present. Enabled={1}, NextRun={2}. Nothing executed." -f $info.Name, $info.Enabled, $info.NextRun)

    Write-TM1ORunSummary -Context $script:LogContext `
                         -Status $runStatus `
                         -FailedProcess $failedChore `
                         -StartTime $startTime `
                         -EndTime $endTime `
                         -RunMode $script:RunMode

    Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs
    Log "------------------------------------------------------------"
    exit $EXIT_SUCCESS
}

# 6) DRYRUN MODE
if ($DryRun) {
    Log "DryRun: no execution, only logging."
    Log ("DryRun: chore '{0}' would be executed in '{1}' / '{2}'. IgnoreDisabled={3}." -f `
        $ChoreName, $Environment, $InstanceName, $IgnoreDisabled.IsPresent)

    $overallStopwatch.Stop()
    $endTime = Get-Date
    $runStatus = "SUCCESS"
    $failedChore = ""

    Write-TM1ORunSummary -Context $script:LogContext `
                         -Status $runStatus `
                         -FailedProcess $failedChore `
                         -StartTime $startTime `
                         -EndTime $endTime `
                         -RunMode $script:RunMode

    Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs
    Log "------------------------------------------------------------"
    exit $EXIT_SUCCESS
}

# 7) NORMAL CHORE EXECUTION
Log ("Starting chore execution in '{0}' / '{1}'..." -f $Environment, $InstanceName)
Log "--------------------------------------"
Log ("Chore: {0}" -f $ChoreName)

$choreInfoObj = Get-TM1ChoreInfo -ChoreName $ChoreName
$procNamesForGuard = $null

if ($choreInfoObj -and $choreInfoObj.Processes -and $choreInfoObj.Processes.Count -gt 0) {
    $procNamesForGuard = @($choreInfoObj.Processes)
}

if (-not $choreInfoObj -or $choreInfoObj.Exists -ne $true) {
    $overallStopwatch.Stop()
    $endTime = Get-Date
    $runStatus = "FAILED"
    $failedChore = $ChoreName

    Log ""
    LogColor ("Chore '{0}' not found or not readable. Abort." -f $ChoreName) -Color Red

    Write-TM1ORunSummary -Context $script:LogContext `
                         -Status $runStatus `
                         -FailedProcess $failedChore `
                         -StartTime $startTime `
                         -EndTime $endTime `
                         -RunMode $script:RunMode

    Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs
    Log "------------------------------------------------------------"
    exit $EXIT_CHORE_FAILED
}

Log ("Chore status before execution: Enabled={0}, NextRun={1}, LastRun={2}" -f `
    $choreInfoObj.Enabled, $choreInfoObj.NextRun, $choreInfoObj.LastRun) "Detail"

if ($choreInfoObj.Enabled -ne $true -and -not $IgnoreDisabled) {
    $overallStopwatch.Stop()
    $endTime = Get-Date
    $runStatus = "FAILED"
    $failedChore = $ChoreName

    Log ""
    LogColor ("Chore '{0}' is disabled and IgnoreDisabled is not set. Not starting." -f $ChoreName) -Color Red

    Write-TM1ORunSummary -Context $script:LogContext `
                         -Status $runStatus `
                         -FailedProcess $failedChore `
                         -StartTime $startTime `
                         -EndTime $endTime `
                         -RunMode $script:RunMode

    Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs
    Log "------------------------------------------------------------"
    exit $EXIT_CHORE_FAILED
}

$result = Invoke-TM1Chore -ChoreName $ChoreName -ProcessNames $procNamesForGuard

# Fix2 parsing
$parsed = Get-ResultStateSuccess -Result $result
$state = $parsed.State
$success = $parsed.Success
$msg = $parsed.Message

$okStates = @("FINISHED","FINISHED_UNOBSERVED")

if (-not $success -or [string]::IsNullOrWhiteSpace($state) -or ($okStates -notcontains $state)) {
    $overallStopwatch.Stop()
    $endTime = Get-Date
    $runStatus = "FAILED"
    $failedChore = $ChoreName

    Log ""
    LogColor ("Chore '{0}' did NOT finish successfully." -f $ChoreName) -Color Red

    if ($state) { LogColor ("State: {0}" -f $state) -Color Red }
    if ($msg)   { LogColor ("Message: {0}" -f $msg) -Color Red }

    Log ("Overall end   : {0}" -f $endTime)
    Log ("Overall dur   : {0} seconds" -f ($endTime - $startTime).TotalSeconds)

    Write-TM1ORunSummary -Context $script:LogContext `
                         -Status $runStatus `
                         -FailedProcess $failedChore `
                         -StartTime $startTime `
                         -EndTime $endTime `
                         -RunMode $script:RunMode

    Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs
    Log "------------------------------------------------------------"
    exit $EXIT_CHORE_FAILED
}

$overallStopwatch.Stop()
$endTime = Get-Date

Log ""
LogColor ("Chore '{0}' finished successfully." -f $ChoreName) -Color Green
Log ("Overall end   : {0}" -f $endTime)
Log ("Overall dur   : {0} seconds" -f ($endTime - $startTime).TotalSeconds)

$runStatus = "SUCCESS"
$failedChore = ""

Write-TM1ORunSummary -Context $script:LogContext `
                     -Status $runStatus `
                     -FailedProcess $failedChore `
                     -StartTime $startTime `
                     -EndTime $endTime `
                     -RunMode $script:RunMode

Rotate-TM1OLogs -Context $script:LogContext -MaxKeepLogs $script:MaxKeepLogs
Log "------------------------------------------------------------"

exit $EXIT_SUCCESS