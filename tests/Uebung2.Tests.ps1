#Requires -Version 7.0
<#
    Selbstkontrolle für Übung 2.

    Start aus dem Ordner der Übung:

        Invoke-Pester .\tests -Output Detailed

    Nur eine Aufgabe prüfen (Aufgabe1, Aufgabe2, Aufgabe3, Aufgabe4, Zusatz):

        Invoke-Pester .\tests -Output Detailed -TagFilter Aufgabe2

    Geprüft wird Ihr Projekt. Die Kontrolle sucht es unter measurement-tools in
    Ihrem Benutzerordner. Liegt es woanders, nennen Sie den Ordner vorher:

        $env:MEASUREMENT_PROJECT = 'D:\Arbeit\measurement-tools'

    Die Kontrolle ändert nichts an Ihrem Projekt. Sie legt Arbeitskopien im
    temporären Ordner des Systems an, führt dort Ihre Tests und Ihre Skripte
    aus und räumt die Kopien am Ende weg. Sie installiert nichts.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester: Variablen aus BeforeAll werden in den It-Blöcken benutzt.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'ProjectRoot', Justification = 'Pester: Der Parameter wird in BeforeAll benutzt.')]
param(
    # Ordner des Projekts, das geprüft wird.
    [string]$ProjectRoot = $(if ($env:MEASUREMENT_PROJECT) { $env:MEASUREMENT_PROJECT } else { Join-Path $HOME 'measurement-tools' })
)

