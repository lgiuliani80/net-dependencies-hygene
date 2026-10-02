[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$analyzer = Join-Path $root 'Get-NuGetDependencyHygiene.ps1'
$sync = Join-Path $root 'Sync-NuGetDependencies.ps1'
$folder = Join-Path ([IO.Path]::GetTempPath()) ('nuget-sync-integration-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $folder | Out-Null

try {
    $folders = foreach ($name in 'transitive-v8', 'transitive-v9', 'direct-v8') {
        $source = Join-Path $PSScriptRoot "fixtures\$name"
        $destination = Join-Path $folder $name
        New-Item -ItemType Directory -Path $destination | Out-Null
        Copy-Item -LiteralPath (Join-Path $source ((Get-ChildItem -LiteralPath $source -Filter '*.csproj')[0].Name)) -Destination $destination
        $destination
    }
    $before = @(& $analyzer -Folders $folders)
    $plans = @($before | & $sync)
    if ($plans.Count -eq 0) { throw 'Nessuna modifica applicata ai progetti di prova.' }
    $after = @(& $analyzer -Folders $folders)
    $conflicts = @($after | Where-Object VersionConflict)
    if ($conflicts.Count -gt 0) {
        throw "Rimangono $($conflicts.Count) pacchetti con versioni diverse: $($conflicts.Package -join ', ')."
    }
    'Test di integrazione NuGet superato.'
}
finally {
    Remove-Item -LiteralPath $folder -Recurse -Force
}
