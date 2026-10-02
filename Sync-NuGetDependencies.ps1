[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Pipeline')]
param(
    [Parameter(Mandatory, ValueFromPipeline, ParameterSetName = 'Pipeline')]
    [object] $InputObject,
    [Parameter(Mandatory, ParameterSetName = 'File')]
    [string] $InputPath,
    [string] $DotNetPath = 'dotnet'
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $entries = [System.Collections.Generic.List[object]]::new()
}

process {
    if ($PSCmdlet.ParameterSetName -eq 'Pipeline') {
        foreach ($entry in @($InputObject)) { $entries.Add($entry) }
    }
}

end {
    if ($PSCmdlet.ParameterSetName -eq 'File') {
        $source = (Resolve-Path -LiteralPath $InputPath -ErrorAction Stop).ProviderPath
        $decoded = Get-Content -LiteralPath $source -Raw -Encoding utf8 | ConvertFrom-Json -NoEnumerate
        if ($null -eq $decoded) { throw "Il file '$source' non contiene un report valido." }
        foreach ($entry in @($decoded)) { $entries.Add($entry) }
    }

    $sdks = & $DotNetPath --list-sdks 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Impossibile trovare gli SDK .NET: $($sdks -join [Environment]::NewLine)" }
    $assemblyPaths = foreach ($line in $sdks) {
        if ($line -match '^\s*(\S+)\s+\[(.+)\]\s*$') {
            Join-Path (Join-Path $Matches[2] $Matches[1]) 'NuGet.Versioning.dll'
        }
    }
    $foundAssemblies = @($assemblyPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    if ($foundAssemblies.Count -eq 0) { throw 'NuGet.Versioning.dll non trovato negli SDK .NET installati.' }
    $assemblyPath = $foundAssemblies[-1]
    Add-Type -Path $assemblyPath

    function Parse-Version {
        param([string] $Value)
        try { return [NuGet.Versioning.NuGetVersion]::Parse($Value) }
        catch { throw "Versione NuGet non valida nel report: '$Value'." }
    }

    function Read-Document {
        param([string] $Path)
        if (-not $documents.ContainsKey($Path)) {
            $original = [IO.File]::ReadAllBytes($Path)
            $content = [IO.File]::ReadAllText($Path)
            $xml = [xml]::new()
            $xml.PreserveWhitespace = $true
            $xml.LoadXml($content)
            $documents[$Path] = [pscustomobject]@{
                Xml = $xml
                InitialXml = $xml.CloneNode($true)
                Original = $original
                Newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
                Dirty = $false
            }
        }
        return $documents[$Path]
    }

    function Add-Element {
        param([System.Xml.XmlNode] $Parent, [System.Xml.XmlElement] $Element, [string] $Newline)
        $document = $Parent.OwnerDocument
        $tail = $Parent.LastChild
        if ($null -ne $tail -and $tail.NodeType -eq [System.Xml.XmlNodeType]::Whitespace -and
            $tail.Value -match '[\r\n]([ ]*)$') {
            $indent = ' ' * ($Matches[1].Length + 2)
            [void]$Parent.InsertBefore($document.CreateWhitespace($Newline + $indent), $tail)
            [void]$Parent.InsertBefore($Element, $tail)
        }
        else {
            [void]$Parent.AppendChild($document.CreateWhitespace($Newline + '    '))
            [void]$Parent.AppendChild($Element)
            [void]$Parent.AppendChild($document.CreateWhitespace($Newline + '  '))
        }
    }

    function Set-Version {
        param([System.Xml.XmlElement] $Element, [string] $Version, [bool] $Override)
        $attribute = if ($Override) { 'VersionOverride' } else { 'Version' }
        $child = @($Element.ChildNodes | Where-Object { $_.LocalName -eq $attribute })
        if ($child.Count -gt 1) { throw "Metadati '$attribute' duplicati nel riferimento '$($Element.GetAttribute('Include'))'." }
        if ($Element.HasAttribute($attribute)) { $Element.SetAttribute($attribute, $Version) }
        elseif ($child.Count -eq 1) { $child[0].InnerText = $Version }
        else { $Element.SetAttribute($attribute, $Version) }
    }

    function Find-CentralFile {
        param([string] $Project)
        $folder = Split-Path $Project -Parent
        while ($folder) {
            $candidate = Join-Path $folder 'Directory.Packages.props'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
            $parent = Split-Path $folder -Parent
            if (-not $parent -or $parent -eq $folder) { break }
            $folder = $parent
        }
        return $null
    }

    function Find-PackageElement {
        param([System.Xml.XmlDocument] $Xml, [string] $Type, [string] $Package)
        return @($Xml.SelectNodes("//*[local-name()='$Type']") |
            Where-Object { $_.GetAttribute('Include') -eq $Package })
    }

    function Get-DeclaredVersion {
        param([System.Xml.XmlElement] $Element)
        foreach ($field in 'VersionOverride', 'Version') {
            if ($Element.HasAttribute($field)) { return $Element.GetAttribute($field) }
            $child = @($Element.ChildNodes | Where-Object { $_.LocalName -eq $field })
            if ($child.Count -eq 1) { return $child[0].InnerText }
        }
        return $null
    }

    function Add-PackageElement {
        param([System.Xml.XmlDocument] $Xml, [string] $Type, [string] $Package, [string] $Version, [string] $Newline)
        $root = $Xml.DocumentElement
        $group = @($root.ChildNodes | Where-Object {
            $_.LocalName -eq 'ItemGroup' -and -not $_.Attributes['Condition'] -and
            @($_.ChildNodes | Where-Object { $_.LocalName -eq $Type }).Count -gt 0
        } | Select-Object -First 1)
        if ($group.Count -eq 0) {
            $group = @($root.ChildNodes | Where-Object { $_.LocalName -eq 'ItemGroup' -and -not $_.Attributes['Condition'] } | Select-Object -First 1)
        }
        if ($group.Count -eq 0) {
            $newGroup = $Xml.CreateElement('ItemGroup', $root.NamespaceURI)
            Add-Element $root $newGroup $Newline
            $group = @($newGroup)
        }
        $element = $Xml.CreateElement($Type, $root.NamespaceURI)
        $element.SetAttribute('Include', $Package)
        if ($Version) { $element.SetAttribute('Version', $Version) }
        Add-Element $group[0] $element $Newline
    }

    $documents = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $actions = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $kinds = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $entries) {
        if ($null -eq $entry -or $null -eq $entry.PSObject.Properties['Package'] -or
            $null -eq $entry.PSObject.Properties['Occurrences']) {
            throw 'Report non valido: Package oppure Occurrences mancante.'
        }
        foreach ($occurrence in $entry.Occurrences) {
            if ($null -eq $occurrence -or $null -eq $occurrence.PSObject.Properties['Project'] -or
                $null -eq $occurrence.PSObject.Properties['Kind']) {
                throw "Report non valido: occorrenza di '$($entry.Package)' incompleta."
            }
            $key = ([IO.Path]::GetFullPath([string]$occurrence.Project)) + '|' + $entry.Package
            if ($kinds.ContainsKey($key)) { throw "Occorrenza duplicata nel report: '$key'." }
            $kinds[$key] = [string]$occurrence.Kind
        }
    }
    foreach ($entry in $entries) {
        foreach ($name in 'Package', 'ResolvedVersions', 'TransitiveMinimums', 'Occurrences') {
            if ($null -eq $entry -or $null -eq $entry.PSObject.Properties[$name]) {
                throw "Report non valido: campo '$name' mancante."
            }
        }
        if ($entry.Package -isnot [string] -or $entry.ResolvedVersions -isnot [array] -or
            $entry.TransitiveMinimums -isnot [array] -or $entry.Occurrences -isnot [array]) {
            throw "Formato inatteso per il pacchetto '$($entry.Package)'."
        }
        $versions = @($entry.ResolvedVersions) + @($entry.TransitiveMinimums)
        if ($versions.Count -eq 0) { throw "Nessuna versione per '$($entry.Package)'." }
        $target = $null
        $targetParsed = $null
        foreach ($version in $versions) {
            $parsed = Parse-Version ([string]$version)
            if ($null -eq $targetParsed -or $parsed.CompareTo($targetParsed) -gt 0) {
                $target = [string]$version
                $targetParsed = $parsed
            }
        }
        foreach ($occurrence in $entry.Occurrences) {
            foreach ($name in 'Project', 'Kind', 'ResolvedVersion', 'RequestedVersion', 'Parents') {
                if ($null -eq $occurrence -or $null -eq $occurrence.PSObject.Properties[$name]) {
                    throw "Occorrenza di '$($entry.Package)' priva di '$name'."
                }
            }
            if ($occurrence.Kind -notin 'Direct', 'Transitive') {
                throw "Tipo di dipendenza non riconosciuto: '$($occurrence.Kind)'."
            }
            $project = (Resolve-Path -LiteralPath $occurrence.Project -ErrorAction Stop).ProviderPath
            if ([IO.Path]::GetExtension($project) -notin '.csproj', '.vbproj') {
                throw "Percorso non valido per un progetto: '$project'."
            }
            $key = $project + '|' + $entry.Package
            if (-not $seen.Add($key)) { throw "Occorrenza duplicata nel report: '$key'." }
            $current = Parse-Version ([string]$occurrence.ResolvedVersion)
            $requestedLower = $false
            if ($occurrence.Kind -eq 'Direct' -and $occurrence.RequestedVersion -and
                $occurrence.RequestedVersion -notmatch '^[\[(]|[,*]') {
                $requestedParsed = Parse-Version ([string]$occurrence.RequestedVersion)
                $requestedLower = $requestedParsed.CompareTo($targetParsed) -lt 0
            }
            $deepestAtTarget = $false
            if ($occurrence.Kind -eq 'Transitive' -and $entry.ResolvedVersions.Count -gt 1 -and
                $current.CompareTo($targetParsed) -eq 0) {
                foreach ($parent in $occurrence.Parents) {
                    $parentKey = $project + '|' + $parent.Package
                    if ($kinds.ContainsKey($parentKey) -and $kinds[$parentKey] -eq 'Transitive') {
                        $deepestAtTarget = $true
                        break
                    }
                }
            }
            if ($current.CompareTo($targetParsed) -ge 0 -and -not $deepestAtTarget -and -not $requestedLower) { continue }
            $fromVersion = if ($requestedLower) { $occurrence.RequestedVersion } else { $occurrence.ResolvedVersion }

            $configuration = Join-Path (Split-Path $project -Parent) 'packages.config'
            if (Test-Path -LiteralPath $configuration -PathType Leaf) {
                $actions.Add([pscustomobject]@{
                    Action = if ($occurrence.Kind -eq 'Direct') { 'Update' } else { 'AddDirect' }
                    Project = $project; Package = $entry.Package; FromVersion = $fromVersion
                    ToVersion = $target; File = $configuration; Status = 'Blocked'
                    Reason = 'packages.config non crea o aggiorna in modo affidabile i riferimenti DLL del progetto legacy.'
                })
                continue
            }

            $projectDocument = Read-Document $project
            $references = @(Find-PackageElement $projectDocument.Xml 'PackageReference' $entry.Package)
            $centralFile = Find-CentralFile $project
            $centralDocument = if ($centralFile) { Read-Document $centralFile } else { $null }
            $centralManaged = $false
            if ($centralDocument) {
                $managed = @($centralDocument.Xml.SelectNodes("//*[local-name()='ManagePackageVersionsCentrally']"))
                $centralManaged = @($managed | Where-Object { $_.InnerText.Trim() -eq 'true' }).Count -gt 0
            }
            $projectManaged = @($projectDocument.Xml.SelectNodes("//*[local-name()='ManagePackageVersionsCentrally']"))
            if (@($projectManaged | Where-Object { $_.InnerText.Trim() -eq 'true' }).Count -gt 0) { $centralManaged = $true }
            $centralVersions = @(if ($centralDocument) {
                Find-PackageElement $centralDocument.Xml 'PackageVersion' $entry.Package
            })

            $reason = $null
            if ($references.Count -gt 1 -or $centralVersions.Count -gt 1) {
                $reason = 'Dichiarazioni multiple o condizionali: modifica automatica ambigua.'
            }
            elseif ($occurrence.Kind -eq 'Direct' -and $references.Count -ne 1) {
                $reason = 'Riferimento diretto non dichiarato localmente (potrebbe provenire da un import MSBuild).'
            }
            elseif ($occurrence.Kind -eq 'Transitive' -and $references.Count -ne 0) {
                $reason = 'Report non aggiornato: il progetto contiene gia'' un riferimento diretto.'
            }
            elseif ($centralManaged -and -not $centralFile) {
                $reason = 'Gestione centralizzata attiva, ma Directory.Packages.props non trovato.'
            }
            elseif ($occurrence.Kind -eq 'Direct') {
                $declared = Get-DeclaredVersion $references[0]
                if ($declared -match '\$\(') {
                    $reason = 'Versione definita da una proprieta'' MSBuild: origine non modificabile con sicurezza.'
                }
                elseif (-not $declared -and $centralVersions.Count -ne 1) {
                    $reason = 'Versione diretta non individuata nel progetto o nel file centrale.'
                }
                elseif (-not $declared -and (Get-DeclaredVersion $centralVersions[0]) -match '\$\(') {
                    $reason = 'Versione centrale definita da una proprieta'' MSBuild.'
                }
                else {
                    $initial = if ($declared) {
                        $initialReference = @(Find-PackageElement $projectDocument.InitialXml 'PackageReference' $entry.Package)
                        Get-DeclaredVersion $initialReference[0]
                    }
                    else {
                        $initialVersion = @(Find-PackageElement $centralDocument.InitialXml 'PackageVersion' $entry.Package)
                        Get-DeclaredVersion $initialVersion[0]
                    }
                    if ($occurrence.RequestedVersion -and $initial -ne $occurrence.RequestedVersion) {
                        $reason = 'Report non aggiornato: la versione dichiarata e'' cambiata dopo l''analisi.'
                    }
                }
            }
            if ($reason) {
                $actions.Add([pscustomobject]@{
                    Action = if ($occurrence.Kind -eq 'Direct') { 'Update' } else { 'AddDirect' }
                    Project = $project; Package = $entry.Package; FromVersion = $fromVersion
                    ToVersion = $target; File = $project; Status = 'Blocked'; Reason = $reason
                })
                continue
            }

            $changedFile = $project
            if ($occurrence.Kind -eq 'Direct') {
                if (Get-DeclaredVersion $references[0]) {
                    $override = $references[0].HasAttribute('VersionOverride') -or
                        @($references[0].ChildNodes | Where-Object LocalName -eq 'VersionOverride').Count -gt 0
                    Set-Version $references[0] $target $override
                    $projectDocument.Dirty = $true
                }
                else {
                    Set-Version $centralVersions[0] $target $false
                    $centralDocument.Dirty = $true
                    $changedFile = $centralFile
                }
            }
            else {
                if ($centralManaged) {
                    if ($centralVersions.Count -eq 1) {
                        if ((Get-DeclaredVersion $centralVersions[0]) -match '\$\(') {
                            throw "Versione centrale di '$($entry.Package)' definita da una proprieta' MSBuild: impossibile aggiornarla."
                        }
                        Set-Version $centralVersions[0] $target $false
                        $centralDocument.Dirty = $true
                    }
                    else {
                        Add-PackageElement $centralDocument.Xml 'PackageVersion' $entry.Package $target $centralDocument.Newline
                        $centralDocument.Dirty = $true
                    }
                    $changedFile = "$project; $centralFile"
                    Add-PackageElement $projectDocument.Xml 'PackageReference' $entry.Package $null $projectDocument.Newline
                    $projectDocument.Dirty = $true
                }
                else {
                    Add-PackageElement $projectDocument.Xml 'PackageReference' $entry.Package $target $projectDocument.Newline
                    $projectDocument.Dirty = $true
                }
            }
            $actions.Add([pscustomobject]@{
                Action = if ($occurrence.Kind -eq 'Direct') { 'Update' } else { 'AddDirect' }
                Project = $project; Package = $entry.Package; FromVersion = $fromVersion
                ToVersion = $target; File = $changedFile; Status = 'Ready'; Reason = $null
            })
        }
    }

    if ($WhatIfPreference) {
        foreach ($action in $actions) {
            if ($action.Status -eq 'Ready') {
                [void]$PSCmdlet.ShouldProcess($action.File, "$($action.Action) $($action.Package) -> $($action.ToVersion)")
            }
            else { Write-Warning "Bloccato: $($action.Project) / $($action.Package): $($action.Reason)" }
        }
        $actions
        return
    }
    $blocked = @($actions | Where-Object Status -eq 'Blocked')
    if ($blocked.Count) {
        throw "Riconciliazione interrotta senza modifiche: $($blocked.Count) interventi non sicuri. Eseguire -WhatIf per consultarli."
    }
    if ($actions.Count -eq 0) { return }
    if (-not $PSCmdlet.ShouldProcess("$($documents.Keys.Count) file", "$($actions.Count) aggiornamenti NuGet")) { return }

    $written = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($path in ($documents.Keys | Sort-Object)) {
            $document = $documents[$path]
            if (-not $document.Dirty) { continue }
            $temporary = Join-Path (Split-Path $path -Parent) ('.nuget-sync-' + [guid]::NewGuid().ToString('N') + '.tmp')
            try {
                $document.Xml.Save($temporary)
                [IO.File]::Move($temporary, $path, $true)
                $written.Add($path)
            }
            finally {
                if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
            }
        }
    }
    catch {
        foreach ($path in $written) { [IO.File]::WriteAllBytes($path, $documents[$path].Original) }
        throw
    }
    $actions
}
