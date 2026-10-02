[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script = Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-NuGetDependencyHygiene.ps1'
$fixtures = Join-Path $PSScriptRoot 'fixtures'
$jsonPath = Join-Path ([IO.Path]::GetTempPath()) ('nuget-hygiene-test-' + [guid]::NewGuid().ToString('N') + '.json')

function Assert {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

try {
    $report = @(& $script -Folders @($fixtures, (Join-Path $fixtures 'legacy')) -TargetFramework net48 -OutputPath $jsonPath)
    $newtonsoft = @($report | Where-Object Package -eq 'Newtonsoft.Json')[0]
    Assert ($newtonsoft.VersionConflict -and $newtonsoft.ResolvedVersions.Count -eq 2) 'Conflitto di versioni dirette non rilevato.'
    Assert (@($newtonsoft.Occurrences | Where-Object { $_.Project -like '*Legacy.vbproj' }).Count -eq 1) 'Cartelle sovrapposte non deduplicate.'
    Assert (@($newtonsoft.Occurrences | Where-Object { $_.Project -like '*LegacyMissing.csproj' -and $_.Kind -eq 'Direct' }).Count -eq 1) 'Fallback packages.config legacy non riuscito.'
    Assert (@($newtonsoft.Occurrences | Where-Object { $_.Project -like '*Central.csproj' -and $_.RequestedVersion -eq '13.0.3' }).Count -eq 1) 'Versione centralizzata non letta.'

    $configuration = @($report | Where-Object Package -eq 'Microsoft.Extensions.Configuration')[0]
    Assert ($configuration.VersionConflict -and $configuration.MinimumConflict) 'Versioni o minimi transitivi diversi non rilevati.'
    Assert (@($configuration.Occurrences | Where-Object { $_.Project -like '*Direct.csproj' -and $_.Kind -eq 'Direct' }).Count -eq 1) 'Dipendenza diretta non riconosciuta.'
    Assert (@($configuration.Occurrences | Where-Object { $_.Project -like '*Nine.csproj' -and $_.Kind -eq 'Transitive' }).Count -eq 1) 'Dipendenza transitiva non riconosciuta.'
    Assert (@($configuration.Occurrences | Where-Object { $_.Project -like '*Pinned.csproj' -and $_.Parents.Count -gt 0 }).Count -eq 1) 'Genitori di un pacchetto diretto non riportati.'
    Assert (@($configuration.Occurrences | Where-Object { $_.Project -like '*Eight.csproj' }).Count -eq 1) 'Progetto .NET Standard non analizzato come consumer net48.'
    $otherParent = @($configuration.Occurrences | Where-Object { $_.Project -like '*OtherParent.csproj' })[0]
    Assert ($otherParent.Kind -eq 'Transitive' -and @($otherParent.Parents | Where-Object Package -eq 'Microsoft.Extensions.Configuration.FileExtensions').Count -eq 1) 'Dipendenza transitiva da un pacchetto padre diverso non rilevata.'

    $parsed = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    Assert (@($parsed).Count -eq $report.Count) 'Export JSON incompleto.'
    $sameResolved = @(& $script -Folders @((Join-Path $fixtures 'transitive-pinned'), (Join-Path $fixtures 'transitive-v9')))
    $pinned = @($sameResolved | Where-Object Package -eq 'Microsoft.Extensions.Configuration')[0]
    Assert (-not $pinned.VersionConflict -and $pinned.MinimumConflict) 'Minimi diversi con versione risolta uguale non rilevati.'

    $empty = @(& $script -Folders (Join-Path $fixtures 'empty') -OutputPath $jsonPath)
    Assert ($empty.Count -eq 0) 'Progetto privo di pacchetti non gestito.'
    Assert (@(Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json).Count -eq 0) 'Export JSON vuoto non valido.'

    $missingFailed = $false
    try { $null = & $script -Folders (Join-Path $fixtures 'missing') }
    catch { $missingFailed = $true }
    Assert $missingFailed 'Cartella mancante non segnalata.'
    'Tutti i test sono passati.'
}
finally {
    if (Test-Path -LiteralPath $jsonPath) { Remove-Item -LiteralPath $jsonPath -Force }
}
