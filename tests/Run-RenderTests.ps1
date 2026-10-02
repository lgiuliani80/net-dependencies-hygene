[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$converter = Join-Path (Split-Path $PSScriptRoot -Parent) 'Convert-NuGetDependencyReport.ps1'
$directory = Join-Path ([IO.Path]::GetTempPath()) ('nuget-report-render-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory | Out-Null

function Assert {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

try {
    $output = Join-Path $directory 'report.html'
    $json = Join-Path $directory 'report.json'
    $package = '</script><script>alert("injected")</script>'
    $sample = [pscustomobject]@{
        Package = $package
        ResolvedVersions = @('8.0.0', '9.0.0')
        VersionConflict = $true
        TransitiveMinimums = @('8.0.0', '9.0.0')
        MinimumConflict = $true
        Occurrences = @(
            [pscustomobject]@{
                Project = 'C:\Sample\One.csproj'
                Kind = 'Direct'
                ResolvedVersion = '8.0.0'
                RequestedVersion = '8.0.0'
                Parents = @([pscustomobject]@{ Package = 'Dependency.Parent'; Range = '[8.0.0, )'; Minimum = '8.0.0' })
            }
        )
    }
    $result = $sample | & $converter -OutputPath $output -NoOpen
    Assert ($result -eq $output -and (Test-Path -LiteralPath $output)) 'Output pipeline non generato.'
    $markup = Get-Content -LiteralPath $output -Raw
    Assert ($markup.Contains('data-theme') -and $markup.Contains('--cp-accent: #b11f4b;')) 'Tema mancante.'
    Assert (-not $markup.Contains($package)) 'Il dato non e'' stato escapato nel documento HTML.'
    Assert ($markup.Contains('\u003c/script\u003e')) 'Escape HTML nel JSON non trovato.'
    Assert ($markup -notmatch '<script\s+src=|<link\s+href=|fetch\(') 'Dipendenza esterna rilevata.'
    $match = [regex]::Match($markup, '(?s)<script id="report-data" type="application/json">(.*?)</script>')
    Assert $match.Success 'Payload JSON inline non trovato.'
    $roundtrip = $match.Groups[1].Value | ConvertFrom-Json
    Assert ($roundtrip.Package -eq $package -and $roundtrip.Occurrences[0].Parents[0].Minimum -eq '8.0.0') 'Payload JSON non integro.'

    ConvertTo-Json -InputObject @($sample) -Depth 10 | Set-Content -LiteralPath $json -Encoding utf8
    $null = & $converter -InputPath $json -OutputPath $output -NoOpen
    Assert ((Get-Content -LiteralPath $output -Raw).Contains('\u003c/script\u003e')) 'Input JSON non renderizzato.'

    '[]' | Set-Content -LiteralPath $json -Encoding utf8
    $null = & $converter -InputPath $json -OutputPath $output -NoOpen
    Assert ((Get-Content -LiteralPath $output -Raw) -match '(?s)id="report-data" type="application/json">\[\]</script>') 'Report vuoto non gestito.'

    $invalid = [pscustomobject]@{ Package = 'Invalid' }
    $failed = $false
    try { $null = $invalid | & $converter -OutputPath $output -NoOpen }
    catch { $failed = $true }
    Assert $failed 'Formato non valido accettato.'
    'Test di rendering superati.'
}
finally {
    Remove-Item -LiteralPath $directory -Recurse -Force
}
