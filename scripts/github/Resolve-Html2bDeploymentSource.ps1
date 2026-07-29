[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $RepositoryRoot,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SourceSha,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $CurrentRef
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($CurrentRef -cne 'refs/heads/main') {
    throw 'Application deployment must be dispatched from main.'
}

$normalizedSourceSha = $SourceSha.Trim().ToLowerInvariant()

if ($normalizedSourceSha -notmatch '^[0-9a-f]{40}$') {
    throw 'The deployment source must be an exact 40-character commit SHA.'
}

$resolvedRepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path

git -C $resolvedRepositoryRoot cat-file -e "$normalizedSourceSha^{commit}"
if ($LASTEXITCODE -ne 0) {
    throw "Deployment source $normalizedSourceSha is not a local commit."
}

git -C $resolvedRepositoryRoot merge-base --is-ancestor `
    $normalizedSourceSha `
    origin/main
if ($LASTEXITCODE -eq 1) {
    throw (
        "Deployment source $normalizedSourceSha is not reachable from " +
        'origin/main.'
    )
}
if ($LASTEXITCODE -ne 0) {
    throw "Source ancestry verification failed with exit code $LASTEXITCODE."
}

Write-Host "Deployment source: $normalizedSourceSha"
