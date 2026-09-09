#Requires -Version 5.1
<#
.SYNOPSIS
    Findet heraus, woher zufaellige Lag-Spikes / Ping-Ausschlaege unter Windows 11 kommen.

.DESCRIPTION
    Das Skript misst gleichzeitig die Latenz zu drei Punkten der Strecke:

        Hop 1  = dein Router / Default-Gateway   -> alles davor ist "bei dir im PC / Kabel / WLAN"
        Hop 2  = erster Router deines Providers  -> alles davor ist "bei dir im Haus / Leitung"
        Ziel   = 1.1.1.1 im Internet             -> alles davor ist "Provider / Peering"

    Durch den Vergleich der drei Werte laesst sich ein Spike eindeutig zuordnen:
    Wenn schon der Ping zum eigenen Router 800 ms macht, liegt es NICHT am Internet.

    Parallel dazu werden pro Sekunde CPU-Last, DPC-/Interrupt-Zeit (Treiberprobleme),
    Festplatten-Warteschlange und der aktuelle Netzwerkdurchsatz aufgezeichnet.
    Bei jedem Spike wird zusaetzlich ein Schnappschuss der Top-Prozesse gespeichert.

    Am Ende erstellt das Skript einen Bericht mit einer Verdachtsdiagnose und
    konkreten naechsten Schritten. Alle Rohdaten landen als CSV im Ausgabeordner.

.PARAMETER DurationMinutes
    Messdauer in Minuten, Nachkommastellen erlaubt (z.B. 0.5).
    0 = laeuft bis Strg+C. Standard: 30.

.PARAMETER IntervalSeconds
    Abstand zwischen zwei Messungen. Standard: 1.

.PARAMETER SpikeThresholdMs
    Ab wie vielen Millisekunden ein Wert als Spike gilt. Standard: 150.
    Zusaetzlich gilt immer: mehr als das 4-fache des laufenden Normalwerts.

.PARAMETER InternetTarget
    Ziel-IP im Internet. Standard: 1.1.1.1 (Cloudflare, antwortet zuverlaessig auf Ping).

.PARAMETER OutputDirectory
    Ordner fuer Bericht und CSV-Dateien. Standard: Desktop\LagDiag.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Diagnose-LagSpikes.ps1

.EXAMPLE
    # Dauerlauf, bis du mit Strg+C abbrichst (z.B. waehrend du zockst):
    powershell -ExecutionPolicy Bypass -File .\Diagnose-LagSpikes.ps1 -DurationMinutes 0

.NOTES
    Laeuft ohne Adminrechte. Mit Adminrechten kommen zusaetzlich die
    Energiespar-Einstellungen des Netzwerkadapters mit in den Bericht.
    Strg+C bricht sauber ab, der Bericht wird trotzdem geschrieben.
#>
[CmdletBinding()]
param(
    [double] $DurationMinutes   = 30,
    [double] $IntervalSeconds   = 1,
    [int]    $SpikeThresholdMs  = 150,
    [string] $InternetTarget    = '1.1.1.1',
    [string] $OutputDirectory   = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'LagDiag')
)

# ----------------------------------------------------------------------------------
# Grundgeruest
# ----------------------------------------------------------------------------------

$ProgressPreference = 'SilentlyContinue'
$startedAt = Get-Date
$stamp     = $startedAt.ToString('yyyy-MM-dd_HH-mm-ss')
$runDir    = Join-Path $OutputDirectory "Lauf_$stamp"
$null      = New-Item -ItemType Directory -Path $runDir -Force

$samplesCsv  = Join-Path $runDir 'messwerte.csv'
$spikesCsv   = Join-Path $runDir 'spikes.csv'
$reportTxt   = Join-Path $runDir 'bericht.txt'
$baselineTxt = Join-Path $runDir 'systemzustand.txt'

$script:ReportLines = New-Object System.Collections.Generic.List[string]

function Add-Report {
    param([string]$Text = '', [ConsoleColor]$Color = 'Gray', [switch]$Quiet)
    $script:ReportLines.Add($Text) | Out-Null
    if (-not $Quiet) { Write-Host $Text -ForegroundColor $Color }
}

function Add-Heading {
    param([string]$Text)
    Add-Report ''
    Add-Report ('=' * 78) -Color DarkGray
    Add-Report "  $Text" -Color Cyan
    Add-Report ('=' * 78) -Color DarkGray
}

function Get-Percentile {
    param([double[]]$Values, [double]$P)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $idx = [int][math]::Ceiling(($P / 100.0) * $sorted.Count) - 1
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -ge $sorted.Count) { $idx = $sorted.Count - 1 }
    return [double]$sorted[$idx]
}

function Get-Median {
    param([double[]]$Values)
    return Get-Percentile -Values $Values -P 50
}

$isAdmin = $false
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
                [Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

Clear-Host
Write-Host ''
Write-Host '  Lag-Spike-Diagnose fuer Windows 11' -ForegroundColor White
Write-Host '  ----------------------------------' -ForegroundColor DarkGray
Write-Host "  Ausgabeordner : $runDir" -ForegroundColor DarkGray
if (-not $isAdmin) {
    Write-Host '  Hinweis       : ohne Adminrechte gestartet - Adapter-Energieeinstellungen werden uebersprungen.' -ForegroundColor DarkYellow
}
Write-Host ''

# ----------------------------------------------------------------------------------
# 1) Systemzustand aufnehmen (einmalig, vor der Messung)
# ----------------------------------------------------------------------------------

Add-Heading 'SCHRITT 1 - Systemzustand'

$baseFindings = New-Object System.Collections.Generic.List[string]

# --- aktive Adapter -----------------------------------------------------------
$upAdapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -eq 'Up' })

Add-Report 'Aktive Netzwerkadapter:'
foreach ($a in $upAdapters) {
    Add-Report ("  - {0,-28} {1,-10} {2}" -f $a.Name, $a.LinkSpeed, $a.InterfaceDescription)
}
if ($upAdapters.Count -eq 0) {
    Add-Report '  (keine physischen Adapter im Status "Up" gefunden)' -Color Yellow
}

# Mehrere Default-Routen gleichzeitig = Windows kann Traffic hin- und herschieben.
# Windows waehlt die Route mit der KLEINSTEN Summe aus Route- und
# Interface-Metrik. Adapter, die nicht verbunden sind, koennen eine
# verwaiste Standardroute hinterlassen - die zaehlt nicht mit.
$defaultRoutes = @(
    Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | ForEach-Object {
        $ad = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue
        [pscustomobject]@{
            NextHop        = $_.NextHop
            InterfaceIndex = $_.InterfaceIndex
            GesamtMetrik   = $_.RouteMetric + $_.InterfaceMetric
            Adapter        = $ad
            IstVerbunden   = ($ad -and $ad.Status -eq 'Up')
        }
    } | Sort-Object @{ Expression = { -not $_.IstVerbunden } }, GesamtMetrik
)

