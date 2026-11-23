#Requires -Version 5.1

# Lädt die Funktionsdateien des Moduls. Dot-Sourcing führt jede Datei im Scope
# des Moduls aus: Die Funktionen bleiben nach dem Laden bestehen. Mit dem
# Aufrufoperator & wären sie am Ende jeder Datei wieder verschwunden.
$publicFiles = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1')
$privateFiles = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1')

foreach ($file in ($privateFiles + $publicFiles)) {
    . $file.FullName
}

# Nach außen gehen nur die Funktionen aus Public\. Das Manifest nennt dieselben
# Namen noch einmal: Beide Angaben wirken wie zwei Filter hintereinander.
Export-ModuleMember -Function $publicFiles.BaseName
