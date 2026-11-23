#Requires -Version 7.0
<#
    Hilfsskript der Selbstkontrolle. Läuft in einem eigenen PowerShell-Prozess.

    Führt ein Installationsskript aus, ohne etwas zu installieren: Befehle, die
    Module installieren, sind in diesem Prozess durch Platzhalter ersetzt, die
    nur mitschreiben, welches Modul in welcher Version angefordert wird und ob
    der Aufruf -WhatIf trug (Set-InstallShadow.ps1). Das Ergebnis steht danach
    als JSON in -ResultPath.

    Mit -WithWhatIf startet das Skript mit dem Parameter -WhatIf.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScriptPath,
    [Parameter(Mandatory)][string]$ResultPath,
    [switch]$WithWhatIf
)

$requestLog = [System.IO.Path]::GetTempFileName()
. (Join-Path $PSScriptRoot 'Set-InstallShadow.ps1') -LogPath $requestLog

$failure = ''
try {
    if ($WithWhatIf) {
        & $ScriptPath -WhatIf | Out-Null
    }
    else {
        & $ScriptPath | Out-Null
    }
}
catch {
    $failure = "$_"
}

$requests = foreach ($line in (Get-Content -LiteralPath $requestLog)) {
    $command, $moduleName, $version, $mode = $line.Split('|')
    [pscustomobject]@{ Command = $command; Name = $moduleName; Version = $version; WhatIf = ($mode -eq 'WhatIf') }
}
Remove-Item -LiteralPath $requestLog

$result = [pscustomobject]@{
    Failure  = $failure
    Requests = @($requests)
}
ConvertTo-Json -InputObject $result -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding utf8