Add-Report ''
Add-Report 'Standardrouten (Weg ins Internet):'
foreach ($r in $defaultRoutes) {
    Add-Report ("  - via {0,-16} ueber {1,-24} Metrik {2,-5} {3}" -f `
        $r.NextHop, `
        $(if ($r.Adapter) { $r.Adapter.Name } else { "Index $($r.InterfaceIndex)" }), `
        $r.GesamtMetrik, `
        $(if ($r.IstVerbunden) { 'verbunden' } else { 'NICHT verbunden (verwaiste Route)' }))
}

# Nur tatsaechlich verbundene Wege zaehlen fuer die Warnung.
$liveRoutes     = @($defaultRoutes | Where-Object { $_.IstVerbunden })
$liveIfIndexes  = @($liveRoutes | Select-Object -ExpandProperty InterfaceIndex -Unique)
$staleRoutes    = @($defaultRoutes | Where-Object { -not $_.IstVerbunden })

if ($liveIfIndexes.Count -gt 1) {
    $baseFindings.Add('WICHTIG: Es sind mehrere Wege ins Internet gleichzeitig verbunden (z.B. LAN UND WLAN). Windows kann Verbindungen zwischen beiden umschalten - das erzeugt genau solche sporadischen Aussetzer. Deaktiviere den Adapter, den du nicht benutzt.') | Out-Null
}
if ($staleRoutes.Count -gt 0) {
    Add-Report ''
    Add-Report ("Hinweis: {0} verwaiste Standardroute(n) von nicht verbundenen Adaptern. Das ist normal und stoert den Datenverkehr nicht." -f $staleRoutes.Count) -Color DarkGray
}

# --- Gateway und Hop 2 ermitteln ----------------------------------------------
$gateway = @($defaultRoutes | Where-Object { $_.IstVerbunden } | Select-Object -First 1).NextHop
if (-not $gateway) { $gateway = ($defaultRoutes | Select-Object -First 1).NextHop }
if (-not $gateway -or $gateway -eq '0.0.0.0') { $gateway = $null }

function Get-HopAddress {
    param([string]$Target, [int]$Ttl)
    try {
        $p    = New-Object System.Net.NetworkInformation.Ping
        $opts = New-Object System.Net.NetworkInformation.PingOptions($Ttl, $true)
        $buf  = New-Object byte[] 32
        $r    = $p.Send($Target, 2000, $buf, $opts)
        $p.Dispose()
        if ($r.Address -and $r.Address.ToString() -ne '0.0.0.0') { return $r.Address.ToString() }
    } catch { }
    return $null
}

Add-Report ''
Add-Report 'Messpunkte werden ermittelt ...'
$hop2 = Get-HopAddress -Target $InternetTarget -Ttl 2
if ($hop2 -eq $gateway) { $hop2 = Get-HopAddress -Target $InternetTarget -Ttl 3 }

function Test-PingTarget {
    # Manche Router und fast alle Provider-Hops beantworten Pings nur teilweise
    # oder gar nicht. Solche Ziele muessen raus, sonst meldet das Skript
    # dauerhaft Fehlalarme statt echter Spikes.
    param([string]$Target)
    if (-not $Target) { return $false }
    try {
        $p = New-Object System.Net.NetworkInformation.Ping
        $ok = 0
        for ($i = 0; $i -lt 3; $i++) {
            $r = $p.Send($Target, 1500)
            if ($r.Status -eq 'Success') { $ok++ }
            Start-Sleep -Milliseconds 200
        }
        $p.Dispose()
        return ($ok -ge 2)
    } catch { return $false }
}

if ($gateway -and -not (Test-PingTarget $gateway)) {
    $baseFindings.Add(("Der Router ({0}) beantwortet keine Pings. Damit laesst sich nicht sicher trennen, ob ein Spike im PC oder im Internet entsteht. In der Router-Oberflaeche ggf. 'Ping-Antwort' aktivieren." -f $gateway)) | Out-Null
    $gateway = $null
}
if ($hop2 -and -not (Test-PingTarget $hop2)) { $hop2 = $null }

Add-Report ("  Hop 1 (dein Router)     : {0}" -f $(if ($gateway) { $gateway } else { 'nicht messbar' }))
Add-Report ("  Hop 2 (Provider)        : {0}" -f $(if ($hop2)    { $hop2 }    else { 'antwortet nicht auf Ping - wird uebersprungen (normal)' }))
Add-Report ("  Ziel  (Internet)        : {0}" -f $InternetTarget)

if (-not $gateway) {
    $baseFindings.Add('Kein Default-Gateway gefunden - die Trennung "lokal vs. Internet" ist damit nur eingeschraenkt moeglich.') | Out-Null
}

