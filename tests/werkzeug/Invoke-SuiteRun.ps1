#Requires -Version 7.0
<#
    Hilfsskript der Selbstkontrolle. Läuft in einem eigenen PowerShell-Prozess.

    Baut aus dem Projekt mehrere Arbeitskopien, legt in jede eine andere Fassung
    des Moduls und führt dort die Tests des Projekts aus. Das Ergebnis je Lauf
    steht danach als JSON in -ResultPath.

    In jeder Arbeitskopie liegen die Dateien des Projekts ohne .git, ohne daten
    und ohne Berichte. Das Modul kommt aus -BaseModule, darüber die Dateien der
    jeweiligen Fassung. Befehle, die Module installieren, sind in diesem Prozess
    durch Platzhalter ersetzt, die nur mitschreiben (Set-InstallShadow.ps1): Die
    Kontrolle installiert nichts.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Die Parameter werden in den Funktionen des Skripts benutzt.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectRoot,
    [Parameter(Mandatory)][string]$BaseModule,
    [Parameter(Mandatory)][string]$VariantRoot,
    [Parameter(Mandatory)][string]$SandboxRoot,
    [Parameter(Mandatory)][string]$ResultPath
)

# Kein $ErrorActionPreference = 'Stop' in diesem Skript: Die Einstellung würde
# bis in die Tests des Projekts durchschlagen und dort jeden gemeldeten Fehler
# zum Abbruch machen.
Import-Module -Name Pester -MinimumVersion 5.0 -MaximumVersion 5.99 -ErrorAction Stop

$installLog = Join-Path $SandboxRoot 'install-calls.txt'
. (Join-Path $PSScriptRoot 'Set-InstallShadow.ps1') -LogPath $installLog

function Copy-ProjectSandbox {
    param([string]$Name, [string]$Overlay)

    $sandbox = Join-Path $SandboxRoot $Name
    $null = New-Item -ItemType Directory -Path $sandbox -Force
    $skip = '.git', 'daten', 'MeasurementTools', 'testResults.xml', 'coverage.xml'
    Get-ChildItem -LiteralPath $ProjectRoot -Force |
        Where-Object { $skip -notcontains $_.Name } |
        Copy-Item -Destination $sandbox -Recurse -Force
    Copy-Item -LiteralPath $BaseModule -Destination (Join-Path $sandbox 'MeasurementTools') -Recurse -Force
    if ($Overlay) {
        Get-ChildItem -LiteralPath $Overlay -Force | Copy-Item -Destination $sandbox -Recurse -Force
    }
    $sandbox
}

function Invoke-SandboxTest {
    param([string]$Name, [string]$Overlay, [string]$Culture)

    $sandbox = Copy-ProjectSandbox -Name $Name -Overlay $Overlay
    Get-Module -Name MeasurementTools | Remove-Module -Force
    if (Test-Path -LiteralPath $installLog) {
        Remove-Item -LiteralPath $installLog
    }

    $cultureBefore = [cultureinfo]::CurrentCulture
    [cultureinfo]::CurrentCulture = [cultureinfo]::GetCultureInfo($Culture)
    Push-Location -LiteralPath $sandbox
    try {
        $config = New-PesterConfiguration
        $config.Run.Path = (Join-Path $sandbox 'tests')
        $config.Run.PassThru = $true
        $config.Output.Verbosity = 'None'
        $run = Invoke-Pester -Configuration $config
    }
    finally {
        Pop-Location
        [cultureinfo]::CurrentCulture = $cultureBefore
    }

    # Jede Zeile im Protokoll ist ein Aufruf, der einen Platzhalter erreicht
    # hat. Das letzte Feld sagt, ob der Aufruf -WhatIf trug.
    $installCalls = @()
    if (Test-Path -LiteralPath $installLog) {
        $installCalls = @(Get-Content -LiteralPath $installLog)
    }

    [pscustomobject]@{
        Name                = $Name
        Culture             = $Culture
        Result              = "$($run.Result)"
        Total               = $run.TotalCount
        Passed              = $run.PassedCount
        Failed              = $run.FailedCount
        FailedTests         = @($run.Failed | ForEach-Object { $_.ExpandedPath })
        InstallCalls        = $installCalls.Count
        InstallCallsForReal = @($installCalls | Where-Object { -not $_.EndsWith('|WhatIf') }).Count
    }
}

$results = @(
    Invoke-SandboxTest -Name 'unveraendert-de-DE' -Overlay '' -Culture 'de-DE'
    Invoke-SandboxTest -Name 'unveraendert-en-US' -Overlay '' -Culture 'en-US'
    foreach ($variant in (Get-ChildItem -LiteralPath $VariantRoot -Directory | Sort-Object -Property Name)) {
        Invoke-SandboxTest -Name $variant.Name -Overlay $variant.FullName -Culture 'de-DE'
    }
)

ConvertTo-Json -InputObject $results -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding utf8
