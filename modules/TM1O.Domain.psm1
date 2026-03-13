<#
================================================================================
  TM1 Orchestrator Framework - Module: TM1O.Domain.psm1 - Version 0.2 (2026-03-13)
================================================================================

 Bestandteil des TM1 Orchestrator Frameworks (TM1O).

 Dieses Modul befindet sich im Verzeichnis:

   TM1Orchestrator\modules\

 und stellt Domain-Objekte sowie Domain-Funktionen bereit, die auf den
 Low-Level REST-Funktionen aus dem Modul TM1O.REST.psm1 aufsetzen.

 -------------------------------------------------------------------------------
 Zweck dieses Moduls
 -------------------------------------------------------------------------------

   TM1O.Domain.psm1 kapselt die fachliche Modellierung von TM1-Objekten und
   stellt komfortable Funktionen bereit, die auf den Low-Level REST-Aufrufen
   aus TM1O.REST.psm1 aufbauen.

   Ziel ist eine klar getrennte Architektur:

      Runner Scripts
           ↓
      Domain Logik
           ↓
      REST Kommunikation
           ↓
      TM1 / Planning Analytics Server

   Dadurch muessen Runner nicht direkt mit REST-Endpunkten arbeiten.

 -------------------------------------------------------------------------------
 Enthaltene Domain-Klassen
 -------------------------------------------------------------------------------

   TM1Cube
       - repraesentiert einen TM1 Cube
       - Eigenschaften: Name, Dimensions

   TM1CellCoordinate
       - repraesentiert eine eindeutige Zellenkoordinate
       - Eigenschaften: CubeName, Coordinates

   TM1CellValue
       - repraesentiert den Wert einer Zelle
       - Eigenschaften: Coordinate, Value

 -------------------------------------------------------------------------------
 Enthaltene Domain-Funktionen
 -------------------------------------------------------------------------------

   Get-TM1CubeDomain
       - liefert Cube-Metadaten als TM1Cube Objekt

   Get-TM1CellDomain
       - liest eine einzelne Zelle (Single Cell Read)
       - Rueckgabe als TM1CellValue Objekt
       - verwendet intern MDX ueber TM1 REST

   Get-TM1CellValue
       - Convenience-Funktion fuer direkten Zellwert

   Get-TM1CellTable
       - liest mehrere Zellen und liefert eine tabellarische Struktur

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
       -> Logging, Config-Zugriff, Framework Utilities

   modules\TM1O.REST.psm1
       -> REST-Kommunikation mit TM1 / Planning Analytics

 -------------------------------------------------------------------------------
 Logging-Konzept
 -------------------------------------------------------------------------------

   Das Modul nutzt das zentrale Logging aus TM1O.Core:

      Write-TM1OLog -Level Info
      Write-TM1OLog -Level Detail
      Write-TM1OLog -Level Debug

   Steuerung ueber ConsoleLogLevel:

      Info   -> nur wichtigste Meldungen
      Detail -> detailliertere Ablaufmeldungen
      Debug  -> sehr detaillierte technische Informationen

 -------------------------------------------------------------------------------
 Hinweis
 -------------------------------------------------------------------------------

   Dieses Modul ist kein eigenstaendig ausfuehrbares Script.

   Es wird ausschliesslich ueber Import-Module von Runner-Scripts oder
   vom CLI Dispatcher (tm1o.ps1) geladen.

#>

# ----------------------------------------
# Abhaengigkeiten: TM1O.Core & TM1O.REST
# ----------------------------------------

$coreModulePath = Join-Path $PSScriptRoot "TM1O.Core.psm1"
$restModulePath = Join-Path $PSScriptRoot "TM1O.REST.psm1"

if (-not (Get-Module -Name TM1O.Core -ErrorAction SilentlyContinue)) {
    if (Test-Path $coreModulePath) {
        Import-Module $coreModulePath -DisableNameChecking -Force
    }
    else {
        throw "TM1O.Core-Modul wurde nicht gefunden: $coreModulePath"
    }
}

if (-not (Get-Module -Name TM1O.REST -ErrorAction SilentlyContinue)) {
    if (Test-Path $restModulePath) {
        Import-Module $restModulePath -DisableNameChecking -Force
    }
    else {
        throw "TM1O.REST-Modul wurde nicht gefunden: $restModulePath"
    }
}