# --- Adapter, ueber den der Traffic laeuft ------------------------------------
$activeRoute   = $defaultRoutes | Where-Object { $_.IstVerbunden } | Select-Object -First 1
if (-not $activeRoute) { $activeRoute = $defaultRoutes | Select-Object -First 1 }
$activeAdapter = $activeRoute.Adapter
$isWifi = $false
if ($activeAdapter) {
    $isWifi = ($activeAdapter.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11') -or
              ($activeAdapter.MediaType -match '802\.11')
    Add-Report ''
    Add-Report ("Genutzter Adapter: {0} ({1})" -f $activeAdapter.Name, $activeAdapter.InterfaceDescription)
    Add-Report ("  Verbindung : {0}" -f $activeAdapter.LinkSpeed)
    Add-Report ("  Treiber    : {0} vom {1}" -f $activeAdapter.DriverVersion, $activeAdapter.DriverDate)

    # 100 Mbit auf einem Gigabit-Port ist fast immer ein defektes/schlechtes Kabel.
    if (-not $isWifi -and $activeAdapter.LinkSpeed -match '^(10|100) Mbps') {
        $baseFindings.Add(("Die LAN-Verbindung laeuft nur mit {0}. Bei modernen Geraeten deutet das auf ein beschaedigtes Kabel oder einen defekten Port hin - eine typische Ursache fuer sporadische Aussetzer. Anderes Kabel / anderen Port testen." -f $activeAdapter.LinkSpeed)) | Out-Null
    }

    # Treiberalter
    try {
        $drvDate = [datetime]$activeAdapter.DriverDate
        if ($drvDate -lt (Get-Date).AddYears(-3)) {
            $baseFindings.Add(("Der Netzwerktreiber ist von {0} und damit recht alt. Aktuellen Treiber direkt beim Hersteller des Mainboards/Notebooks holen (nicht ueber Windows Update)." -f $drvDate.ToString('yyyy-MM-dd'))) | Out-Null
        }
    } catch { }
}

# --- Energiesparen am Adapter (haeufigste Ursache fuer "geht kurz weg") -------
if ($isAdmin -and $activeAdapter) {
    try {
        $pm = Get-NetAdapterPowerManagement -Name $activeAdapter.Name -ErrorAction Stop
        Add-Report ''
        Add-Report ("Energieverwaltung des Adapters: SelectiveSuspend={0}, WakeOnMagicPacket={1}" -f $pm.SelectiveSuspend, $pm.WakeOnMagicPacket)
        if ($pm.SelectiveSuspend -eq 'Enabled') {
            $baseFindings.Add('Am Netzwerkadapter ist "Selective Suspend" aktiv. Windows darf den Adapter dann schlafen legen - klassische Ursache fuer kurze Haenger. Geraete-Manager > Adapter > Energieverwaltung > Haken bei "Computer kann das Geraet ausschalten" entfernen.') | Out-Null
        }
    } catch { }
}

# Erweiterte Adaptereigenschaften, die bekanntermassen Latenz verursachen
try {
    $advProps = Get-NetAdapterAdvancedProperty -Name $activeAdapter.Name -ErrorAction Stop
    $suspects = $advProps | Where-Object {
        $_.DisplayName -match 'Energy Efficient|Green Ethernet|Energieeffizient|EEE|Interrupt Moderation|Flow Control|Power Saving'
    }
    if ($suspects) {
        Add-Report ''
        Add-Report 'Latenzrelevante Adaptereinstellungen:'
        foreach ($s in $suspects) {
            Add-Report ("  - {0,-42} = {1}" -f $s.DisplayName, $s.DisplayValue)
        }
        $eee = $suspects | Where-Object { $_.DisplayName -match 'Energy Efficient|Green Ethernet|Energieeffizient|EEE' -and $_.DisplayValue -match 'On|Ein|Enabled|Aktiv' }
        if ($eee) {
            $baseFindings.Add('"Energy Efficient Ethernet" / "Green Ethernet" ist eingeschaltet. Das legt den Link im Leerlauf schlafen und verursacht messbare Aussetzer. Im Geraete-Manager unter Erweitert auf "Aus" stellen.') | Out-Null
        }
    }
} catch { }

# --- WLAN-Details -------------------------------------------------------------
$wlanIsUp = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
              Where-Object { $_.Status -eq 'Up' -and ($_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11') }).Count -gt 0
if ($wlanIsUp) {
    Add-Report ''
    Add-Report 'WLAN-Status:'
    $wlan = & netsh wlan show interfaces 2>$null
    foreach ($line in $wlan) {
        if ($line -match '^\s*(SSID|Signal|Radiotyp|Radio type|Kanal|Channel|Empfangsrate|Receive rate|Sendrate|Transmit rate|Authentifizierung|Authentication)\s*:\s*(.+)$') {
            Add-Report ("  {0}" -f $line.Trim())
        }
    }
    if (-not $isWifi) {
        $baseFindings.Add('Das WLAN ist noch aktiv, obwohl der Traffic ueber LAN laeuft. Zum Testen das WLAN komplett deaktivieren - so faellt eine Ursache sicher weg.') | Out-Null
    }
}

# --- Energieplan --------------------------------------------------------------
try {
    $plan = (& powercfg /getactivescheme) -join ' '
    Add-Report ''
    Add-Report ("Energieplan: {0}" -f $plan.Trim())
    if ($plan -match 'Energiesparmodus|Power saver') {
        $baseFindings.Add('Aktiver Energieplan ist "Energiesparmodus". Zum Testen auf "Ausbalanciert" oder "Hoechstleistung" stellen.') | Out-Null
    }
} catch { }

# --- Delivery Optimization / Windows Update laufen im Hintergrund? -----------
try {
    $doSvc = Get-Service -Name DoSvc -ErrorAction SilentlyContinue
    $wuSvc = Get-Service -Name wuauserv -ErrorAction SilentlyContinue
    Add-Report ''
    Add-Report ("Windows Update: {0} | Uebermittlungsoptimierung: {1}" -f `
        $(if ($wuSvc) { $wuSvc.Status } else { 'n/a' }), `
        $(if ($doSvc) { $doSvc.Status } else { 'n/a' }))
} catch { }

# --- bekannte Stoerenfriede unter den laufenden Prozessen ---------------------
$knownNoisy = 'Killer|SmartByte|cFosSpeed|Bonjour|NordVPN|ExpressVPN|Hamachi|OpenVPN|WireGuard|Nahimic|Razer Synapse|iCUE|Norton|McAfee|Avast|AVG|Kaspersky|Malwarebytes'
$noisyFound = @(Get-Process -ErrorAction SilentlyContinue |
                Where-Object { $_.ProcessName -match $knownNoisy -or $_.Description -match $knownNoisy } |
                Select-Object -ExpandProperty ProcessName -Unique)
if ($noisyFound) {
    Add-Report ''
    Add-Report ("Bekannte Kandidaten fuer Netzwerkprobleme laufen: {0}" -f ($noisyFound -join ', ')) -Color Yellow
    $baseFindings.Add(("Folgende Programme sind bekannt dafuer, Netzwerklatenz zu verursachen und laufen gerade: {0}. Zum Testen einzeln beenden." -f ($noisyFound -join ', '))) | Out-Null
}

if ($baseFindings.Count -gt 0) {
    Add-Report ''
    Add-Report 'Auffaelligkeiten schon vor der Messung:' -Color Yellow
    foreach ($f in $baseFindings) { Add-Report ("  ! $f") -Color Yellow }
}

$script:ReportLines -join "`r`n" | Out-File -FilePath $baselineTxt -Encoding UTF8

# ----------------------------------------------------------------------------------
# 2) Messung
# ----------------------------------------------------------------------------------

Add-Heading 'SCHRITT 2 - Messung laeuft'

if ($DurationMinutes -gt 0) {
    Add-Report ("Dauer: {0:0.##} Minuten (Abbruch jederzeit mit Strg+C - der Bericht wird trotzdem erstellt)." -f $DurationMinutes)
} else {
    Add-Report 'Dauer: unbegrenzt - mit Strg+C beenden, dann wird der Bericht erstellt.'
}
Add-Report 'Tipp: Genau das machen, bei dem die Lags auftreten (zocken, Call, Stream).'
Add-Report ''

$endTime = if ($DurationMinutes -gt 0) { $startedAt.AddMinutes($DurationMinutes) } else { [datetime]::MaxValue }

$samples = New-Object System.Collections.Generic.List[object]
$spikes  = New-Object System.Collections.Generic.List[object]

$pingTimeout = 2000
$pingBuffer  = New-Object byte[] 32
$pGw  = New-Object System.Net.NetworkInformation.Ping
$pH2  = New-Object System.Net.NetworkInformation.Ping
$pNet = New-Object System.Net.NetworkInformation.Ping

$prevStats     = $null
$prevStatsTime = $null
$recentGw      = New-Object System.Collections.Generic.List[double]
$recentH2      = New-Object System.Collections.Generic.List[double]
$recentNet     = New-Object System.Collections.Generic.List[double]
$lastSnapshot  = [datetime]::MinValue
$lastStatusOut = [datetime]::MinValue
$tick          = 0

function Invoke-PingValue {
    param($Pinger, [string]$Target)
    # Rueckgabe: Millisekunden, -1 = keine Antwort (Verlust), $null = kein Ziel
    if (-not $Target) { return $null }
    try {
        $t = $Pinger.SendPingAsync($Target, $pingTimeout, $pingBuffer)
        return $t
    } catch { return $null }
}

function Resolve-PingTask {
    param($Task)
    if ($null -eq $Task) { return $null }
    try {
        $r = $Task.Result
        if ($r.Status -eq 'Success') { return [double]$r.RoundtripTime }
        return -1.0
    } catch { return -1.0 }
}

function Test-IsSpike {
    # Ein Wert gilt als Spike, wenn er entweder die feste Schwelle reisst
    # oder das Vierfache des aktuell normalen Werts erreicht. Das zweite
    # Kriterium faengt auch Spikes auf Leitungen mit von Haus aus hohem Ping.
    param($Value, $Baseline)
    if ($null -eq $Value) { return $false }
    if ($Value -lt 0)     { return $true }
    if ($Value -ge $SpikeThresholdMs) { return $true }
    if ($null -ne $Baseline -and $Baseline -gt 0 -and $Value -ge [math]::Max(($Baseline * 4), 30)) { return $true }
    return $false
}

function Add-Recent {
    param($List, $Value)
    if ($null -ne $Value -and $Value -ge 0) { $List.Add([double]$Value) | Out-Null }
    while ($List.Count -gt 60) { $List.RemoveAt(0) }
}

function Get-Baseline {
    param($List)
    if ($List.Count -ge 10) { return Get-Median $List.ToArray() }
    return $null
}

$fmtMs = {
    param($v)
    if ($null -eq $v) { '   -' } elseif ($v -lt 0) { 'LOSS' } else { '{0,4:0}' -f $v }
}

try {
    while ((Get-Date) -lt $endTime) {
        $tickStart = Get-Date
        $tick++

        # --- die drei Pings parallel absetzen ---------------------------------
        $tGw  = Invoke-PingValue -Pinger $pGw  -Target $gateway
        $tH2  = Invoke-PingValue -Pinger $pH2  -Target $hop2
        $tNet = Invoke-PingValue -Pinger $pNet -Target $InternetTarget

        # --- waehrend die Pings unterwegs sind: Systemzaehler lesen -----------
        $cpuPct = $null; $dpcPct = $null; $intPct = $null; $diskQ = $null
        try {
            $cpu = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor `
                                   -Filter "Name='_Total'" -ErrorAction Stop
            $cpuPct = [double]$cpu.PercentProcessorTime
            $dpcPct = [double]$cpu.PercentDPCTime
            $intPct = [double]$cpu.PercentInterruptTime
        } catch { }
        try {
            $disk = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfDisk_PhysicalDisk `
                                    -Filter "Name='_Total'" -ErrorAction Stop
            $diskQ = [double]$disk.CurrentDiskQueueLength
        } catch { }

        # --- Netzwerkdurchsatz ueber Delta der Adapterstatistik ---------------
        $rxMbit = $null; $txMbit = $null; $nicFehler = $null
        if ($activeAdapter) {
            try {
                $st  = Get-NetAdapterStatistics -Name $activeAdapter.Name -ErrorAction Stop
                $now = Get-Date
                if ($prevStats) {
                    $dt = ($now - $prevStatsTime).TotalSeconds
                    if ($dt -gt 0) {
                        $rxMbit = [math]::Round((($st.ReceivedBytes  - $prevStats.ReceivedBytes)  * 8 / 1MB) / $dt, 2)
                        $txMbit = [math]::Round((($st.SentBytes      - $prevStats.SentBytes)      * 8 / 1MB) / $dt, 2)
                        if ($rxMbit -lt 0) { $rxMbit = $null }
                        if ($txMbit -lt 0) { $txMbit = $null }
                    }
                    # Fehlerhafte und verworfene Pakete sind der direkte
                    # Nachweis fuer ein defektes Kabel, einen schlechten Port
                    # oder eine gestoerte Funkstrecke. Auf einer gesunden
                    # Leitung bleiben diese Zaehler bei exakt null.
                    $e = 0
                    foreach ($f in 'ReceivedPacketErrors','OutboundPacketErrors','ReceivedDiscardedPackets','OutboundDiscardedPackets') {
                        if ($null -ne $st.$f -and $null -ne $prevStats.$f) { $e += ($st.$f - $prevStats.$f) }
                    }
                    if ($e -ge 0) { $nicFehler = $e }
                }
                $prevStats = $st; $prevStatsTime = $now
            } catch { }
        }

        # --- WLAN-Signal (nur wenn WLAN der aktive Weg ist) -------------------
        $wifiSignal = $null
        if ($isWifi -and ($tick % 5 -eq 1)) {
            try {
                $sig = (& netsh wlan show interfaces 2>$null | Select-String -Pattern '^\s*(Signal|Signalqualitaet)\s*:\s*(\d+)%')
                if ($sig) { $wifiSignal = [int]$sig.Matches[0].Groups[2].Value }
            } catch { }
        }

        # --- Ping-Ergebnisse einsammeln ---------------------------------------
        $gwMs  = Resolve-PingTask $tGw
        $h2Ms  = Resolve-PingTask $tH2
        $netMs = Resolve-PingTask $tNet

        # --- laufender Normalwert (Median der letzten 60 sauberen Messungen) --
        Add-Recent $recentGw  $gwMs
        Add-Recent $recentH2  $h2Ms
        Add-Recent $recentNet $netMs

        $gwSpike  = Test-IsSpike -Value $gwMs  -Baseline (Get-Baseline $recentGw)
        $h2Spike  = Test-IsSpike -Value $h2Ms  -Baseline (Get-Baseline $recentH2)
        $netSpike = Test-IsSpike -Value $netMs -Baseline (Get-Baseline $recentNet)
        $isSpike  = $gwSpike -or $h2Spike -or $netSpike

        $sample = [pscustomobject]@{
            Zeit           = $tickStart.ToString('yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
            GatewayMs      = $gwMs
            Hop2Ms         = $h2Ms
            InternetMs     = $netMs
            CpuProzent     = $cpuPct
            DpcProzent     = $dpcPct
            InterruptPct   = $intPct
            DatentraegerQ  = $diskQ
            DownMbit       = $rxMbit
            UpMbit         = $txMbit
            NicFehler      = $nicFehler
            WlanSignal     = $wifiSignal
            Spike          = $isSpike
        }
        $samples.Add($sample) | Out-Null

        # --- bei einem Spike: Detailschnappschuss ------------------------------
        if ($isSpike) {
            $where = @()
            if ($gwSpike)  { $where += 'Router' }
            if ($h2Spike)  { $where += 'Provider' }
            if ($netSpike) { $where += 'Internet' }

            $topProcs = ''
            if (((Get-Date) - $lastSnapshot).TotalSeconds -ge 5) {
                $lastSnapshot = Get-Date
                try {
                    $topProcs = (Get-CimInstance -ClassName Win32_PerfFormattedData_PerfProc_Process -ErrorAction Stop |
                                 Where-Object { $_.Name -ne '_Total' -and $_.Name -ne 'Idle' } |
                                 Sort-Object -Property PercentProcessorTime -Descending |
                                 Select-Object -First 5 |
                                 ForEach-Object { "$($_.Name):$($_.PercentProcessorTime)%" }) -join ', '
                } catch { }
            }

            $spike = [pscustomobject]@{
                Zeit          = $sample.Zeit
                Betrifft      = ($where -join '+')
                GatewayMs     = $gwMs
                Hop2Ms        = $h2Ms
                InternetMs    = $netMs
                CpuProzent    = $cpuPct
                DpcProzent    = $dpcPct
                DatentraegerQ = $diskQ
                DownMbit      = $rxMbit
                UpMbit        = $txMbit
                NicFehler     = $nicFehler
                WlanSignal    = $wifiSignal
                TopProzesse   = $topProcs
            }
            $spikes.Add($spike) | Out-Null

            Write-Host ("[{0}] SPIKE {1,-18} Router {2} ms | Provider {3} ms | Internet {4} ms | CPU {5,3:0}% | Down {6} Mbit" -f `
                $tickStart.ToString('HH:mm:ss'), ($where -join '+'), (& $fmtMs $gwMs), (& $fmtMs $h2Ms), (& $fmtMs $netMs), `
                $(if ($null -ne $cpuPct) { $cpuPct } else { 0 }), `
                $(if ($null -ne $rxMbit) { $rxMbit } else { 0 })) -ForegroundColor Red
        }
        elseif (((Get-Date) - $lastStatusOut).TotalSeconds -ge 15) {
            $lastStatusOut = Get-Date
            Write-Host ("[{0}] ok    Router {1,4:0} ms | Internet {2,4:0} ms | Spikes bisher: {3}" -f `
                $tickStart.ToString('HH:mm:ss'), `
                $(if ($null -ne $gwMs -and $gwMs -ge 0) { $gwMs } else { 0 }), `
                $(if ($null -ne $netMs -and $netMs -ge 0) { $netMs } else { 0 }), `
                $spikes.Count) -ForegroundColor DarkGray
        }

        # --- alle 60 Messungen zwischenspeichern, damit auch ein harter --------
        # --- Abbruch (Absturz, Neustart) die Daten nicht verliert -------------
        if ($tick % 60 -eq 0) {
            try {
                $samples | Export-Csv -Path $samplesCsv -NoTypeInformation -Encoding UTF8
                if ($spikes.Count -gt 0) { $spikes | Export-Csv -Path $spikesCsv -NoTypeInformation -Encoding UTF8 }
            } catch { }
        }

        # --- Takt halten -------------------------------------------------------
        $elapsed = ((Get-Date) - $tickStart).TotalSeconds
        $sleep   = $IntervalSeconds - $elapsed
        if ($sleep -gt 0) { Start-Sleep -Milliseconds ([int]($sleep * 1000)) }
    }
}
finally {
    foreach ($p in @($pGw, $pH2, $pNet)) { try { $p.Dispose() } catch { } }

    $stoppedAt = Get-Date
    if ($samples.Count -gt 0) { $samples | Export-Csv -Path $samplesCsv -NoTypeInformation -Encoding UTF8 }
    if ($spikes.Count  -gt 0) { $spikes  | Export-Csv -Path $spikesCsv  -NoTypeInformation -Encoding UTF8 }

    # ------------------------------------------------------------------------------
    # 3) Auswertung
    # ------------------------------------------------------------------------------

    Add-Heading 'SCHRITT 3 - Auswertung'

    $durationSec = [math]::Round(($stoppedAt - $startedAt).TotalSeconds)
    Add-Report ("Messdauer: {0} Sekunden, {1} Messpunkte, {2} Spikes." -f $durationSec, $samples.Count, $spikes.Count)

    $gwVals  = @($samples | Where-Object { $null -ne $_.GatewayMs  -and $_.GatewayMs  -ge 0 } | ForEach-Object { [double]$_.GatewayMs })
    $h2Vals  = @($samples | Where-Object { $null -ne $_.Hop2Ms     -and $_.Hop2Ms     -ge 0 } | ForEach-Object { [double]$_.Hop2Ms })
    $netVals = @($samples | Where-Object { $null -ne $_.InternetMs -and $_.InternetMs -ge 0 } | ForEach-Object { [double]$_.InternetMs })

    $gwLoss  = @($samples | Where-Object { $_.GatewayMs  -eq -1 }).Count
    $netLoss = @($samples | Where-Object { $_.InternetMs -eq -1 }).Count

    Add-Report ''
    Add-Report 'Latenzen (Median / 95. Perzentil / Maximum):'
    foreach ($set in @(
        @{ Name = 'Router   (Hop 1)'; Vals = $gwVals  },
        @{ Name = 'Provider (Hop 2)'; Vals = $h2Vals  },
        @{ Name = 'Internet        '; Vals = $netVals }
    )) {
        if ($set.Vals.Count -gt 0) {
            Add-Report ("  {0} : {1,6:0.0} ms / {2,6:0.0} ms / {3,6:0.0} ms" -f `
                $set.Name, (Get-Median $set.Vals), (Get-Percentile $set.Vals 95), ($set.Vals | Measure-Object -Maximum).Maximum)
        } else {
            Add-Report ("  {0} : keine Daten" -f $set.Name)
        }
    }
    if ($gwLoss -gt 0 -or $netLoss -gt 0) {
        Add-Report ("  Paketverlust: Router {0}x, Internet {1}x" -f $gwLoss, $netLoss) -Color Yellow
    }

    # --- Fehlerhafte Pakete auf der Leitung ----------------------------------
    $fehlerSumme = 0
    $fehlerTicks = 0
    foreach ($smp in $samples) {
        if ($null -ne $smp.NicFehler -and $smp.NicFehler -gt 0) {
            $fehlerSumme += [int]$smp.NicFehler
            $fehlerTicks++
        }
    }
    Add-Report ''
    if ($fehlerSumme -gt 0) {
        Add-Report ("Fehlerhafte/verworfene Pakete auf der Leitung: {0} in {1} Sekunden." -f $fehlerSumme, $fehlerTicks) -Color Yellow
    } else {
        Add-Report 'Fehlerhafte/verworfene Pakete auf der Leitung: keine.' -Color Green
    }

    # --- Zeitleiste: wann war es schlimm? ------------------------------------
    # Macht Phasen sichtbar - z.B. unterschiedliche Spiele oder Programme.
    if ($spikes.Count -gt 0 -and $durationSec -ge 180) {
        # Balkenbreite so waehlen, dass rund 15 Zeilen entstehen - bei einer
        # kurzen Messung feiner, bei einer langen groeber.
        $eimerSek = [math]::Max(60, [math]::Ceiling($durationSec / 15 / 60) * 60)
        Add-Report ''
        Add-Report ("Zeitlicher Verlauf (Spikes je {0} Minute(n)):" -f ($eimerSek / 60))
        $eimer = @{}
        foreach ($sp in $spikes) {
            $tt = [datetime]::ParseExact($sp.Zeit, 'yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
            $k  = [int][math]::Floor(($tt - $startedAt).TotalSeconds / $eimerSek)
            if ($eimer.ContainsKey($k)) { $eimer[$k]++ } else { $eimer[$k] = 1 }
        }
        $maxE = ($eimer.Values | Measure-Object -Maximum).Maximum
        for ($k = 0; $k -le [int][math]::Floor($durationSec / $eimerSek); $k++) {
            $n   = if ($eimer.ContainsKey($k)) { $eimer[$k] } else { 0 }
            $bar = '#' * [int][math]::Round(($n / [math]::Max($maxE,1)) * 40)
            Add-Report ("  {0}  {1,-40} {2}" -f $startedAt.AddSeconds($k*$eimerSek).ToString('HH:mm'), $bar, $n)
        }
        Add-Report '  Wenn sich die Spikes auf einzelne Abschnitte ballen, vergleiche das mit dem,'
        Add-Report '  was zu der Zeit lief - das eingrenzende Programm steckt meist genau dort.'
    }

    # --- Zuordnung: wo faengt der Spike an? ----------------------------------
    $spLocal = @($spikes | Where-Object { $_.Betrifft -like '*Router*' }).Count
    $spIsp   = @($spikes | Where-Object { $_.Betrifft -notlike '*Router*' -and $_.Betrifft -like '*Provider*' }).Count
    $spFar   = @($spikes | Where-Object { $_.Betrifft -eq 'Internet' }).Count

    Add-Report ''
    Add-Report 'Wo entstehen die Spikes?'
    Add-Report ("  Schon beim eigenen Router (PC/Kabel/WLAN/Treiber) : {0}" -f $spLocal)
    Add-Report ("  Erst beim Provider (Leitung/Router/Anschluss)     : {0}" -f $spIsp)
    Add-Report ("  Erst weiter draussen im Internet                  : {0}" -f $spFar)

    # --- Korrelationen -------------------------------------------------------
    $verdicts = New-Object System.Collections.Generic.List[string]
    foreach ($f in $baseFindings) { $verdicts.Add($f) | Out-Null }

    if ($spikes.Count -eq 0) {
        Add-Report ''
        Add-Report 'In diesem Zeitraum ist kein einziger Spike aufgetreten.' -Color Green
        $verdicts.Add('Waehrend der Messung gab es keine Spikes. Lass das Skript erneut laufen, waehrend das Problem tatsaechlich auftritt - am besten mit -DurationMinutes 0 im Hintergrund, waehrend du spielst.') | Out-Null
    }
    else {
        $normal = @($samples | Where-Object { -not $_.Spike })

        function Get-Avg {
            param($Rows, [string]$Prop)
            $v = @($Rows | Where-Object { $null -ne $_.$Prop } | ForEach-Object { [double]$_.$Prop })
            if ($v.Count -eq 0) { return $null }
            return [math]::Round(($v | Measure-Object -Average).Average, 1)
        }

        $dlSpike  = Get-Avg $spikes 'DownMbit';    $dlNorm  = Get-Avg $normal 'DownMbit'
        $ulSpike  = Get-Avg $spikes 'UpMbit';      $ulNorm  = Get-Avg $normal 'UpMbit'
        $cpuSpike = Get-Avg $spikes 'CpuProzent';  $cpuNorm = Get-Avg $normal 'CpuProzent'
        $dpcSpike = Get-Avg $spikes 'DpcProzent';  $dpcNorm = Get-Avg $normal 'DpcProzent'
        $dqSpike  = Get-Avg $spikes 'DatentraegerQ'

        # Wenn ausschliesslich Spikes gemessen wurden, gibt es keinen
        # Normalbetrieb zum Vergleichen - dann "n/a" statt einer Leerstelle.
        $na = { param($v) if ($null -eq $v) { 'n/a' } else { $v } }

        Add-Report ''
        Add-Report 'Systemzustand waehrend der Spikes (Spike / Normalbetrieb):'
        Add-Report ("  Download    : {0} / {1} Mbit/s" -f (& $na $dlSpike),  (& $na $dlNorm))
        Add-Report ("  Upload      : {0} / {1} Mbit/s" -f (& $na $ulSpike),  (& $na $ulNorm))
        Add-Report ("  CPU         : {0} / {1} %"      -f (& $na $cpuSpike), (& $na $cpuNorm))
        Add-Report ("  DPC-Zeit    : {0} / {1} %"      -f (& $na $dpcSpike), (& $na $dpcNorm))
        if ($normal.Count -eq 0) {
            Add-Report '  (Es gab keinen einzigen stoerungsfreien Messpunkt - die Spalte Normalbetrieb bleibt daher leer.)' -Color Yellow
        }

        # Bufferbloat: Latenz steigt genau dann, wenn die Leitung ausgelastet ist
        if ($null -ne $dlSpike -and $null -ne $dlNorm -and $dlNorm -ge 0 -and $dlSpike -gt ([math]::Max($dlNorm * 3, 5))) {
            $verdicts.Add(("BUFFERBLOAT: Waehrend der Spikes lief der Download mit {0} Mbit/s statt sonst {1} Mbit/s. Die Leitung wird also vollgemacht, und der Router puffert - das erzeugt genau diese 500-1000 ms Ausschlaege. Suche den Verursacher (Steam/Epic/Windows Update/Cloud-Sync/anderes Geraet im Haushalt) oder aktiviere im Router SQM/QoS bzw. Smart Queue Management." -f $dlSpike, $dlNorm)) | Out-Null
        }
        if ($null -ne $ulSpike -and $null -ne $ulNorm -and $ulNorm -ge 0 -and $ulSpike -gt ([math]::Max($ulNorm * 3, 2))) {
            $verdicts.Add(("BUFFERBLOAT IM UPLOAD: Waehrend der Spikes lief der Upload mit {0} Mbit/s statt sonst {1} Mbit/s. Ein voller Upstream ist die haeufigste Ursache fuer hohen Ping bei sonst normaler Leitung - typisch: Cloud-Backup, OneDrive/Dropbox-Sync, Streaming-Software, Torrents oder die Windows-Uebermittlungsoptimierung." -f $ulSpike, $ulNorm)) | Out-Null
        }

        # Treiber-/DPC-Problem
        if ($null -ne $dpcSpike -and $dpcSpike -ge 5) {
            $verdicts.Add(("TREIBERVERDACHT: Die DPC-Zeit liegt waehrend der Spikes bei {0} %. Werte ueber ca. 5 % deuten auf einen Treiber hin, der das System blockiert (haeufig Netzwerk-, Grafik- oder Audiotreiber). Pruefe das gezielt mit dem kostenlosen Tool LatencyMon." -f $dpcSpike)) | Out-Null
        }
        if ($null -ne $cpuSpike -and $null -ne $cpuNorm -and $cpuSpike -ge 85 -and $cpuSpike -gt ($cpuNorm + 25)) {
            $verdicts.Add(("SYSTEMLAST: Die CPU war waehrend der Spikes im Schnitt bei {0} % (sonst {1} %). Die Lags koennen dann auch ohne Netzwerkproblem entstehen. Die Spalte TopProzesse in spikes.csv zeigt, wer die Last verursacht." -f $cpuSpike, $cpuNorm)) | Out-Null
        }
        if ($null -ne $dqSpike -and $dqSpike -ge 5) {
            $verdicts.Add(("DATENTRAEGER: Die Warteschlange der Festplatte lag waehrend der Spikes bei {0}. Eine ausgelastete Platte friert Spiele und Windows kurz ein - das fuehlt sich an wie Lag, ist aber keiner." -f $dqSpike)) | Out-Null
        }

        # WLAN-Signal
        $wsp = @($spikes | Where-Object { $null -ne $_.WlanSignal } | ForEach-Object { [int]$_.WlanSignal })
        if ($wsp.Count -gt 0) {
            $wAvg = [math]::Round(($wsp | Measure-Object -Average).Average)
            if ($wAvg -lt 70) {
                $verdicts.Add(("WLAN-SIGNAL: Waehrend der Spikes lag die Signalqualitaet bei durchschnittlich {0} %. Unter ca. 70 % kommt es zu Neuuebertragungen und Latenzspitzen." -f $wAvg)) | Out-Null
            }
        }

        # Fehlerhafte Pakete = harter Nachweis fuer eine kaputte Strecke
        if ($fehlerSumme -gt 0) {
            $verdicts.Add(("LEITUNG DEFEKT: Die Netzwerkkarte hat waehrend der Messung {0} fehlerhafte oder verworfene Pakete gezaehlt. Auf einer gesunden Verbindung ist dieser Wert exakt null. Per Kabel bedeutet das: anderes LAN-Kabel und anderer Router-Port, in dieser Reihenfolge. Per WLAN bedeutet es Funkstoerung oder zu schwaches Signal." -f $fehlerSumme)) | Out-Null
        }

        # Ort der Entstehung - nur aussagekraeftig, wenn der Router
        # tatsaechlich auf Pings geantwortet hat. Ohne Hop-1-Messung waere
        # jede Aussage "liegt nicht am PC" schlicht geraten.
        if ($gwVals.Count -eq 0) {
            $verdicts.Add('ORT NICHT BESTIMMBAR: Der eigene Router hat nicht auf Pings geantwortet. Deshalb laesst sich nicht sagen, ob die Spikes im PC oder erst dahinter entstehen. Aktiviere in der Router-Oberflaeche die Ping-Antwort (oft "ICMP" oder "Ping vom LAN beantworten") und miss erneut.') | Out-Null
        }
        elseif ($spLocal -gt 0 -and $spLocal -ge ($spikes.Count * 0.5)) {
            $verdicts.Add(("ORT: {0} von {1} Spikes treten schon auf dem Weg zum eigenen Router auf. Damit ist das Internet bzw. dein Provider ausgeschlossen - die Ursache liegt zwischen deinem PC und dem Router: Netzwerkkarte, Treiber, Energiesparen, Kabel/Port oder WLAN-Stoerung." -f $spLocal, $spikes.Count)) | Out-Null
        }
        elseif ($gwVals.Count -gt 0 -and ($spIsp + $spFar) -gt 0 -and ($spIsp + $spFar) -ge ($spikes.Count * 0.5)) {
            $verdicts.Add(("ORT: Der Ping zum eigenen Router bleibt bei den meisten Spikes sauber, erst dahinter wird es langsam. Die Ursache liegt also nicht am PC, sondern an Router, Leitung oder Provider. Auffaellig: seit gestern - das passt zu einer Stoerung am Anschluss. Router einmal fuer 5 Minuten stromlos machen und, wenn es bleibt, den Provider auf eine Leitungsstoerung ansprechen.")) | Out-Null
            if ($spFar -gt 0 -and $spIsp -eq 0 -and $h2Vals.Count -eq 0) {
                $verdicts.Add('Hinweis: Hop 2 hat nicht auf Ping geantwortet, deshalb konnte "Provider" nicht sauber von "Internet" getrennt werden. Das ist normal und kein Fehler.') | Out-Null
            }
        }

        # Regelmaessigkeit -> deutet auf einen Timer/Dienst statt auf Zufall
        if ($spikes.Count -ge 4) {
            $times = @($spikes | ForEach-Object { [datetime]::ParseExact($_.Zeit, 'yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture) })
            $gaps  = @()
            for ($i = 1; $i -lt $times.Count; $i++) { $gaps += ($times[$i] - $times[$i-1]).TotalSeconds }
            $gapMed = Get-Median ([double[]]$gaps)
            $tight  = @($gaps | Where-Object { [math]::Abs($_ - $gapMed) -le ([math]::Max($gapMed * 0.2, 1)) }).Count
            Add-Report ''
            Add-Report ("Abstand zwischen den Spikes: im Mittel {0:0.0} Sekunden." -f $gapMed)
            if ($tight -ge ($gaps.Count * 0.6) -and $gapMed -ge 5) {
                $verdicts.Add(("REGELMASSIGES MUSTER: Die Spikes kommen in einem sehr gleichmaessigen Abstand von rund {0:0} Sekunden. Das ist kein Zufall, sondern ein Programm oder Dienst mit festem Intervall (z.B. WLAN-Kanalsuche, Backup, Cloud-Sync, Virenscanner, Update-Dienst). Die Aufgabenplanung und die Spalte TopProzesse in spikes.csv fuehren zum Verursacher." -f $gapMed)) | Out-Null
            }
        }
    }

    # --- Ist schon der Weg zum eigenen Router zu langsam? --------------------
    # Im gleichen Haus sollte der Router praktisch sofort antworten:
    # per Kabel unter 1 ms, per WLAN wenige Millisekunden. Alles darueber
    # ist bereits ein Defekt - voellig unabhaengig von einzelnen Spikes.
    if ($gwVals.Count -ge 30) {
        $gwMed   = Get-Median $gwVals
        $grenze  = if ($isWifi) { 8 } else { 3 }
        $medium  = if ($isWifi) { 'WLAN-Strecke' } else { 'LAN-Kabel' }
        $erwartet= if ($isWifi) { 'wenige Millisekunden' } else { 'unter 1 ms' }
        if ($gwMed -gt $grenze) {
            $verdicts.Add(("STRECKE ZUM ROUTER: Schon im Normalbetrieb braucht dein eigener Router im Median {0:0.0} ms fuer eine Antwort. Erwartbar waeren ueber {1} {2}. Die Verbindung zwischen PC und Router ist damit dauerhaft gestoert, nicht nur bei den Spitzen - das erklaert Ruckler und Jitter in Spielen auch dann, wenn der Ping gerade nicht ausschlaegt." -f $gwMed, $medium, $erwartet)) | Out-Null
        }
    }

    # --- Ereignisprotokoll im Messzeitraum -----------------------------------
    try {
        $evts = @(Get-WinEvent -FilterHashtable @{
                     LogName   = 'System'
                     StartTime = $startedAt.AddMinutes(-5)
                     Level     = 1,2,3
                  } -ErrorAction SilentlyContinue | Select-Object -First 40)
        $netEvts = @($evts | Where-Object {
            $_.ProviderName -match 'Tcpip|Ndis|Dhcp|DNS|Netwtw|e1[a-z]|rt\d|Realtek|Intel|Killer|Kernel-Power|Kernel-PnP|disk|storahci|nvlddmkm|amdkmdag'
        })
        if ($netEvts.Count -gt 0) {
            Add-Report ''
            Add-Report 'Relevante Windows-Ereignisse im Messzeitraum:' -Color Yellow
            foreach ($e in ($netEvts | Select-Object -First 12)) {
                $msg = ($e.Message -split "`n")[0]
                if ($msg.Length -gt 110) { $msg = $msg.Substring(0, 110) + '...' }
                Add-Report ("  {0}  [{1}] {2}: {3}" -f $e.TimeCreated.ToString('HH:mm:ss'), $e.LevelDisplayName, $e.ProviderName, $msg)
            }
            $verdicts.Add('Im Windows-Ereignisprotokoll stehen Fehler/Warnungen von Netzwerk- oder Treiberkomponenten aus dem Messzeitraum (siehe oben). Die sind ein sehr direkter Hinweis auf die Ursache.') | Out-Null
        }
    } catch { }

    # --- Fazit ---------------------------------------------------------------
    Add-Heading 'FAZIT'

    if ($verdicts.Count -eq 0) {
        Add-Report 'Es wurde nichts Auffaelliges gefunden. Bitte die Messung wiederholen, waehrend das Problem auftritt.' -Color Green
    } else {
        $n = 0
        foreach ($v in $verdicts) {
            $n++
            Add-Report ''
            Add-Report ("{0}. {1}" -f $n, $v) -Color Yellow
        }
    }

    Add-Report ''
    Add-Report 'Immer sinnvoll zu pruefen, egal was oben steht:'
    Add-Report '  - Nur EINEN Netzwerkweg aktiv lassen (entweder LAN oder WLAN, nicht beides).'
    Add-Report '  - Geraete-Manager > Netzwerkadapter > Energieverwaltung: Haken bei "Computer kann das Geraet ausschalten" entfernen.'
    Add-Report '  - Anderes LAN-Kabel und anderen Router-Port testen (defekte Kabel machen genau solche sporadischen Aussetzer).'
    Add-Report '  - Netzwerktreiber direkt beim Hersteller des Mainboards/Notebooks laden, nicht ueber Windows Update.'
    Add-Report '  - Pruefen, ob ein anderes Geraet im Haushalt die Leitung auslastet (Konsole, TV, Handy-Backup).'
    Add-Report '  - "Seit gestern" ist ein starker Hinweis: Was hat sich gestern geaendert? Windows-Update, neuer Treiber, neues Programm, neues Geraet im Netz?'

    Add-Report ''
    Add-Report 'Gespeicherte Dateien:'
    Add-Report ("  Bericht        : {0}" -f $reportTxt)
    Add-Report ("  Alle Messwerte : {0}" -f $samplesCsv)
    Add-Report ("  Nur Spikes     : {0}" -f $spikesCsv)
    Add-Report ("  Systemzustand  : {0}" -f $baselineTxt)

    $script:ReportLines -join "`r`n" | Out-File -FilePath $reportTxt -Encoding UTF8
    Write-Host ''
}