BeforeAll {
    $packRoot = Split-Path -Parent $PSScriptRoot
    $baseModule = Join-Path (Join-Path $packRoot 'start') 'MeasurementTools'
    $variantArchive = Join-Path $PSScriptRoot 'fassungen.zip'
    $toolRoot = Join-Path $PSScriptRoot 'werkzeug'
    $shell = (Get-Process -Id $PID).Path

    $sandboxRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('uebung2-kontrolle-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $sandboxRoot

    function Assert-Project {
        # Bricht den Test mit einer klaren Meldung ab, wenn das Projekt fehlt.
        if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
            throw "Projektordner nicht gefunden: $ProjectRoot. Legen Sie ihn an wie im README unter Vorbereitung, oder setzen Sie `$env:MEASUREMENT_PROJECT."
        }
    }

    function Assert-ProjectFile {
        # Bricht den Test ab, wenn eine Datei des Projekts fehlt.
        param([string]$RelativePath)

        Assert-Project
        if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot $RelativePath) -PathType Leaf)) {
            throw "Im Projekt fehlt die Datei $RelativePath."
        }
    }

    function Assert-Repository {
        # Bricht den Test ab, wenn der Projektordner kein eigenes Repository ist.
        Assert-Project
        $prefix = Invoke-Git -Arguments 'rev-parse', '--show-prefix'
        if ($prefix.ExitCode -ne 0) {
            throw "Der Projektordner ist noch kein Git-Repository: $ProjectRoot"
        }
        if ("$($prefix.Output)" -ne '') {
            throw "Der Projektordner liegt in einem anderen Repository und hat kein eigenes: $ProjectRoot"
        }
    }

    function Invoke-Git {
        # Ruft git im Projektordner auf und liefert Exitcode und Ausgabe.
        param([string[]]$Arguments)

        $output = @()
        $exitCode = -1
        if (Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue) {
            $output = @(& git -C $ProjectRoot @Arguments 2>$null)
            $exitCode = $LASTEXITCODE
        }
        [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
    }

    function Copy-ProjectSandbox {
        # Kopiert das Projekt ohne .git, ohne daten und ohne Berichte in einen
        # neuen Ordner und gibt dessen Pfad zurück.
        param([string]$Name)

        $sandbox = Join-Path $sandboxRoot $Name
        $null = New-Item -ItemType Directory -Path $sandbox -Force
        $skip = '.git', 'daten', 'testResults.xml', 'coverage.xml'
        Get-ChildItem -LiteralPath $ProjectRoot -Force |
            Where-Object { $skip -notcontains $_.Name } |
            Copy-Item -Destination $sandbox -Recurse -Force
        $sandbox
    }

    function Invoke-SandboxScript {
        # Startet ein Skript der Arbeitskopie in einem eigenen Prozess und gibt
        # den Prozess zurück, ohne auf sein Ende zu warten.
        #
        # Der Prozess startet nicht das Skript selbst, sondern ein Startskript
        # außerhalb der Arbeitskopie. Es ersetzt zuerst die Befehle, die Module
        # installieren, durch Platzhalter, ruft dann das Skript auf und endet
        # mit dem Exitcode, den pwsh -NoProfile -File <Skript> hätte: 1 nach
        # einer Ausnahme, der Wert von exit, sonst 0. Endet das Skript ohne
        # exit und ohne Ausnahme, zählt ein Exitcode nicht, den nur ein Befehl
        # im Skript hinterlassen hat (ein natives Programm oder Invoke-Pester
        # ohne Run.Exit): Dann ist $? wahr, und auch pwsh -File endet mit 0.
        param([string]$Sandbox, [string]$Script, [string]$Culture)

        # Die Pfade stehen im Startskript in einfachen Anführungszeichen, ein
        # Apostroph im Pfad wird dafür verdoppelt. Start-Process setzt um ein
        # Argument keine Anführungszeichen: Der Pfad des Startskripts bekommt
        # sie hier, sonst zerfiele er an jedem Leerzeichen.
        $launcher = "$Sandbox.start.ps1"
        $shadowScript = (Join-Path $toolRoot 'Set-InstallShadow.ps1').Replace("'", "''")
        $shadowLog = "$Sandbox.install.txt".Replace("'", "''")
        $lines = @(
            ". '$shadowScript' -LogPath '$shadowLog'"
            if ($Culture) { "[cultureinfo]::CurrentCulture = [cultureinfo]::GetCultureInfo('$Culture')" }
            '$global:LASTEXITCODE = 0'
            "& './$Script'"
            'if ($?) { exit 0 }'
            'exit $LASTEXITCODE'
        )
        Set-Content -LiteralPath $launcher -Value $lines

        $start = @{
            FilePath               = $shell
            ArgumentList           = @('-NoProfile', '-File', "`"$launcher`"")
            WorkingDirectory       = $Sandbox
            RedirectStandardOutput = "$Sandbox.ausgabe.txt"
            RedirectStandardError  = "$Sandbox.fehler.txt"
            PassThru               = $true
        }
        if ($IsWindows) {
            $start.WindowStyle = 'Hidden'
        }
        Start-Process @start
    }

    function Wait-SandboxScript {
        # Wartet auf den Prozess und liefert Exitcode und Ausgabe.
        param($Process, [string]$Sandbox)

        if (-not $Process.WaitForExit(300000)) {
            $Process.Kill()
        }
        $Process.WaitForExit()
        [pscustomobject]@{
            ExitCode = $Process.ExitCode
            Output   = (Get-Content -LiteralPath "$Sandbox.ausgabe.txt" -Raw -ErrorAction SilentlyContinue)
            Sandbox  = $Sandbox
        }
    }

    function Invoke-SuiteRun {
        # Führt die Tests des Projekts gegen das unveränderte Modul und gegen
        # jede Fassung unter -Variants aus. Liefert die Läufe nach Namen.
        param([string]$Name, [string]$Variants)

        $runRoot = Join-Path $sandboxRoot $Name
        $null = New-Item -ItemType Directory -Path $runRoot -Force
        $resultPath = Join-Path $runRoot 'ergebnis.json'
        $arguments = @(
            '-NoProfile', '-File', (Join-Path $toolRoot 'Invoke-SuiteRun.ps1')
            '-ProjectRoot', $ProjectRoot
            '-BaseModule', $baseModule
            '-VariantRoot', $Variants
            '-SandboxRoot', $runRoot
            '-ResultPath', $resultPath
        )
        $null = & $shell @arguments 2>&1

        $runs = @{}
        if (Test-Path -LiteralPath $resultPath) {
            foreach ($run in (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)) {
                $runs[$run.Name] = $run
            }
        }
        $runs
    }

    function Get-ProjectTestFile {
        # Liefert die Testdateien des Projekts.
        @(Get-ChildItem -Path (Join-Path $ProjectRoot 'tests') -Filter '*.Tests.ps1' -Recurse -File -ErrorAction SilentlyContinue)
    }
}

AfterAll {
    if (Test-Path -LiteralPath $sandboxRoot) {
        Remove-Item -LiteralPath $sandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Aufgabe 1: Das Projekt ist ein Repository' -Tag 'Aufgabe1' {

    It 'ist ein eigenes Git-Repository mit dem Branch main' {
        Assert-Repository
        if ((Invoke-Git -Arguments 'rev-parse', '--verify', '--quiet', 'refs/heads/main').ExitCode -ne 0) {
            throw 'Im Repository gibt es keinen Branch main mit einem Commit.'
        }
    }

    It 'hat auf main mindestens einen Commit mit den sechs Dateien des Moduls' {
        Assert-Repository
        $files = @((Invoke-Git -Arguments 'ls-tree', '-r', '--name-only', 'main', '--', 'MeasurementTools').Output)
        $files | Should -HaveCount 6
    }

    It 'hält erzeugte Dateien aus dem Repository heraus: keine Übungsdaten, kein Testbericht, keine Coverage' {
        Assert-Repository
        $tracked = Invoke-Git -Arguments 'ls-files'
        $generated = @($tracked.Output | Where-Object { $_ -like 'daten/*' -or $_ -in 'testResults.xml', 'coverage.xml' })
        if ($generated.Count -gt 0) {
            throw "Im Repository liegen $($generated.Count) erzeugte Dateien, zum Beispiel $($generated[0])."
        }
    }

    It 'ignoriert <_>' -ForEach 'daten/messwerte/Nord_2026-11-23.csv', 'testResults.xml', 'coverage.xml' {
        Assert-Repository
        if ((Invoke-Git -Arguments 'check-ignore', '--quiet', '--no-index', $_).ExitCode -ne 0) {
            throw "Git würde $_ in den nächsten Commit aufnehmen: Keine Regel in .gitignore passt auf den Pfad."
        }
    }
}

Describe 'Aufgabe 2: Tests für das Modul' -Tag 'Aufgabe2' {

    BeforeAll {
        $suiteRuns = @{}
        if (@(Get-ProjectTestFile).Count -gt 0) {
            # Die sechs Fassungen liegen gepackt im Kursmaterial und werden nur
            # in den temporären Ordner der Kontrolle ausgepackt.
            $variantRoot = Join-Path $sandboxRoot 'fassungen'
            Expand-Archive -LiteralPath $variantArchive -DestinationPath $variantRoot
            $suiteRuns = Invoke-SuiteRun -Name 'aufgabe2' -Variants $variantRoot
        }

        function Assert-SuiteGreen {
            # Die Tests müssen gegen das unveränderte Modul bestehen, bevor
            # eine Aussage über die Fassungen möglich ist.
            param([string]$Culture)

            Assert-Project
            if (@(Get-ProjectTestFile).Count -eq 0) {
                throw 'Im Projekt liegt unter tests noch keine Datei mit der Endung .Tests.ps1.'
            }
            $run = $suiteRuns["unveraendert-$Culture"]
            if (-not $run) {
                throw 'Der Testlauf in der Arbeitskopie ist nicht zustande gekommen.'
            }
            if ($run.Total -eq 0) {
                throw 'Pester hat in Ihren Testdateien keinen einzigen Test gefunden.'
            }
            if ($run.Result -ne 'Passed') {
                $names = @($run.FailedTests) -join '; '
                throw "Gegen das unveränderte Modul bestehen $($run.Passed) von $($run.Total) Tests (Sitzung mit der Kultur $Culture, ohne den Ordner daten). Nicht bestanden: $names"
            }
            $run
        }
    }

    It 'bestehen gegen das unveränderte Modul, in einer Arbeitskopie ohne den Ordner daten (Sitzung mit der Kultur <_>)' -ForEach 'de-DE', 'en-US' {
        $null = Assert-SuiteGreen -Culture $_
    }

    It 'bemerken Fassung <Number> (weicht in <Function> vom Modul ab)' -ForEach @(
        @{ Number = 1; Function = 'Import-MeasurementFile' }
        @{ Number = 2; Function = 'Import-MeasurementFile' }
        @{ Number = 3; Function = 'Test-Measurement' }
        @{ Number = 4; Function = 'Test-Measurement' }
        @{ Number = 5; Function = 'Get-MeasurementSummary' }
        @{ Number = 6; Function = 'Get-MeasurementSummary' }
    ) {
        $null = Assert-SuiteGreen -Culture 'de-DE'
        $run = $suiteRuns["fassung-$Number"]
        if ($run.Result -ne 'Failed') {
            throw "Alle $($run.Total) Tests bestehen auch mit Fassung $Number. Diese Fassung verhält sich in $Function anders als das Modul."
        }
    }
}

Describe 'Aufgabe 3: Analyse und Tests als Skripte' -Tag 'Aufgabe3' {

    BeforeAll {
        $analysisScript = 'ci/Invoke-Analysis.ps1'
        $testScript = 'ci/Invoke-Tests.ps1'
        $hasAnalysis = Test-Path -LiteralPath (Join-Path $ProjectRoot $analysisScript) -PathType Leaf
        $hasTests = Test-Path -LiteralPath (Join-Path $ProjectRoot $testScript) -PathType Leaf
        $ciRuns = @{}
        $started = @{}

        if ($hasAnalysis) {
            # Das Projekt, wie es ist.
            $sandbox = Copy-ProjectSandbox -Name 'analyse'
            $started['analyse'] = @{ Sandbox = $sandbox; Process = (Invoke-SandboxScript -Sandbox $sandbox -Script $analysisScript) }

            # Dazu eine Funktion im Modul mit einer Variablen, die niemand liest.
            $sandbox = Copy-ProjectSandbox -Name 'analyse-modul'
            Set-Content -LiteralPath (Join-Path $sandbox 'MeasurementTools/Private/Get-ControlSample.ps1') -Encoding utf8BOM -Value @'
function Get-ControlSample {
    [CmdletBinding()]
    param()

    $unused = 42
    'Kontrolle'
}
'@
            $started['analyse-modul'] = @{ Sandbox = $sandbox; Process = (Invoke-SandboxScript -Sandbox $sandbox -Script $analysisScript) }

            # Dazu eine Testdatei, die einen Alias benutzt.
            $sandbox = Copy-ProjectSandbox -Name 'analyse-tests'
            $null = New-Item -ItemType Directory -Path (Join-Path $sandbox 'tests') -Force
            Set-Content -LiteralPath (Join-Path $sandbox 'tests/ControlSample.Tests.ps1') -Encoding utf8BOM -Value @'
Describe 'Kontrolle' {
    It 'listet Dateien' {
        gci | Should -Not -BeNullOrEmpty
    }
}
'@
            $started['analyse-tests'] = @{ Sandbox = $sandbox; Process = (Invoke-SandboxScript -Sandbox $sandbox -Script $analysisScript) }
        }

        if ($hasTests) {
            # Das Projekt, wie es ist.
            $sandbox = Copy-ProjectSandbox -Name 'tests'
            $started['tests'] = @{ Sandbox = $sandbox; Process = (Invoke-SandboxScript -Sandbox $sandbox -Script $testScript) }

            # Eine Funktion, die kein Test aufruft: 19 Befehle.
            $untestedFunction = @'
function Get-MeasurementRange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [psobject[]]$InputObject
    )

    begin {
        $ranges = @{}
    }

    process {
        foreach ($item in $InputObject) {
            if ($null -eq $item.Value) {
                continue
            }
            if (-not $ranges.ContainsKey($item.DeviceId)) {
                $ranges[$item.DeviceId] = [pscustomobject]@{
                    DeviceId = $item.DeviceId
                    Lowest   = $item.Value
                    Highest  = $item.Value
                    Range    = 0.0
                }
            }
            $entry = $ranges[$item.DeviceId]
            if ($item.Value -lt $entry.Lowest) {
                $entry.Lowest = $item.Value
            }
            if ($item.Value -gt $entry.Highest) {
                $entry.Highest = $item.Value
            }
            $entry.Range = $entry.Highest - $entry.Lowest
        }
    }

    end {
        foreach ($key in ($ranges.Keys | Sort-Object)) {
            $ranges[$key]
        }
    }
}
'@

            # Das Projekt mit dieser Funktion in einer Sitzung mit deutscher
            # Kultur: Die Coverage hat dann Nachkommastellen.
            $sandbox = Copy-ProjectSandbox -Name 'tests-kultur'
            Set-Content -LiteralPath (Join-Path $sandbox 'MeasurementTools/Public/Get-MeasurementRange.ps1') -Encoding utf8BOM -Value $untestedFunction
            $started['tests-kultur'] = @{ Sandbox = $sandbox; Process = (Invoke-SandboxScript -Sandbox $sandbox -Script $testScript -Culture 'de-DE') }

            # Dazu ein Test, der fehlschlägt.
            $sandbox = Copy-ProjectSandbox -Name 'tests-rot'
            $null = New-Item -ItemType Directory -Path (Join-Path $sandbox 'tests') -Force
            Set-Content -LiteralPath (Join-Path $sandbox 'tests/ControlSample.Tests.ps1') -Value @'
Describe 'Kontrolle' {
    It 'schlägt fehl' {
        1 | Should -Be 2
    }
}
'@
            $started['tests-rot'] = @{ Sandbox = $sandbox; Process = (Invoke-SandboxScript -Sandbox $sandbox -Script $testScript) }

            # Dazu eine Funktion im Modul, die kein Test aufruft.
            $sandbox = Copy-ProjectSandbox -Name 'tests-neue-funktion'
            Set-Content -LiteralPath (Join-Path $sandbox 'MeasurementTools/Public/Get-MeasurementRange.ps1') -Encoding utf8BOM -Value $untestedFunction
            $started['tests-neue-funktion'] = @{ Sandbox = $sandbox; Process = (Invoke-SandboxScript -Sandbox $sandbox -Script $testScript) }
        }

        foreach ($name in @($started.Keys)) {
            $ciRuns[$name] = Wait-SandboxScript -Process $started[$name].Process -Sandbox $started[$name].Sandbox
        }
    }

    It 'ci/Invoke-Analysis.ps1 endet für Ihr Projekt mit dem Exitcode 0' {
        Assert-ProjectFile -RelativePath $analysisScript
        $run = $ciRuns['analyse']
        if ($run.ExitCode -ne 0) {
            throw "Exitcode $($run.ExitCode). Ausgabe des Skripts:`n$($run.Output)"
        }
    }

    It 'ci/Invoke-Analysis.ps1 endet mit einem Exitcode ungleich 0, wenn im Modul eine Variable zugewiesen und nie gelesen wird' {
        Assert-ProjectFile -RelativePath $analysisScript
        if ($ciRuns['analyse-modul'].ExitCode -eq 0) {
            throw 'Exitcode 0: Die Analyse hat die Variable $unused in einer neuen Funktion des Moduls nicht gemeldet.'
        }
    }

    It 'ci/Invoke-Analysis.ps1 endet mit einem Exitcode ungleich 0, wenn eine Testdatei einen Alias wie gci benutzt' {
        Assert-ProjectFile -RelativePath $analysisScript
        if ($ciRuns['analyse-tests'].ExitCode -eq 0) {
            throw 'Exitcode 0: Die Analyse hat den Alias gci in einer neuen Testdatei unter tests nicht gemeldet.'
        }
    }

    It 'ci/Invoke-Tests.ps1 endet für Ihr Projekt mit dem Exitcode 0' {
        Assert-ProjectFile -RelativePath $testScript
        $run = $ciRuns['tests']
        if ($run.ExitCode -ne 0) {
            throw "Exitcode $($run.ExitCode). Ende der Ausgabe des Skripts:`n$(@($run.Output -split "`n" | Select-Object -Last 15) -join "`n")"
        }
    }

    It 'ci/Invoke-Tests.ps1 schreibt testResults.xml im Format JUnit' {
        Assert-ProjectFile -RelativePath $testScript
        $report = Join-Path $ciRuns['tests'].Sandbox 'testResults.xml'
        $report | Should -Exist
        # LocalName statt Name: Das Wurzelelement hat ein Attribut name, und das
        # verdeckt in PowerShell die gleichnamige Eigenschaft des Knotens.
        ([xml](Get-Content -LiteralPath $report -Raw)).DocumentElement.LocalName | Should -Be 'testsuites'
    }

    It 'ci/Invoke-Tests.ps1 schreibt coverage.xml' {
        Assert-ProjectFile -RelativePath $testScript
        $report = Join-Path $ciRuns['tests'].Sandbox 'coverage.xml'
        $report | Should -Exist
        ([xml](Get-Content -LiteralPath $report -Raw)).DocumentElement | Should -Not -BeNullOrEmpty
    }

    It 'ci/Invoke-Tests.ps1 endet mit einem Exitcode ungleich 0, wenn ein Test fehlschlägt, und schreibt den Testbericht trotzdem' {
        Assert-ProjectFile -RelativePath $testScript
        $run = $ciRuns['tests-rot']
        if ($run.ExitCode -eq 0) {
            throw 'Exitcode 0, obwohl ein Test fehlgeschlagen ist. Eine Pipeline hielte diesen Lauf für erfolgreich.'
        }
        if (-not (Test-Path -LiteralPath (Join-Path $run.Sandbox 'testResults.xml'))) {
            throw 'Bei einem roten Test fehlt testResults.xml. GitLab könnte den fehlgeschlagenen Test nicht anzeigen.'
        }
    }

    It 'ci/Invoke-Tests.ps1 endet mit einem Exitcode ungleich 0, wenn im Modul eine Funktion ohne Tests dazukommt' {
        Assert-ProjectFile -RelativePath $testScript
        if ($ciRuns['tests'].ExitCode -ne 0) {
            throw 'Der Lauf muss zuerst für Ihr Projekt mit dem Exitcode 0 enden.'
        }
        if ($ciRuns['tests-neue-funktion'].ExitCode -eq 0) {
            $line = [regex]::Matches("$($ciRuns['tests-neue-funktion'].Output)", 'Covered [^\r\n]*') | Select-Object -Last 1
            throw "Exitcode 0, obwohl eine Funktion aus 19 Befehlen ohne jeden Test dazugekommen ist. Zeile im Log: $line"
        }
    }

    It 'ci/Invoke-Tests.ps1 schreibt die Coverage auch in einer deutschen Sitzung so ins Log, dass GitLab die ganze Zahl liest' {
        Assert-ProjectFile -RelativePath $testScript
        # GitLab sucht im Log mit dem Muster für Pester, nimmt den letzten
        # Treffer und liest daraus die erste Zahl. Als Dezimaltrenner gilt
        # dabei nur der Punkt.
        $log = "$($ciRuns['tests-kultur'].Output)"
        $hits = [regex]::Matches($log, 'Covered \d{1,3}[.,]?\d{0,2}%')

        # Eine Zeile mit mehr als zwei Nachkommastellen passt nicht auf das
        # Muster: GitLab überginge sie.
        $tooLong = [regex]::Matches($log, 'Covered \d{1,3}[.,]\d{3,}%') | Select-Object -Last 1
        $tooLongText = ''
        if ($tooLong) {
            $tooLongText = " Die Zeile '$($tooLong.Value)' zählt nicht: Das Muster von GitLab lässt höchstens zwei Nachkommastellen zu."
        }

        if ($hits.Count -eq 0) {
            throw "Im Log steht keine Zeile der Form `"Covered 87.5%`".$tooLongText"
        }
        $last = $hits[$hits.Count - 1].Value
        if ($last.Contains(',')) {
            throw "Der letzte Treffer im Log ist '$last'. GitLab läse daraus nur die Zahl vor dem Komma.$tooLongText"
        }
    }
}

Describe 'Aufgabe 4: Pipeline (Vorabprüfung ohne Server)' -Tag 'Aufgabe4' {

    BeforeAll {
        $pipelineFile = Join-Path $ProjectRoot '.gitlab-ci.yml'
        $pipelineText = ''
        if (Test-Path -LiteralPath $pipelineFile -PathType Leaf) {
            $pipelineText = Get-Content -LiteralPath $pipelineFile -Raw
        }

        $installScript = Join-Path (Join-Path $ProjectRoot 'ci') 'Install-Modules.ps1'
        $installProbe = $null
        if (Test-Path -LiteralPath $installScript -PathType Leaf) {
            $probeRoot = Join-Path $sandboxRoot 'aufgabe4'
            $null = New-Item -ItemType Directory -Path $probeRoot -Force
            $resultPath = Join-Path $probeRoot 'ergebnis.json'
            $arguments = @(
                '-NoProfile', '-File', (Join-Path $toolRoot 'Invoke-InstallProbe.ps1')
                '-ScriptPath', $installScript
                '-ResultPath', $resultPath
            )
            $null = & $shell @arguments 2>&1
            if (Test-Path -LiteralPath $resultPath) {
                $installProbe = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            }
        }
    }

    It '.gitlab-ci.yml liegt im Stamm des Projekts und ist committet' {
        Assert-ProjectFile -RelativePath '.gitlab-ci.yml'
        Assert-Repository
        $state = Invoke-Git -Arguments 'status', '--porcelain', '--', '.gitlab-ci.yml'
        if ((Invoke-Git -Arguments 'ls-files', '--error-unmatch', '.gitlab-ci.yml').ExitCode -ne 0 -or "$($state.Output)" -ne '') {
            throw 'Die Datei .gitlab-ci.yml ist noch nicht oder nicht in ihrem aktuellen Stand committet.'
        }
    }

    It 'jedes Skript, das .gitlab-ci.yml aufruft, liegt unter genau diesem Namen im Repository (Schrägstriche, Groß- und Kleinschreibung)' {
        Assert-ProjectFile -RelativePath '.gitlab-ci.yml'
        $called = @([regex]::Matches($pipelineText, '[^\s''"]+\.ps1') | ForEach-Object { $_.Value } | Sort-Object -Unique)
        if ($called.Count -eq 0) {
            throw 'In .gitlab-ci.yml ruft kein Job ein Skript aus dem Repository auf.'
        }
        Assert-Repository
        $tracked = @((Invoke-Git -Arguments 'ls-files').Output)
        $missing = @($called | Where-Object { $tracked -cnotcontains $_ })
        if ($missing.Count -gt 0) {
            throw "Nicht unter diesem Namen im Repository: $($missing -join ', ')"
        }
    }

    It '.gitlab-ci.yml nennt die Berichte testResults.xml und coverage.xml' {
        Assert-ProjectFile -RelativePath '.gitlab-ci.yml'
        $pipelineText | Should -MatchExactly 'testResults\.xml'
        $pipelineText | Should -MatchExactly 'coverage\.xml'
    }

    It 'ci/Install-Modules.ps1 fordert Pester in Version 5.9.1 und PSScriptAnalyzer in einer festen Version an' {
        Assert-ProjectFile -RelativePath 'ci/Install-Modules.ps1'
        if (-not $installProbe) {
            throw 'Das Installationsskript ließ sich in der Arbeitskopie nicht ausführen.'
        }
        if ($installProbe.Failure) {
            throw "Das Installationsskript ist mit einem Fehler abgebrochen: $($installProbe.Failure)"
        }
        $requests = @($installProbe.Requests)
        $pester = @($requests | Where-Object Name -eq 'Pester')
        $analyzer = @($requests | Where-Object Name -eq 'PSScriptAnalyzer')

        # Die Vorabprüfung läuft auf dem Rechner der Teilnehmenden. Ein Skript,
        # das vorher nachsieht, was schon installiert ist, fordert dort nichts
        # an. Die Meldung nennt diesen Fall.
        $notRequested = @('Pester', 'PSScriptAnalyzer' | Where-Object { $requests.Name -notcontains $_ })
        if ($notRequested.Count -gt 0) {
            throw "Das Skript hat $($notRequested -join ' und ') nicht angefordert. Die Vorabprüfung führt es auf Ihrem Rechner aus, und hier sind die Module vorhanden: Ein Skript, das vorher nachsieht, was schon installiert ist, fordert deshalb nichts an. Im Container der Pipeline ist bei jedem Job nichts installiert. Das Skript installiert ohne Abfrage."
        }
        if ($pester.Count -ne 1 -or $analyzer.Count -ne 1) {
            throw "Das Skript fordert Pester $($pester.Count) Mal und PSScriptAnalyzer $($analyzer.Count) Mal an. Erwartet ist je ein Aufruf."
        }
        if (-not $pester[0].Version) {
            throw 'Das Skript fordert Pester ohne feste Version an.'
        }
        $pester[0].Version | Should -Be '5.9.1'
        if ($analyzer[0].Version -notmatch '^\d+\.\d+\.\d+$') {
            throw "Das Skript fordert PSScriptAnalyzer ohne feste Version an (angegeben: '$($analyzer[0].Version)')."
        }
    }
}

Describe 'Zusatzaufgabe: Ein Test für das Installationsskript' -Tag 'Zusatz' {

    BeforeAll {
        $extraRuns = @{}
        $whatIfProbe = $null
        $extraInstallScript = Join-Path (Join-Path $ProjectRoot 'ci') 'Install-Modules.ps1'
        $hasInstallScript = Test-Path -LiteralPath $extraInstallScript -PathType Leaf

        if ($hasInstallScript) {
            # Das Installationsskript des Projekts mit -WhatIf, in einem Prozess
            # mit Platzhaltern für die Installationsbefehle.
            $probeRoot = Join-Path $sandboxRoot 'zusatz-whatif'
            $null = New-Item -ItemType Directory -Path $probeRoot -Force
            $resultPath = Join-Path $probeRoot 'ergebnis.json'
            $arguments = @(
                '-NoProfile', '-File', (Join-Path $toolRoot 'Invoke-InstallProbe.ps1')
                '-ScriptPath', $extraInstallScript
                '-ResultPath', $resultPath
                '-WithWhatIf'
            )
            $null = & $shell @arguments 2>&1
            if (Test-Path -LiteralPath $resultPath) {
                $whatIfProbe = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            }
        }

        if ($hasInstallScript -and @(Get-ProjectTestFile).Count -gt 0) {
            # Eine Fassung des Installationsskripts, die Pester ohne Version anfordert.
            $extraVariants = Join-Path $sandboxRoot 'zusatz-fassungen'
            $null = New-Item -ItemType Directory -Path (Join-Path $extraVariants 'ohne-version/ci') -Force
            Set-Content -LiteralPath (Join-Path $extraVariants 'ohne-version/ci/Install-Modules.ps1') -Value @(
                '[CmdletBinding(SupportsShouldProcess)]'
                'param()'
                ''
                'Install-Module -Name Pester -Force -WhatIf:$WhatIfPreference'
                "Install-Module -Name PSScriptAnalyzer -RequiredVersion '1.25.0' -Force -WhatIf:`$WhatIfPreference"
            )
            $extraRuns = Invoke-SuiteRun -Name 'zusatz' -Variants $extraVariants
        }

        function Get-ReachedInstallCall {
            # Zählt die Aufrufe, die in den beiden Läufen einen Platzhalter
            # erreicht haben, also an keinem Mock hängen geblieben sind.
            $base = $extraRuns['unveraendert-de-DE']
            $run = $extraRuns['ohne-version']
            [pscustomobject]@{
                All     = [int]$base.InstallCalls + [int]$run.InstallCalls
                ForReal = [int]$base.InstallCallsForReal + [int]$run.InstallCallsForReal
            }
        }
    }

    It 'ci/Install-Modules.ps1 installiert mit -WhatIf nichts: Kein Aufruf erreicht einen Installationsbefehl ohne -WhatIf' {
        Assert-ProjectFile -RelativePath 'ci/Install-Modules.ps1'
        if (-not $whatIfProbe) {
            throw 'Das Installationsskript ließ sich in der Arbeitskopie nicht ausführen.'
        }
        if ($whatIfProbe.Failure) {
            throw "Mit -WhatIf gestartet, bricht das Installationsskript ab: $($whatIfProbe.Failure)"
        }
        $forReal = @($whatIfProbe.Requests | Where-Object { -not $_.WhatIf })
        if ($forReal.Count -gt 0) {
            throw "Mit -WhatIf gestartet, hat das Skript $($forReal.Count) Mal einen Installationsbefehl ohne -WhatIf aufgerufen ($(@($forReal.Name) -join ', ')). Es nimmt den Parameter noch nicht an oder reicht ihn nicht weiter."
        }
    }

    It 'Ihre Tests bemerken ein Installationsskript, das Pester ohne feste Version anfordert' {
        Assert-ProjectFile -RelativePath 'ci/Install-Modules.ps1'
        $base = $extraRuns['unveraendert-de-DE']
        if (-not $base -or $base.Result -ne 'Passed') {
            throw 'Ihre Tests müssen zuerst mit Ihrem eigenen Installationsskript bestehen.'
        }
        $run = $extraRuns['ohne-version']
        if ($run.Result -ne 'Failed') {
            throw "Alle $($run.Total) Tests bestehen auch mit einem Installationsskript, das Pester ohne Version anfordert."
        }
    }

    It 'Ihre Tests installieren dabei nichts: Jeder Aufruf eines Installationsbefehls trifft auf einen Mock' {
        Assert-ProjectFile -RelativePath 'ci/Install-Modules.ps1'
        $base = $extraRuns['unveraendert-de-DE']
        $run = $extraRuns['ohne-version']
        $reached = Get-ReachedInstallCall
        if ($reached.ForReal -gt 0) {
            throw "Ihre Tests haben $($reached.All) Mal einen Installationsbefehl wirklich aufgerufen, davon $($reached.ForReal) Mal ohne -WhatIf. In der Arbeitskopie der Kontrolle ist dabei nichts installiert worden. Auf Ihrem Rechner und in der Pipeline wäre es passiert."
        }
        if ($reached.All -gt 0) {
            throw "Ihre Tests haben $($reached.All) Mal einen Installationsbefehl wirklich aufgerufen: Kein Mock hat diese Aufrufe abgefangen. Jeder trug -WhatIf, auf Ihrem Rechner wäre deshalb nur eine Ankündigung erschienen."
        }
        if (-not $base -or -not $run -or $base.Result -ne 'Passed' -or $run.Result -ne 'Failed') {
            throw 'Noch kein Test prüft das Installationsskript.'
        }
    }
}