# ----------------------------------------
# Domain-Klassen
# ----------------------------------------

class TM1Cube {
    [string]  $Name
    [string[]]$Dimensions

    TM1Cube([string]$name, [string[]]$dimensions) {
        $this.Name       = $name
        $this.Dimensions = $dimensions
    }

    [string] ToString() {
        return "TM1Cube(Name={0}, Dimensions=[{1}])" -f $this.Name, ($this.Dimensions -join ", ")
    }
}

class TM1CellCoordinate {
    [string]  $CubeName
    [string[]]$Coordinates

    TM1CellCoordinate([string]$cubeName, [string[]]$coordinates) {
        $this.CubeName    = $cubeName
        $this.Coordinates = $coordinates
    }

    [string] ToString() {
        return "TM1CellCoordinate(Cube={0}, Coords=[{1}])" -f $this.CubeName, ($this.Coordinates -join ", ")
    }
}

class TM1CellValue {
    [TM1CellCoordinate]$Coordinate
    [object]           $Value

    TM1CellValue([TM1CellCoordinate]$coordinate, [object]$value) {
        $this.Coordinate = $coordinate
        $this.Value      = $value
    }

    [string] ToString() {
        return "TM1CellValue({0}, Value={1})" -f $this.Coordinate.ToString(), $this.Value
    }
}

# ----------------------------------------
# Hilfs-Logging (mit Level-Integration)
# ----------------------------------------

function Write-TM1ODomainLog {
    param(
        [Parameter(Mandatory = $false)]
        [object]$LogContext,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Info","Detail","Debug")]
        [string]$Level = "Info"
    )

    if ($LogContext) {
        # Neuer Core: akzeptiert Level
        Write-TM1OLog -Context $LogContext -Message $Message -Level $Level
    }
    else {
        # Fallback: Level in Konsole mit ausgeben
        $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
        Write-Host $line
    }
}

# ----------------------------------------
# 1) Cube-Domain: Get-TM1CubeDomain
# ----------------------------------------

function Get-TM1CubeDomain {
    <#
    .SYNOPSIS
        Liefert einen TM1Cube (Name, Dimensions) fuer einen Cube.

    .PARAMETER BaseUrl
        TM1 REST Basis-URL (https://.../api/v1).

    .PARAMETER Headers
        HTTP-Header (Authorization, CAMNamespace, Content-Type).

    .PARAMETER CubeName
        Name des Cubes.

    .PARAMETER RetrySettings
        Optionales RetrySettings-Objekt (von TM1O.Core).

    .PARAMETER LogContext
        Optionaler LogContext (TM1O.Core).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [string]$CubeName,

        [Parameter(Mandatory = $false)]
        [object]$RetrySettings,

        [Parameter(Mandatory = $false)]
        [object]$LogContext
    )

    Write-TM1ODomainLog -LogContext $LogContext -Message ("Domain: lese Cube '{0}' ..." -f $CubeName) -Level "Info"

    # 1) Cube-Objekt selbst holen (nur Name)
    $cubePath = "Cubes('$CubeName')?`$select=Name"

    $cubeResult = Invoke-TM1RestGet -BaseUrl $BaseUrl `
                                    -Path $cubePath `
                                    -Headers $Headers `
                                    -RetrySettings $RetrySettings `
                                    -LogContext $LogContext

    if (-not $cubeResult) {
        throw "Get-TM1CubeDomain: REST-Ergebnis fuer Cube '$CubeName' ist leer/null."
    }

    $cubeNameFromRest = $null

    if ($cubeResult.PSObject.Properties.Name -contains "value") {
        # Collection von Cubes
        $candidate = $cubeResult.value | Where-Object { $_.Name -eq $CubeName } | Select-Object -First 1
        if ($candidate) {
            $cubeNameFromRest = $candidate.Name
        }
    }
    else {
        # Einzel-Cube
        $cubeNameFromRest = $cubeResult.Name
    }

    if (-not $cubeNameFromRest) {
        throw "Get-TM1CubeDomain: Cube '$CubeName' wurde in der REST-Antwort nicht gefunden."
    }

    # 2) Dimensionsliste separat ueber Sub-Resource holen
    #    /Cubes('KST')/Dimensions?$select=Name
    Write-TM1ODomainLog -LogContext $LogContext -Message ("Domain: lese Dimensions fuer Cube '{0}' ..." -f $CubeName) -Level "Detail"

    $dimsPath = "Cubes('$CubeName')/Dimensions?`$select=Name"

    $dimsResult = Invoke-TM1RestGet -BaseUrl $BaseUrl `
                                    -Path $dimsPath `
                                    -Headers $Headers `
                                    -RetrySettings $RetrySettings `
                                    -LogContext $LogContext

    if (-not $dimsResult) {
        throw "Get-TM1CubeDomain: REST-Ergebnis fuer Dimensions von Cube '$CubeName' ist leer/null."
    }

    $dims = @()

    if ($dimsResult.PSObject.Properties.Name -contains "value") {
        foreach ($d in $dimsResult.value) {
            if ($d -and ($d.PSObject.Properties.Name -contains "Name")) {
                $dims += $d.Name
            }
        }
    }
    else {
        # Falls TM1 hier doch ein einzelnes Objekt liefert
        if ($dimsResult.PSObject.Properties.Name -contains "Name") {
            $dims += $dimsResult.Name
        }
    }

    if (-not $dims -or $dims.Count -eq 0) {
        throw "Get-TM1CubeDomain: Cube '$CubeName' liefert keine Dimensionsinformationen (Sub-Resource /Dimensions ist leer)."
    }

    $cubeObj = [TM1Cube]::new($cubeNameFromRest, $dims)
    return $cubeObj
}

