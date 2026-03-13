<#
================================================================================
  TM1 Orchestrator Framework - Module: TM1O.REST.psm1 - Version 0.2 (2026-03-13)
================================================================================

 Bestandteil des TM1 Orchestrator Frameworks (TM1O).

 Dieses Modul befindet sich im Verzeichnis:

   TM1Orchestrator\modules\

 und stellt Funktionen fuer REST-Kommunikation mit IBM Planning Analytics /
 TM1 Servern bereit.

 Dieses Modul wird typischerweise geladen von:

   runners\Run_TM1_Process.ps1
   runners\Run_TM1_Query.ps1
   runners\Run_TM1_Chore.ps1
   tm1o.ps1 (CLI Dispatcher)

 -------------------------------------------------------------------------------
 Zweck dieses Moduls
 -------------------------------------------------------------------------------

   TM1O.REST.psm1 kapselt alle REST-Aufrufe gegen die TM1 / Planning Analytics
   REST API.

   Dazu gehoeren insbesondere:

     - Aufbau der REST-Verbindung
     - Authentifizierung
     - Ausfuehrung von TM1 Prozessen
     - Ausfuehrung von Chores
     - Abfragen von Cube-Daten
     - Statusabfragen von Threads / Prozessen
     - Vereinheitlichte Rueckgabeobjekte fuer Runner

 -------------------------------------------------------------------------------
 Frameworkstruktur (relevant fuer dieses Modul)
 -------------------------------------------------------------------------------

   TM1Orchestrator\
      config\        -> tm1o.json (Framework-Konfiguration)
      modules\       -> TM1O.Core.psm1, TM1O.REST.psm1, TM1O.Domain.psm1
      runners\       -> Runner-Scripts
      processchains\ -> Definition der ProcessChains
      logs\          -> Logdateien

 Dieses Modul nutzt:

   modules\TM1O.Core.psm1

 fuer:

     - Logging
     - Konfigurationszugriff
     - Standardisierte Rueckgabeobjekte
     - Fehlerbehandlung

 -------------------------------------------------------------------------------
 Wichtige Designprinzipien
 -------------------------------------------------------------------------------

   - REST-Aufrufe sind zentral in diesem Modul gekapselt
   - Runner greifen nicht direkt auf die TM1 REST API zu
   - Rueckgaben erfolgen konsistent als PSCustomObject
   - Fehler werden zentral abgefangen und an die Runner weitergegeben

 -------------------------------------------------------------------------------
 Hinweis
 -------------------------------------------------------------------------------

   Dieses Modul ist kein eigenstaendig ausfuehrbares Script.

   Es wird ausschliesslich ueber Import-Module von Runner-Scripts oder
   vom CLI Dispatcher (tm1o.ps1) geladen.

#>

# ----------------------------------------
# TM1O.Core importieren (gleicher Ordner)
# ----------------------------------------

$coreModulePath = Join-Path $PSScriptRoot "TM1O.Core.psm1"

if (-not (Get-Module -Name TM1O.Core -ErrorAction SilentlyContinue)) {
    if (Test-Path $coreModulePath) {
        Import-Module $coreModulePath -DisableNameChecking -Force
    }
    else {
        throw "TM1O.Core module not found: $coreModulePath"
    }
}

# ----------------------------------------
# Interne Logging-Helfer
# ----------------------------------------

function _Write-RestLog {
    param(
        [object]$Context,
        [AllowEmptyString()][string]$Message,
        [ValidateSet("Info","Detail","Debug")]
        [string]$Level = "Debug"
    )

    if ($Context) {
        Write-TM1OLog -Context $Context -Message $Message -Level $Level
    }
    else {
        $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
        Write-Host $line
    }
}

function _Write-RestLogColor {
    param(
        [object]$Context,
        [AllowEmptyString()][string]$Message,
        [ConsoleColor]$Color = "Green",
        [ValidateSet("Info","Detail","Debug")]
        [string]$Level = "Debug"
    )

    if ($Context) {
        Write-TM1OLogColor -Context $Context -Message $Message -Color $Color -Level $Level
    }
    else {
        $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
        Write-Host $line -ForegroundColor $Color
    }
}

# ----------------------------------------
# 0) Generische Wrapper: GET / POST / DELETE
# ----------------------------------------

function Invoke-TM1RestGet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $false)]
        [object]$RetrySettings,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSec,

        [Parameter(Mandatory = $false)]
        [object]$LogContext
    )

    $maxRetries = if ($RetrySettings -and $RetrySettings.MaxRetries) { [int]$RetrySettings.MaxRetries } else { 1 }
    $retryDelay = if ($RetrySettings -and $RetrySettings.RetryDelaySec) { [int]$RetrySettings.RetryDelaySec } else { 0 }

    $effectiveTimeout = if ($RetrySettings -and $RetrySettings.TimeoutSec) { [int]$RetrySettings.TimeoutSec } else { 600 }
    if ($PSBoundParameters.ContainsKey("TimeoutSec") -and $TimeoutSec -gt 0) { $effectiveTimeout = $TimeoutSec }

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Invoke-TM1RestGet: Path must not be empty."
    }

    _Write-RestLog -Context $LogContext -Message ("Invoke-TM1RestGet (raw): BaseUrl='{0}', Path='{1}'" -f $BaseUrl, $Path) -Level "Debug"

    if ($Path -like '$select=*') {
        _Write-RestLog -Context $LogContext -Message ("Invoke-TM1RestGet: Auto-fix path (from '{0}')." -f $Path) -Level "Debug"
        $Path = "Cubes?{0}" -f $Path.TrimEnd(',')
    }

    _Write-RestLog -Context $LogContext -Message ("Invoke-TM1RestGet (normalized): BaseUrl='{0}', Path='{1}'" -f $BaseUrl, $Path) -Level "Debug"

    if ($Path -like "http*://*") {
        $url = $Path
    }
    else {
        $baseClean = $BaseUrl.TrimEnd("/")
        $pathClean = $Path.TrimStart("/")
        $url = "$baseClean/$pathClean"
    }

    $attempt = 0
    $lastError = $null

    while ($attempt -lt $maxRetries) {
        $attempt++
        _Write-RestLog -Context $LogContext -Message ("REST GET: {0}, attempt {1}" -f $url, $attempt) -Level "Detail"

        try {
            $invokeParams = @{
                Method     = "Get"
                Uri        = $url
                Headers    = $Headers
                TimeoutSec = $effectiveTimeout
            }
            return Invoke-RestMethod @invokeParams
        }
        catch {
            $lastError = $_
            _Write-RestLog -Context $LogContext -Message ("REST GET error {0}, attempt {1}: {2}" -f $url, $attempt, $_.Exception.Message) -Level "Info"

            if ($attempt -lt $maxRetries -and $retryDelay -gt 0) {
                Start-Sleep -Seconds $retryDelay
            }
        }
    }

    if ($lastError) { throw $lastError }
    throw "Invoke-TM1RestGet: Unknown error after $maxRetries attempts for URL $url."
}

