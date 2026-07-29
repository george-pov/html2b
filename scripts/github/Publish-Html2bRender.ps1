[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SourceRoot,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $SourceSha,

    [Parameter(Mandatory)]
    [guid] $SubscriptionId,

    [Parameter(Mandatory)]
    [guid] $ExpectedTenantId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9]+$')]
    [string] $RegistryName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9._/-]*$')]
    [string] $ImageRepository,

    [AllowEmptyString()]
    [string] $GitHubOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedSourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$dockerfileRelativePath = 'src/api/Html2b.Render/Dockerfile'
$dockerfilePath = Join-Path `
    $resolvedSourceRoot `
    $dockerfileRelativePath

if (-not (Test-Path -LiteralPath $dockerfilePath -PathType Leaf)) {
    throw "Render Dockerfile was not found at $dockerfilePath."
}

$accountJsonLines = @(
    az account show `
        --subscription $SubscriptionId `
        --output json `
        --only-show-errors
)
if ($LASTEXITCODE -ne 0) {
    throw "Azure account readback failed with exit code $LASTEXITCODE."
}

$account = ($accountJsonLines -join "`n") | ConvertFrom-Json -Depth 20
$actualSubscriptionId = [guid] $account.id
$actualTenantId = [guid] $account.tenantId

if ($actualSubscriptionId -ne $SubscriptionId) {
    throw 'The active Azure subscription does not match the selected Environment.'
}
if ($actualTenantId -ne $ExpectedTenantId) {
    throw 'The active Azure tenant does not match the selected Environment.'
}

$loginServerLines = @(
    az acr show `
        --subscription $SubscriptionId `
        --name $RegistryName `
        --query loginServer `
        --output tsv `
        --only-show-errors
)
if ($LASTEXITCODE -ne 0) {
    throw "Registry readback failed with exit code $LASTEXITCODE."
}

$loginServer = ($loginServerLines -join "`n").Trim().ToLowerInvariant()
if ($loginServer -notmatch '^[a-z0-9.-]+(?::[0-9]+)?$') {
    throw 'Azure returned an invalid Container Registry login server.'
}

$tag = "${ImageRepository}:$SourceSha"
az acr build `
    --subscription $SubscriptionId `
    --registry $RegistryName `
    --image $tag `
    --file $dockerfileRelativePath `
    --source-acr-auth-id '[caller]' `
    --only-show-errors `
    --output none `
    $resolvedSourceRoot
if ($LASTEXITCODE -ne 0) {
    throw "Render image build failed with exit code $LASTEXITCODE."
}

$digestLines = @(
    az acr repository show `
        --subscription $SubscriptionId `
        --name $RegistryName `
        --image $tag `
        --query digest `
        --output tsv `
        --only-show-errors
)
if ($LASTEXITCODE -ne 0) {
    throw "Render image digest readback failed with exit code $LASTEXITCODE."
}

$digest = ($digestLines -join "`n").Trim().ToLowerInvariant()
if ($digest -notmatch '^sha256:[0-9a-f]{64}$') {
    throw 'Azure returned an invalid Render image digest.'
}

$image = "$loginServer/$ImageRepository@$digest"

if (-not [string]::IsNullOrWhiteSpace($GitHubOutputPath)) {
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::AppendAllText(
        $GitHubOutputPath,
        "image=$image`n",
        $encoding
    )
}

Write-Host "Render image: $image"
