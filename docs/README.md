# TM1 Orchestrator Framework (TM1O)

Version: 0.2  
Stand: 2026-03-13

---

# Überblick

Der **TM1 Orchestrator (TM1O)** ist ein PowerShell-basiertes Automations-Framework für **IBM Planning Analytics / TM1**.

Das Framework stellt eine strukturierte und erweiterbare technische Grundlage bereit für:

- Orchestrierung von **TM1 Prozessen**
- Ausführung von **TM1 Chores**
- REST-basierte **Cube-Abfragen**
- technische **Automatisierung von TM1 Workflows**
- standardisierte **Logging- und Fehlerbehandlung**
- **Environment- und Instanzsteuerung**
- spätere Integration von **Git-basierten Deployment-Workflows**

Der TM1 Orchestrator verfolgt das Ziel, **TM1 Operationen reproduzierbar, transparent und automatisierbar zu machen**.

---

# Hauptziele des Frameworks

Das Framework adressiert typische Herausforderungen im Betrieb von TM1-Systemen:

| Problem | Lösung im Framework |
|--------|---------------------|
| unstrukturierte Prozessausführung | strukturierte Runner |
| fehlende Nachvollziehbarkeit | zentrales Logging |
| direkte REST-Aufrufe im Code | gekapselte REST-Schicht |
| schwer wartbare Scripts | modulare Architektur |
| fehlende Automatisierung | CLI-basierter Einstieg |
| manuelle Ausführung | Batch- und Scheduler-Integration |

---

# Architektur des Frameworks

Das Framework ist bewusst **mehrschichtig aufgebaut**.

```text
Runner Scripts
      |
      v
Domain Layer
      |
      v
REST Layer
      |
      v
TM1 / Planning Analytics Server
```

Zusätzlich stellt ein **Core Modul** gemeinsame Infrastruktur bereit.

```text
              +----------------------+
              |      tm1o.ps1        |
              |  CLI Dispatcher      |
              +----------+-----------+
                         |
                         v
                 Runner Scripts
           (Process / Query / Chore)
                         |
                         v
                 TM1Orchestrator.psm1
                (Aggregator Modul)
                         |
         +---------------+---------------+
         |               |               |
         v               v               v
    TM1O.Core      TM1O.REST        TM1O.Domain
      Logging        REST API        Domain Logic
      Config         TM1 Calls       TM1 Objects
```

---

# Folderstruktur des Frameworks

```text
TM1Orchestrator\
|
+-- config\
|   +-- tm1o.json
|
+-- modules\
|   +-- TM1Orchestrator.psm1
|   +-- TM1O.Core.psm1
|   +-- TM1O.REST.psm1
|   +-- TM1O.Domain.psm1
|
+-- runners\
|   +-- Run_TM1_Process.ps1
|   +-- Run_TM1_Query.ps1
|   +-- Run_TM1_Chore.ps1
|
+-- processchains\
|
+-- logs\
|
+-- scripts\
+-- docs\
+-- gfx\
+-- gui\
|
+-- tm1o.ps1
+-- tm1o.bat
```

---

# Zentrale Komponenten des Frameworks

## CLI Dispatcher (`tm1o.ps1`)

Die Datei **`tm1o.ps1`** stellt den zentralen Einstiegspunkt des Frameworks dar.

Sie implementiert eine **Command Line Interface (CLI)**.

Eine Command Line Interface ist eine textbasierte Schnittstelle zur Interaktion mit Software über Kommandozeilenbefehle.

Das CLI übernimmt folgende Aufgaben:

- zentrale Initialisierung des Frameworks
- Aufruf der Runner Scripts
- Parameterverarbeitung
- konsistenter Einstiegspunkt für Scheduler und Automatisierung

Typische CLI-Aufrufe:

```bash
tm1o process --env DEV --inst KST_2026
tm1o query --env DEV --inst KST_2026
tm1o chore --env DEV --inst KST_2026
```

## Nutzung des TM1O CLI in der Konsole

Damit das **TM1Orchestrator CLI (`tm1o`)** von überall in der Konsole  
(**CMD** oder **PowerShell**) aufgerufen werden kann, muss der Installationsordner des Frameworks in der **Windows PATH Umgebungsvariable** hinterlegt werden.

### Schritt-für-Schritt Anleitung