function Invoke-TM1RestPost {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $false)]
        $Body = $null,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSec = 60,

        [Parameter(Mandatory = $false)]
        [object]$RetrySettings,

        [Parameter(Mandatory = $false)]
        [object]$LogContext
    )

    if ($Path -match '^https?://') {
        $url = $Path
    }
    else {
        if ($Path.StartsWith("/")) { $url = ($BaseUrl.TrimEnd("/")) + $Path }
        else { $url = ($BaseUrl.TrimEnd("/")) + "/" + $Path }
    }

    _Write-RestLog -Context $LogContext -Message ("REST POST: {0}" -f $url) -Level "Detail"

    # IMPORTANT FIX (502):
    # Always send an explicit body for POST so Content-Length is set (0 for empty string).
    $bodyToSend = $null

    if ($null -eq $Body) {
        $bodyToSend = ""
    }
    elseif ($Body -is [string]) {
        $bodyToSend = $Body
    }
    else {
        $bodyToSend = $Body | ConvertTo-Json -Depth 10
    }

    $invokeParams = @{
        Method     = "Post"
        Uri        = $url
        Headers    = $Headers
        TimeoutSec = $TimeoutSec
        Body       = $bodyToSend
    }

    if ($RetrySettings) {
        $result = Invoke-TM1ORetry -RetrySettings $RetrySettings `
                                   -Context $LogContext `
                                   -Action { Invoke-RestMethod @invokeParams } `
                                   -ActionDescription ("REST POST {0}" -f $url)
        return $result
    }

    return Invoke-RestMethod @invokeParams
}

function Invoke-TM1RestDelete {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSec = 60,

        [Parameter(Mandatory = $false)]
        [object]$RetrySettings,

        [Parameter(Mandatory = $false)]
        [object]$LogContext
    )

    if ($Path -match '^https?://') {
        $url = $Path
    }
    else {
        if ($Path.StartsWith("/")) { $url = ($BaseUrl.TrimEnd("/")) + $Path }
        else { $url = ($BaseUrl.TrimEnd("/")) + "/" + $Path }
    }

    _Write-RestLog -Context $LogContext -Message ("REST DELETE: {0}" -f $url) -Level "Detail"

    $invokeParams = @{
        Method     = "Delete"
        Uri        = $url
        Headers    = $Headers
        TimeoutSec = $TimeoutSec
    }

    if ($RetrySettings) {
        $result = Invoke-TM1ORetry -RetrySettings $RetrySettings `
                                   -Context $LogContext `
                                   -Action { Invoke-RestMethod @invokeParams } `
                                   -ActionDescription ("REST DELETE {0}" -f $url)
        return $result
    }

    return Invoke-RestMethod @invokeParams
}

