[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]] $Folders,
    [string] $TargetFramework = 'net48',
    [string] $OutputPath,
    [string] $DotNetPath = 'dotnet'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Items {
    param($Result, [string] $Name)
    $property = $Result.Items.PSObject.Properties[$Name]
    if ($null -eq $property) { return @() }
    return @($property.Value)
}

function Get-Metadata {
    param($Item, [string] $Name)
    $property = $Item.PSObject.Properties[$Name]
    if ($null -eq $property) { return '' }
    return [string]$property.Value
}

function Get-MinimumVersion {
    param([string] $Range)
    if ([string]::IsNullOrWhiteSpace($Range)) { return $null }
    $value = $Range.Trim()
    if ($value -match '^[\[(]\s*([^,\])]+)') { return $Matches[1].Trim() }
    if ($value -match '^[\[(]\s*,') { return $null }
    return $value
}

function Read-ProjectDependencies {
    param([string] $Project)

    $config = Join-Path (Split-Path $Project -Parent) 'packages.config'
    $evaluation = & $DotNetPath msbuild $Project -nologo -getItem:PackageReference -getItem:PackageVersion -getItem:GlobalPackageReference "-p:TargetFramework=$TargetFramework" 2>&1
    if ($LASTEXITCODE -ne 0) {
        if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
            throw "Valutazione MSBuild fallita per '$Project': $($evaluation -join [Environment]::NewLine)"
        }
        [xml]$projectXml = Get-Content -LiteralPath $Project -Raw
        if ($projectXml.SelectNodes("//*[local-name()='PackageReference']").Count -gt 0) {
            throw "Valutazione MSBuild fallita per '$Project' con PackageReference: $($evaluation -join [Environment]::NewLine)"
        }
        Write-Warning "MSBuild non ha valutato '$Project'; uso solo packages.config (eventuali riferimenti da file importati non sono verificabili)."
        $items = [pscustomobject]@{ Items = [pscustomobject]@{} }
    }
    else {
        try { $items = ($evaluation -join [Environment]::NewLine) | ConvertFrom-Json }
        catch { throw "Risposta MSBuild non valida per '$Project': $($evaluation -join [Environment]::NewLine)" }
    }

    $central = @{}
    foreach ($item in (Get-Items $items 'PackageVersion')) {
        $central[$item.Identity] = Get-Metadata $item 'Version'
    }
    $direct = @{}
    $exactIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in @((Get-Items $items 'PackageReference')) + @((Get-Items $items 'GlobalPackageReference'))) {
        $id = [string]$item.Identity
        $version = Get-Metadata $item 'VersionOverride'
        if (-not $version) { $version = Get-Metadata $item 'Version' }
        if (-not $version -and $central.ContainsKey($id)) { $version = [string]$central[$id] }
        if (-not $version) { throw "Versione mancante per PackageReference '$id' in '$Project'." }
        if ($direct.ContainsKey($id) -and $direct[$id] -ne $version) {
            throw "Versioni dirette incompatibili per '$id' in '$Project'."
        }
        $direct[$id] = $version
    }

    if (Test-Path -LiteralPath $config -PathType Leaf) {
        [xml]$xml = Get-Content -LiteralPath $config -Raw
        foreach ($package in $xml.SelectNodes('/packages/package')) {
            $id = [string]$package.id
            $version = [string]$package.version
            if (-not $id -or -not $version) { throw "Voce packages.config incompleta in '$config'." }
            if ($direct.ContainsKey($id) -and $direct[$id] -ne $version) {
                throw "Versioni diverse per '$id' tra PackageReference e packages.config in '$Project'."
            }
            $direct[$id] = $version
            [void]$exactIds.Add($id)
        }
    }
    return [pscustomobject]@{ Versions = $direct; ExactIds = $exactIds }
}

