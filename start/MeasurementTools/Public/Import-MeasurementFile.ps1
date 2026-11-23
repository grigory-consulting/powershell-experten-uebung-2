function Import-MeasurementFile {
    <#
    .SYNOPSIS
        Liest Messwertdateien ein und liefert je Zeile ein Messwertobjekt.

    .DESCRIPTION
        Erwartet CSV-Dateien mit dem Trennzeichen Semikolon und den Spalten
        Zeitstempel, Geraet, Wert, Einheit und Status.

        Der Zeitstempel hat das feste Format dd.MM.yyyy HH:mm. Die Zahl in der
        Spalte Wert wird in der Kultur gelesen, die -Culture nennt. Beides hängt
        nicht von der Kultur der Sitzung ab: Die Funktion liefert auf jedem
        Rechner dieselben Objekte.

        Eine Zeile ohne Wert ergibt ein Objekt mit Value = $null. Eine Zeile,
        deren Zeitstempel oder Wert sich nicht lesen lässt, ergibt kein Objekt,
        sondern einen Fehler mit Dateiname und Zeilennummer; die übrigen Zeilen
        werden weiter gelesen.

    .PARAMETER Path
        Pfad einer oder mehrerer Messwertdateien. Platzhalter sind erlaubt.
        Aus der Pipeline kommen Pfade als Text oder Dateiobjekte (Eigenschaft
        FullName).

    .PARAMETER Culture
        Kultur, in der die Zahlen der Datei geschrieben sind. Standard ist
        de-DE (Dezimalkomma).

    .EXAMPLE
        Import-MeasurementFile -Path .\daten\messwerte\Nord_2026-11-23.csv

        Liest eine Datei ein.

    .EXAMPLE
        Get-ChildItem .\daten\messwerte\Nord_*.csv | Import-MeasurementFile | Test-Measurement

        Liest alle Dateien eines Standorts ein und prüft die Werte.

    .EXAMPLE
        Import-MeasurementFile -Path .\lieferung.csv -Culture en-US

        Liest eine Datei, deren Zahlen mit Dezimalpunkt geschrieben sind.

    .INPUTS
        System.String

    .OUTPUTS
        PSCustomObject mit Timestamp, DeviceId, Value, Unit, Status und SourceFile.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string[]]$Path,

        [cultureinfo]$Culture = [cultureinfo]::GetCultureInfo('de-DE')
    )

    begin {
        # GetCultureInfo liefert die Kultur ohne die Anpassungen, die ein
        # Benutzer in den Regionaleinstellungen von Windows vorgenommen hat.
        $numberCulture = [cultureinfo]::GetCultureInfo($Culture.Name)
    }

    process {
        foreach ($item in $Path) {
            foreach ($resolved in (Resolve-Path -Path $item)) {
                $fileName = Split-Path -Path $resolved.ProviderPath -Leaf
                Write-Verbose "Lese $($resolved.ProviderPath)"

                # Die Kopfzeile ist Zeile 1 der Datei.
                $lineNumber = 1

                foreach ($row in (Import-Csv -LiteralPath $resolved.ProviderPath -Delimiter ';' -Encoding UTF8)) {
                    $lineNumber++

                    # Ein Fehler in ConvertTo-MeasurementValue beendet die
                    # aufrufende Anweisung nicht von selbst: Ohne try entstünde
                    # ein Objekt mit leerem Value. So gibt es für eine Zeile,
                    # die sich nicht lesen lässt, eine Fehlermeldung und kein Objekt.
                    try {
                        $timestamp = [datetime]::ParseExact($row.Zeitstempel, 'dd.MM.yyyy HH:mm', [cultureinfo]::InvariantCulture)
                        $value = ConvertTo-MeasurementValue -Text $row.Wert -Culture $numberCulture
                    }
                    catch {
                        $reason = $_.Exception.GetBaseException().Message
                        Write-Error -Message "$fileName, Zeile ${lineNumber}: Zeitstempel oder Wert nicht lesbar. $reason" -Category InvalidData -TargetObject $row
                        continue
                    }

                    [pscustomobject]@{
                        Timestamp  = $timestamp
                        DeviceId   = $row.Geraet
                        Value      = $value
                        Unit       = $row.Einheit
                        Status     = $row.Status
                        SourceFile = $fileName
                    }
                }
            }
        }
    }
}
