[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$sync = Join-Path (Split-Path $PSScriptRoot -Parent) 'Sync-NuGetDependencies.ps1'
$folder = Join-Path ([IO.Path]::GetTempPath()) ('nuget-hintpath-tests-' + [guid]::NewGuid().ToString('N'))
$projectFolder = Join-Path $folder 'src'
New-Item -ItemType Directory -Path $projectFolder | Out-Null

function Assert {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

try {
    $packageFolder = Join-Path $folder 'packages\PC.1.0\lib\net48'
    $libs = Join-Path $folder 'libs'
    New-Item -ItemType Directory -Path $packageFolder -Force | Out-Null
    New-Item -ItemType Directory -Path $libs | Out-Null
    'assembly' | Set-Content -LiteralPath (Join-Path $packageFolder 'PC.dll')
    'not an assembly' | Set-Content -LiteralPath (Join-Path $packageFolder 'PC.txt')
    'assembly' | Set-Content -LiteralPath (Join-Path $libs 'PN.dll')
    'assembly' | Set-Content -LiteralPath (Join-Path $libs 'PT.dll')

    $legacy = Join-Path $projectFolder 'Legacy.vbproj'
    $absolute = Join-Path $libs 'External.dll'
    @"
<Project ToolsVersion="15.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <ItemGroup>
    <Reference Include="PC"><HintPath>..\packages\PC.1.0\lib\net48\PC.dll</HintPath></Reference>
    <Reference Include="System" />
    <Reference Include="External"><HintPath>$absolute</HintPath></Reference>
    <Reference Include="Missing"><HintPath>..\libs\Missing.dll</HintPath></Reference>
    <Reference Include="PN"><HintPath>..\libs\PN.dll</HintPath></Reference>
    <Reference Include="PT"><HintPath>..\packages\..\libs\PT.dll</HintPath></Reference>
    <Reference Include="Variable"><HintPath>`$(SolutionDir)\lib\Variable.dll</HintPath></Reference>
    <Reference Include="WrongExtension"><HintPath>..\packages\PC.1.0\lib\net48\PC.txt</HintPath></Reference>
  </ItemGroup>
</Project>
"@ | Set-Content -LiteralPath $legacy -Encoding utf8
    '<packages><package id="PC" version="1.0" /><package id="PN" version="1.0" /></packages>' |
        Set-Content -LiteralPath (Join-Path $projectFolder 'packages.config') -Encoding utf8

    $sdk = Join-Path $folder 'Modern.csproj'
    '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup><Reference Include="NoHint" /></ItemGroup></Project>' |
        Set-Content -LiteralPath $sdk -Encoding utf8
    $report = [pscustomobject]@{
        Package = 'PC'; ResolvedVersions = @('1.0'); TransitiveMinimums = @()
        Occurrences = @(
            [pscustomobject]@{ Project = $legacy; Kind = 'Direct'; RequestedVersion = '1.0'; ResolvedVersion = '1.0'; Parents = @() }
            [pscustomobject]@{ Project = $sdk; Kind = 'Direct'; RequestedVersion = '1.0'; ResolvedVersion = '1.0'; Parents = @() }
        )
    }
    $before = [IO.File]::ReadAllBytes($legacy)
    $warnings = @($report | & $sync -WhatIf 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } |
        ForEach-Object { $_.Message })
    Assert ($warnings.Count -eq 7) "Attesi 7 warning, ottenuti $($warnings.Count): $($warnings -join ' | ')"
    foreach ($text in @('System.*mancante', 'External.*relativo', 'Missing.*non trova', 'PN.*sotto', 'PT.*sotto', 'Variable.*variabili', 'WrongExtension.*\.dll')) {
        Assert (@($warnings | Where-Object { $_ -match $text }).Count -eq 1) "Warning non trovato: $text"
    }
    Assert (@($warnings | Where-Object { $_ -match 'PC.*PC.dll|Modern.csproj' }).Count -eq 0) 'Riferimento valido o SDK-style segnalato.'
    Assert ([Convert]::ToBase64String($before) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($legacy))) 'La verifica ha modificato il progetto.'

    $normalWarnings = @($report | & $sync 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
    Assert ($normalWarnings.Count -eq $warnings.Count) 'La verifica deve avvenire anche senza -WhatIf.'
    'Test HintPath superati.'
}
finally {
    Remove-Item -LiteralPath $folder -Recurse -Force
}