function Invoke-TM1RestExecuteMDX {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [string]$Mdx,

        [Parameter(Mandatory = $false)]
        [object]$RetrySettings,

        [Parameter(Mandatory = $false)]
        [object]$LogContext
    )

    if ([string]::IsNullOrWhiteSpace($Mdx)) {
        throw "Invoke-TM1RestExecuteMDX: MDX must not be empty."
    }

    $path = "ExecuteMDX?`$expand=Cells"
    $bodyObject = @{ MDX = $Mdx }
    $bodyJson = $bodyObject | ConvertTo-Json -Depth 5

    _Write-RestLog -Context $LogContext -Message ("REST POST ExecuteMDX: {0}" -f $Mdx) -Level "Debug"

    $result = Invoke-TM1RestPost -BaseUrl $BaseUrl `
                                 -Path $path `
                                 -Headers $Headers `
                                 -Body $bodyJson `
                                 -RetrySettings $RetrySettings `
                                 -LogContext $LogContext
    return $result
}

# ----------------------------------------
# 1) HealthCheck: /Configuration
# ----------------------------------------

function Test-TM1RestConnection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSec = 30,

        [Parameter(Mandatory = $false)]
        [object]$LogContext
    )

    _Write-RestLog -Context $LogContext -Message "REST HealthCheck: checking TM1 instance (Configuration)..." -Level "Detail"

    try {
        $null = Invoke-TM1RestGet -BaseUrl $BaseUrl `
                                  -Path "Configuration" `
                                  -Headers $Headers `
                                  -TimeoutSec $TimeoutSec `
                                  -LogContext $LogContext
        _Write-RestLogColor -Context $LogContext -Message "REST HealthCheck OK: TM1 instance responds." -Color Green -Level "Info"
        return $true
    }
    catch {
        _Write-RestLogColor -Context $LogContext -Message "REST HealthCheck FAILED: TM1 instance not reachable." -Color Red -Level "Info"
        _Write-RestLog -Context $LogContext -Message ($_ | Out-String) -Level "Debug"
        return $false
    }
}

# ----------------------------------------
# 2) ProcessExists: /Processes('<Name>')
# ----------------------------------------

function Test-TM1RestProcessExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [string]$ProcessName,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSec = 60,

        [Parameter(Mandatory = $false)]
        [object]$LogContext
    )

    $path = "Processes('$ProcessName')"
    _Write-RestLog -Context $LogContext -Message ("REST ProcessExists: checking process '{0}'..." -f $ProcessName) -Level "Detail"

    try {
        $null = Invoke-TM1RestGet -BaseUrl $BaseUrl `
                                  -Path $path `
                                  -Headers $Headers `
                                  -TimeoutSec $TimeoutSec `
                                  -LogContext $LogContext
        _Write-RestLogColor -Context $LogContext -Message ("REST ProcessExists: process '{0}' exists." -f $ProcessName) -Color Green -Level "Info"
        return $true
    }
    catch {
        _Write-RestLogColor -Context $LogContext -Message ("REST ProcessExists: process '{0}' not found or not reachable." -f $ProcessName) -Color Red -Level "Info"
        _Write-RestLog -Context $LogContext -Message ($_ | Out-String) -Level "Debug"
        return $false
    }
}

# ----------------------------------------
# 3) ProcessExecute: /Processes('<Name>')/tm1.ExecuteWithReturn
# ----------------------------------------

function Invoke-TM1RestProcessExecute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [string]$ProcessName,

        [Parameter(Mandatory = $false)]
        [array]$Parameters = @(),

        [Parameter(Mandatory = $true)]
        [object]$RetrySettings,

        [Parameter(Mandatory = $false)]
        [object]$LogContext
    )

    $bodyObject = @{
        "@odata.type" = "ibm.tm1.api.v1.ExecuteProcess"
        Parameters    = $Parameters
    }

    $path = "Processes('$ProcessName')/tm1.ExecuteWithReturn"
    _Write-RestLog -Context $LogContext -Message ("REST ProcessExecute: starting process '{0}'..." -f $ProcessName) -Level "Detail"

    $procStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $response = $null

    try {
        $response = Invoke-TM1RestPost -BaseUrl $BaseUrl `
                                       -Path $path `
                                       -Headers $Headers `
                                       -Body $bodyObject `
                                       -TimeoutSec $RetrySettings.TimeoutSec `
                                       -RetrySettings $RetrySettings `
                                       -LogContext $LogContext
    }
    catch {
        $procStopwatch.Stop()
        _Write-RestLog -Context $LogContext -Message ("REST ProcessExecute: failed after retries for '{0}'." -f $ProcessName) -Level "Info"
        _Write-RestLog -Context $LogContext -Message ($_ | Out-String) -Level "Debug"
        _Write-RestLog -Context $LogContext -Message ("Process runtime (sec, incl retries): {0}" -f $procStopwatch.Elapsed.TotalSeconds) -Level "Detail"

        return [PSCustomObject]@{
            Success  = $false
            Response = $null
        }
    }

    $procStopwatch.Stop()
    _Write-RestLog -Context $LogContext -Message ("Process runtime (sec, incl retries): {0}" -f $procStopwatch.Elapsed.TotalSeconds) -Level "Detail"

    if ($null -eq $response) {
        _Write-RestLog -Context $LogContext -Message "REST ProcessExecute: null response object, HTTP call succeeded." -Level "Detail"
        _Write-RestLogColor -Context $LogContext -Message ("REST ProcessExecute: process '{0}' treated as SUCCESS." -f $ProcessName) -Color Green -Level "Info"
        return [PSCustomObject]@{
            Success  = $true
            Response = $null
        }
    }

    $hasCode = $response.PSObject.Properties.Name -contains "ProcessExecuteStatusCode"
    $code = $null
    if ($hasCode) { $code = $response.ProcessExecuteStatusCode }

    _Write-RestLog -Context $LogContext -Message ("REST ProcessExecute: ProcessExecuteStatusCode (raw): {0}" -f $code) -Level "Detail"

    if ($hasCode -and $code -eq 3) {
        _Write-RestLogColor -Context $LogContext -Message ("REST ProcessExecute: process '{0}' ended with ERROR (code=3)." -f $ProcessName) -Color Red -Level "Info"
        $response | ConvertTo-Json -Depth 10 | ForEach-Object { _Write-RestLog -Context $LogContext -Message $_ -Level "Debug" }

        return [PSCustomObject]@{
            Success  = $false
            Response = $response
        }
    }

    _Write-RestLogColor -Context $LogContext -Message ("REST ProcessExecute: process '{0}' treated as SUCCESS." -f $ProcessName) -Color Green -Level "Info"
    $response | ConvertTo-Json -Depth 10 | ForEach-Object { _Write-RestLog -Context $LogContext -Message $_ -Level "Debug" }

    return [PSCustomObject]@{
        Success  = $true
        Response = $response
    }
}

# ----------------------------------------
# 4) Cube lesen: /Cubes('<Name>')
# ----------------------------------------

function Get-TM1RestCube {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [string]$CubeName,

        [Parameter(Mandatory = $false)]
        [string[]]$Properties,

        [Parameter(Mandatory = $false)]
        [object]$RetrySettings,

        [Parameter(Mandatory = $false)]
        [object]$LogContext
    )

    $path = "Cubes('$CubeName')"
    if ($Properties -and $Properties.Count -gt 0) {
        $select = ($Properties -join ",")
        $path = "$path?`$select=$select"
    }

    _Write-RestLog -Context $LogContext -Message ("REST GET Cube: Path='{0}'" -f $path) -Level "Detail"

    return Invoke-TM1RestGet -BaseUrl $BaseUrl `
                             -Path $path `
                             -Headers $Headers `
                             -RetrySettings $RetrySettings `
                             -LogContext $LogContext
}

# ----------------------------------------
# 5) Dimension lesen: /Dimensions('<Name>')
# ----------------------------------------

function Get-TM1RestDimension {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [string]$DimensionName,

        [Parameter(Mandatory = $false)]
        [string[]]$Properties,

        [Parameter(Mandatory = $false)]
        [object]$RetrySettings,

        [Parameter(Mandatory = $false)]
        [object]$LogContext
    )

    $path = "Dimensions('$DimensionName')"
    if ($Properties -and $Properties.Count -gt 0) {
        $select = ($Properties -join ",")
        $path = "$path?`$select=$select"
    }

    _Write-RestLog -Context $LogContext -Message ("REST Dimension: reading dimension '{0}'..." -f $DimensionName) -Level "Detail"

    return Invoke-TM1RestGet -BaseUrl $BaseUrl `
                             -Path $path `
                             -Headers $Headers `
                             -RetrySettings $RetrySettings `
                             -LogContext $LogContext
}

# ----------------------------------------
# 6) Einzelne Zelle lesen - Platzhalter
# ----------------------------------------

function Get-TM1RestCell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,
        [Parameter(Mandatory = $true)]
        [string]$CubeName,
        [Parameter(Mandatory = $true)]
        [string[]]$Coordinates,
        [Parameter(Mandatory = $false)]
        [object]$RetrySettings,
        [Parameter(Mandatory = $false)]
        [object]$LogContext
    )

    _Write-RestLog -Context $LogContext -Message (
        "Get-TM1RestCell: not implemented. Use ExecuteMDX based functions."
    ) -Level "Info"

    throw "Get-TM1RestCell: Direct 'Cubes(...) / Cells(...)' not supported on this TM1 version. Use ExecuteMDX."
}

# ----------------------------------------
# 7a) Chore-Info lesen: /Chores('<Name>') + Tasks
# ----------------------------------------

