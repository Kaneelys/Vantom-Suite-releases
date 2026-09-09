# Diagnose-LagSpikes.ps1

Findet heraus, woher sporadische Lag-Spikes / Ping-Ausschlaege unter Windows 11 kommen.

## Starten

PowerShell im Ordner `scripts` oeffnen und ausfuehren:

```powershell
powershell -ExecutionPolicy Bypass -File .\Diagnose-LagSpikes.ps1
```

Dauerlauf, bis du mit `Strg+C` abbrichst (z.B. waehrend du spielst):

```powershell
powershell -ExecutionPolicy Bypass -File .\Diagnose-LagSpikes.ps1 -DurationMinutes 0
```

Adminrechte sind nicht noetig, liefern aber zusaetzlich die Energiespar-Einstellungen
des Netzwerkadapters.

## Was es macht

Das Skript pingt sekuendlich drei Punkte der Strecke gleichzeitig an:

| Messpunkt | Bedeutung eines Spikes an dieser Stelle |
|---|---|
| Hop 1 – dein Router | Ursache liegt im PC, im Kabel oder im WLAN |
| Hop 2 – erster Provider-Router | Ursache liegt an Router, Hausverkabelung oder Anschluss |
| Ziel – 1.1.1.1 | Ursache liegt beim Provider oder weiter draussen |

Parallel werden CPU-Last, DPC-Zeit (Treiberprobleme), Datentraeger-Warteschlange,
Netzwerkdurchsatz und – im WLAN – die Signalqualitaet aufgezeichnet. Bei jedem Spike
kommt ein Schnappschuss der Top-Prozesse dazu.

Am Ende steht ein Bericht mit Verdachtsdiagnose und konkreten naechsten Schritten.

## Parameter

| Parameter | Standard | Bedeutung |
|---|---|---|
| `-DurationMinutes` | `30` | Messdauer, Nachkommastellen erlaubt. `0` = bis `Strg+C` |
| `-IntervalSeconds` | `1` | Abstand zwischen zwei Messungen |
| `-SpikeThresholdMs` | `150` | Ab wann ein Wert als Spike gilt. Zusaetzlich gilt immer: mehr als das Vierfache des laufenden Normalwerts |
| `-InternetTarget` | `1.1.1.1` | Ziel-IP im Internet |
| `-OutputDirectory` | `Desktop\LagDiag` | Ablageort fuer Bericht und Rohdaten |

## Ergebnisdateien

Pro Lauf entsteht ein Unterordner `Lauf_<Zeitstempel>` mit:

- `bericht.txt` – Auswertung und Fazit
- `messwerte.csv` – jede einzelne Messung
- `spikes.csv` – nur die Spikes, inklusive Top-Prozesse
- `systemzustand.txt` – Adapter, Routen, Treiber und Einstellungen vor der Messung

Die CSV-Dateien werden waehrend des Laufs regelmaessig zwischengespeichert, ein
Absturz oder Neustart kostet also hoechstens die letzte Minute.
