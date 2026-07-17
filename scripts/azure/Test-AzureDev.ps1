[CmdletBinding()]
param(
    [ValidateSet('Preview')]
    [string] $ValidationMode = 'Preview',

    [Parameter(Mandatory)]
    [string] $SanitizedWhatIfPath,

    [string] $OutputDirectory = 'build/validation/004/p01/preview'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepositoryRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Invoke-AzureCli {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI read failed with exit code $LASTEXITCODE. Output was suppressed."
    }
    return ($output | Out-String).Trim()
}

function Invoke-GitHubCli {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $output = & gh @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI read failed with exit code $LASTEXITCODE. Output was suppressed."
    }
    return ($output | Out-String).Trim()
}

function Get-AzureResourceInventory {
    $inventory = Invoke-AzureCli -Arguments @(
        'resource', 'list',
        '--resource-group', 'rg-html2b-dev',
        '--query', '[].{name:name,type:type,location:location}',
        '--output', 'json'
    ) | ConvertFrom-Json

    return @($inventory | Sort-Object name)
}

function Get-GitHubOidcSubjectState {
    $customization = Invoke-GitHubCli -Arguments @(
        'api',
        'repos/george-pov/html2b/actions/oidc/customization/sub'
    ) | ConvertFrom-Json

    return [pscustomobject]@{
        UsesDefaultSubject = [bool] $customization.use_default
        ExpectedEnvironmentSubject = 'repo:george-pov/html2b:environment:dev'
    }
}

function Assert-SharedFoundationState {
    param(
        [Parameter(Mandatory)]
        [object[]] $Inventory
    )

    $registry = @($Inventory | Where-Object {
            $_.name -eq 'crhtml2bdev' -and
            $_.type -eq 'Microsoft.ContainerRegistry/registries'
        })
    $workspace = @($Inventory | Where-Object {
            $_.name -eq 'log-html2b-dev' -and
            $_.type -eq 'Microsoft.OperationalInsights/workspaces'
        })
    if ($registry.Count -ne 1 -or $workspace.Count -ne 1) {
        throw 'The shared ACR and Log Analytics foundation does not match the approved baseline.'
    }

    $registryState = Invoke-AzureCli -Arguments @(
        'acr', 'show',
        '--resource-group', 'rg-html2b-dev',
        '--name', 'crhtml2bdev',
        '--query', '{sku:sku.name,roleAssignmentMode:roleAssignmentMode,adminUserEnabled:adminUserEnabled,anonymousPullEnabled:anonymousPullEnabled}',
        '--output', 'json'
    ) | ConvertFrom-Json
    if ($registryState.sku -ne 'Basic' -or
        $registryState.roleAssignmentMode -ne 'AbacRepositoryPermissions' -or
        $registryState.adminUserEnabled -ne $false -or
        $registryState.anonymousPullEnabled -ne $false) {
        throw 'ACR no longer matches the approved Basic ABAC credential-free contract.'
    }
}

function Assert-LegacyResourcesRetained {
    param(
        [Parameter(Mandatory)]
        [object[]] $Inventory,

        [Parameter(Mandatory)]
        [pscustomobject] $SanitizedWhatIf
    )

    $legacyNames = @(
        'ca-html2b-dev',
        'cae-html2b-dev',
        'id-html2b-api-dev'
    )
    foreach ($name in $legacyNames) {
        if (@($Inventory | Where-Object name -eq $name).Count -ne 1) {
            throw "Retained legacy resource '$name' is missing."
        }

        $effectiveChange = @($SanitizedWhatIf.changes | Where-Object {
                $_.resourceName -eq $name -and
                $_.changeType -notin @('NoChange', 'Ignore')
            })
        if ($effectiveChange.Count -ne 0) {
            throw "Preview changes retained legacy resource '$name'."
        }
    }
}