function Get-TM1RestChoreInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [string]$ChoreName,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSec = 60,

        [Parameter(Mandatory = $false)]
        [object]$RetrySettings,

        [Parameter(Mandatory = $false)]
        [object]$LogContext
    )

    $safeName = $ChoreName
    _Write-RestLog -Context $LogContext -Message ("REST ChoreInfo: reading chore '{0}'..." -f $safeName) -Level "Detail"

    $pathChore = "Chores('$safeName')"

    try {
        $chore = Invoke-TM1RestGet -BaseUrl $BaseUrl `
                                   -Path $pathChore `
                                   -Headers $Headers `
                                   -RetrySettings $RetrySettings `
                                   -TimeoutSec $TimeoutSec `
                                   -LogContext $LogContext
    }
    catch {
        _Write-RestLogColor -Context $LogContext -Message ("REST ChoreInfo: chore '{0}' not readable." -f $safeName) -Color Red -Level "Info"
        _Write-RestLog -Context $LogContext -Message ($_ | Out-String) -Level "Debug"

        return [PSCustomObject]@{
            Exists    = $false
            Name      = $safeName
            Enabled   = $false
            NextRun   = $null
            LastRun   = $null
            Processes = @()
            Raw       = $null
        }
    }

    $name = $chore.Name
    if (-not $name) { $name = $safeName }

    $enabled = $false
    if ($chore.PSObject.Properties.Name -contains "Enabled") { $enabled = [bool]$chore.Enabled }
    elseif ($chore.PSObject.Properties.Name -contains "Active") { $enabled = [bool]$chore.Active }

    $nextRun = $null
    foreach ($prop in @("NextRun", "StartTime", "ServerLocalStartTime")) {
        if ($chore.PSObject.Properties.Name -contains $prop -and $null -ne $chore.$prop) { $nextRun = $chore.$prop; break }
    }

    $lastRun = $null
    foreach ($prop in @("LastRun", "LastExecution", "LastSuccessfulRun")) {
        if ($chore.PSObject.Properties.Name -contains $prop -and $null -ne $chore.$prop) { $lastRun = $chore.$prop; break }
    }

    $processNames = @()
    try {
        $tasksPath = "Chores('$safeName')/Tasks?`$expand=Process(`$select=Name)"
        _Write-RestLog -Context $LogContext -Message ("REST ChoreInfo: reading tasks for chore '{0}'..." -f $safeName) -Level "Detail"

        $tasksResult = Invoke-TM1RestGet -BaseUrl $BaseUrl `
                                         -Path $tasksPath `
                                         -Headers $Headers `
                                         -RetrySettings $RetrySettings `
                                         -TimeoutSec $TimeoutSec `
                                         -LogContext $LogContext

        if ($tasksResult -and $tasksResult.value) {
            foreach ($t in $tasksResult.value) {
                $pName = $null
                if ($t.Process -and ($t.Process.PSObject.Properties.Name -contains "Name")) { $pName = $t.Process.Name }
                elseif ($t.PSObject.Properties.Name -contains "Process") { $pName = $t.Process }

                if ($pName) { $processNames += [string]$pName }
            }
        }
    }
    catch {
        _Write-RestLog -Context $LogContext -Message ("REST ChoreInfo: failed reading tasks for '{0}' (details in debug)." -f $safeName) -Level "Info"
        _Write-RestLog -Context $LogContext -Message ($_ | Out-String) -Level "Debug"
    }

    _Write-RestLogColor -Context $LogContext -Message (
        "REST ChoreInfo: chore '{0}' found. Enabled={1}, NextRun={2}, LastRun={3}, Tasks={4}" -f `
            $name, $enabled, $nextRun, $lastRun, ($processNames -join ", ")
    ) -Color Green -Level "Info"

    return [PSCustomObject]@{
        Exists    = $true
        Name      = $name
        Enabled   = $enabled
        NextRun   = $nextRun
        LastRun   = $lastRun
        Processes = $processNames
        Raw       = $chore
    }
}

# ----------------------------------------
# 7b) Threads lesen: /Threads
# ----------------------------------------

function Get-TM1RestThreads {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [int]$TimeoutSec = 30,

        [Parameter(Mandatory = $false)]
        [object]$RetrySettings,

        [Parameter(Mandatory = $false)]
        [object]$LogContext
    )

    _Write-RestLog -Context $LogContext -Message "REST GET Threads: reading /Threads..." -Level "Detail"

    try {
        $result = Invoke-TM1RestGet -BaseUrl $BaseUrl `
                                    -Path "Threads" `
                                    -Headers $Headers `
                                    -RetrySettings $RetrySettings `
                                    -TimeoutSec $TimeoutSec `
                                    -LogContext $LogContext

        if ($null -eq $result) { return @() }
        if ($result.PSObject.Properties.Name -contains "value") { return @($result.value) }
        return @($result)
    }
    catch {
        _Write-RestLog -Context $LogContext -Message ("REST GET Threads error: {0}" -f $_.Exception.Message) -Level "Info"
        return @()
    }
}

# ----------------------------------------
# 7c) Chore Running Detection via Threads
#   - Must match:
#       Function = POST /api/v1/Chores('X')/tm1.Execute
# ----------------------------------------

