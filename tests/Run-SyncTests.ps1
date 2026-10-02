[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sync = Join-Path (Split-Path $PSScriptRoot -Parent) 'Sync-NuGetDependencies.ps1'
$folder = Join-Path ([IO.Path]::GetTempPath()) ('nuget-sync-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $folder | Out-Null

function Assert {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function New-Project {
    param([string] $Name, [string] $References)
    $path = Join-Path $folder "$Name.csproj"
    "<Project Sdk=`"Microsoft.NET.Sdk`"><PropertyGroup><TargetFramework>net48</TargetFramework></PropertyGroup><ItemGroup>$References</ItemGroup></Project>" |
        Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

function New-Occurrence {
    param([string] $Path, [string] $Kind, [string] $Resolved, [string] $Requested = '', [object[]] $Parents = @())
    return [pscustomobject]@{
        Project = $Path; Kind = $Kind; ResolvedVersion = $Resolved
        RequestedVersion = if ($Requested) { $Requested } else { $null }
        Parents = $Parents
    }
}

function New-Report {
    param([object[]] $Occurrences, [string[]] $Versions)
    return [pscustomobject]@{
        Package = 'PC'; ResolvedVersions = $Versions; TransitiveMinimums = @()
        Occurrences = $Occurrences
    }
}

try {
    $a = New-Project 'A' '<PackageReference Include="PA" Version="1.0" />'
    $b = New-Project 'B' '<PackageReference Include="PB" Version="1.0" />'
    $c = New-Project 'C' '<PackageReference Include="PD" Version="1.0" />'
    $d = New-Project 'D' '<PackageReference Include="PC" Version="1.0" />'
    $first = New-Report @(
        (New-Occurrence $a 'Transitive' '1.5')
        (New-Occurrence $b 'Transitive' '1.4')
        (New-Occurrence $c 'Transitive' '1.1')
        (New-Occurrence $d 'Direct' '1.0' '1.0')
    ) @('1.5', '1.4', '1.1', '1.0')
    $before = [IO.File]::ReadAllBytes($b)
    $preview = @($first | & $sync -WhatIf)
    Assert ($preview.Count -eq 3 -and @($preview | Where-Object ToVersion -ne '1.5').Count -eq 0) 'Esempio 1: piano errato.'
    Assert ([Convert]::ToBase64String($before) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($b))) '-WhatIf ha modificato un progetto.'
    $json = Join-Path $folder 'report.json'
    ConvertTo-Json -InputObject @($first) -Depth 10 | Set-Content -LiteralPath $json -Encoding utf8
    Assert (@(& $sync -InputPath $json -WhatIf).Count -eq 3) 'Input JSON non riconosciuto.'
    $applied = @($first | & $sync)
    Assert ($applied.Count -eq 3) 'Esempio 1: azioni mancanti.'
    foreach ($path in @($b, $c, $d)) {
        [xml]$xml = Get-Content -LiteralPath $path -Raw
        Assert (@($xml.SelectNodes("//*[local-name()='PackageReference' and @Include='PC' and @Version='1.5']")).Count -eq 1) "Esempio 1: PC non riconciliato in '$path'."
    }
    Assert (-not ((Get-Content -LiteralPath $a -Raw) -match 'Include="PC"')) 'Esempio 1: A non doveva cambiare.'

    $a2 = New-Project 'A2' '<PackageReference Include="PA" Version="1.0" /><PackageReference Include="PC" Version="1.6" />'
    $b2 = New-Project 'B2' '<PackageReference Include="PX" Version="1.0" />'
    $c2 = New-Project 'C2' '<PackageReference Include="PC" Version="1.0" />'
    $d2 = New-Project 'D2' '<PackageReference Include="PC" Version="1.8" />'
    $second = New-Report @(
        (New-Occurrence $a2 'Direct' '1.6' '1.6')
        (New-Occurrence $b2 'Transitive' '1.9' -Parents @([pscustomobject]@{ Package = 'PZ'; Range = '1.9'; Minimum = '1.9' }))
        (New-Occurrence $c2 'Direct' '1.0' '1.0')
        (New-Occurrence $d2 'Direct' '1.8' '1.8')
    ) @('1.6', '1.9', '1.0', '1.8')
    $pz = [pscustomobject]@{
        Package = 'PZ'; ResolvedVersions = @('1.0'); TransitiveMinimums = @()
        Occurrences = @((New-Occurrence $b2 'Transitive' '1.0'))
    }
    $output = @(@($second, $pz) | & $sync)
    Assert ($output.Count -eq 4 -and @($output | Where-Object Action -eq 'AddDirect').Count -eq 1) 'Esempio 2: aggiornamenti errati.'
    foreach ($path in @($a2, $b2, $c2, $d2)) {
        [xml]$xml = Get-Content -LiteralPath $path -Raw
        Assert (@($xml.SelectNodes("//*[local-name()='PackageReference' and @Include='PC' and @Version='1.9']")).Count -eq 1) "Esempio 2: aggiornamento mancante in '$path'."
    }

    $higher = New-Project 'Higher' '<PackageReference Include="PC" Version="1.9" />'
    $source = New-Project 'Source' '<PackageReference Include="PC" Version="1.10" />'
    $versions = New-Report @(
        (New-Occurrence $higher 'Direct' '1.9' '1.9')
        (New-Occurrence $source 'Direct' '1.10' '1.10')
    ) @('1.9', '1.10')
    Assert (@($versions | & $sync -WhatIf)[0].ToVersion -eq '1.10') 'Confronto semantico delle versioni fallito.'

    $requestedLow = New-Project 'RequestedLow' '<PackageReference Include="PC" Version="1.0" />'
    $resolvedPeer = New-Project 'ResolvedPeer' '<PackageReference Include="PC" Version="2.0" />'
    $alreadyResolved = New-Report @(
        (New-Occurrence $requestedLow 'Direct' '2.0' '1.0')
        (New-Occurrence $resolvedPeer 'Direct' '2.0' '2.0')
    ) @('2.0')
    Assert (@($alreadyResolved | & $sync -WhatIf)[0].FromVersion -eq '1.0') 'Versione richiesta inferiore ignorata.'

    $centralFolder = Join-Path $folder 'central'
    New-Item -ItemType Directory -Path $centralFolder | Out-Null
    $central = Join-Path $centralFolder 'Directory.Packages.props'
    '<Project><PropertyGroup><ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally></PropertyGroup><ItemGroup><PackageVersion Include="PC" Version="1.0" /></ItemGroup></Project>' |
        Set-Content -LiteralPath $central -Encoding utf8
    $centralProject = Join-Path $centralFolder 'Central.csproj'
    '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><PackageReference Include="PC" /></ItemGroup></Project>' |
        Set-Content -LiteralPath $centralProject -Encoding utf8
    $modern = New-Project 'Modern' '<PackageReference Include="PC" Version="2.0" />'
    $centralReport = New-Report @(
        (New-Occurrence $centralProject 'Direct' '1.0' '1.0')
        (New-Occurrence $modern 'Direct' '2.0' '2.0')
    ) @('1.0', '2.0')
    $null = $centralReport | & $sync
    [xml]$centralXml = Get-Content -LiteralPath $central -Raw
    Assert (@($centralXml.SelectNodes("//*[local-name()='PackageVersion' and @Include='PC' and @Version='2.0']")).Count -eq 1) 'Versione centrale non aggiornata.'
    Assert (-not ((Get-Content -LiteralPath $centralProject -Raw) -match 'Version="2.0"')) 'Versione centralizzata scritta anche nel progetto.'

    $centralNewFolder = Join-Path $folder 'central-new'
    New-Item -ItemType Directory -Path $centralNewFolder | Out-Null
    $centralNew = Join-Path $centralNewFolder 'Directory.Packages.props'
    '<Project><PropertyGroup><ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally></PropertyGroup><ItemGroup><PackageVersion Include="PA" Version="1.0" /></ItemGroup></Project>' |
        Set-Content -LiteralPath $centralNew -Encoding utf8
    $transitiveProject = Join-Path $centralNewFolder 'Transit.csproj'
    '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><PackageReference Include="PA" /></ItemGroup></Project>' |
        Set-Content -LiteralPath $transitiveProject -Encoding utf8
    $centralAdd = New-Report @(
        (New-Occurrence $transitiveProject 'Transitive' '1.0')
        (New-Occurrence $modern 'Direct' '2.0' '2.0')
    ) @('1.0', '2.0')
    $added = @($centralAdd | & $sync)
    Assert ($added.Count -eq 1 -and $added[0].Action -eq 'AddDirect') 'Dipendenza transitiva centralizzata non pianificata.'
    [xml]$centralNewXml = Get-Content -LiteralPath $centralNew -Raw
    [xml]$transitiveXml = Get-Content -LiteralPath $transitiveProject -Raw
    Assert (@($centralNewXml.SelectNodes("//*[local-name()='PackageVersion' and @Include='PC' and @Version='2.0']")).Count -eq 1) 'Nuova versione centrale non inserita.'
    Assert (@($transitiveXml.SelectNodes("//*[local-name()='PackageReference' and @Include='PC' and not(@Version)]")).Count -eq 1) 'Riferimento centralizzato deve essere privo di Version.'

    $stale = $false
    try { $null = $second | & $sync }
    catch { $stale = $true }
    Assert $stale 'Report obsoleto non bloccato.'

    $legacy = New-Project 'Legacy' '<Reference Include="PC"><HintPath>..\packages\PC.1.0\lib\net48\PC.dll</HintPath></Reference>'
    '<packages><package id="PC" version="1.0" targetFramework="net48" /></packages>' |
        Set-Content -LiteralPath (Join-Path $folder 'packages.config') -Encoding utf8
    $safeFolder = Join-Path $folder 'safe'
    New-Item -ItemType Directory -Path $safeFolder | Out-Null
    $safeProject = Join-Path $safeFolder 'Safe.csproj'
    '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><PackageReference Include="PC" Version="1.0" /></ItemGroup></Project>' |
        Set-Content -LiteralPath $safeProject -Encoding utf8
    $legacyReport = New-Report @(
        (New-Occurrence $legacy 'Direct' '1.0' '1.0')
        (New-Occurrence $safeProject 'Direct' '1.0' '1.0')
        (New-Occurrence $modern 'Direct' '2.0' '2.0')
    ) @('1.0', '2.0')
    $blocked = @($legacyReport | & $sync -WhatIf)
    Assert ($blocked.Count -eq 2 -and @($blocked | Where-Object Status -eq 'Blocked').Count -eq 1) 'Progetto legacy non bloccato in anteprima.'
    $failed = $false
    try { $null = $legacyReport | & $sync }
    catch { $failed = $true }
    Assert $failed 'Progetto legacy modificato senza un percorso sicuro.'
    Assert ((Get-Content -LiteralPath $legacy -Raw) -match 'PC.1.0') 'Progetto legacy modificato.'
    Assert ((Get-Content -LiteralPath $safeProject -Raw) -match 'Version="1.0"') 'Azioni sicure applicate nonostante il blocco legacy.'

    'Test di riconciliazione superati.'
}
finally {
    Remove-Item -LiteralPath $folder -Recurse -Force
}
