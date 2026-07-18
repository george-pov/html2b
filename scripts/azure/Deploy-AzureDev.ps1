[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Validate', 'WhatIf', 'ApplyFoundation', 'ApplyApplication')]
    [string] $Operation,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $SourceCommit,

    [string] $RenderImage = '',

    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $DeploymentPrincipalId = '',

    [string] $PreviewManifestPath = '',

    [string] $OutputDirectory = 'build/deployment/004'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepositoryRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Invoke-AzureCli {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [switch] $AllowFailure
    )

    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()

    if ($exitCode -ne 0) {
        if ($AllowFailure) {
            return $null
        }

        $commandLabel = (@($Arguments | Select-Object -First 3) -join ' ')
        $errorCode = if ($text -match '(?m)^(?:ERROR:\s*)?\((?<code>[A-Za-z][A-Za-z0-9_.-]+)\)') {
            $Matches.code
        }
        elseif ($text -match '(?i)(unrecognized arguments|the following arguments are required|invalid choice)') {
            'AzureCliArgumentError'
        }
        else {
            'Unavailable'
        }

        throw "Azure CLI command '$commandLabel' failed with exit code $exitCode (error code: $errorCode). The command output was suppressed because it may contain deployment details."
    }

    return $text
}

function Assert-AzureCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is required.'
    }

    $null = Invoke-AzureCli -Arguments @('account', 'show', '--output', 'none')
}

function Assert-BicepCli {
    $version = Invoke-AzureCli -Arguments @('bicep', 'version')
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw 'The Azure CLI-managed Bicep CLI is required.'
    }
}

function Get-AzureSubscriptionContext {
    $account = Invoke-AzureCli -Arguments @(
        'account', 'show',
        '--query', '{name:name,id:id,tenantId:tenantId,state:state,userType:user.type,userName:user.name}',
        '--output', 'json'
    ) | ConvertFrom-Json

    if ($account.state -ne 'Enabled') {
        throw "The selected Azure subscription '$($account.name)' is not enabled."
    }

    if ($account.userType -notin @('user', 'servicePrincipal')) {
        throw "Unsupported Azure identity type '$($account.userType)'."
    }

    return [pscustomobject]@{
        Name = [string] $account.name
        Id = ([string] $account.id).ToLowerInvariant()
        TenantId = ([string] $account.tenantId).ToLowerInvariant()
        UserType = [string] $account.userType
        UserName = [string] $account.userName
    }
}

function Resolve-DeploymentPrincipalId {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $SubscriptionContext,

        [string] $ExplicitPrincipalId
    )

    $resolvedPrincipalId = if ($SubscriptionContext.UserType -eq 'user') {
        Invoke-AzureCli -Arguments @(
            'ad', 'signed-in-user', 'show',
            '--query', 'id',
            '--output', 'tsv'
        )
    }
    else {
        $accessToken = Invoke-AzureCli -Arguments @(
            'account', 'get-access-token',
            '--resource', 'https://management.azure.com/',
            '--query', 'accessToken',
            '--output', 'tsv'
        )
        try {
            $segments = $accessToken -split '\.'
            if ($segments.Count -ne 3) {
                throw 'Azure CLI returned an invalid access token shape.'
            }
            $payload = $segments[1].Replace('-', '+').Replace('_', '/')
            switch ($payload.Length % 4) {
                2 { $payload += '==' }
                3 { $payload += '=' }
            }
            $claims = [System.Text.Encoding]::UTF8.GetString(
                [Convert]::FromBase64String($payload)) | ConvertFrom-Json
            [string] $claims.oid
        }
        finally {
            $accessToken = $null
        }
    }

    if ($resolvedPrincipalId -notmatch '^[0-9a-fA-F-]{36}$') {
        throw 'The active Azure principal object ID could not be resolved.'
    }

    $resolvedPrincipalId = $resolvedPrincipalId.ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($ExplicitPrincipalId) -and
        $resolvedPrincipalId -ne $ExplicitPrincipalId.ToLowerInvariant()) {
        throw 'DeploymentPrincipalId does not match the active Azure identity.'
    }

    return $resolvedPrincipalId
}