# ----------------------------------------
# 2) Single-Cell-Domain: Get-TM1CellDomain (via MDX)
# ----------------------------------------

function Get-TM1CellDomain {
    <#
    .SYNOPSIS
        Liest eine einzelne Zelle als TM1CellValue (Domain-Objekt) ueber MDX.

    .DESCRIPTION
        Nutzt ExecuteMDX ueber TM1O.REST, um genau eine Zelle aus einem
        Cube zu lesen. Die Dimensionreihenfolge wird aus dem Cube
        (Get-TM1CubeDomain) ermittelt.

        Unterstuetzte Koordinaten-Formate:

          1) Nur Elemente (reihenfolge-basiert):
             Coordinates = @("ElemDim1","ElemDim2","ElemDim3",...)
             -> Reihenfolge muss exakt der Dimensionsreihenfolge im Cube entsprechen.

          2) "Dimension:Element" (namenbasiert):
             Coordinates = @("Dim1:Elem1","Dim2:Elem2",...)
             -> Reihenfolge egal, Zuordnung per Dimensionsnamen (case-insensitive).

        Rueckgabe:
          TM1CellValue mit Coordinate (TM1CellCoordinate) und Value.
    #>
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

    if (-not $Coordinates -or $Coordinates.Count -eq 0) {
        throw "Get-TM1CellDomain: Es muss mindestens eine Koordinate angegeben werden."
    }

    # 1) Cube-Dimensionen besorgen
    $cube = Get-TM1CubeDomain -BaseUrl $BaseUrl `
                               -Headers $Headers `
                               -CubeName $CubeName `
                               -RetrySettings $RetrySettings `
                               -LogContext $LogContext

    if (-not $cube -or -not $cube.Dimensions -or $cube.Dimensions.Count -eq 0) {
        throw "Get-TM1CellDomain: Cube '$CubeName' liefert keine Dimensionsinformationen."
    }

    $dimOrder = $cube.Dimensions

    # 2) Koordinaten interpretieren
    $hasColon = $false
    foreach ($c in $Coordinates) {
        if ($c -and $c.Contains(":")) {
            $hasColon = $true
            break
        }
    }

    $normalizedCoordsForDomain = @()
    $elementsByDimName         = @{}
    $elementListByPosition     = @()

    if ($hasColon) {
        # Variante: "Dim:Elem"
        foreach ($c in $Coordinates) {
            if ([string]::IsNullOrWhiteSpace($c)) { continue }
            $cTrim = $c.Trim()
            $normalizedCoordsForDomain += $cTrim

            $parts = $cTrim.Split(":", 2)
            if ($parts.Count -ne 2) {
                throw "Get-TM1CellDomain: Mischformat erkannt. Wenn ein ':' verwendet wird, muessen alle Koordinaten im Format 'Dim:Elem' vorliegen. Fehlerhafte Koordinate: '$cTrim'"
            }

            $dimName  = $parts[0].Trim()
            $elemName = $parts[1].Trim()

            if ([string]::IsNullOrWhiteSpace($dimName) -or [string]::IsNullOrWhiteSpace($elemName)) {
                throw "Get-TM1CellDomain: Ungueltige 'Dim:Elem'-Koordinate: '$cTrim'"
            }

            $key = $dimName.ToUpper()
            if ($elementsByDimName.ContainsKey($key)) {
                throw "Get-TM1CellDomain: Dimension '$dimName' wurde mehrfach in den Koordinaten angegeben."
            }
            $elementsByDimName[$key] = $elemName
        }

        foreach ($dim in $dimOrder) {
            $dimKey = $dim.ToUpper()
            if (-not $elementsByDimName.ContainsKey($dimKey)) {
                throw "Get-TM1CellDomain: Fuer Dimension '$dim' wurde kein Element angegeben (Koordinaten im Format 'Dim:Elem' unvollstaendig)."
            }
            $elementListByPosition += $elementsByDimName[$dimKey]
        }
    }
    else {
        # Variante: nur Elemente, Reihenfolge entspricht Cube-Dimensionsreihenfolge
        if ($Coordinates.Count -ne $dimOrder.Count) {
            throw ("Get-TM1CellDomain: Anzahl der Koordinaten ({0}) passt nicht zur Anzahl der Cube-Dimensionen ({1})." -f $Coordinates.Count, $dimOrder.Count)
        }

        foreach ($c in $Coordinates) {
            if ([string]::IsNullOrWhiteSpace($c)) {
                throw "Get-TM1CellDomain: Leere Koordinate in reihenfolge-basiertem Modus ist nicht erlaubt."
            }
            $cTrim = $c.Trim()
            $normalizedCoordsForDomain += $cTrim
            $elementListByPosition     += $cTrim
        }
    }

    # 3) MDX-Tupel bauen: ([Dim1].[Dim1].[Elem1], [Dim2].[Dim2].[Elem2], ...)
    $tupleMembers = @()
    for ($i = 0; $i -lt $dimOrder.Count; $i++) {
        $dim  = $dimOrder[$i]
        $elem = $elementListByPosition[$i]

        # Einfacher Standard: Hierarchie-Name = Dimensionsname
        $member = "[{0}].[{0}].[{1}]" -f $dim, $elem
        $tupleMembers += $member
    }

    $tuple = "(" + ($tupleMembers -join ", ") + ")"

    # MDX braucht einen Set-Ausdruck auf der Achse -> { <tuple> }
    $mdx = "SELECT {$tuple} ON 0 FROM [$CubeName]"

    Write-TM1ODomainLog -LogContext $LogContext -Message ("Domain: MDX fuer Single-Cell: " + $mdx) -Level "Debug"

    if ([string]::IsNullOrWhiteSpace($mdx)) {
        throw "Get-TM1CellDomain: MDX-Statement ist leer, etwas ist bei der MDX-Erstellung schiefgelaufen."
    }

    # 4) MDX ausfuehren
    $mdxResult = Invoke-TM1RestExecuteMDX -BaseUrl $BaseUrl `
                                          -Headers $Headers `
                                          -Mdx $mdx `
                                          -RetrySettings $RetrySettings `
                                          -LogContext $LogContext

    if (-not $mdxResult) {
        Write-TM1ODomainLog -LogContext $LogContext -Message 'Get-TM1CellDomain: MDX-Ergebnis ist NULL oder leer (kein Objekt).' -Level "Detail"
        $coordNull = [TM1CellCoordinate]::new($CubeName, $normalizedCoordsForDomain)
        return [TM1CellValue]::new($coordNull, $null)
    }

    $cellCount = 0
    if ($mdxResult.PSObject.Properties.Name -contains 'Cells' -and $mdxResult.Cells) {
        $cellCount = $mdxResult.Cells.Count
    }

    $logMsgCellCount = 'Get-TM1CellDomain: MDX-Ergebnis enthaelt ' + $cellCount + ' Cell(s).'
    Write-TM1ODomainLog -LogContext $LogContext -Message $logMsgCellCount -Level "Detail"

    if ($cellCount -eq 0) {
        Write-TM1ODomainLog -LogContext $LogContext -Message 'Get-TM1CellDomain: Keine Cells im Ergebnis – wahrscheinlich leere oder nicht vorhandene Kombination.' -Level "Info"
        $coordEmpty = [TM1CellCoordinate]::new($CubeName, $normalizedCoordsForDomain)
        return [TM1CellValue]::new($coordEmpty, $null)
    }

    # 5) Erste Zelle auswerten
    $cell  = $mdxResult.Cells[0]
    $names = $cell.PSObject.Properties.Name

    $value = $null
    if ($names -contains 'Value') {
        $value = $cell.Value
    }
    elseif ($names -contains 'NumericValue') {
        $value = $cell.NumericValue
    }
    elseif ($names -contains 'StringValue') {
        $value = $cell.StringValue
    }
    else {
        # Fallback: gesamtes Cell-Objekt
        $value = $cell
    }

    # Wert fuer Logging aufbereiten
    $valueType = if ($null -ne $value) { $value.GetType().FullName } else { '<null>' }
    $logMsgVal = 'Get-TM1CellDomain: erster Cell-Wert (Typ=' + $valueType + '): ' + [string]$value
    Write-TM1ODomainLog -LogContext $LogContext -Message $logMsgVal -Level "Detail"

    $coordObj = [TM1CellCoordinate]::new($CubeName, $normalizedCoordsForDomain)
    return [TM1CellValue]::new($coordObj, $value)
}