function Assert-PreviewResourceSet {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $SanitizedWhatIf
    )

    if ($SanitizedWhatIf.status -notin @('Succeeded', 'NoChange')) {
        throw "Azure what-if status '$($SanitizedWhatIf.status)' is not successful."
    }

    $allowedChangeTypes = @('Create', 'Modify', 'NoChange', 'Deploy', 'Ignore')
    foreach ($change in @($SanitizedWhatIf.changes)) {
        if ($change.changeType -notin $allowedChangeTypes) {
            throw "Preview contains unsafe change type '$($change.changeType)'."
        }
        if ($change.resourceType -ne 'Microsoft.Resources/resourceGroups' -and
            $change.resourceGroup -ne 'rg-html2b-dev') {
            throw "Preview contains out-of-scope resource '$($change.resourceName)'."
        }
    }

    $requiredNames = @(
        'vnet-html2b-dev',
        'snet-container-apps-dev',
        'snet-functions-dev',
        'appi-html2b-dev',
        'sthtml2bfuncdev',
        'id-html2b-functions-dev',
        'plan-html2b-functions-dev',
        'func-html2b-api-dev',
        'id-html2b-render-dev',
        'cae-html2b-render-dev',
        'ca-html2b-render-dev',
        'id-html2b-application-deploy-dev'
    )
    foreach ($name in $requiredNames) {
        if (@($SanitizedWhatIf.changes | Where-Object resourceName -eq $name).Count -eq 0) {
            throw "Complete preview is missing planned resource '$name'."
        }
    }
}

function Assert-RoleAssignmentScope {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $SanitizedWhatIf
    )

    $roleChanges = @($SanitizedWhatIf.changes | Where-Object {
            $_.resourceType -eq 'Microsoft.Authorization/roleAssignments'
        })
    if ($roleChanges.Count -lt 6) {
        throw "Preview contains $($roleChanges.Count) role assignments; expected at least six exact assignments."
    }
    if (@($roleChanges | Where-Object resourceGroup -ne 'rg-html2b-dev').Count -ne 0) {
        throw 'Preview contains a role assignment outside rg-html2b-dev resources.'
    }

    $registryId = Invoke-AzureCli -Arguments @(
        'acr', 'show',
        '--resource-group', 'rg-html2b-dev',
        '--name', 'crhtml2bdev',
        '--query', 'id',
        '--output', 'tsv'
    )
    $legacyAssignments = Invoke-AzureCli -Arguments @(
        'role', 'assignment', 'list',
        '--scope', $registryId,
        '--query', '[].{scope:scope,condition:condition,conditionVersion:conditionVersion}',
        '--output', 'json'
    ) | ConvertFrom-Json
    if (@($legacyAssignments).Count -lt 2 -or
        @($legacyAssignments | Where-Object {
                $_.scope -ine $registryId -or $_.conditionVersion -ne '2.0'
            }).Count -ne 0) {
        throw 'Existing ACR repository assignments no longer match the scoped ABAC baseline.'
    }
}

function Write-SanitizedValidationEvidence {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [object[]] $Inventory,

        [Parameter(Mandatory)]
        [pscustomobject] $OidcState,

        [Parameter(Mandatory)]
        [pscustomobject] $SanitizedWhatIf
    )

    $evidence = [ordered]@{
        schema = 'Html2bAzureDevPreviewValidationV1'
        mode = 'Preview'
        resourceGroup = 'rg-html2b-dev'
        inventory = @($Inventory)
        githubOidc = [ordered]@{
            usesDefaultSubject = $OidcState.UsesDefaultSubject
            expectedEnvironmentSubject = $OidcState.ExpectedEnvironmentSubject
        }
        preview = [ordered]@{
            status = $SanitizedWhatIf.status
            changeCount = @($SanitizedWhatIf.changes).Count
            safe = $true
        }
        validatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    }
    [System.IO.File]::WriteAllText(
        $Path,
        ($evidence | ConvertTo-Json -Depth 15),
        [System.Text.UTF8Encoding]::new($false))
}

# Retained output-contract helpers are used when P02 extends this script with
# live Function validation.
function Assert-ContentDisposition {
    param(
        [Parameter(Mandatory)][object] $Disposition,
        [Parameter(Mandatory)][string] $ExpectedFileName
    )
    if ($null -eq $Disposition) {
        throw 'Response omitted Content-Disposition.'
    }
    $actual = if (-not [string]::IsNullOrWhiteSpace($Disposition.FileNameStar)) {
        $Disposition.FileNameStar
    }
    else {
        $Disposition.FileName
    }
    if ($actual.Trim('"') -ne $ExpectedFileName) {
        throw "Response filename '$actual' does not match '$ExpectedFileName'."
    }
}