function Get-InfrastructureDeploymentPrincipalId {
    $principalId = Invoke-AzureCli -Arguments @(
        'identity', 'show',
        '--resource-group', 'rg-html2b-dev',
        '--name', 'id-html2b-infrastructure-dev',
        '--query', 'principalId',
        '--output', 'tsv'
    )

    if ($principalId -notmatch '^[0-9a-fA-F-]{36}$') {
        throw 'The infrastructure deployment identity principal ID could not be resolved.'
    }

    return $principalId.ToLowerInvariant()
}

function Assert-ImmutableRenderImage {
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    if ($Value -cnotmatch '^crhtml2bdev\.azurecr\.io/html2b-render@sha256:[0-9a-f]{64}$') {
        throw 'RenderImage must be the immutable crhtml2bdev.azurecr.io/html2b-render digest reference.'
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

function Read-PreviewManifest {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $SourceCommit,

        [Parameter(Mandatory)]
        [string] $CompiledTemplatePath,

        [Parameter(Mandatory)]
        [string] $CompiledParametersPath
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'A sanitized preview manifest is required before apply.'
    }

    $manifestTestPath = Join-Path $PSScriptRoot 'Test-AzureDevManifest.ps1'
    $null = & $manifestTestPath `
        -ManifestPath $Path `
        -ExpectedSourceCommit $SourceCommit `
        -ExpectedMode Preview `
        -ExpectedBicepPath $CompiledTemplatePath `
        -ExpectedParametersPath $CompiledParametersPath

    $convertFromJsonParameters = @{
        Depth = 30
    }
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        $convertFromJsonParameters.DateKind = 'String'
    }
    $manifest = Get-Content -Raw -LiteralPath $Path |
        ConvertFrom-Json @convertFromJsonParameters

    if ([string] $manifest.artifacts.renderImage -cne
        "crhtml2bdev.azurecr.io/html2b-render@$([string] $manifest.artifacts.renderDigest)") {
        throw 'Preview manifest Render image and digest do not match.'
    }

    $validationByName = @{}
    foreach ($validation in @($manifest.validation)) {
        $validationByName[[string] $validation.name] = [string] $validation.status
    }
    foreach ($requiredValidation in @(
            'Repository',
            'AzureValidation',
            'AzureWhatIf',
            'PreviewState'
        )) {
        if ($validationByName[$requiredValidation] -ne 'Passed') {
            throw "Preview manifest validation '$requiredValidation' did not pass."
        }
    }

    return $manifest
}

function Assert-FoundationApplyPreconditions {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Manifest,

        [Parameter(Mandatory)]
        [string] $SourceCommit,

        [Parameter(Mandatory)]
        [string] $ActivePrincipalId,

        [Parameter(Mandatory)]
        [string] $ExpectedPrincipalId,

        [string] $RenderImage
    )

    if ([string] $Manifest.source.commit -cne $SourceCommit) {
        throw 'Foundation apply source does not match the preview manifest.'
    }
    if (-not [string]::IsNullOrWhiteSpace($RenderImage)) {
        throw 'ApplyFoundation does not accept RenderImage.'
    }
    if ($ActivePrincipalId -cne $ExpectedPrincipalId) {
        throw 'ApplyFoundation requires the exact infrastructure deployment identity.'
    }
}

function Assert-ApplicationApplyPreconditions {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Manifest,

        [Parameter(Mandatory)]
        [string] $SourceCommit,

        [Parameter(Mandatory)]
        [string] $ActivePrincipalId,

        [Parameter(Mandatory)]
        [string] $ExpectedPrincipalId,

        [Parameter(Mandatory)]
        [string] $RenderImage
    )

    Assert-ImmutableRenderImage -Value $RenderImage
    if ([string] $Manifest.source.commit -cne $SourceCommit) {
        throw 'Application apply source does not match the preview manifest.'
    }
    if ([string] $Manifest.artifacts.renderImage -cne $RenderImage) {
        throw 'ApplyApplication RenderImage does not match the preview manifest.'
    }
    if ($ActivePrincipalId -cne $ExpectedPrincipalId) {
        throw 'ApplyApplication requires the exact infrastructure deployment identity.'
    }
}

function Assert-SourceCommit {
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [string] $ExpectedCommit
    )

    $head = (& git -C $RepositoryRoot rev-parse HEAD 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -cne $ExpectedCommit) {
        throw 'SourceCommit must equal the checked-out full HEAD commit.'
    }

    $trackedStatus = (& git -C $RepositoryRoot status --porcelain --untracked-files=all -- `
        src/api/Html2b.slnx `
        src/api/Html2b.AzureFunctions `
        src/api/Html2b.Render `
        bicep `
        scripts/azure `
        .github 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not inspect deployment source status.'
    }

    if (-not [string]::IsNullOrWhiteSpace($trackedStatus)) {
        throw 'Deployment and host inputs must be committed in SourceCommit.'
    }
}

function Resolve-OutputDirectory {
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [string] $RequestedPath,

        [Parameter(Mandatory)]
        [string] $SourceCommit
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

    $resolvedPath = Join-Path $basePath $SourceCommit
    $null = New-Item -ItemType Directory -Force -Path $resolvedPath
    return $resolvedPath
}

function Invoke-BicepBuild {
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [string] $OutputDirectory
    )

    $templatePath = Join-Path $RepositoryRoot 'bicep/main.bicep'
    $compiledPath = Join-Path $OutputDirectory 'main.json'
    $null = Invoke-AzureCli -Arguments @(
        'bicep', 'build',
        '--file', $templatePath,
        '--outfile', $compiledPath
    )

    if (-not (Test-Path -LiteralPath $compiledPath -PathType Leaf)) {
        throw 'Bicep compilation did not produce main.json.'
    }

    return $compiledPath
}

function Invoke-BicepParameterBuild {
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [string] $OutputDirectory
    )

    $parameterSourcePath = Join-Path $RepositoryRoot 'bicep/environments/dev.bicepparam'
    $compiledPath = Join-Path $OutputDirectory 'dev.parameters.json'
    $null = Invoke-AzureCli -Arguments @(
        'bicep', 'build-params',
        '--file', $parameterSourcePath,
        '--outfile', $compiledPath
    )

    if (-not (Test-Path -LiteralPath $compiledPath -PathType Leaf)) {
        throw 'Bicep parameter compilation did not produce dev.parameters.json.'
    }

    return $compiledPath
}

function New-DeploymentArguments {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('validate', 'what-if', 'create')]
        [string] $AzureOperation,

        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [string] $DeploymentName,

        [Parameter(Mandatory)]
        [ValidateSet('foundation', 'application')]
        [string] $DeploymentMode,

        [string] $RenderImage
    )

    $arguments = @(
        'deployment', 'sub', $AzureOperation,
        '--name', $DeploymentName,
        '--location', 'westus2',
        '--template-file', (Join-Path $RepositoryRoot 'bicep/main.bicep'),
        '--parameters', (Join-Path $RepositoryRoot 'bicep/environments/dev.bicepparam'),
        "deploymentMode=$DeploymentMode"
    )

    if ($DeploymentMode -eq 'application') {
        $arguments += "renderImage=$RenderImage"
    }

    $arguments += '--only-show-errors'
    return $arguments
}

function Invoke-SubscriptionValidation {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $null = Invoke-AzureCli -Arguments ($Arguments + @('--output', 'none'))
}

function Invoke-SubscriptionWhatIf {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    return Invoke-AzureCli -Arguments ($Arguments + @(
        '--result-format', 'FullResourcePayloads',
        '--no-pretty-print',
        '--output', 'json'
    ))
}

function Invoke-SubscriptionDeployment {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    return Invoke-AzureCli -Arguments ($Arguments + @('--output', 'json'))
}

function ConvertTo-SanitizedWhatIf {
    param(
        [Parameter(Mandatory)]
        [string] $WhatIfJson
    )

    $result = $WhatIfJson | ConvertFrom-Json -Depth 100
    $changes = foreach ($change in @($result.changes)) {
        $resourceId = [string] $change.resourceId
        $segments = @($resourceId.Trim('/') -split '/')
        $resourceGroupIndex = [Array]::IndexOf($segments, 'resourceGroups')
        $providersIndex = [Array]::LastIndexOf($segments, 'providers')

        $resourceGroup = if ($resourceGroupIndex -ge 0 -and $segments.Count -gt $resourceGroupIndex + 1) {
            $segments[$resourceGroupIndex + 1]
        }
        else {
            ''
        }
        $resourceType = if ($providersIndex -ge 0 -and $segments.Count -gt $providersIndex + 2) {
            $typeSegments = [System.Collections.Generic.List[string]]::new()
            $typeSegments.Add($segments[$providersIndex + 1])
            for ($index = $providersIndex + 2; $index -lt $segments.Count; $index += 2) {
                $typeSegments.Add($segments[$index])
            }
            $typeSegments -join '/'
        }
        elseif ($segments.Count -ge 2 -and $segments[0] -eq 'subscriptions' -and $resourceGroupIndex -ge 0) {
            'Microsoft.Resources/resourceGroups'
        }
        else {
            ''
        }
        $resourceName = if ($segments.Count -gt 0) { $segments[-1] } else { '' }

        [ordered]@{
            changeType = [string] $change.changeType
            resourceGroup = $resourceGroup
            resourceType = $resourceType
            resourceName = $resourceName
        }
    }

    return [ordered]@{
        status = [string] $result.status
        changes = @($changes | Sort-Object resourceGroup, resourceType, resourceName)
    }
}

function Assert-SafeWhatIf {
    param(
        [Parameter(Mandatory)]
        [string] $WhatIfJson,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $SanitizedWhatIf
    )

    $rawResult = $WhatIfJson | ConvertFrom-Json -Depth 100
    $allowedChangeTypes = @('Create', 'Modify', 'NoChange', 'Deploy', 'Ignore')
    $retainedNames = @(
        'ca-html2b-dev',
        'cae-html2b-dev',
        'id-html2b-api-dev',
        'id-html2b-infrastructure-dev'
    )

    foreach ($change in @($rawResult.changes)) {
        if ([string] $change.changeType -notin $allowedChangeTypes) {
            throw "Unsafe Azure what-if change type '$($change.changeType)' was rejected."
        }

        if ($null -ne $change.before -and $null -ne $change.after) {
            foreach ($identityProperty in @('id', 'name', 'type')) {
                $beforeValue = [string] $change.before.$identityProperty
                $afterValue = [string] $change.after.$identityProperty
                if (-not [string]::IsNullOrWhiteSpace($beforeValue) -and
                    -not [string]::IsNullOrWhiteSpace($afterValue) -and
                    $beforeValue -cne $afterValue) {
                    throw "Azure what-if proposed a resource replacement through '$identityProperty'."
                }
            }
        }
    }

    foreach ($change in @($SanitizedWhatIf.changes)) {
        if ($change.resourceType -eq 'Microsoft.Resources/resourceGroups') {
            if ($change.resourceName -ne 'rg-html2b-dev') {
                throw "Azure what-if targeted unexpected resource group '$($change.resourceName)'."
            }
        }
        elseif ($change.resourceGroup -ne 'rg-html2b-dev') {
            throw "Azure what-if targeted out-of-scope resource group '$($change.resourceGroup)'."
        }

        if ($change.changeType -notin @('NoChange', 'Ignore') -and
            $change.resourceName -in $retainedNames) {
            throw "Azure what-if proposed changing retained resource '$($change.resourceName)'."
        }
    }

    $serialized = $SanitizedWhatIf | ConvertTo-Json -Depth 10
    if ($serialized -match '(?i)(password|secret|token|connectionstring|instrumentationkey|sharedkey|accountkey|sas)') {
        throw 'Sanitized Azure what-if contains a secret-like field.'
    }
}

function Assert-DeploymentMatchesWhatIf {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $SanitizedWhatIf,

        [Parameter(Mandatory)]
        [ValidateSet('foundation', 'application')]
        [string] $DeploymentMode,

        [Parameter(Mandatory)]
        [pscustomobject] $Manifest,

        [string] $RenderImage
    )

    if ($SanitizedWhatIf.status -ne 'Succeeded') {
        throw "Fresh Azure what-if status '$($SanitizedWhatIf.status)' is not successful."
    }

    if ($DeploymentMode -eq 'foundation') {
        if (-not [string]::IsNullOrWhiteSpace($RenderImage)) {
            throw 'Foundation deployment input differs from its fresh what-if.'
        }
    }
    elseif ([string] $Manifest.artifacts.renderImage -cne $RenderImage) {
        throw 'Application deployment Render image differs from its fresh what-if.'
    }

    foreach ($change in @($SanitizedWhatIf.changes)) {
        if ($change.changeType -in @('Delete', 'DeleteThenCreate', 'CreateThenDelete')) {
            throw "Fresh Azure what-if contains forbidden '$($change.changeType)' change."
        }
    }
}

function ConvertTo-SanitizedDeployment {
    param(
        [Parameter(Mandatory)]
        [string] $DeploymentJson,

        [Parameter(Mandatory)]
        [ValidateSet('foundation', 'application')]
        [string] $DeploymentMode,

        [Parameter(Mandatory)]
        [string] $DeploymentName,

        [Parameter(Mandatory)]
        [string] $SourceCommit,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $ExpectedRenderImage
    )

    $deployment = $DeploymentJson | ConvertFrom-Json -Depth 100
    if ([string] $deployment.properties.provisioningState -ne 'Succeeded') {
        throw 'Azure subscription deployment did not report successful provisioning.'
    }

    $outputs = $deployment.properties.outputs
    $requiredOutputNames = @(
        'resourceGroupName',
        'containerRegistryLoginServer',
        'renderContainerAppFqdn',
        'functionAppName',
        'functionAppDefaultHostName',
        'applicationDeploymentClientId',
        'deployedRenderImage'
    )
    foreach ($outputName in $requiredOutputNames) {
        if ($null -eq $outputs.PSObject.Properties[$outputName]) {
            throw "Azure subscription deployment omitted output '$outputName'."
        }
    }

    $resourceGroupName = [string] $outputs.resourceGroupName.value
    $containerRegistryLoginServer = [string] $outputs.containerRegistryLoginServer.value
    $functionAppName = [string] $outputs.functionAppName.value
    $applicationDeploymentClientId = [string] $outputs.applicationDeploymentClientId.value
    $deployedRenderImage = [string] $outputs.deployedRenderImage.value

    if ($resourceGroupName -ne 'rg-html2b-dev' -or
        $containerRegistryLoginServer -ne 'crhtml2bdev.azurecr.io' -or
        $functionAppName -ne 'func-html2b-api-dev' -or
        $applicationDeploymentClientId -notmatch '^[0-9a-fA-F-]{36}$') {
        throw 'Azure subscription deployment returned an unexpected topology output.'
    }
    if ($DeploymentMode -eq 'foundation' -and
        -not [string]::IsNullOrWhiteSpace($deployedRenderImage)) {
        throw 'Foundation deployment unexpectedly returned a Render image.'
    }
    if ($DeploymentMode -eq 'application' -and
        $deployedRenderImage -cne $ExpectedRenderImage) {
        throw 'Application deployment returned a different Render image.'
    }

    return [ordered]@{
        provisioningState = 'Succeeded'
        sourceCommit = $SourceCommit
        deploymentName = $DeploymentName
        deploymentMode = $DeploymentMode
        resourceGroupName = $resourceGroupName
        containerRegistryLoginServer = $containerRegistryLoginServer
        renderContainerAppFqdn = [string] $outputs.renderContainerAppFqdn.value
        functionAppName = $functionAppName
        functionAppDefaultHostName = [string] $outputs.functionAppDefaultHostName.value
        applicationDeploymentClientId = $applicationDeploymentClientId.ToLowerInvariant()
        deployedRenderImage = $deployedRenderImage
    }
}

function Write-SanitizedJson {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [object] $Value,

        [int] $Depth = 10
    )

    [System.IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth $Depth),
        [System.Text.UTF8Encoding]::new($false))
}

if ($Operation -in @('ApplyFoundation', 'ApplyApplication') -and
    $PSBoundParameters.ContainsKey('Confirm') -and
    -not [bool] $PSBoundParameters['Confirm']) {
    throw 'Apply operations reject confirmation suppression.'
}

Assert-AzureCli
Assert-BicepCli

$repositoryRoot = Resolve-RepositoryRoot
Assert-SourceCommit -RepositoryRoot $repositoryRoot -ExpectedCommit $SourceCommit
$subscriptionContext = Get-AzureSubscriptionContext
$activePrincipalId = Resolve-DeploymentPrincipalId `
    -SubscriptionContext $subscriptionContext `
    -ExplicitPrincipalId $DeploymentPrincipalId

$deploymentMode = if ($Operation -eq 'ApplyFoundation') {
    if (-not [string]::IsNullOrWhiteSpace($RenderImage)) {
        throw 'ApplyFoundation does not accept RenderImage.'
    }
    'foundation'
}
elseif ($Operation -eq 'ApplyApplication') {
    Assert-ImmutableRenderImage -Value $RenderImage
    'application'
}
elseif ([string]::IsNullOrWhiteSpace($RenderImage)) {
    'foundation'
}
else {
    Assert-ImmutableRenderImage -Value $RenderImage
    'application'
}

if ($Operation -eq 'WhatIf' -and $deploymentMode -ne 'application') {
    throw 'WhatIf requires the immutable RenderImage so the complete topology is previewed.'
}

$resolvedOutputDirectory = Resolve-OutputDirectory `
    -RepositoryRoot $repositoryRoot `
    -RequestedPath $OutputDirectory `
    -SourceCommit $SourceCommit
$compiledTemplatePath = Invoke-BicepBuild `
    -RepositoryRoot $repositoryRoot `
    -OutputDirectory $resolvedOutputDirectory
$compiledParametersPath = Invoke-BicepParameterBuild `
    -RepositoryRoot $repositoryRoot `
    -OutputDirectory $resolvedOutputDirectory

$deploymentName = if ($Operation -eq 'ApplyFoundation') {
    "html2b-004-$($SourceCommit.Substring(0, 12))-foundation"
}
elseif ($Operation -eq 'ApplyApplication') {
    "html2b-004-$($SourceCommit.Substring(0, 12))-application"
}
else {
    "html2b-004-$($SourceCommit.Substring(0, 12))-$($Operation.ToLowerInvariant())"
}
$validationArguments = New-DeploymentArguments `
    -AzureOperation validate `
    -RepositoryRoot $repositoryRoot `
    -DeploymentName $deploymentName `
    -DeploymentMode $deploymentMode `
    -RenderImage $RenderImage
Invoke-SubscriptionValidation -Arguments $validationArguments

$validationEvidence = [ordered]@{
    operation = $Operation
    sourceCommit = $SourceCommit
    deploymentMode = $deploymentMode
    subscription = $subscriptionContext.Name
    subscriptionId = $subscriptionContext.Id
    tenantId = $subscriptionContext.TenantId
    location = 'westus2'
    resourceGroup = 'rg-html2b-dev'
    validated = $true
    validatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
}
$validationPath = Join-Path $resolvedOutputDirectory 'validation.sanitized.json'
Write-SanitizedJson -Path $validationPath -Value $validationEvidence -Depth 5

$isApplyOperation = $Operation -in @('ApplyFoundation', 'ApplyApplication')
$previewManifest = $null
if ($isApplyOperation) {
    $previewManifest = Read-PreviewManifest `
        -Path $PreviewManifestPath `
        -SourceCommit $SourceCommit `
        -CompiledTemplatePath $compiledTemplatePath `
        -CompiledParametersPath $compiledParametersPath
    $expectedPrincipalId = Get-InfrastructureDeploymentPrincipalId

    if ($Operation -eq 'ApplyFoundation') {
        Assert-FoundationApplyPreconditions `
            -Manifest $previewManifest `
            -SourceCommit $SourceCommit `
            -ActivePrincipalId $activePrincipalId `
            -ExpectedPrincipalId $expectedPrincipalId `
            -RenderImage $RenderImage
    }
    else {
        Assert-ApplicationApplyPreconditions `
            -Manifest $previewManifest `
            -SourceCommit $SourceCommit `
            -ActivePrincipalId $activePrincipalId `
            -ExpectedPrincipalId $expectedPrincipalId `
            -RenderImage $RenderImage
    }
}

if ($Operation -eq 'WhatIf' -or $isApplyOperation) {
    $whatIfArguments = New-DeploymentArguments `
        -AzureOperation 'what-if' `
        -RepositoryRoot $repositoryRoot `
        -DeploymentName $deploymentName `
        -DeploymentMode $deploymentMode `
        -RenderImage $RenderImage
    $rawWhatIf = Invoke-SubscriptionWhatIf -Arguments $whatIfArguments
    $sanitizedWhatIf = ConvertTo-SanitizedWhatIf -WhatIfJson $rawWhatIf
    Assert-SafeWhatIf -WhatIfJson $rawWhatIf -SanitizedWhatIf $sanitizedWhatIf
    if ($isApplyOperation) {
        Assert-DeploymentMatchesWhatIf `
            -SanitizedWhatIf $sanitizedWhatIf `
            -DeploymentMode $deploymentMode `
            -Manifest $previewManifest `
            -RenderImage $RenderImage
    }

    $whatIfPath = Join-Path $resolvedOutputDirectory 'what-if.sanitized.json'
    Write-SanitizedJson -Path $whatIfPath -Value $sanitizedWhatIf -Depth 10
    Write-Output "sanitizedWhatIfPath=$whatIfPath"
}

if ($isApplyOperation) {
    $renderDigest = [string] $previewManifest.artifacts.renderDigest
    Write-Output "subscriptionName=$($subscriptionContext.Name)"
    Write-Output "subscriptionId=$($subscriptionContext.Id)"
    Write-Output "tenantId=$($subscriptionContext.TenantId)"
    Write-Output 'resourceGroupName=rg-html2b-dev'
    Write-Output "deploymentMode=$deploymentMode"
    Write-Output "deploymentName=$deploymentName"
    Write-Output "renderDigest=$renderDigest"

    $target = "$($subscriptionContext.Id)/rg-html2b-dev/$deploymentName"
    $action = "Apply $deploymentMode deployment for $SourceCommit with Render digest $renderDigest"
    if ($PSCmdlet.ShouldProcess($target, $action)) {
        $deploymentArguments = New-DeploymentArguments `
            -AzureOperation create `
            -RepositoryRoot $repositoryRoot `
            -DeploymentName $deploymentName `
            -DeploymentMode $deploymentMode `
            -RenderImage $RenderImage
        $deploymentJson = Invoke-SubscriptionDeployment -Arguments $deploymentArguments
        $sanitizedDeployment = ConvertTo-SanitizedDeployment `
            -DeploymentJson $deploymentJson `
            -DeploymentMode $deploymentMode `
            -DeploymentName $deploymentName `
            -SourceCommit $SourceCommit `
            -ExpectedRenderImage $RenderImage
        $deploymentPath = Join-Path $resolvedOutputDirectory "$deploymentMode-deployment.sanitized.json"
        Write-SanitizedJson -Path $deploymentPath -Value $sanitizedDeployment -Depth 10

        Write-Output "deploymentEvidencePath=$deploymentPath"
        Write-Output "containerRegistryLoginServer=$($sanitizedDeployment.containerRegistryLoginServer)"
        Write-Output "renderContainerAppFqdn=$($sanitizedDeployment.renderContainerAppFqdn)"
        Write-Output "functionAppName=$($sanitizedDeployment.functionAppName)"
        Write-Output "functionDefaultHostName=$($sanitizedDeployment.functionAppDefaultHostName)"
        Write-Output "applicationDeploymentClientId=$($sanitizedDeployment.applicationDeploymentClientId)"
        Write-Output "deployedRenderImage=$($sanitizedDeployment.deployedRenderImage)"
    }
}

Write-Output "compiledTemplatePath=$compiledTemplatePath"
Write-Output "compiledParametersPath=$compiledParametersPath"
Write-Output "validationEvidencePath=$validationPath"