# ----------------------------------------
# 3) Single-Cell-Value: Get-TM1CellValue (nur Wert)
# ----------------------------------------

function Get-TM1CellValue {
    <#
    .SYNOPSIS
        Liefert nur den Wert einer einzelnen TM1-Zelle (Scalar) zurueck.

    .DESCRIPTION
        Thin-Wrapper um Get-TM1CellDomain:

        Koordinaten-Formate wie bei Get-TM1CellDomain:

          1) Reihenfolge-basiert:
             Coordinates = @('ElemDim1','ElemDim2',...)

          2) Namenbasiert:
             Coordinates = @('Dim1:Elem1','Dim2:Elem2',...)
             -> Reihenfolge egal, Zuordnung per Dimensionsnamen.
    #>
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

    if (-not $Coordinates -or $Coordinates.Count -eq 0) {
        throw 'Get-TM1CellValue: Es muss mindestens eine Koordinate angegeben werden.'
    }

    Write-TM1ODomainLog -LogContext $LogContext -Message ('Get-TM1CellValue: lese Wert aus Cube ' + $CubeName + ' ...') -Level "Info"

    $cell = Get-TM1CellDomain -BaseUrl $BaseUrl `
                              -Headers $Headers `
                              -CubeName $CubeName `
                              -Coordinates $Coordinates `
                              -RetrySettings $RetrySettings `
                              -LogContext $LogContext

    if (-not $cell) {
        Write-TM1ODomainLog -LogContext $LogContext -Message 'Get-TM1CellValue: Get-TM1CellDomain hat $null zurueckgegeben.' -Level "Detail"
        return $null
    }

    return $cell.Value
}

# ----------------------------------------
# 4) Multi-Cell-Tabelle: Get-TM1CellTable
# ----------------------------------------

function Get-TM1CellTable {
    <#
    .SYNOPSIS
        Liest mehrere TM1-Zellen und gibt sie als Tabelle (PSCustomObject-Collection) zurueck.

    .DESCRIPTION
        Wrapper um Get-TM1CellDomain fuer mehrere Koordinatensets.

        Erwartet eine Liste von Koordinatenarrays (CoordinateSets), z.B.:

            $coords = @(
                @('Kostenstellen:P_10190','Kostenarten:2S.GV2','Freigabe:Entwicklung','Sichtweise:monatlich','Version:Ist_EUR','Zeit:Dez_25'),
                @('Kostenstellen:P_10200','Kostenarten:2S.GV2','Freigabe:Entwicklung','Sichtweise:monatlich','Version:Ist_EUR','Zeit:Dez_25')
            )

        Rueckgabe:
            Liste von PSCustomObjects mit:
              Index, Cube, Value, und pro Dimension eine Spalte.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [string]$CubeName,

        [Parameter(Mandatory = $true)]
        [object[]]$CoordinateSets,

        [Parameter(Mandatory = $false)]
        [object]$RetrySettings,

        [Parameter(Mandatory = $false)]
        [object]$LogContext
    )

    if (-not $CoordinateSets -or $CoordinateSets.Count -eq 0) {
        throw 'Get-TM1CellTable: Es muss mindestens ein Koordinatenset angegeben werden.'
    }

    Write-TM1ODomainLog -LogContext $LogContext -Message ('Get-TM1CellTable: starte Lesevorgang fuer Cube ' + $CubeName + ' mit ' + $CoordinateSets.Count + ' Koordinatenset(s).') -Level "Info"

    # 1) Cube-Domain einmal laden, um Dimensionsreihenfolge fuer Spaltennamen zu haben
    $cubeDomain = Get-TM1CubeDomain -BaseUrl $BaseUrl `
                                    -Headers $Headers `
                                    -CubeName $CubeName `
                                    -RetrySettings $RetrySettings `
                                    -LogContext $LogContext

    if (-not $cubeDomain -or -not $cubeDomain.Dimensions -or $cubeDomain.Dimensions.Count -eq 0) {
        throw 'Get-TM1CellTable: CubeDomain enthaelt keine Dimensionsinformationen.'
    }

    $dimOrder = $cubeDomain.Dimensions

    $rows   = @()
    $index  = 0

    foreach ($coordSet in $CoordinateSets) {

        # Versuchen, das Koordinatenset als string[] zu interpretieren
        [string[]]$coords = $null

        if ($coordSet -is [string[]]) {
            $coords = $coordSet
        }
        elseif ($coordSet -is [System.Collections.IEnumerable]) {
            $tmp = @()
            foreach ($c in $coordSet) {
                if ($c -ne $null) {
                    $tmp += [string]$c
                }
            }
            $coords = $tmp
        }
        else {
            throw 'Get-TM1CellTable: Ein Eintrag in CoordinateSets ist weder string[] noch IEnumerable.'
        }

        Write-TM1ODomainLog -LogContext $LogContext -Message ('Get-TM1CellTable: lese Zelle fuer Koordinaten-Set Index ' + $index + ' ...') -Level "Detail"

        $cell = Get-TM1CellDomain -BaseUrl $BaseUrl `
                                  -Headers $Headers `
                                  -CubeName $CubeName `
                                  -Coordinates $coords `
                                  -RetrySettings $RetrySettings `
                                  -LogContext $LogContext

        if (-not $cell) {
            Write-TM1ODomainLog -LogContext $LogContext -Message ('Get-TM1CellTable: Get-TM1CellDomain hat $null fuer Index ' + $index + ' zurueckgegeben.') -Level "Detail"
            $index++
            continue
        }

        $coordObj = $cell.Coordinate
        $value    = $cell.Value

        $row = [PSCustomObject]@{
            Index = $index
            Cube  = $coordObj.CubeName
            Value = $value
        }

        if ($coordObj -and $coordObj.Coordinates) {
            for ($iDim = 0; $iDim -lt $dimOrder.Count -and $iDim -lt $coordObj.Coordinates.Count; $iDim++) {
                $dimName  = $dimOrder[$iDim]
                $elemName = $coordObj.Coordinates[$iDim]
                $row | Add-Member -NotePropertyName $dimName -NotePropertyValue $elemName -Force
            }
        }

        $rows += $row
        $index++
    }

    return $rows
}

# ----------------------------------------
# Exporte
# ----------------------------------------

Export-ModuleMember -Function `
    Get-TM1CubeDomain, `
    Get-TM1CellDomain, `
    Get-TM1CellValue, `
    Get-TM1CellTable