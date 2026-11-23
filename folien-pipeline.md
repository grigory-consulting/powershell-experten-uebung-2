# Auszug aus den Folien: Pipeline

Die vier Folien, aus denen Sie in Aufgabe 4, Schritt 2 die Datei `.gitlab-ci.yml` zusammensetzen.

## `.gitlab-ci.yml`: Stufen und Jobs

```yaml
stages: [analyze, test]

analyze:
  stage: analyze
  script:
    - pwsh -NoProfile -File ci/Invoke-Analysis.ps1

test:
  stage: test
  script:
    - pwsh -NoProfile -File ci/Invoke-Tests.ps1
```

- `.gitlab-ci.yml` im Stamm des Repositorys: Jeder Push startet eine Pipeline für den Commit
- `analyze` und `test` sind Jobs, die Namen sind frei; `stage` ordnet jeden Job einer Stufe zu
- `stages` legt die Reihenfolge der Stufen fest: Scheitert `analyze`, startet `test` nicht
- `script` ruft Skripte aus dem Repository auf, die lokal genauso laufen

## Container-Image mit PowerShell

```yaml
default:
  image: mcr.microsoft.com/dotnet/sdk:10.0
  before_script:
    - pwsh -NoProfile -File ci/Install-Modules.ps1
```

- `image` nennt das Container-Image für den Job; `default` gilt für alle Jobs
- PowerShell steckt im .NET-SDK-Image von Microsoft: Tag `10.0` enthält 7.6
- `mcr.microsoft.com/powershell` gilt als veraltet, ein stabiles 7.6 fehlt dort
- Pester und PSScriptAnalyzer installiert `before_script` in fester Version
- In 5.1 testen: nur mit einem Windows-Runner, der Container hat 7.6

Quelle: Microsoft Learn, Use PowerShell in Docker

## Test-Job mit Testbericht

```yaml
test:
  stage: test
  script:
    - pwsh -NoProfile -File ci/Invoke-Tests.ps1
  artifacts:
    when: always
    paths:
      - testResults.xml
    reports:
      junit: testResults.xml
```

- `reports:junit` liest den Bericht von Pester: GitLab zeigt die Tests in der Pipeline und im Merge Request
- `when: always` lädt die Datei auch hoch, wenn Tests fehlschlagen
- `paths` macht die Datei zusätzlich als Download am Job verfügbar

## Coverage im Merge Request

```yaml
test:
  script:
    - pwsh -NoProfile -File ci/Invoke-Tests.ps1
  coverage: '/Covered \d{1,3}[.,]?\d{0,2}%/'
  artifacts:
    reports:
      coverage_report:
        coverage_format: cobertura
        path: coverage.xml
```

- `coverage` sucht mit einem regulären Ausdruck im Log des Jobs: Pester schreibt dort eine Zeile wie `Covered 47.96% / 75%.`
- GitLab zeigt den Prozentwert am Job und im Merge Request
- `coverage_report` liest `coverage.xml` und markiert im Diff des Merge Requests getestete und ungetestete Zeilen

Quelle: GitLab Docs, Coverage reporting und Coverage visualization
