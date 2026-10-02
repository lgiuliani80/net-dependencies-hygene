# Igiene delle dipendenze NuGet

`Get-NuGetDependencyHygiene.ps1` analizza ricorsivamente i progetti `.csproj` e `.vbproj` nelle cartelle specificate, valutando i `PackageReference` (anche con `Directory.Packages.props`) e i `packages.config`. Richiede PowerShell 7, .NET SDK con `dotnet msbuild` e accesso ai feed NuGet configurati.

```powershell
$report = .\Get-NuGetDependencyHygiene.ps1 -Folders @('C:\Sorgenti\App1', 'C:\Sorgenti\App2')
$report | Select-Object Package, VersionConflict, MinimumConflict, ResolvedVersions, TransitiveMinimums
$report | Where-Object { $_.VersionConflict -or $_.MinimumConflict } |
    ForEach-Object { $_.Occurrences | Select-Object Package, Project, Kind, ResolvedVersion, RequestedVersion, Parents }

.\Get-NuGetDependencyHygiene.ps1 -Folders @('C:\Sorgenti\App1') `
    -TargetFramework net472 -OutputPath 'C:\Report\nuget-dependencies.json'
```

## Report HTML navigabile

`Convert-NuGetDependencyReport.ps1` crea un file HTML autonomo, senza CDN, librerie o richieste di rete, e lo apre nel browser predefinito. Accetta direttamente gli oggetti emessi dall'analisi oppure il JSON esportato:

```powershell
.\Get-NuGetDependencyHygiene.ps1 -Folders @('C:\Sorgenti\App1', 'C:\Sorgenti\App2') |
    .\Convert-NuGetDependencyReport.ps1 -OutputPath 'C:\Report\NuGetDependencyReport.html'

.\Convert-NuGetDependencyReport.ps1 -InputPath 'C:\Report\nuget-dependencies.json' `
    -OutputPath 'C:\Report\NuGetDependencyReport.html'
```

Senza `-OutputPath` salva `NuGetDependencyReport.html` nella directory corrente. Con `-NoOpen` genera il file senza aprirlo (utile per pipeline automatiche). Il report permette di cercare per pacchetto, progetto o pacchetto padre, filtrare le divergenze, ordinare e aprire i dettagli delle versioni e dei vincoli transitivi. Non carica contenuti esterni e non modifica il JSON in ingresso.

## Riconciliare le versioni

`Sync-NuGetDependencies.ps1` legge lo stesso report (oggetti o JSON), individua la versione NuGet più alta tra versioni risolte e minimi transitivi e propone modifiche ai progetti con `PackageReference`. Usa il confronto semantico NuGet: `1.10` è maggiore di `1.9`. Aggiorna i riferimenti diretti più vecchi; per un pacchetto transitivo a versione inferiore aggiunge un riferimento diretto alla versione scelta. Quando la versione massima è già presente solo tramite una catena transitiva di almeno due passaggi e altrove è stata risolta una versione diversa, aggiunge comunque un riferimento esplicito per stabilizzarla (secondo esempio). Un pacchetto già alla versione massima attraverso un genitore diretto non cambia (primo esempio).

```powershell
$report = .\Get-NuGetDependencyHygiene.ps1 -Folders @('C:\Sorgenti\App1', 'C:\Sorgenti\App2')
$report | .\Sync-NuGetDependencies.ps1 -WhatIf | Format-Table Action, Project, Package, FromVersion, ToVersion, Status
$report | .\Sync-NuGetDependencies.ps1

.\Sync-NuGetDependencies.ps1 -InputPath 'C:\Report\nuget-dependencies.json' -WhatIf
```

Con `-WhatIf` **non viene scritto alcun file**: oltre all'anteprima standard di PowerShell, vengono restituiti oggetti con `Action`, `Project`, `Package`, `FromVersion`, `ToVersion`, `File`, `Status` e `Reason`. Per i progetti con gestione centralizzata lo script aggiorna o aggiunge `PackageVersion` in `Directory.Packages.props` e inserisce un `PackageReference` senza versione nel progetto. Aggiornare un file centrale puo' interessare anche progetti esterni al report: verificarne gli utilizzatori prima di applicare modifiche.

I progetti con `packages.config`, i riferimenti importati o ambigui e le versioni definite da proprieta' MSBuild vengono indicati come `Blocked` in anteprima; l'esecuzione reale si interrompe **prima di qualsiasi modifica** se ne trova uno. Il solo aggiornamento di `packages.config` non garantirebbe che i riferimenti DLL e gli HintPath legacy siano aggiornati. Lo script controlla inoltre che le versioni dirette dichiarate non siano cambiate rispetto al report: rigenerare il report prima di un nuovo tentativo. Dopo l'applicazione, ripetere analisi e restore/build dei progetti reali per verificare compatibilita' e output delle DLL; l'analisi originaria usa un progetto temporaneo e non riproduce ogni opzione di build.

Il framework di consumo predefinito e' `net48`. Per ciascun progetto lo script valuta i riferimenti tramite MSBuild con il framework richiesto, ripristina un progetto SDK temporaneo in una sottocartella del progetto originale e legge il grafo risolto in `project.assets.json`. I progetti sorgente non vengono modificati; i file temporanei vengono eliminati, mentre NuGet puo' popolare la propria cache. Le cartelle sovrapposte non duplicano i progetti. Gli errori di restore o di valutazione interrompono l'analisi.

Il risultato PowerShell e l'eventuale file JSON contengono una voce per pacchetto:

- `ResolvedVersions` e `VersionConflict`: versioni effettivamente risolte nei vari progetti e presenza di versioni distinte.
- `TransitiveMinimums` e `MinimumConflict`: limiti inferiori delle dipendenze transitive dei pacchetti padri e presenza di minimi distinti **anche se la versione risolta coincide**.
- `Occurrences`: progetto, `Kind` (`Direct` o `Transitive`), `RequestedVersion` se diretta, `ResolvedVersion` e `Parents` con pacchetto padre, intervallo richiesto e minimo. Un pacchetto diretto puo' avere anche dei padri transitivi.

Le voci di `packages.config` sono considerate tutte dirette e la loro versione viene vincolata esattamente: il file non conserva l'informazione su quali installazioni fossero originariamente transitive. Se la valutazione di un progetto legacy fallisce, si usa il suo `packages.config` soltanto se il file di progetto non contiene `PackageReference`; viene emesso un avviso per eventuali riferimenti provenienti da import non verificabili.

Il ripristino temporaneo normalizza i riferimenti diretti sul framework richiesto: non riproduce necessariamente opzioni specifiche del progetto originale come `ExcludeAssets`, lock file, riferimenti ad altri progetti o comportamenti personalizzati di build. Le differenze nelle versioni dei pacchetti sono **segnali di rischio** per le DLL, non una verifica delle identita' o delle versioni delle DLL effettivamente copiate nell'output. Un errore di compatibilita' del pacchetto con il framework scelto viene segnalato dal restore.

Per eseguire i test con restore NuGet reale:

```powershell
.\tests\Run-Tests.ps1
.\tests\Run-RenderTests.ps1
.\tests\Run-SyncTests.ps1
.\tests\Run-SyncIntegrationTests.ps1
```
