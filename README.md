# PowerShell: Scripting für Experten, Übung 2

Selbstkontrolle für Übung 2. Start im Ordner dieses Repositorys:

```powershell
Invoke-Pester .\tests -Output Detailed
```

Die Kontrolle prüft Ihr Projekt unter `measurement-tools` in Ihrem Benutzerordner (anderer Ort: `$env:MEASUREMENT_PROJECT`). `start\MeasurementTools` ist das Modul, aus dem die Kontrolle ihre Vergleichsfassungen baut. `tests\fassungen.zip` bitte nicht auspacken.

Folien zum Mitlesen (Teil I bis III): <https://grigory-consulting.github.io/powershell-experten-uebung-1/>
