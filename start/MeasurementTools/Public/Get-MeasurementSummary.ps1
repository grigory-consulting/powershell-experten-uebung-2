function Get-MeasurementSummary {
    <#
    .SYNOPSIS
        Fasst Messwertobjekte je Gerät zusammen.

    .DESCRIPTION
        Liefert je Gerät ein Objekt:

          DeviceId       Gerätenummer
          Count          Zahl aller Messwertobjekte des Geräts
          Sum            Summe der gültigen Werte
          Min            kleinster gültiger Wert, $null ohne gültige Werte
          Max            größter gültiger Wert, $null ohne gültige Werte
          InvalidCount   Zahl der Messwertobjekte mit IsValid = $false
          GapCount       Zahl der fehlenden Intervalle zwischen dem ersten und
                         dem letzten Zeitstempel des Geräts

        Gültig ist ein Messwert, wenn Test-Measurement ihn so markiert hat.
        Objekte ohne die Eigenschaft IsValid schickt die Funktion selbst durch
        Test-Measurement (ohne Obergrenze); sie tragen danach IsValid und Reason.

        Die Summe entsteht in [decimal], damit sich keine Rundungsreste der
        Gleitkommazahlen aufaddieren.

    .PARAMETER InputObject
        Messwertobjekte aus Import-MeasurementFile oder Test-Measurement.

    .PARAMETER IntervalMinutes
        Abstand zweier Messwerte in Minuten. Standard ist 15.

    .EXAMPLE
        Import-MeasurementFile -Path .\daten\messwerte\Nord_2026-11-23.csv |
            Test-Measurement |
            Get-MeasurementSummary

        Fasst die Messwerte einer Datei je Gerät zusammen.

    .EXAMPLE
        Get-ChildItem .\daten\messwerte\Nord_*.csv |
            Import-MeasurementFile |
            Test-Measurement -MaxValue 1500 |
            Get-MeasurementSummary |
            Sort-Object InvalidCount -Descending

        Fasst alle Tage eines Standorts zusammen, Werte über 1500 gelten als ungültig.

    .INPUTS
        PSCustomObject mit Timestamp, DeviceId, Value und Status.

    .OUTPUTS
        PSCustomObject mit DeviceId, Count, Sum, Min, Max, InvalidCount und GapCount.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [psobject[]]$InputObject,

        [ValidateRange(1, 1440)]
        [int]$IntervalMinutes = 15
    )

    begin {
        # Eine Zusammenfassung braucht alle Objekte. process sammelt sie nur,
        # ausgewertet wird in end.
        $measurements = [System.Collections.Generic.List[object]]::new()
    }

    process {
        foreach ($item in $InputObject) {
            $measurements.Add($item)
        }
    }

    end {
        # Was noch nicht geprüft ist, läuft jetzt durch Test-Measurement.
        $checked = foreach ($item in $measurements) {
            if ($null -eq $item.PSObject.Properties['IsValid']) {
                $item | Test-Measurement
            }
            else {
                $item
            }
        }

        foreach ($group in ($checked | Group-Object -Property DeviceId | Sort-Object -Property Name)) {
            $sum = [decimal]0
            $min = $null
            $max = $null
            $invalidCount = 0

            foreach ($item in $group.Group) {
                if (-not $item.IsValid) {
                    $invalidCount++
                    continue
                }
                $sum += [decimal]$item.Value
                if ($null -eq $min -or $item.Value -lt $min) {
                    $min = $item.Value
                }
                if ($null -eq $max -or $item.Value -gt $max) {
                    $max = $item.Value
                }
            }

            # Lücken: Zwischen zwei aufeinanderfolgenden Zeitstempeln fehlen
            # so viele Intervalle, wie zusätzlich hineingepasst hätten.
            # Doppelte Zeitstempel zählen dabei nur einmal.
            $gapCount = 0
            $timestamps = @($group.Group | ForEach-Object { $_.Timestamp } | Sort-Object -Unique)
            for ($index = 1; $index -lt $timestamps.Count; $index++) {
                $minutes = ($timestamps[$index] - $timestamps[$index - 1]).TotalMinutes
                $missing = [int][math]::Floor($minutes / $IntervalMinutes) - 1
                if ($missing -gt 0) {
                    $gapCount += $missing
                }
            }

            [pscustomobject]@{
                DeviceId     = $group.Name
                Count        = $group.Count
                Sum          = [double]$sum
                Min          = $min
                Max          = $max
                InvalidCount = $invalidCount
                GapCount     = $gapCount
            }
        }
    }
}