1. Öffne die **Windows-Suche**
2. Suche nach: **Umgebungsvariablen**
3. Öffne: Umgebungsvariablen für dieses Konto bearbeiten
4. Unter **Benutzervariablen** die Variable auswählen: Path
5. Klicke auf **Bearbeiten**
6. Füge einen neuen Eintrag hinzu, z.B.: C:\Tools\TM1Orchestrator\

### Ergebnis

Nach dem Hinzufügen des Pfades kann das CLI von jedem beliebigen Verzeichnis aus gestartet werden:

```bash
tm1o process --env DEV --inst KST_2026
tm1o query   --env DEV --inst KST_2026
tm1o chore   --env DEV --inst KST_2026
```

Es ist anschließend **kein vollständiger Pfad mehr zum Script erforderlich**.

---

# Konfiguration

Die Frameworkkonfiguration befindet sich in:

```text
config\tm1o.json
```

Dort werden zentrale Einstellungen definiert:

- TM1 Server URLs
- Authentifizierung
- Environment-Definitionen
- Logging-Parameter
- Retry-Einstellungen
- technische Frameworkparameter

---

# Modularchitektur

Alle technischen Funktionen sind in **PowerShell Modulen** gekapselt.

```text
modules\
```

Diese Module werden über das Aggregator-Modul geladen:

```text
TM1Orchestrator.psm1
```

---

# TM1Orchestrator.psm1 (Aggregator)

Das Aggregator-Modul dient als zentrale Importstelle für alle Framework-Module.

Runner laden nur dieses Modul.

Intern werden geladen:

```text
TM1O.Core.psm1
TM1O.REST.psm1
TM1O.Domain.psm1
```

Vorteile:

- Runner müssen keine Einzelmodule kennen
- Erweiterungen können zentral integriert werden
- zukünftige Module (z.B. Git Integration) können einfach ergänzt werden

---

# Modul: TM1O.Core.psm1

Das Core-Modul stellt zentrale Infrastruktur bereit.

## Hauptfunktionen

- Laden der Frameworkkonfiguration
- Logging
- Logrotation
- Retry-Mechanismen
- gemeinsame Utility-Funktionen

---

## Logging

Das Framework verwendet ein abgestuftes Logging-System.

```text
Info
Detail
Debug
```

Steuerung über:

```text
-ConsoleLogLevel
```

Beispiel:

```text
ConsoleLogLevel Info
```

---

## Logverwaltung

Logs werden im Ordner abgelegt:

```text
logs\
```

Zusätzlich existiert ein Archiv:

```text
logs\archive\
```

Die Anzahl der Logdateien wird über **maxKeepLogs** gesteuert.

---

# Modul: TM1O.REST.psm1

Dieses Modul kapselt sämtliche REST-Kommunikation mit dem TM1 Server.

Runner greifen **nicht direkt auf REST-Endpunkte zu**.

Die REST-Logik ist vollständig hier implementiert.

## Aufgaben des REST-Moduls

- Aufbau der REST-Verbindung
- Authentifizierung
- Prozessausführung
- Chore-Ausführung
- Thread-Statusabfragen
- Cube-Abfragen
- konsistente Rückgabeobjekte

## Wichtige Designprinzipien

- REST-Aufrufe sind zentral gekapselt
- Runner kennen keine REST-Endpunkte
- Rückgaben erfolgen als `PSCustomObject`
- Fehlerbehandlung ist zentralisiert

---

# Modul: TM1O.Domain.psm1

Dieses Modul stellt die **fachliche Abstraktionsebene** über den REST-Aufrufen dar.

Domainlogik arbeitet mit **TM1-Objekten** statt REST-JSON.

## Domain-Klassen

### TM1Cube

Repräsentiert einen Cube.

Eigenschaften:

```text
Name
Dimensions
```

### TM1CellCoordinate

Repräsentiert eine Zellenkoordinate.

Eigenschaften:

```text
CubeName
Coordinates
```

### TM1CellValue

Repräsentiert einen Zellwert.

Eigenschaften:

```text
Coordinate
Value
```

## Domain-Funktionen

```text
Get-TM1CubeDomain
Get-TM1CellDomain
Get-TM1CellValue
Get-TM1CellTable
```

---

# Runner Scripts

Runner stellen konkrete Operationen dar.

Sie befinden sich im Ordner:

