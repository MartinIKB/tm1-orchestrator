TM1 ORCHESTRATOR
Automate your TM1 Workflows

Der TM1 Orchestrator ist ein PowerShell-basiertes Framework zur automatisierten Ausführung von TM1-Prozessketten über die IBM Planning Analytics REST API.
Er unterstützt Health Checks, Retry-Mechanismen, Logging, Logrotation, Archivierung und einen komfortablen CLI-Wrapper (tm1o).

🔧 INHALT

Übersicht
Features
Ordnerstruktur
Installation
Konfiguration (config.json)
Prozessketten (processchains)
Ausführung über CLI (tm1o)
Direkter Scriptaufruf (Run_TM1_Process.ps1)
RunModes
Logging & Logrotation
Exitcodes
Troubleshooting

1) ÜBERSICHT
Der TM1 Orchestrator ermöglicht:
- Ausführung von TM1 Prozessen über die REST API
- Ausführung mehrerer Prozesse als Kette
- Health Check der TM1 Instanz
- Wiederholmechanismus (Retry) bei Netzwerkfehlern
- DryRun & ValidateOnly Modi
- Vollständiges Logging inkl. Archivierung
- CLI-Wrapper für benutzerfreundlichen Aufruf
- Saubere Exitcodes für Scheduler/Batchverarbeitung

2) FEATURES
Feature | Beschreibung
REST-basierte Prozessausführung | Führt TM1 TurboIntegrator-Prozesse via REST API aus
Prozessketten | Beliebig viele Prozesse sequenziell
Health Check | Prüfung, ob TM1 Instanz erreichbar ist
Retry-Mechanismus | Wiederholt REST-Calls bei Timeout/Netzproblemen
3 RunModes | Execute, DryRun, ValidateOnly
Farbiges Logging | Farbliche Hervorhebung im Terminal
Log-Rotation | Automatische Archivierung alter Logs
CSV-Archiv | Dauerhafte Zusammenfassung aller Runs
CLI-Wrapper | Einfacher Aufruf wie: tm1o DEV KST_2026 run

3) ORDNERSTRUKTUR
TM1-Orchestrator/
├── Run_TM1_Process.ps1
├── tm1o.ps1
├── tm1o.bat
├── config.json
├── logs/
│   └── archive/
└── processchains/
    ├── DEV_KST_2026.json
    ├── TEST_KST_2026.json
    └── PROD_KST_2026.json

4) INSTALLATION
- Projekt herunterladen
- config.json anpassen
- tm1o.bat zur PATH-Variable hinzufügen

5) KONFIGURATION (config.json)
(Beispiel)
{
  "maxKeepLogs": 10,
  "RetrySettings": {
    "MaxRetries": 3,
    "RetryDelaySec": 10,
    "TimeoutSec": 600
  },
  "Environments": [
    {
      "Name": "DEV",
      "CAMNamespace": "LDAP",
      "ApiKey": "***",
      "Instances": [
        {
          "Name": "KST_2026",
          "TM1RestBase": "https://ikbdev.planning-analytics.cloud.ibm.com/tm1/api/KST_2026/api/v1"
        }
      ]
    }
  ]
}

6) PROZESSKETTEN
Beispiel DEV_KST_2026.json:
{
  "ProcessChain": [
    { "Name": "S_21_Kostenarten_Buchungen", "Parameters": [] },
    { "Name": "D_10_DTL_KST_BELEGE", "Parameters": [] }
  ]
}

7) CLI-NUTZUNG (tm1o)
tm1o <environment> <instance> <mode>

Beispiele:
tm1o DEV KST_2026 run
tm1o DEV KST_2026 dryrun
tm1o DEV KST_2026 validate

8) DIREKTER AUFRUF
Execute:
powershell -File Run_TM1_Process.ps1 -Environment DEV -InstanceName KST_2026

DryRun:
powershell -File Run_TM1_Process.ps1 -Environment DEV -InstanceName KST_2026 -DryRun

ValidateOnly:
powershell -File Run_TM1_Process.ps1 -Environment DEV -InstanceName KST_2026 -ValidateOnly

9) RUNMODES
Execute – komplette Ausführung
DryRun – nur Vorschau
ValidateOnly – Existenzprüfung

10) LOGGING
Logs: /logs/
Archvie: /logs/archive/*.csv

11) EXITCODES
0 = Erfolg
2 = Config-Fehler
3 = HealthCheck fehlgeschlagen
4 = ValidateOnly Prozess fehlt
5 = Prozesskette fehlgeschlagen

12) TROUBLESHOOTING
401 → API-Key/Namespace falsch
404 → Prozessname falsch
HealthCheck failed → Server nicht erreichbar
Logrotation → Schreibrechte prüfen