function Test-TM1RestChoreRunningByThreads {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChoreName,

        [Parameter(Mandatory = $false)]
        [string[]]$ProcessNames = @(),

        [Parameter(Mandatory = $true)]
        [object[]]$Threads,

        [Parameter(Mandatory = $false)]
        [object]$LogContext
    )

    if (-not $Threads -or $Threads.Count -eq 0) {
        _Write-RestLog -Context $LogContext -Message ("REST Guard: no threads available for chore '{0}'." -f $ChoreName) -Level "Detail"
        return $false
    }

    $needleChore = $ChoreName.Trim()
    $needleChoreLower = $needleChore.ToLowerInvariant()

    $procLower = @()
    foreach ($p in $ProcessNames) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $procLower += $p.Trim().ToLowerInvariant()
    }

    $matchCount = 0
    $sample = $null

    foreach ($t in $Threads) {
        if ($null -eq $t) { continue }

        $state = ""
        $func = ""
        $objType = ""
        $objName = ""
        $info = ""
        $user = ""

        if ($t.PSObject.Properties.Name -contains "State"      -and $t.State)      { $state   = [string]$t.State }
        if ($t.PSObject.Properties.Name -contains "Function"   -and $t.Function)   { $func    = [string]$t.Function }
        if ($t.PSObject.Properties.Name -contains "ObjectType" -and $t.ObjectType) { $objType = [string]$t.ObjectType }
        if ($t.PSObject.Properties.Name -contains "ObjectName" -and $t.ObjectName) { $objName = [string]$t.ObjectName }
        if ($t.PSObject.Properties.Name -contains "Info"       -and $t.Info)       { $info    = [string]$t.Info }
        if ($t.PSObject.Properties.Name -contains "Name"       -and $t.Name)       { $user    = [string]$t.Name }

        $objTypeLower = $objType.ToLowerInvariant()
        $objNameLower = $objName.ToLowerInvariant()
        $funcLower    = $func.ToLowerInvariant()
        $infoLower    = $info.ToLowerInvariant()

        $hit = $false
        $why = ""

        # 1) Best case: ObjectType/ObjectName identifies the chore
        if ($objTypeLower -eq "chore" -and $objNameLower -eq $needleChoreLower) {
            $hit = $true
            $why = "ObjectType=Chore and ObjectName=ChoreName"
        }

        # 2) Function contains the REST chore execute call
        #    Expected: POST /api/v1/Chores('X')/tm1.Execute
        if (-not $hit -and -not [string]::IsNullOrWhiteSpace($funcLower)) {
            if ($funcLower -like "*post*" -and $funcLower -like "*/chores('*" -and $funcLower -like "*)/tm1.execute*") {
                if ($funcLower -like ("*chores('" + $needleChoreLower + "')/tm1.execute*")) {
                    $hit = $true
                    $why = "Function matches POST /Chores('X')/tm1.Execute"
                }
            }

            # Fallback: function contains chore name somewhere
            if (-not $hit -and $funcLower -like "*chore*" -and $funcLower -like ("*" + $needleChoreLower + "*")) {
                $hit = $true
                $why = "Function contains chore name"
            }
        }

        # 3) Info contains chore name or process names
        if (-not $hit -and -not [string]::IsNullOrWhiteSpace($infoLower)) {
            if ($infoLower -like ("*" + $needleChoreLower + "*")) {
                $hit = $true
                $why = "Info contains chore name"
            }
            elseif ($procLower.Count -gt 0) {
                foreach ($pn in $procLower) {
                    if ($infoLower -like ("*" + $pn + "*")) {
                        $hit = $true
                        $why = "Info contains process name"
                        break
                    }
                }
            }
        }

        # 4) ObjectType/Name for process
        if (-not $hit -and $procLower.Count -gt 0 -and $objTypeLower -eq "process" -and -not [string]::IsNullOrWhiteSpace($objNameLower)) {
            foreach ($pn in $procLower) {
                if ($objNameLower -eq $pn) {
                    $hit = $true
                    $why = "ObjectType=Process and ObjectName=ProcessName"
                    break
                }
            }
        }

        if ($hit) {
            $matchCount++
            if (-not $sample) {
                $sample = [PSCustomObject]@{
                    ID         = $(if ($t.PSObject.Properties.Name -contains "ID") { $t.ID } else { $null })
                    State      = $state
                    Function   = $func
                    ObjectType = $objType
                    ObjectName = $objName
                    Info       = $info
                    Name       = $user
                    Why        = $why
                }
            }
        }
    }

    if ($matchCount -gt 0) {
        _Write-RestLogColor -Context $LogContext -Message ("REST Guard: threads match found for chore '{0}' (Matches={1})." -f $ChoreName, $matchCount) -Color Yellow -Level "Info"
        if ($sample) {
            _Write-RestLog -Context $LogContext -Message ("REST Guard sample: ID={0}; State={1}; Function={2}; ObjectType={3}; ObjectName={4}; Why={5}" -f `
                $sample.ID, $sample.State, $sample.Function, $sample.ObjectType, $sample.ObjectName, $sample.Why) -Level "Debug"
        }
        return $true
    }

    _Write-RestLog -Context $LogContext -Message ("REST Guard: no thread matches for chore '{0}'." -f $ChoreName) -Level "Detail"
    return $false
}

# ----------------------------------------
# 7d) Wait for Chore completion via Threads only
#   Success States: FINISHED, FINISHED_UNOBSERVED
# ----------------------------------------

function Wait-TM1RestChoreCompletion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [string]$ChoreName,

        [Parameter(Mandatory = $false)]
        [string[]]$ProcessNames = @(),

        [Parameter(Mandatory = $false)]
        [int]$MaxWaitSec = 3600,

        [Parameter(Mandatory = $false)]
        [int]$PollSec = 10,

        [Parameter(Mandatory = $false)]
        [int]$NoMatchConfirmCount = 3,

        [Parameter(Mandatory = $false)]
        [int]$StartDetectTimeoutSec = 120,

        [Parameter(Mandatory = $false)]
        [int]$StartDetectPollSec = 1,

        [Parameter(Mandatory = $false)]
        [bool]$TriggerAssumedStarted = $false,

        [Parameter(Mandatory = $false)]
        [int]$GracePeriodSec = 3,

        [Parameter(Mandatory = $false)]
        [int]$NoMatchConfirmPollSec = 1,

        [Parameter(Mandatory = $false)]
        [int]$MaxStartDetectWhenAssumedSec = 10,

        [Parameter(Mandatory = $false)]
        [object]$LogContext
    )

    if ($PollSec -lt 1) { $PollSec = 1 }
    if ($StartDetectPollSec -lt 1) { $StartDetectPollSec = 1 }
    if ($NoMatchConfirmCount -lt 2) { $NoMatchConfirmCount = 2 }
    if ($GracePeriodSec -lt 0) { $GracePeriodSec = 0 }
    if ($NoMatchConfirmPollSec -lt 1) { $NoMatchConfirmPollSec = 1 }
    if ($MaxStartDetectWhenAssumedSec -lt 1) { $MaxStartDetectWhenAssumedSec = 1 }

    _Write-RestLog -Context $LogContext -Message ("REST Wait: wait for chore '{0}' (MaxWaitSec={1}, PollSec={2})" -f $ChoreName, $MaxWaitSec, $PollSec) -Level "Detail"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # -----------------------------
    # Phase 1: Start detect (try to see RUNNING once)
    # Adaptive: if trigger is assumed started, do not burn 180s polling.
    # -----------------------------
    $seenRunning = $false

    $effectiveStartDetectTimeout = $StartDetectTimeoutSec
    if ($TriggerAssumedStarted -and $effectiveStartDetectTimeout -gt $MaxStartDetectWhenAssumedSec) {
        $effectiveStartDetectTimeout = $MaxStartDetectWhenAssumedSec
    }

    $startSw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $seenRunning -and $startSw.Elapsed.TotalSeconds -lt $effectiveStartDetectTimeout -and $sw.Elapsed.TotalSeconds -lt $MaxWaitSec) {
        $threads = Get-TM1RestThreads -BaseUrl $BaseUrl -Headers $Headers -TimeoutSec 30 -RetrySettings $null -LogContext $LogContext
        $isRunning = Test-TM1RestChoreRunningByThreads -ChoreName $ChoreName -ProcessNames $ProcessNames -Threads $threads -LogContext $LogContext

        if ($isRunning) {
            $seenRunning = $true
            break
        }

        Start-Sleep -Seconds $StartDetectPollSec
    }
    $startSw.Stop()

    if ($seenRunning) {
        _Write-RestLogColor -Context $LogContext -Message ("REST Wait: chore '{0}' is RUNNING. waiting for finish..." -f $ChoreName) -Color Yellow -Level "Info"
    }
    else {
        if (-not $TriggerAssumedStarted) {
            $sw.Stop()
            _Write-RestLogColor -Context $LogContext -Message ("REST Wait: no RUNNING observed for '{0}' within {1}s." -f $ChoreName, $effectiveStartDetectTimeout) -Color Red -Level "Info"
            return @{
                Success     = $false
                State       = "NOT_DETECTED"
                Message     = "No RUNNING observed. Abort."
                DurationSec = [math]::Round($sw.Elapsed.TotalSeconds)
            }
        }

        _Write-RestLogColor -Context $LogContext -Message ("REST Wait: RUNNING not observed, but trigger assumed started. GracePeriod={0}s." -f $GracePeriodSec) -Color Yellow -Level "Info"

        if ($GracePeriodSec -gt 0) {
            Start-Sleep -Seconds $GracePeriodSec
        }
    }

    # -----------------------------
    # Phase 2: Finish detection
    # Logic:
    # - If match exists -> normal PollSec
    # - If match disappears -> confirm quickly with NoMatchConfirmPollSec
    # -----------------------------
    $noMatchStreak = 0

    while ($sw.Elapsed.TotalSeconds -lt $MaxWaitSec) {
        $threads = Get-TM1RestThreads -BaseUrl $BaseUrl -Headers $Headers -TimeoutSec 30 -RetrySettings $null -LogContext $LogContext
        $isRunning = Test-TM1RestChoreRunningByThreads -ChoreName $ChoreName -ProcessNames $ProcessNames -Threads $threads -LogContext $LogContext

        if ($isRunning) {
            $noMatchStreak = 0
            Start-Sleep -Seconds $PollSec
            continue
        }

        $noMatchStreak++
        _Write-RestLog -Context $LogContext -Message ("REST Wait: no match ({0}/{1}) for '{2}'." -f $noMatchStreak, $NoMatchConfirmCount, $ChoreName) -Level "Detail"

        if ($noMatchStreak -ge $NoMatchConfirmCount) {
            $sw.Stop()

            $state = "FINISHED"
            $msg = "Chore finished."
            if (-not $seenRunning) {
                $state = "FINISHED_UNOBSERVED"
                $msg = "Chore finished, RUNNING not observed (short run or threads not visible)."
            }

            _Write-RestLogColor -Context $LogContext -Message ("REST Wait: chore '{0}' finished (no thread matches confirmed)." -f $ChoreName) -Color Green -Level "Info"
            return @{
                Success     = $true
                State       = $state
                Message     = $msg
                DurationSec = [math]::Round($sw.Elapsed.TotalSeconds)
            }
        }

        # Quick confirm when no match
        Start-Sleep -Seconds $NoMatchConfirmPollSec
    }

    $sw.Stop()
    _Write-RestLogColor -Context $LogContext -Message ("REST Wait: timeout waiting for '{0}' after {1}s." -f $ChoreName, [math]::Round($sw.Elapsed.TotalSeconds)) -Color Red -Level "Info"
    return @{
        Success     = $false
        State       = "WAIT_TIMEOUT"
        Message     = "Timeout waiting for chore finish."
        DurationSec = [math]::Round($sw.Elapsed.TotalSeconds)
    }
}

# ----------------------------------------
# 8) Chore ausfuehren: /Chores('<Name>')/tm1.Execute
#   IMPORTANT: no retry (avoid double start)
# ----------------------------------------

function Invoke-TM1RestChoreExecute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [string]$ChoreName,

        [Parameter(Mandatory = $true)]
        [object]$RetrySettings,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSec = 60,

        [Parameter(Mandatory = $false)]
        [string[]]$ProcessNames = $null,

        [Parameter(Mandatory = $false)]
        [switch]$WaitForCompletion,

        [Parameter(Mandatory = $false)]
        [int]$MaxWaitSec = 3600,

        [Parameter(Mandatory = $false)]
        [int]$PollSec = 10,

        [Parameter(Mandatory = $false)]
        [int]$NoMatchConfirmCount = 3,

        [Parameter(Mandatory = $false)]
        [int]$StartDetectTimeoutSec = 120,

        [Parameter(Mandatory = $false)]
        [int]$StartDetectPollSec = 1,

        [Parameter(Mandatory = $false)]
        [int]$GracePeriodSec = 3,

        [Parameter(Mandatory = $false)]
        [int]$NoMatchConfirmPollSec = 1,

        [Parameter(Mandatory = $false)]
        [int]$MaxStartDetectWhenAssumedSec = 10,

        [Parameter(Mandatory = $false)]
        [object]$LogContext
    )

    $safeName = $ChoreName
    $path = "Chores('$safeName')/tm1.Execute"

    _Write-RestLog -Context $LogContext -Message ("REST ChoreExecute: starting chore '{0}'..." -f $safeName) -Level "Detail"

    # Single attempt only (never retry a chore trigger)
    $singleAttemptRetry = [PSCustomObject]@{
        MaxRetries    = 1
        RetryDelaySec = 0
        TimeoutSec    = 0
    }
    if ($RetrySettings -and ($RetrySettings.PSObject.Properties.Name -contains "TimeoutSec") -and $RetrySettings.TimeoutSec) {
        $singleAttemptRetry.TimeoutSec = [int]$RetrySettings.TimeoutSec
    }

    $effectiveTimeout = $TimeoutSec
    if ($singleAttemptRetry.TimeoutSec -gt 0 -and $effectiveTimeout -lt $singleAttemptRetry.TimeoutSec) {
        $effectiveTimeout = $singleAttemptRetry.TimeoutSec
    }

    # PreInfo for process list (guard matching)
    $preInfo = $null
    try {
        $preInfo = Get-TM1RestChoreInfo -BaseUrl $BaseUrl `
                                       -Headers $Headers `
                                       -ChoreName $safeName `
                                       -TimeoutSec 60 `
                                       -RetrySettings $null `
                                       -LogContext $LogContext
    }
    catch {
        $preInfo = $null
    }

    $procNames = @()
    if ($ProcessNames -and $ProcessNames.Count -gt 0) {
        $procNames = @($ProcessNames)
    }
    elseif ($preInfo -and ($preInfo.PSObject.Properties.Name -contains "Processes") -and $preInfo.Processes) {
        $procNames = @($preInfo.Processes)
    }

    # Guard BEFORE start (best-effort)
    try {
        $threadsBefore = Get-TM1RestThreads -BaseUrl $BaseUrl -Headers $Headers -TimeoutSec 30 -RetrySettings $null -LogContext $LogContext
        $isRunningBefore = Test-TM1RestChoreRunningByThreads -ChoreName $safeName -ProcessNames $procNames -Threads $threadsBefore -LogContext $LogContext

        if ($isRunningBefore) {
            _Write-RestLogColor -Context $LogContext -Message ("REST Guard: chore '{0}' already running. No REST start." -f $safeName) -Color Yellow -Level "Info"

            if ($WaitForCompletion) {
                $waitRes = Wait-TM1RestChoreCompletion -BaseUrl $BaseUrl -Headers $Headers -ChoreName $safeName `
                                                       -ProcessNames $procNames `
                                                       -MaxWaitSec $MaxWaitSec -PollSec $PollSec `
                                                       -NoMatchConfirmCount $NoMatchConfirmCount `
                                                       -StartDetectTimeoutSec $StartDetectTimeoutSec `
                                                       -StartDetectPollSec $StartDetectPollSec `
                                                       -TriggerAssumedStarted $true `
                                                       -GracePeriodSec $GracePeriodSec `
                                                       -NoMatchConfirmPollSec $NoMatchConfirmPollSec `
                                                       -MaxStartDetectWhenAssumedSec $MaxStartDetectWhenAssumedSec `
                                                       -LogContext $LogContext

                return [PSCustomObject]@{
                    Success = [bool]$waitRes.Success
                    Skipped = $true
                    State   = [string]$waitRes.State
                    Message = [string]$waitRes.Message
                }
            }

            return [PSCustomObject]@{
                Success  = $true
                Skipped  = $true
                State    = "RUNNING"
                Finished = $false
                Message  = "Chore already running. Start skipped."
            }
        }
    }
    catch {
        _Write-RestLog -Context $LogContext -Message ("REST Guard: thread check error (ignored): {0}" -f $_.Exception.Message) -Level "Info"
    }

    # Single POST attempt
    $postSucceeded = $false
    try {
        # IMPORTANT FIX (502): use empty string body -> Content-Length=0
        $null = Invoke-TM1RestPost -BaseUrl $BaseUrl `
                                  -Path $path `
                                  -Headers $Headers `
                                  -Body "" `
                                  -TimeoutSec $effectiveTimeout `
                                  -RetrySettings $singleAttemptRetry `
                                  -LogContext $LogContext
        $postSucceeded = $true
    }
    catch {
        $postSucceeded = $false
        $msg = $_.Exception.Message

        # If trigger errors, check if it still started (threads)
        $isRunningAfter = $false
        try {
            $threadsAfter = Get-TM1RestThreads -BaseUrl $BaseUrl -Headers $Headers -TimeoutSec 30 -RetrySettings $null -LogContext $LogContext
            $isRunningAfter = Test-TM1RestChoreRunningByThreads -ChoreName $safeName -ProcessNames $procNames -Threads $threadsAfter -LogContext $LogContext
        }
        catch {
            $isRunningAfter = $false
        }

        if ($isRunningAfter) {
            _Write-RestLogColor -Context $LogContext -Message "REST ChoreExecute: trigger returned error, but chore is RUNNING (thread match)." -Color Yellow -Level "Info"

            if ($WaitForCompletion) {
                $waitRes = Wait-TM1RestChoreCompletion -BaseUrl $BaseUrl -Headers $Headers -ChoreName $safeName `
                                                       -ProcessNames $procNames `
                                                       -MaxWaitSec $MaxWaitSec -PollSec $PollSec `
                                                       -NoMatchConfirmCount $NoMatchConfirmCount `
                                                       -StartDetectTimeoutSec $StartDetectTimeoutSec `
                                                       -StartDetectPollSec $StartDetectPollSec `
                                                       -TriggerAssumedStarted $true `
                                                       -GracePeriodSec $GracePeriodSec `
                                                       -NoMatchConfirmPollSec $NoMatchConfirmPollSec `
                                                       -MaxStartDetectWhenAssumedSec $MaxStartDetectWhenAssumedSec `
                                                       -LogContext $LogContext

                return [PSCustomObject]@{
                    Success = [bool]$waitRes.Success
                    Skipped = $false
                    State   = [string]$waitRes.State
                    Message = [string]$waitRes.Message
                }
            }

            return [PSCustomObject]@{
                Success  = $true
                Skipped  = $false
                State    = "RUNNING"
                Finished = $false
                Message  = "Trigger error, but chore is running (thread match). No retry."
            }
        }

        _Write-RestLogColor -Context $LogContext -Message ("REST ChoreExecute: trigger failed for '{0}'. No retry (avoid double start)." -f $safeName) -Color Red -Level "Info"
        _Write-RestLog -Context $LogContext -Message ("Error: {0}" -f $msg) -Level "Detail"

        return [PSCustomObject]@{
            Success  = $false
            Skipped  = $false
            State    = "TRIGGER_FAILED"
            Finished = $false
            Message  = "Trigger failed. No retry. Details: " + $msg
        }
    }

    if ($postSucceeded) {
        _Write-RestLog -Context $LogContext -Message ("REST ChoreExecute: chore '{0}' triggered (single attempt)." -f $safeName) -Level "Info"

        if ($WaitForCompletion) {
            $waitRes = Wait-TM1RestChoreCompletion -BaseUrl $BaseUrl -Headers $Headers -ChoreName $safeName `
                                                   -ProcessNames $procNames `
                                                   -MaxWaitSec $MaxWaitSec -PollSec $PollSec `
                                                   -NoMatchConfirmCount $NoMatchConfirmCount `
                                                   -StartDetectTimeoutSec $StartDetectTimeoutSec `
                                                   -StartDetectPollSec $StartDetectPollSec `
                                                   -TriggerAssumedStarted $true `
                                                   -GracePeriodSec $GracePeriodSec `
                                                   -NoMatchConfirmPollSec $NoMatchConfirmPollSec `
                                                   -MaxStartDetectWhenAssumedSec $MaxStartDetectWhenAssumedSec `
                                                   -LogContext $LogContext

            return [PSCustomObject]@{
                Success = [bool]$waitRes.Success
                Skipped = $false
                State   = [string]$waitRes.State
                Message = [string]$waitRes.Message
            }
        }

        return [PSCustomObject]@{
            Success  = $true
            Skipped  = $false
            State    = "TRIGGERED"
            Finished = $false
            Message  = "Chore triggered via REST."
        }
    }

    return [PSCustomObject]@{
        Success  = $false
        Skipped  = $false
        State    = "UNKNOWN"
        Finished = $false
        Message  = "Unknown state after chore trigger."
    }
}

# ----------------------------------------
# 9) Chore aktivieren: /Chores('<Name>')/tm1.Activate
# ----------------------------------------

function Invoke-TM1RestChoreActivate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [string]$ChoreName,

        [Parameter(Mandatory = $true)]
        [object]$RetrySettings,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSec = 60,

        [Parameter(Mandatory = $false)]
        [object]$LogContext
    )

    $safeName = $ChoreName
    $path = "Chores('$safeName')/tm1.Activate"

    _Write-RestLog -Context $LogContext -Message ("REST ChoreActivate: activating chore '{0}'..." -f $safeName) -Level "Detail"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $response = $null

    try {
        $response = Invoke-TM1RestPost -BaseUrl $BaseUrl `
                                       -Path $path `
                                       -Headers $Headers `
                                       -Body $null `
                                       -TimeoutSec $TimeoutSec `
                                       -RetrySettings $RetrySettings `
                                       -LogContext $LogContext
    }
    catch {
        $sw.Stop()
        _Write-RestLog -Context $LogContext -Message ("REST ChoreActivate: failed after retries for '{0}'." -f $safeName) -Level "Info"
        _Write-RestLog -Context $LogContext -Message ($_ | Out-String) -Level "Debug"
        _Write-RestLog -Context $LogContext -Message ("ChoreActivate runtime (sec, incl retries): {0}" -f $sw.Elapsed.TotalSeconds) -Level "Detail"

        return [PSCustomObject]@{
            Success  = $false
            Response = $null
            Message  = $_.Exception.Message
        }
    }

    $sw.Stop()
    _Write-RestLog -Context $LogContext -Message ("ChoreActivate runtime (sec, incl retries): {0}" -f $sw.Elapsed.TotalSeconds) -Level "Detail"
    _Write-RestLogColor -Context $LogContext -Message ("REST ChoreActivate: chore '{0}' activated." -f $safeName) -Color Green -Level "Info"

    return [PSCustomObject]@{
        Success  = $true
        Response = $response
        Message  = "Chore activated."
    }
}

