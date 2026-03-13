
powershell -ExecutionPolicy Bypass -File "%~dp0Run_TM1_Query.ps1" -Env "DEV" -Inst "KST_2026" -Mode CellTable -CubeName "KST" -CoordinateSets "Entwicklung,2S.GV2,P_10190,monatlich,Okt_25,Ist_EUR;Entwicklung,2S.GV2,P_10190,monatlich,Nov_25,Ist_EUR"

pause