```text
runners\
```

---

# Run_TM1_Process.ps1

Dieser Runner orchestriert die Ausführung von **TM1 Prozessen**.

Typischer Einsatz:

- ETL
- Datenimport
- Berechnungen
- Prozessketten

## Beispielaufruf

```bash
powershell -ExecutionPolicy Bypass -File "runners\Run_TM1_Process.ps1" -Env "DEV" -Inst "KST_2026"
```

## Modi

### Execute

Normale Ausführung der ProcessChain.

### DryRun

Simulation ohne tatsächliche Ausführung.

### ValidateOnly

Nur Prüfung, ob Prozesse existieren.

---

# Run_TM1_Query.ps1

Der Query Runner ermöglicht REST-basierte Cube-Abfragen.

Unterstützt:

```text
CubeInfo
CellValue
CellTable
```

## CubeInfo

Liefert Metadaten eines Cubes.

```text
-Mode CubeInfo
```

## CellValue

Liest eine einzelne Zelle.

Beispiel:

```bash
powershell -ExecutionPolicy Bypass -File "Run_TM1_Query.ps1" -Env DEV -Inst KST_2026 -Mode CellValue -CubeName KST -Coordinates "Kostenstellen:P_10190","Kostenarten:2S.GV2","Freigabe:Entwicklung","Sichtweise:monatlich","Version:Ist_EUR","Zeit:Dez_25"
```

## CellTable

Liest mehrere Zellen gleichzeitig.

CMD-kompatible Variante:

```text
-CoordinateSets "Set1;Set2"
```

Beispiel:

```bash
powershell -ExecutionPolicy Bypass -File "Run_TM1_Query.ps1" -Env DEV -Inst KST_2026 -Mode CellTable -CubeName KST -CoordinateSets "P_10190,2S.GV2,Entwicklung,monatlich,Ist_EUR,Okt_25;P_10190,2S.GV2,Entwicklung,monatlich,Ist_EUR,Nov_25"
```

### Unterstützte Eingabeformate für Koordinaten

#### 1. Single Cell (`CellValue`)

**A) Format ohne Dimensionsnamen**

```powershell
-Coordinates "P_10190","2S.GV2","Entwicklung","monatlich","Ist_EUR","Dez_25"
```

**B) Format mit Dimensionsnamen**

```powershell
-Coordinates `
    "Kostenstellen:P_10190", `
    "Kostenarten:2S.GV2", `
    "Freigabe:Entwicklung", `
    "Sichtweise:monatlich", `
    "Version:Ist_EUR", `
    "Zeit:Dez_25"
```

Beide Varianten werden automatisch normalisiert.

#### 2. Multi Cell (`CellTable`)

Es werden mehrere Koordinaten-Sets akzeptiert.

**A) Ein String mit semikolon-getrennten Sets (empfohlen für CMD/BAT)**

```powershell
-CoordinateSets "P_10190,2S.GV2,Entwicklung,monatlich,Ist_EUR,Okt_25;P_10190,2S.GV2,Entwicklung,monatlich,Ist_EUR,Nov_25"
```

Wichtig: Die Reihenfolge der Dimensionen muss zwingend der Reihenfolge im Cube entsprechen, wenn keine Dimensionsnamen angegeben werden.

Mit Dimensionsnamen:

```powershell
-CoordinateSets "Kostenstellen:P_10190,Kostenarten:2S.GV2,Freigabe:Entwicklung,Sichtweise:monatlich,Version:Ist_EUR,Zeit:Okt_25;Kostenstellen:P_10190,Kostenarten:2S.GV2,Freigabe:Entwicklung,Sichtweise:monatlich,Version:Ist_EUR,Zeit:Nov_25"
```

**B) Mehrere Strings, jeweils ein Set (nur PowerShell)**

```powershell
-CoordinateSets `
    "P_10190,2S.GV2,Entwicklung,monatlich,Ist_EUR,Okt_25" `
    "P_10190,2S.GV2,Entwicklung,monatlich,Ist_EUR,Nov_25"
```

oder

```powershell
-CoordinateSets `
    "Kostenstellen:P_10190,Kostenarten:2S.GV2,Freigabe:Entwicklung,Sichtweise:monatlich,Version:Ist_EUR,Zeit:Okt_25" `
    "Kostenstellen:P_10190,Kostenarten:2S.GV2,Freigabe:Entwicklung,Sichtweise:monatlich,Version:Ist_EUR,Zeit:Nov_25"
```