# ----------------------------------------
# 10) Chore deaktivieren: /Chores('<Name>')/tm1.Deactivate
# ----------------------------------------

function Invoke-TM1RestChoreDeactivate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [string]$ChoreName,

        [Parameter(Mandatory = $true)]
        [object]$RetrySettings,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSec = 60,

        [Parameter(Mandatory = $false)]
        [object]$LogContext
    )

    $safeName = $ChoreName
    $path = "Chores('$safeName')/tm1.Deactivate"

    _Write-RestLog -Context $LogContext -Message ("REST ChoreDeactivate: deactivating chore '{0}'..." -f $safeName) -Level "Detail"

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $response = $null

    try {
        $response = Invoke-TM1RestPost -BaseUrl $BaseUrl `
                                       -Path $path `
                                       -Headers $Headers `
                                       -Body $null `
                                       -TimeoutSec $TimeoutSec `
                                       -RetrySettings $RetrySettings `
                                       -LogContext $LogContext
    }
    catch {
        $sw.Stop()
        _Write-RestLog -Context $LogContext -Message ("REST ChoreDeactivate: failed after retries for '{0}'." -f $safeName) -Level "Info"
        _Write-RestLog -Context $LogContext -Message ($_ | Out-String) -Level "Debug"
        _Write-RestLog -Context $LogContext -Message ("ChoreDeactivate runtime (sec, incl retries): {0}" -f $sw.Elapsed.TotalSeconds) -Level "Detail"

        return [PSCustomObject]@{
            Success  = $false
            Response = $null
            Message  = $_.Exception.Message
        }
    }

    $sw.Stop()
    _Write-RestLog -Context $LogContext -Message ("ChoreDeactivate runtime (sec, incl retries): {0}" -f $sw.Elapsed.TotalSeconds) -Level "Detail"
    _Write-RestLogColor -Context $LogContext -Message ("REST ChoreDeactivate: chore '{0}' deactivated." -f $safeName) -Color Green -Level "Info"

    return [PSCustomObject]@{
        Success  = $true
        Response = $response
        Message  = "Chore deactivated."
    }
}

