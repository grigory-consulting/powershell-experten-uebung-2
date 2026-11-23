function Test-Measurement {
    <#
    .SYNOPSIS
        Prüft Messwertobjekte und ergänzt IsValid und Reason.

    .DESCRIPTION
        Gibt jedes Objekt wieder aus, ergänzt um zwei Eigenschaften:

          IsValid   $true, wenn nichts gegen den Messwert spricht
          Reason    die Gründe als Text, getrennt durch Semikolon; leer bei
                    gültigen Messwerten

        Mögliche Gründe:

          Wert fehlt        Value ist $null
          Wert negativ      Value ist kleiner als 0
          Wert zu hoch      Value ist größer als -MaxValue
          Status nicht OK   Status ist nicht OK

        Ergänzt werden die Objekte selbst, es entstehen keine Kopien. Ein
        zweiter Lauf mit anderem -MaxValue überschreibt das Ergebnis des ersten.

    .PARAMETER InputObject
        Messwertobjekte aus Import-MeasurementFile.

    .PARAMETER MaxValue
        Obergrenze für plausible Werte. Ohne Angabe gibt es keine Obergrenze.

    .EXAMPLE
        Import-MeasurementFile -Path .\daten\messwerte\Nord_2026-11-23.csv | Test-Measurement

        Prüft alle Messwerte einer Datei.

    .EXAMPLE
        Import-MeasurementFile -Path .\daten\messwerte\Nord_2026-11-23.csv |
            Test-Measurement -MaxValue 1500 |
            Where-Object { -not $_.IsValid }

        Zeigt die Messwerte, gegen die etwas spricht, mit Obergrenze 1500.

    .INPUTS
        PSCustomObject mit Value und Status.

    .OUTPUTS
        Dieselben Objekte mit IsValid und Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [psobject[]]$InputObject,

        [double]$MaxValue = [double]::MaxValue
    )

    process {
        foreach ($item in $InputObject) {
            $reasons = [System.Collections.Generic.List[string]]::new()

            # Die Reihenfolge zählt: $null -lt 0 ist $true. Ohne die Prüfung
            # auf $null zuerst gälte ein fehlender Wert als negativ.
            if ($null -eq $item.Value) {
                $reasons.Add('Wert fehlt')
            }
            elseif ($item.Value -lt 0) {
                $reasons.Add('Wert negativ')
            }
            elseif ($item.Value -gt $MaxValue) {
                $reasons.Add('Wert zu hoch')
            }

            if ($item.Status -ne 'OK') {
                $reasons.Add('Status nicht OK')
            }

            $result = [ordered]@{
                IsValid = ($reasons.Count -eq 0)
                Reason  = ($reasons -join '; ')
            }
            Add-Member -InputObject $item -NotePropertyMembers $result -Force
            $item
        }
    }
}