function Assert-FileSignature {
    param(
        [Parameter(Mandatory)][ValidateSet('png', 'jpeg', 'pdf')][string] $Format,
        [Parameter(Mandatory)][byte[]] $Bytes
    )
    $valid = switch ($Format) {
        'png' {
            $Bytes.Length -ge 8 -and
            [Convert]::ToHexString($Bytes[0..7]) -eq '89504E470D0A1A0A'
        }
        'jpeg' {
            $Bytes.Length -ge 4 -and
            $Bytes[0] -eq 0xff -and $Bytes[1] -eq 0xd8 -and
            $Bytes[-2] -eq 0xff -and $Bytes[-1] -eq 0xd9
        }
        'pdf' {
            $Bytes.Length -ge 5 -and
            [System.Text.Encoding]::ASCII.GetString($Bytes, 0, 5) -eq '%PDF-'
        }
    }
    if (-not $valid) {
        throw "$Format file signature validation failed."
    }
}

function Assert-RasterDimensions {
    param(
        [Parameter(Mandatory)][ValidateSet('png', 'jpeg')][string] $Format,
        [Parameter(Mandatory)][byte[]] $Bytes,
        [int] $ExpectedWidth = 1280,
        [int] $ExpectedHeight = 720
    )
    if ($Format -eq 'png') {
        $width = [System.Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($Bytes, 16))
        $height = [System.Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($Bytes, 20))
        if ($width -ne $ExpectedWidth -or $height -ne $ExpectedHeight) {
            throw 'PNG dimensions do not match the expected contract.'
        }
    }
}

function Assert-PdfPageSize {
    param(
        [Parameter(Mandatory)][byte[]] $Bytes,
        [double] $ExpectedWidthPoints = 960,
        [double] $ExpectedHeightPoints = 540
    )
    $text = [System.Text.Encoding]::ASCII.GetString($Bytes)
    if ($text -notmatch "/MediaBox\s*\[\s*0(?:\.0+)?\s+0(?:\.0+)?\s+$ExpectedWidthPoints(?:\.0+)?\s+$ExpectedHeightPoints(?:\.0+)?\s*\]") {
        throw 'PDF page size does not match the expected contract.'
    }
}

if ($ValidationMode -ne 'Preview') {
    throw 'P01 supports Preview validation only.'
}
if (-not (Get-Command az -ErrorAction SilentlyContinue) -or
    -not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI and GitHub CLI are required.'
}
if (-not (Test-Path -LiteralPath $SanitizedWhatIfPath -PathType Leaf)) {
    throw "Sanitized what-if '$SanitizedWhatIfPath' does not exist."
}

$repositoryRoot = Resolve-RepositoryRoot
$resolvedOutputDirectory = if ([System.IO.Path]::IsPathRooted($OutputDirectory)) {
    [System.IO.Path]::GetFullPath($OutputDirectory)
}
else {
    [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $OutputDirectory))
}
$buildRoot = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot 'build'))
if (-not $resolvedOutputDirectory.StartsWith("$buildRoot$([System.IO.Path]::DirectorySeparatorChar)", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'OutputDirectory must remain beneath the repository build directory.'
}
$null = New-Item -ItemType Directory -Force -Path $resolvedOutputDirectory

$sanitizedWhatIf = Get-Content -Raw -LiteralPath $SanitizedWhatIfPath | ConvertFrom-Json -Depth 30
$serializedWhatIf = $sanitizedWhatIf | ConvertTo-Json -Depth 30 -Compress
if ($serializedWhatIf -match '(?i)(password|secret|token|connectionstring|instrumentationkey|sharedkey|accountkey|sas)') {
    throw 'Sanitized what-if contains a secret-like field.'
}

$inventory = Get-AzureResourceInventory
$oidcState = Get-GitHubOidcSubjectState
if (-not $oidcState.UsesDefaultSubject) {
    throw 'GitHub OIDC no longer uses the expected default subject format.'
}
Assert-SharedFoundationState -Inventory $inventory
Assert-LegacyResourcesRetained -Inventory $inventory -SanitizedWhatIf $sanitizedWhatIf
Assert-PreviewResourceSet -SanitizedWhatIf $sanitizedWhatIf
Assert-RoleAssignmentScope -SanitizedWhatIf $sanitizedWhatIf

$evidencePath = Join-Path $resolvedOutputDirectory 'preview-validation.sanitized.json'
Write-SanitizedValidationEvidence `
    -Path $evidencePath `
    -Inventory $inventory `
    -OidcState $oidcState `
    -SanitizedWhatIf $sanitizedWhatIf

Write-Output "previewValidationEvidencePath=$evidencePath"
Write-Output 'previewValidation=passed'
