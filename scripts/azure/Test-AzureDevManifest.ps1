[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ManifestPath,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedSourceCommit,

    [ValidateSet('Preview', 'Deployment', 'Rollback', 'Cleanup')]
    [string] $ExpectedMode = 'Preview',

    [string] $ExpectedFunctionPackagePath = '',

    [string] $ExpectedBicepPath = '',

    [string] $ExpectedParametersPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-FullCommitSha {
    param(
        [Parameter(Mandatory)]
        [string] $Value,

        [string] $Name = 'source commit'
    )

    if ($Value -cnotmatch '^[0-9a-f]{40}$') {
        throw "$Name must be a full lowercase Git commit SHA."
    }
}

function Assert-Sha256 {
    param(
        [Parameter(Mandatory)]
        [string] $Value,

        [string] $Name = 'SHA-256'
    )

    if ($Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Name must be a lowercase SHA-256 value."
    }
}

function Assert-ImmutableRenderDigest {
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    if ($Value -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'Render digest must be an immutable lowercase sha256 digest.'
    }
}

function Get-FileSha256 {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Hash input '$Path' does not exist."
    }

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Assert-ManifestSchema {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Manifest
    )

    if ($Manifest.schema -ne 'AzureDevDeploymentManifestV1') {
        throw "Unsupported manifest schema '$($Manifest.schema)'."
    }
    if ($Manifest.mode -notin @('Preview', 'Deployment', 'Rollback', 'Cleanup')) {
        throw "Unsupported manifest mode '$($Manifest.mode)'."
    }
    if ([string] $Manifest.manifestId -cnotmatch '^[0-9a-f-]{36}$') {
        throw 'Manifest ID must be a lowercase GUID.'
    }

    Assert-FullCommitSha -Value ([string] $Manifest.source.commit) -Name 'manifest source commit'
    Assert-Sha256 -Value ([string] $Manifest.artifacts.functionPackageSha256) -Name 'Function package hash'
    Assert-ImmutableRenderDigest -Value ([string] $Manifest.artifacts.renderDigest)
    Assert-Sha256 -Value ([string] $Manifest.infrastructure.bicepSha256) -Name 'Bicep hash'
    Assert-Sha256 -Value ([string] $Manifest.infrastructure.parametersSha256) -Name 'parameter hash'

    if ($Manifest.source.repository -ne 'george-pov/html2b') {
        throw "Unexpected source repository '$($Manifest.source.repository)'."
    }
    if ($Manifest.resources.resourceGroupName -ne 'rg-html2b-dev' -or
        $Manifest.resources.containerRegistryName -ne 'crhtml2bdev' -or
        $Manifest.resources.renderContainerAppName -ne 'ca-html2b-render-dev' -or
        $Manifest.resources.functionAppName -ne 'func-html2b-api-dev') {
        throw 'Manifest resource names do not match the Html2B dev topology.'
    }

    try {
        $created = [DateTimeOffset]::ParseExact(
            [string] $Manifest.timestamps.createdAtUtc,
            'O',
            [System.Globalization.CultureInfo]::InvariantCulture)
        $updated = [DateTimeOffset]::ParseExact(
            [string] $Manifest.timestamps.updatedAtUtc,
            'O',
            [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        throw 'Manifest timestamps must use the round-trip UTC format.'
    }
    if ($updated -lt $created) {
        throw 'Manifest updated timestamp precedes its created timestamp.'
    }
}

function Assert-ManifestMatchesSource {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Manifest,

        [Parameter(Mandatory)]
        [string] $SourceCommit
    )

    Assert-FullCommitSha -Value $SourceCommit
    if ([string] $Manifest.source.commit -cne $SourceCommit) {
        throw 'Manifest source commit does not match the selected source.'
    }
    if ([string] $Manifest.workflow.headSha -cne $SourceCommit) {
        throw 'Manifest workflow SHA does not match the selected source.'
    }
    if ([string] $Manifest.artifacts.renderCommitTag -cnotmatch "/html2b-render:$SourceCommit$") {
        throw 'Manifest Render commit tag does not match the selected source.'
    }
}

function Assert-ManifestContainsNoSecrets {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Manifest
    )

    $propertyNames = [System.Collections.Generic.List[string]]::new()
    function Add-PropertyNames {
        param([object] $Value)
        if ($null -eq $Value) {
            return
        }
        if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string] -and $Value -isnot [pscustomobject]) {
            foreach ($item in $Value) {
                Add-PropertyNames -Value $item
            }
            return
        }
        if ($Value -is [pscustomobject]) {
            foreach ($property in $Value.PSObject.Properties) {
                $propertyNames.Add($property.Name)
                Add-PropertyNames -Value $property.Value
            }
        }
    }
    Add-PropertyNames -Value $Manifest

    $forbiddenPropertyPattern = '(?i)(password|secret|access.?token|refresh.?token|connection.?string|publish.?profile|storage.?key|account.?key|shared.?key|instrumentation.?key|registry.?credential|sas)'
    $forbiddenProperty = $propertyNames | Where-Object { $_ -match $forbiddenPropertyPattern } | Select-Object -First 1
    if ($null -ne $forbiddenProperty) {
        throw "Manifest contains forbidden secret-like field '$forbiddenProperty'."
    }

    $serialized = $Manifest | ConvertTo-Json -Depth 20 -Compress
    $forbiddenValuePattern = '(?i)(AccountKey=|SharedAccessSignature=|InstrumentationKey=|Authorization:\s*Bearer|gh[pousr]_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]+PRIVATE KEY-----)'
    if ($serialized -match $forbiddenValuePattern) {
        throw 'Manifest contains a secret-like value.'
    }
}

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Manifest '$ManifestPath' does not exist."
}

$convertFromJsonParameters = @{
    Depth = 30
}
if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
    $convertFromJsonParameters.DateKind = 'String'
}
$manifest = Get-Content -Raw -LiteralPath $ManifestPath |
    ConvertFrom-Json @convertFromJsonParameters
Assert-ManifestSchema -Manifest $manifest
Assert-ManifestMatchesSource -Manifest $manifest -SourceCommit $ExpectedSourceCommit
Assert-ManifestContainsNoSecrets -Manifest $manifest

if ($manifest.mode -ne $ExpectedMode) {
    throw "Manifest mode '$($manifest.mode)' does not match '$ExpectedMode'."
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedFunctionPackagePath) -and
    $manifest.artifacts.functionPackageSha256 -cne (Get-FileSha256 -Path $ExpectedFunctionPackagePath)) {
    throw 'Manifest Function package hash does not match the selected package.'
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedBicepPath) -and
    $manifest.infrastructure.bicepSha256 -cne (Get-FileSha256 -Path $ExpectedBicepPath)) {
    throw 'Manifest Bicep hash does not match the selected compiled template.'
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedParametersPath) -and
    $manifest.infrastructure.parametersSha256 -cne (Get-FileSha256 -Path $ExpectedParametersPath)) {
    throw 'Manifest parameter hash does not match the selected compiled parameters.'
}

Write-Output "manifestId=$($manifest.manifestId)"
Write-Output 'manifestValidation=passed'
