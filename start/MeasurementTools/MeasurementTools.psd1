#
# Modulmanifest für das Modul MeasurementTools
# Erzeugt aus der Projektvorlage "Skriptmodul".
#

@{

    # Skriptdatei, die beim Import des Moduls geladen wird.
    RootModule           = 'MeasurementTools.psm1'

    # Version des Moduls.
    ModuleVersion        = '0.1.0'

    # Unterstützte Editionen: Desktop ist Windows PowerShell 5.1, Core ist PowerShell 7.
    CompatiblePSEditions = @('Desktop', 'Core')

    # Eindeutige Kennung des Moduls.
    GUID                 = 'adaed64e-d376-4296-8387-c65b83e1bf34'

    # Autor des Moduls.
    Author               = 'Kursteam Messwerte'

    # Beschreibung des Moduls.
    Description          = 'Liest Messwertdateien ein, prüft die Werte und fasst sie je Gerät zusammen.'

    # Mindestens erforderliche PowerShell-Version.
    PowerShellVersion    = '5.1'

    # Aus dem Modul exportierte Funktionen.
    FunctionsToExport    = @('Import-MeasurementFile', 'Test-Measurement', 'Get-MeasurementSummary')

    # Aus dem Modul exportierte Cmdlets.
    CmdletsToExport      = @()

    # Aus dem Modul exportierte Variablen.
    VariablesToExport    = @()

    # Aus dem Modul exportierte Aliase.
    AliasesToExport      = @()

}
