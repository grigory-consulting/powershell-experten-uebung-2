#Requires -Version 7.0
<#
    Hilfsskript der Selbstkontrolle. Wird per Dot-Sourcing in einen eigenen
    PowerShell-Prozess geladen, bevor dort Tests oder Skripte eines Projekts
    laufen.

    Ersetzt in diesem Prozess die Befehle, die Module, Skripte oder Pakete
    installieren, aktualisieren, entfernen oder veröffentlichen oder die
    Einstellungen der Paketquellen ändern, durch Platzhalter mit denselben
    Parametern. Ein Platzhalter ändert nichts am Rechner. Er schreibt nur eine
    Zeile nach -LogPath:

        Befehl|Name|verlangte Version|WhatIf

    Das letzte Feld ist "WhatIf", wenn der Aufruf -WhatIf trug, sonst leer.

    Der Ersatz gilt auch für Aufrufe mit dem Modulnamen davor, zum Beispiel
    PowerShellGet\Install-Module. Wer sich den echten Befehl mit Get-Command
    aus dem Modul holt und über & startet, umgeht ihn.
#>
param(
    [Parameter(Mandatory)][string]$LogPath
)

$shadowNames = @(
    # PowerShellGet
    'Install-Module', 'Update-Module', 'Save-Module', 'Uninstall-Module', 'Publish-Module'
    'Install-Script', 'Update-Script', 'Save-Script', 'Uninstall-Script', 'Publish-Script'
    'Register-PSRepository', 'Set-PSRepository', 'Unregister-PSRepository'
    # PackageManagement
    'Install-Package', 'Save-Package', 'Uninstall-Package', 'Install-PackageProvider'
    'Register-PackageSource', 'Set-PackageSource', 'Unregister-PackageSource'
    # Microsoft.PowerShell.PSResourceGet
    'Install-PSResource', 'Update-PSResource', 'Save-PSResource', 'Uninstall-PSResource', 'Publish-PSResource'
    'Register-PSResourceRepository', 'Set-PSResourceRepository', 'Unregister-PSResourceRepository'
)

# Der Pfad steht im Platzhalter in einfachen Anführungszeichen. Ein Apostroph
# im Pfad (Benutzername) wird dafür verdoppelt.
$shadowLogLiteral = $LogPath.Replace("'", "''")
$shadowFunctions = @{}

foreach ($shadowName in $shadowNames) {
    $shadowCommand = Get-Command -Name $shadowName -CommandType Function, Cmdlet -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $shadowCommand) {
        continue
    }
    $shadowMetadata = [System.Management.Automation.CommandMetadata]::new($shadowCommand)
    $shadowBinding = [System.Management.Automation.ProxyCommand]::GetCmdletBindingAttribute($shadowMetadata)
    $shadowParameters = [System.Management.Automation.ProxyCommand]::GetParamBlock($shadowMetadata)

    # Der Platzhalter nimmt zusätzlich jeden weiteren Parameter an: Manche
    # Befehle bekommen Parameter erst vom Anbieter der Paketquelle (-Scope bei
    # Install-Package). Geschrieben wird mit .NET, damit -WhatIf am Aufruf das
    # Mitschreiben nicht verhindert.
    $shadowBody = @"
$shadowBinding
param($shadowParameters,
    [Parameter(ValueFromRemainingArguments)]
    [object[]]`$ShadowRemainingArgument)
`$requestedVersion = "`$(`$PSBoundParameters['RequiredVersion'])`$(`$PSBoundParameters['Version'])"
`$requestedMode = if (`$PSBoundParameters['WhatIf']) { 'WhatIf' } else { '' }
foreach (`$requestedName in @(`$PSBoundParameters['Name'])) {
    [System.IO.File]::AppendAllLines('$shadowLogLiteral', [string[]]@("$shadowName|`$requestedName|`$requestedVersion|`$requestedMode"))
}
"@
    Set-Item -Path "function:global:$shadowName" -Value ([scriptblock]::Create($shadowBody))
    $shadowFunctions[$shadowName] = Get-Item -Path "function:$shadowName"
}

# Ein Aufruf mit Modulnamen (PowerShellGet\Install-Module) fände den echten
# Befehl. Diese Stelle lenkt ihn auf den Platzhalter um. Sie läuft vor jeder
# Befehlssuche und benutzt deshalb selbst keinen Befehl.
$ExecutionContext.InvokeCommand.PreCommandLookupAction = {
    param($commandName, $lookup)

    $separator = $commandName.LastIndexOf('\')
    if ($separator -ge 0) {
        $shadowFunction = $shadowFunctions[$commandName.Substring($separator + 1)]
        if ($shadowFunction) {
            $lookup.Command = $shadowFunction
            $lookup.StopSearch = $true
        }
    }
}.GetNewClosure()
