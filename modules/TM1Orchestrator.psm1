<#
================================================================================
  TM1 Orchestrator Framework - Module: TM1Orchestrator.psm1 - Version 0.2 (2026-03-13)
================================================================================

 Bestandteil des TM1 Orchestrator Frameworks (TM1O).

 Dieses Modul dient als zentrales Aggregator-Modul fuer das Framework und laedt
 die einzelnen Teilmodule in definierter Reihenfolge.

 Geladene Teilmodule:
   - TM1O.Core.psm1
   - TM1O.REST.psm1
   - TM1O.Domain.psm1

 Spaetere Erweiterungen:
   - TM1O.Git.psm1

 Hinweis:
   Dieses Modul stellt selbst keine eigene Fachlogik bereit, sondern kapselt den
   Import der Teilmodule fuer Runner und CLI.
#>

$moduleRoot = $PSScriptRoot

$coreModulePath   = Join-Path $moduleRoot "TM1O.Core.psm1"
$restModulePath   = Join-Path $moduleRoot "TM1O.REST.psm1"
$domainModulePath = Join-Path $moduleRoot "TM1O.Domain.psm1"
$gitModulePath    = Join-Path $moduleRoot "TM1O.Git.psm1"

foreach ($modulePath in @($coreModulePath, $restModulePath, $domainModulePath, $gitModulePath)) {
    if (-not (Test-Path $modulePath)) {
        throw "TM1O Modul nicht gefunden: $modulePath"
    }
}

Import-Module $coreModulePath   -Force -DisableNameChecking
Import-Module $restModulePath   -Force -DisableNameChecking
Import-Module $domainModulePath -Force -DisableNameChecking
Import-Module $gitModulePath    -Force -DisableNameChecking