#Requires -Version 5.1

<#
.SYNOPSIS
    Erzeugt die Übungsdaten des Kurses: Messwertdateien, Logdateien des Importdienstes und die Serverliste.

.DESCRIPTION
    Legt im Zielordner an:

      messwerte\<Standort>_<yyyy-MM-dd>.csv    36 Dateien (4 Standorte, 9 Tage ab dem 23.11.2026)
      logs\import-service_<yyyy-MM-dd>.log     9 Dateien, passend zu den Messwertdateien
      server.csv                               Serverliste mit 16 erfundenen Namen

    Alle Daten sind erfunden. Jeder Lauf erzeugt dieselben Bytes, unter Windows
    PowerShell 5.1 genauso wie unter PowerShell 7.x und unabhängig von der Kultur
    des Rechners:

      - Der Zufall kommt aus einem eigenen linearen Kongruenzgenerator mit
        Startwert 1 (System.Random liefert in .NET Framework und in modernem .NET
        unterschiedliche Folgen).
      - Alle Berechnungen laufen mit ganzen Zahlen (Hundertstel kWh).
      - Zahlen und Zeitstempel werden von Hand formatiert, nie über die Kultur
        der Sitzung.
      - Das Zeilenende ist immer LF.

.PARAMETER Path
    Zielordner. Standard ist der Ordner daten neben diesem Skript.

.PARAMETER Force
    Erzeugt die Daten neu, auch wenn im Zielordner schon welche liegen. Gelöscht
    werden dabei nur messwerte\, logs\ und server.csv.

.EXAMPLE
    .\New-CourseData.ps1

    Erzeugt die Daten im Ordner daten neben dem Skript.

.EXAMPLE
    .\New-CourseData.ps1 -Force

    Verwirft vorhandene Kursdaten im Ordner daten und erzeugt sie neu.

.EXAMPLE
    .\New-CourseData.ps1 -Path C:\Kurs\daten

    Erzeugt die Daten in einem anderen Ordner.

.OUTPUTS
    Ein Objekt mit Path, MeasurementFiles, MeasurementRows, LogFiles und ServerRows.