function Read-RestoredGraph {
    param([string] $Project, [hashtable] $Direct, [System.Collections.Generic.HashSet[string]] $ExactIds)

    $temporaryDirectory = Join-Path (Split-Path $Project -Parent) ('.nuget-hygiene-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
    try {
        $temporaryProject = Join-Path $temporaryDirectory 'Analysis.csproj'
        $document = New-Object System.Xml.XmlDocument
        $root = $document.CreateElement('Project')
        $root.SetAttribute('Sdk', 'Microsoft.NET.Sdk')
        [void]$document.AppendChild($root)
        $properties = $document.CreateElement('PropertyGroup')
        [void]$root.AppendChild($properties)
        foreach ($entry in @{ TargetFramework = $TargetFramework; ManagePackageVersionsCentrally = 'false' }.GetEnumerator()) {
            $element = $document.CreateElement($entry.Key)
            $element.InnerText = $entry.Value
            [void]$properties.AppendChild($element)
        }
        $group = $document.CreateElement('ItemGroup')
        [void]$root.AppendChild($group)
        foreach ($id in ($Direct.Keys | Sort-Object)) {
            $reference = $document.CreateElement('PackageReference')
            $reference.SetAttribute('Include', $id)
            $version = if ($ExactIds.Contains($id)) { "[$($Direct[$id])]" } else { $Direct[$id] }
            $reference.SetAttribute('Version', $version)
            [void]$group.AppendChild($reference)
        }
        $document.Save($temporaryProject)
        $restore = & $DotNetPath restore $temporaryProject --verbosity quiet 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Restore fallito per '$Project' (target $TargetFramework): $($restore -join [Environment]::NewLine)"
        }
        foreach ($message in $restore) {
            if (-not [string]::IsNullOrWhiteSpace([string]$message)) { Write-Warning "Restore '$Project': $message" }
        }
        $assetsPath = Join-Path $temporaryDirectory 'obj\project.assets.json'
        if (-not (Test-Path -LiteralPath $assetsPath -PathType Leaf)) {
            throw "Restore di '$Project' terminato senza project.assets.json."
        }
        $assets = Get-Content -LiteralPath $assetsPath -Raw | ConvertFrom-Json
        $targets = @($assets.targets.PSObject.Properties | Where-Object { $_.Name -notlike '*/*' })
        if ($targets.Count -ne 1) { throw "Target NuGet inattesi per '$Project': $($targets.Name -join ', ')." }
        $nodes = @{}
        foreach ($entry in $targets[0].Value.PSObject.Properties) {
            if ($entry.Value.type -ne 'package') { continue }
            $parts = $entry.Name -split '/', 2
            if ($parts.Count -ne 2) { throw "Pacchetto NuGet non valido: '$($entry.Name)'." }
            $dependenciesProperty = $entry.Value.PSObject.Properties['dependencies']
            $nodes[$parts[0]] = [pscustomobject]@{
                Id = $parts[0]
                Version = $parts[1]
                Dependencies = if ($null -eq $dependenciesProperty) { $null } else { $dependenciesProperty.Value }
            }
        }
        $edges = [System.Collections.Generic.List[object]]::new()
        foreach ($node in $nodes.Values) {
            if ($null -eq $node.Dependencies) { continue }
            foreach ($dependency in $node.Dependencies.PSObject.Properties) {
                if (-not $nodes.ContainsKey($dependency.Name)) { continue }
                $edges.Add([pscustomobject]@{
                    Parent = $node.Id
                    Child = $dependency.Name
                    Range = [string]$dependency.Value
                    Minimum = Get-MinimumVersion ([string]$dependency.Value)
                })
            }
        }
        foreach ($id in $Direct.Keys) {
            if (-not $nodes.ContainsKey($id)) { throw "La dipendenza diretta '$id' non e' nel grafo ripristinato per '$Project'." }
        }
        return [pscustomobject]@{ Nodes = $nodes; Edges = @($edges.ToArray()) }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryDirectory) {
            Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
        }
    }
}

$projects = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($folder in $Folders) {
    $resolvedFolder = (Resolve-Path -LiteralPath $folder -ErrorAction Stop).ProviderPath
    if (-not (Test-Path -LiteralPath $resolvedFolder -PathType Container)) {
        throw "La cartella '$folder' non esiste o non e' una directory."
    }
    foreach ($project in (Get-ChildItem -LiteralPath $resolvedFolder -Recurse -File | Where-Object { $_.Extension -in '.csproj', '.vbproj' })) {
        $projects[$project.FullName] = $project.FullName
    }
}
if ($projects.Count -eq 0) { throw 'Nessun file .csproj o .vbproj trovato.' }

$observations = [System.Collections.Generic.List[object]]::new()
foreach ($project in ($projects.Keys | Sort-Object)) {
    $declarations = Read-ProjectDependencies $project
    $direct = $declarations.Versions
    if ($direct.Count -eq 0) { continue }
    $graph = Read-RestoredGraph $project $direct $declarations.ExactIds
    foreach ($node in $graph.Nodes.Values) {
        $incoming = @($graph.Edges | Where-Object { $_.Child -eq $node.Id })
        $isDirect = $direct.ContainsKey($node.Id)
        $observations.Add([pscustomobject]@{
            Package = $node.Id
            Project = $project
            Kind = if ($isDirect) { 'Direct' } else { 'Transitive' }
            ResolvedVersion = $node.Version
            RequestedVersion = if ($isDirect) { $direct[$node.Id] } else { $null }
            Parents = @($incoming | ForEach-Object {
                [pscustomobject]@{ Package = $_.Parent; Range = $_.Range; Minimum = $_.Minimum }
            })
        })
    }
}

$report = @($observations | Group-Object -Property Package | ForEach-Object {
    $occurrences = @($_.Group | Sort-Object Project)
    $versions = @($occurrences.ResolvedVersion | Sort-Object -Unique)
    $allMinimums = foreach ($occurrence in $occurrences) {
        foreach ($parent in $occurrence.Parents) {
            if ($null -ne $parent.Minimum) { $parent.Minimum }
        }
    }
    $minimums = @($allMinimums | Sort-Object -Unique)
    [pscustomobject]@{
        Package = $_.Name
        ResolvedVersions = $versions
        VersionConflict = $versions.Count -gt 1
        TransitiveMinimums = $minimums
        MinimumConflict = $minimums.Count -gt 1
        Occurrences = $occurrences
    }
} | Sort-Object Package)

if ($OutputPath) {
    ConvertTo-Json -InputObject $report -Depth 20 | Set-Content -LiteralPath $OutputPath -Encoding utf8
}
$report
