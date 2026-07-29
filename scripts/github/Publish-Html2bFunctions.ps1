[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SourceRoot,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $OutputDirectory,

    [ValidateNotNullOrEmpty()]
    [string] $Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedSourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$projectPath = Join-Path `
    $resolvedSourceRoot `
    'src/api/Html2b.AzureFunctions/Html2b.AzureFunctions.csproj'

if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
    throw "Functions project was not found at $projectPath."
}

$buildRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $resolvedSourceRoot 'build')
)
$resolvedOutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)
$buildRootPrefix = $buildRoot.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
) + [System.IO.Path]::DirectorySeparatorChar

if (
    -not $resolvedOutputDirectory.StartsWith(
        $buildRootPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )
) {
    throw 'Functions output must remain below the selected source build directory.'
}

if (Test-Path -LiteralPath $resolvedOutputDirectory) {
    Remove-Item -LiteralPath $resolvedOutputDirectory -Recurse -Force
}

New-Item `
    -ItemType Directory `
    -Path $resolvedOutputDirectory `
    -Force |
    Out-Null

dotnet publish `
    $projectPath `
    --configuration $Configuration `
    --output $resolvedOutputDirectory `
    /p:UseAppHost=false
if ($LASTEXITCODE -ne 0) {
    throw "Functions publish failed with exit code $LASTEXITCODE."
}

Write-Host "Functions publish directory: $resolvedOutputDirectory"