**C) PowerShell-Array von Array-Sets (PS-Skripte, nie aus CMD/BAT)**

```powershell
-CoordinateSets @(
    @("P_10190","2S.GV2","Entwicklung","monatlich","Ist_EUR","Okt_25"),
    @("P_10190","2S.GV2","Entwicklung","monatlich","Ist_EUR","Nov_25")
)
```

### Wichtiger Hinweis für CMD / Batch

CMD trennt Parameter ausschließlich nach Leerzeichen.  
Darum muss bei `CellTable` aus einem BAT-File folgendes Format verwendet werden:

```text
EIN EINZIGER STRING:
-CoordinateSets "Set1;Set2"
```

Alle anderen Varianten funktionieren nur in interaktiver PowerShell, nicht jedoch in `.bat`- oder Windows-Scheduler-Umgebungen.

---

# Run_TM1_Chore.ps1

Dieser Runner startet **TM1 Chores**.

## Beispielaufruf

```bash
powershell -ExecutionPolicy Bypass -File "runners\Run_TM1_Chore.ps1" -Env "DEV" -Inst "KST_2026" -ChoreName "J_20_Gesamtprozess"
```

## Option

```text
-IgnoreDisabled
```

Erlaubt die Ausführung auch dann, wenn der Chore deaktiviert ist.

Der Parameter `-IgnoreDisabled` führt den Chore auch dann aus, wenn er in TM1 als "disabled" markiert ist. Normalerweise würde der Runner in diesem Fall die Ausführung verweigern, um unbeabsichtigte Starts zu verhindern. Mit `-IgnoreDisabled` wird diese Sicherheitsprüfung umgangen.

Erfolgsstates:

```text
FINISHED
FINISHED_UNOBSERVED
```

---

# Logging

Alle Runner nutzen das zentrale Logging des Core-Moduls.

Logs werden gespeichert in:

```text
logs\
```

Typische Inhalte:

- Startzeit
- Environment
- Instanz
- ausgeführte Operation
- REST-Rückgaben
- Fehlerstatus
- Summary

---

# Designprinzipien des Frameworks

Das Framework folgt bewusst mehreren Architekturprinzipien.

## Trennung von Verantwortlichkeiten

```text
Runner -> Orchestrierung
Domain -> Fachlogik
REST   -> API-Kommunikation
Core   -> Infrastruktur
```

## Erweiterbarkeit

Neue Module können jederzeit ergänzt werden.

Beispiel zukünftige Erweiterungen:

```text
TM1O.Git.psm1
TM1O.Deployment.psm1
TM1O.Monitoring.psm1
```

## Zentrale Konfiguration

Alle technischen Parameter befinden sich in:

```text
config\tm1o.json
```

## Standardisierte Loggingstruktur

Alle Runner verwenden identische Logging-Mechanismen.

---

# Typische Einsatzszenarien

Der TM1 Orchestrator kann z.B. verwendet werden für:

- automatisierte TM1 ETL-Pipelines
- Batch-Verarbeitung von Daten
- Monitoring von TM1 Prozessen
- REST-basierte Cube-Abfragen
- automatisierte Ausführung von Chores
- technische Orchestrierung komplexer TM1 Workflows

---

# Geplante Erweiterungen

Geplante Weiterentwicklungen des Frameworks:

- Git-Integration
- Deployment-Automatisierung
- automatische Build-Pipelines
- erweitertes Monitoring
- GUI-Integration
- Integration mit CI/CD-Pipelines

---

# Zusammenfassung

Der **TM1 Orchestrator** ist ein strukturiertes Framework zur Automatisierung von IBM Planning Analytics / TM1.

Es bietet:

- klare Architektur
- modulare Erweiterbarkeit
- standardisierte REST-Kommunikation
- konsistentes Logging
- automatisierte Orchestrierung von TM1 Operationen

Damit stellt das Framework eine stabile technische Grundlage für professionelle TM1-Automatisierung dar.


---

# Konfiguration / Einrichtung

Copy the template configuration and adjust it to your environment.

config/git-repositories.template.json
        ↓
config/git-repositories.json



config/tm1o.template.json
        ↓
config/tm1o.json