# ----------------------------------------
# 11) Alle Chores auflisten
# ----------------------------------------

function Get-TM1RestChores {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [int]$TimeoutSec = 60,

        [Parameter(Mandatory = $false)]
        [object]$LogContext
    )

    if ($LogContext) {
        _Write-RestLog -Context $LogContext -Message "REST: reading chores list via GET /Chores" -Level "Detail"
    }

    $base = $BaseUrl.TrimEnd("/")
    $url = "$base/Chores?`$select=Name,Enabled,NextRun,LastRun"

    try {
        $response = Invoke-RestMethod -Method Get -Uri $url -Headers $Headers -TimeoutSec $TimeoutSec
        if ($null -eq $response) { return @() }
        if ($response.PSObject.Properties.Name -contains "value") { return @($response.value) }
        return @($response)
    }
    catch {
        _Write-RestLog -Context $LogContext -Message ("REST Get-TM1RestChores error: {0}" -f $_.Exception.Message) -Level "Info"
        return $null
    }
}

# ----------------------------------------
# Exporte
# ----------------------------------------

Export-ModuleMember -Function `
    Invoke-TM1RestGet, `
    Invoke-TM1RestPost, `
    Invoke-TM1RestDelete, `
    Invoke-TM1RestExecuteMDX, `
    Test-TM1RestConnection, `
    Test-TM1RestProcessExists, `
    Invoke-TM1RestProcessExecute, `
    Get-TM1RestCube, `
    Get-TM1RestDimension, `
    Get-TM1RestCell, `
    Get-TM1RestChoreInfo, `
    Get-TM1RestThreads, `
    Test-TM1RestChoreRunningByThreads, `
    Wait-TM1RestChoreCompletion, `
    Invoke-TM1RestChoreExecute, `
    Invoke-TM1RestChoreActivate, `
    Invoke-TM1RestChoreDeactivate, `
    Get-TM1RestChores