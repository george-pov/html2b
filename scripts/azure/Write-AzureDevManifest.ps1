[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Preview', 'Deployment', 'Rollback', 'Cleanup')]
    [string] $Mode,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $SourceCommit,

    [Parameter(Mandatory)]
    [string] $FunctionPackagePath,

    [Parameter(Mandatory)]
    [ValidatePattern('^crhtml2bdev\.azurecr\.io/html2b-render:[0-9a-f]{40}$')]
    [string] $RenderCommitTag,

    [Parameter(Mandatory)]
    [ValidatePattern('^sha256:[0-9a-f]{64}$')]
    [string] $RenderDigest,

    [Parameter(Mandatory)]
    [string] $BicepPath,

    [Parameter(Mandatory)]
    [string] $ParametersPath,

    [string] $WorkflowRunId = '',

    [string] $WorkflowRunAttempt = '',

    [string] $FunctionDefaultHostName = '',

    [string] $PreviousManifestId = '',

    [string[]] $ValidationResult = @(),

    [string] $OutputDirectory = 'build/deployment/004'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepositoryRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Assert-FullCommitSha {
    param([Parameter(Mandatory)][string] $Value)
    if ($Value -cnotmatch '^[0-9a-f]{40}$') {
        throw 'SourceCommit must be a full lowercase Git commit SHA.'
    }
}

function Assert-Sha256 {
    param([Parameter(Mandatory)][string] $Value)
    if ($Value -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Expected a lowercase SHA-256 value.'
    }
}

function Assert-ImmutableRenderDigest {
    param([Parameter(Mandatory)][string] $Value)
    if ($Value -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'RenderDigest must be an immutable lowercase sha256 digest.'
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Hash input '$Path' does not exist."
    }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Resolve-ManifestOutputDirectory {
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][string] $RequestedPath,
        [Parameter(Mandatory)][string] $SourceCommit
    )

    $basePath = if ([System.IO.Path]::IsPathRooted($RequestedPath)) {
        [System.IO.Path]::GetFullPath($RequestedPath)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $RequestedPath))
    }
    $buildRoot = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'build'))
    if (-not $basePath.StartsWith("$buildRoot$([System.IO.Path]::DirectorySeparatorChar)", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'OutputDirectory must remain beneath the repository build directory.'
    }

    $manifestDirectory = Join-Path (Join-Path $basePath $SourceCommit) 'manifest'
    $null = New-Item -ItemType Directory -Force -Path $manifestDirectory
    return $manifestDirectory
}

Assert-FullCommitSha -Value $SourceCommit
Assert-ImmutableRenderDigest -Value $RenderDigest
if ($RenderCommitTag -cnotmatch ":$SourceCommit$") {
    throw 'RenderCommitTag must end with SourceCommit.'
}
if (-not [string]::IsNullOrWhiteSpace($PreviousManifestId) -and
    $PreviousManifestId -cnotmatch '^[0-9a-f-]{36}$') {
    throw 'PreviousManifestId must be a lowercase GUID when supplied.'
}

$functionPackageSha256 = Get-FileSha256 -Path $FunctionPackagePath
$bicepSha256 = Get-FileSha256 -Path $BicepPath
$parametersSha256 = Get-FileSha256 -Path $ParametersPath
Assert-Sha256 -Value $functionPackageSha256
Assert-Sha256 -Value $bicepSha256
Assert-Sha256 -Value $parametersSha256

$validation = foreach ($result in $ValidationResult) {
    $parts = $result -split '=', 2
    if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or
        $parts[1] -notin @('Passed', 'Failed', 'Skipped')) {
        throw "ValidationResult '$result' must use Name=Passed, Name=Failed, or Name=Skipped."
    }
    [ordered]@{
        name = $parts[0]
        status = $parts[1]
    }
}

$now = [DateTimeOffset]::UtcNow.ToString('O')
$runId = if ([string]::IsNullOrWhiteSpace($WorkflowRunId)) {
    if ([string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) { 'local' } else { $env:GITHUB_RUN_ID }
}
else {
    $WorkflowRunId
}
$runAttempt = if ([string]::IsNullOrWhiteSpace($WorkflowRunAttempt)) {
    if ([string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ATTEMPT)) { '1' } else { $env:GITHUB_RUN_ATTEMPT }
}
else {
    $WorkflowRunAttempt
}

$manifest = [ordered]@{
    schema = 'AzureDevDeploymentManifestV1'
    manifestId = [guid]::NewGuid().ToString('D').ToLowerInvariant()
    mode = $Mode
    source = [ordered]@{
        repository = 'george-pov/html2b'
        commit = $SourceCommit
    }
    workflow = [ordered]@{
        runId = $runId
        runAttempt = $runAttempt
        headSha = $SourceCommit
    }
    artifacts = [ordered]@{
        functionPackageSha256 = $functionPackageSha256
        renderCommitTag = $RenderCommitTag
        renderDigest = $RenderDigest
        renderImage = "crhtml2bdev.azurecr.io/html2b-render@$RenderDigest"
    }
    infrastructure = [ordered]@{
        bicepSha256 = $bicepSha256
        parametersSha256 = $parametersSha256
    }
    resources = [ordered]@{
        resourceGroupName = 'rg-html2b-dev'
        containerRegistryName = 'crhtml2bdev'
        renderContainerAppsEnvironmentName = 'cae-html2b-render-dev'
        renderContainerAppName = 'ca-html2b-render-dev'
        functionAppName = 'func-html2b-api-dev'
        functionDefaultHostName = $FunctionDefaultHostName
        functionUrl = if ([string]::IsNullOrWhiteSpace($FunctionDefaultHostName)) {
            ''
        }
        else {
            "https://$FunctionDefaultHostName"
        }
    }
    previousManifestId = $PreviousManifestId
    validation = @($validation)
    timestamps = [ordered]@{
        createdAtUtc = $now
        updatedAtUtc = $now
    }
}

$repositoryRoot = Resolve-RepositoryRoot
$manifestDirectory = Resolve-ManifestOutputDirectory `
    -RepositoryRoot $repositoryRoot `
    -RequestedPath $OutputDirectory `
    -SourceCommit $SourceCommit
$manifestPath = Join-Path $manifestDirectory 'azure-dev-manifest.json'
[System.IO.File]::WriteAllText(
    $manifestPath,
    ($manifest | ConvertTo-Json -Depth 20),
    [System.Text.UTF8Encoding]::new($false))

$testScript = Join-Path $PSScriptRoot 'Test-AzureDevManifest.ps1'
$null = & $testScript `
    -ManifestPath $manifestPath `
    -ExpectedSourceCommit $SourceCommit `
    -ExpectedMode $Mode `
    -ExpectedFunctionPackagePath $FunctionPackagePath `
    -ExpectedBicepPath $BicepPath `
    -ExpectedParametersPath $ParametersPath

Write-Output "manifestPath=$manifestPath"
Write-Output "manifestId=$($manifest.manifestId)"
