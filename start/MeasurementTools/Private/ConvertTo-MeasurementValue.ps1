function ConvertTo-MeasurementValue {
    <#
    .SYNOPSIS
        Wandelt den Text eines Messwerts in eine Zahl um.

    .DESCRIPTION
        Liest den Text in der genannten Kultur, unabhängig von der Kultur der
        Sitzung. Ein leerer Text ergibt $null: Ein fehlender Wert ist keine 0.

        Erlaubt sind Vorzeichen, Dezimaltrennzeichen und Exponent, aber keine
        Tausendertrennzeichen. Ein Text im Format einer anderen Kultur (zum
        Beispiel 100.50 bei de-DE) führt deshalb zu einem Fehler und nicht zu
        einer falschen Zahl.

    .PARAMETER Text
        Der Wert als Text, zum Beispiel 1234,56.

    .PARAMETER Culture
        Kultur, in der der Text geschrieben ist.

    .OUTPUTS
        System.Double oder $null.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [string]$Text,

        [Parameter(Mandatory)]
        [cultureinfo]$Culture
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    # Ohne die Angabe von NumberStyles erlaubt Parse auch Tausendertrennzeichen.
    # Unter de-DE ist das der Punkt: Aus 100.50 würde still 10050.
    [double]::Parse($Text, [System.Globalization.NumberStyles]::Float, $Culture)
}