#>
[CmdletBinding()]
param(
    [string]$Path = (Join-Path $PSScriptRoot 'daten'),

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# -----------------------------------------------------------------------------
# Feste Größen des Datenbestands
# -----------------------------------------------------------------------------
$sites = 'Nord', 'Sued', 'West', 'Ost'
$firstDay = [datetime]::new(2026, 11, 23)
$dayCount = 9
$devicesPerSite = 15
$intervalsPerDay = 96
$firstDeviceNumber = 1001

# Tagesgang in Prozent der Grundlast, ein Wert je Stunde.
$hourFactor = 62, 60, 58, 58, 60, 68, 82, 98, 112, 120, 124, 126,
    122, 120, 118, 116, 114, 118, 122, 116, 104, 90, 78, 68

# Fehlercodes des Importdienstes mit ihren Folgezeilen.
$errorCatalog = @(
    @{
        Code  = 'E4012'
        Trace = '   bei ImportService.Reader.ReadFile(String path)',
            '   bei ImportService.Worker.Run()'
    }
    @{
        Code  = 'E4031'
        Trace = '   bei ImportService.Reader.OpenStream(String path)',
            '   bei ImportService.Reader.ReadFile(String path)',
            '   bei ImportService.Worker.Run()'
    }
    @{
        Code  = 'E5003'
        Trace = '   bei ImportService.Database.Connect()',
            '   bei ImportService.Worker.Run()'
    }
)

$invariant = [cultureinfo]::InvariantCulture
$utf8WithBom = New-Object System.Text.UTF8Encoding($true)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# -----------------------------------------------------------------------------
# Zufall: linearer Kongruenzgenerator nach Park und Miller
#   seed = seed * 48271 mod (2^31 - 1)
# Das größte Zwischenergebnis liegt bei rund 1,04 * 10^14 und passt in Int64.
# In den inneren Schleifen steht dieselbe Formel direkt im Code, weil ein
# Funktionsaufruf je Messwert den Lauf spürbar bremst.
# -----------------------------------------------------------------------------
[long]$seed = 1

function Get-RandomNumber {
    # Liefert eine ganze Zahl von 0 bis Maximum - 1.
    param([int]$Maximum)

    $script:seed = ($script:seed * 48271) % 2147483647
    return [int]($script:seed % $Maximum)
}

function Get-AnomalyCell {
    # Sucht für eine Auffälligkeit eine freie Stelle (Gerät und Intervall) und
    # liefert sie als Schlüssel Gerät * 100 + Intervall. Zwei Intervalle Abstand
    # zu jeder anderen Auffälligkeit desselben Geräts und zu den Tagesrändern
    # bleiben frei, damit sich die Fundstellen nicht überlagern.
    param(
        [hashtable]$Reserved,
        [int]$Length = 1
    )

    while ($true) {
        $device = Get-RandomNumber -Maximum $script:devicesPerSite
        $interval = 2 + (Get-RandomNumber -Maximum ($script:intervalsPerDay - 6))
        $isFree = $true
        foreach ($offset in -2..($Length + 1)) {
            if ($Reserved.ContainsKey($device * 100 + $interval + $offset)) {
                $isFree = $false
            }
        }
        if ($isFree) {
            return ($device * 100 + $interval)
        }
    }
}

function Format-LogTime {
    # Millisekunden seit Mitternacht als HH:mm:ss,fff.
    param([long]$Milliseconds)

    $fraction = $Milliseconds % 1000
    $totalSeconds = ($Milliseconds - $fraction) / 1000
    $second = $totalSeconds % 60
    $totalMinutes = ($totalSeconds - $second) / 60
    $minute = $totalMinutes % 60
    $hour = ($totalMinutes - $minute) / 60
    return ('{0}:{1}:{2},{3}' -f
        ([int]$hour).ToString('00', $script:invariant),
        ([int]$minute).ToString('00', $script:invariant),
        ([int]$second).ToString('00', $script:invariant),
        ([int]$fraction).ToString('000', $script:invariant))
}

# -----------------------------------------------------------------------------
# Zielordner vorbereiten
# -----------------------------------------------------------------------------
$targetRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
$measurementDirectory = Join-Path $targetRoot 'messwerte'
$logDirectory = Join-Path $targetRoot 'logs'
$serverFile = Join-Path $targetRoot 'server.csv'

$existing = @($measurementDirectory, $logDirectory, $serverFile | Where-Object { Test-Path -LiteralPath $_ })
if ($existing.Count -gt 0) {
    if (-not $Force) {
        throw "Unter '$targetRoot' liegen bereits Kursdaten. Mit -Force werden sie neu erzeugt."
    }
    Remove-Item -LiteralPath $existing -Recurse -Force
}
$null = New-Item -Path $measurementDirectory -ItemType Directory -Force
$null = New-Item -Path $logDirectory -ItemType Directory -Force

# -----------------------------------------------------------------------------
# Grundlast je Gerät in Hundertstel kWh je Viertelstunde (100,00 bis 1500,00)
# -----------------------------------------------------------------------------
$deviceBase = foreach ($index in 1..($sites.Count * $devicesPerSite)) {
    10000 + (Get-RandomNumber -Maximum 140001)
}

# Uhrzeiten der 96 Viertelstunden.
$timeText = foreach ($interval in 0..($intervalsPerDay - 1)) {
    $minuteOfDay = $interval * 15
    $minute = $minuteOfDay % 60
    $hour = ($minuteOfDay - $minute) / 60
    ([int]$hour).ToString('00', $invariant) + ':' + ([int]$minute).ToString('00', $invariant)
}

# -----------------------------------------------------------------------------
# Messwertdateien und Logdateien, Tag für Tag
# -----------------------------------------------------------------------------
$measurementRows = 0

foreach ($dayIndex in 0..($dayCount - 1)) {
    $day = $firstDay.AddDays($dayIndex)
    $fileDate = $day.ToString('yyyy-MM-dd', $invariant)
    $rowDate = $day.ToString('dd.MM.yyyy', $invariant)

    # Was der Importdienst an diesem Tag über die vier Dateien protokolliert.
    $imports = New-Object 'System.Collections.Generic.List[object]'

    foreach ($siteIndex in 0..($sites.Count - 1)) {
        $fileName = '{0}_{1}.csv' -f $sites[$siteIndex], $fileDate

        # Auffälligkeiten dieser Datei festlegen. Die Reihenfolge der Ziehungen
        # ist fest, sonst ändert sich der ganze Datenbestand.
        $anomaly = @{}

        $missingCount = 2 + (Get-RandomNumber -Maximum 3)
        foreach ($index in 1..$missingCount) {
            $anomaly[(Get-AnomalyCell -Reserved $anomaly)] = 'Missing'
        }

        $substituteCount = 3 + (Get-RandomNumber -Maximum 4)
        foreach ($index in 1..$substituteCount) {
            $anomaly[(Get-AnomalyCell -Reserved $anomaly)] = 'Substitute'
        }

        $anomaly[(Get-AnomalyCell -Reserved $anomaly)] = 'Negative'

        $gapLength = 1 + (Get-RandomNumber -Maximum 3)
        $gapStart = Get-AnomalyCell -Reserved $anomaly -Length $gapLength
        foreach ($gapOffset in 0..($gapLength - 1)) {
            # Schlüssel und Abfrage müssen denselben Typ haben: Ein Int64 als
            # Schlüssel wird mit einem Int32 nicht wiedergefunden.
            $anomaly[[int]($gapStart + $gapOffset)] = 'Gap'
        }

        $anomaly[(Get-AnomalyCell -Reserved $anomaly)] = 'Duplicate'

        # Zeilen der Datei, Gerät für Gerät, je Gerät in zeitlicher Folge.
        $lines = New-Object 'System.Collections.Generic.List[string]'
        $lines.Add('Zeitstempel;Geraet;Wert;Einheit;Status')
        $missingRows = New-Object 'System.Collections.Generic.List[object]'

        foreach ($deviceIndex in 0..($devicesPerSite - 1)) {
            $deviceNumber = $siteIndex * $devicesPerSite + $deviceIndex
            $deviceId = 'G-' + ($firstDeviceNumber + $deviceNumber)
            $base = $deviceBase[$deviceNumber]

            foreach ($interval in 0..($intervalsPerDay - 1)) {
                # Der Zufallswert wird für jede Stelle gezogen, auch wenn die
                # Zeile wegen einer Lücke entfällt. So hängen die Werte nicht
                # davon ab, wo die Auffälligkeiten liegen.
                $seed = ($seed * 48271) % 2147483647
                $raw = $base * $hourFactor[($interval - $interval % 4) / 4] * (9700 + $seed % 601)
                [long]$value = ($raw - $raw % 1000000) / 1000000

                $kind = $anomaly[[int]($deviceIndex * 100 + $interval)]
                if ($kind -eq 'Gap') {
                    continue
                }

                $cents = $value % 100
                $valueText = [string](($value - $cents) / 100) + ','
                if ($cents -lt 10) {
                    $valueText += '0'
                }
                $valueText += [string]$cents

                $status = 'OK'
                if ($kind -eq 'Missing') {
                    $valueText = ''
                    $status = 'Gestoert'
                }
                elseif ($kind -eq 'Substitute') {
                    $status = 'Ersatzwert'
                }
                elseif ($kind -eq 'Negative') {
                    $valueText = '-' + $valueText
                }

                $line = $rowDate + ' ' + $timeText[$interval] + ';' + $deviceId + ';' + $valueText + ';kWh;' + $status
                $lines.Add($line)
                if ($kind -eq 'Missing') {
                    # Zeilennummer in der Datei, die Kopfzeile ist Zeile 1.
                    $missingRows.Add(@{ DeviceId = $deviceId; Line = $lines.Count })
                }
                elseif ($kind -eq 'Duplicate') {
                    $lines.Add($line)
                }
            }
        }

        $content = [string]::Join("`n", $lines.ToArray()) + "`n"
        [System.IO.File]::WriteAllText((Join-Path $measurementDirectory $fileName), $content, $utf8WithBom)

        $rowCount = $lines.Count - 1
        $measurementRows += $rowCount
        $imports.Add(@{ FileName = $fileName; RowCount = $rowCount; MissingRows = $missingRows })
    }

    # Log des Importdienstes: Die vier Importe laufen überlappend, deshalb
    # stehen ihre Zeilen ineinander. Sortiert wird am Ende nach der Uhrzeit.
    $logEvents = New-Object 'System.Collections.Generic.List[object]'
    $order = 0
    [long]$clock = (15 * 60 + 2) * 1000

    foreach ($import in $imports) {
        [long]$start = $clock + (Get-RandomNumber -Maximum 900)
        $clock = $start + 200 + (Get-RandomNumber -Maximum 600)
        $startLine = 'Import gestartet: Datei={0} Geraete={1}' -f $import.FileName, $devicesPerSite

        if ((Get-RandomNumber -Maximum 4) -eq 0) {
            # Erster Versuch scheitert, der Dienst versucht es einige Sekunden später erneut.
            $failure = $errorCatalog[(Get-RandomNumber -Maximum $errorCatalog.Count)]
            $duration = 800 + (Get-RandomNumber -Maximum 1800)
            $logEvents.Add(@{ Time = $start; Order = $order; Level = 'INFO '; Text = $startLine; Trace = @() })
            $order++
            $text = 'Import fehlgeschlagen: Datei={0} Code={1} Dauer={2}ms' -f $import.FileName, $failure.Code, $duration
            $logEvents.Add(@{ Time = $start + $duration; Order = $order; Level = 'ERROR'; Text = $text; Trace = $failure.Trace })
            $order++
            $start = $start + $duration + 4000 + (Get-RandomNumber -Maximum 5000)
        }

        $duration = 1200 + (Get-RandomNumber -Maximum 1200)
        $logEvents.Add(@{ Time = $start; Order = $order; Level = 'INFO '; Text = $startLine; Trace = @() })
        $order++
        foreach ($row in $import.MissingRows) {
            # Der Dienst meldet die Zeile, sobald er sie erreicht: Die Uhrzeit
            # wächst mit der Zeilennummer.
            $progress = $duration * $row.Line
            $divisor = $import.RowCount + 2
            $elapsed = [long](($progress - $progress % $divisor) / $divisor)
            $text = 'Wert fehlt: Datei={0} Geraet={1} Zeile={2}' -f $import.FileName, $row.DeviceId, $row.Line
            $logEvents.Add(@{ Time = $start + $elapsed; Order = $order; Level = 'WARN '; Text = $text; Trace = @() })
            $order++
        }
        $text = 'Import beendet: Datei={0} Zeilen={1} Dauer={2}ms' -f $import.FileName, $import.RowCount, $duration
        $logEvents.Add(@{ Time = $start + $duration; Order = $order; Level = 'INFO '; Text = $text; Trace = @() })
        $order++
    }

    $logLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($logEvent in ($logEvents | Sort-Object -Property { $_.Time }, { $_.Order })) {
        $logLines.Add(('{0} {1} [{2}] {3}' -f $fileDate, (Format-LogTime -Milliseconds $logEvent.Time), $logEvent.Level, $logEvent.Text))
        foreach ($traceLine in $logEvent.Trace) {
            $logLines.Add($traceLine)
        }
    }

    # Die Logzeilen enthalten nur ASCII-Zeichen und stehen ohne BOM in der Datei.
    $content = [string]::Join("`n", $logLines.ToArray()) + "`n"
    [System.IO.File]::WriteAllText((Join-Path $logDirectory ('import-service_{0}.log' -f $fileDate)), $content, $utf8NoBom)
}

# -----------------------------------------------------------------------------
# Serverliste. Die Namen sind erfunden und nicht auflösbar.
# -----------------------------------------------------------------------------
$serverLines = New-Object 'System.Collections.Generic.List[string]'
$serverLines.Add('Name;Rolle;Standort')
foreach ($site in $sites) {
    $siteCode = $site.ToUpperInvariant()
    $serverLines.Add(('IMP-{0}-01;Import;{1}' -f $siteCode, $site))
    $serverLines.Add(('IMP-{0}-02;Import;{1}' -f $siteCode, $site))
    $serverLines.Add(('DB-{0}-01;Datenbank;{1}' -f $siteCode, $site))
    $serverLines.Add(('WEB-{0}-01;Web;{1}' -f $siteCode, $site))
}
$content = [string]::Join("`n", $serverLines.ToArray()) + "`n"
[System.IO.File]::WriteAllText($serverFile, $content, $utf8WithBom)

[pscustomobject]@{
    Path             = $targetRoot
    MeasurementFiles = $sites.Count * $dayCount
    MeasurementRows  = $measurementRows
    LogFiles         = $dayCount
    ServerRows       = $serverLines.Count - 1
}
