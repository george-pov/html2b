[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Validate', 'WhatIf')]
    [string] $Operation,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $SourceCommit,

    [string] $RenderImage = '',

    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $DeploymentPrincipalId = '',

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

function Assert-ImmutableRenderImage {
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    if ($Value -cnotmatch '^crhtml2bdev\.azurecr\.io/html2b-render@sha256:[0-9a-f]{64}$') {
        throw 'RenderImage must be the immutable crhtml2bdev.azurecr.io/html2b-render digest reference.'
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
        [ValidateSet('validate', 'what-if')]
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
    $legacyNames = @('ca-html2b-dev', 'cae-html2b-dev', 'id-html2b-api-dev')

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
            $change.resourceName -in $legacyNames) {
            throw "Azure what-if proposed changing retained legacy resource '$($change.resourceName)'."
        }
    }

    $serialized = $SanitizedWhatIf | ConvertTo-Json -Depth 10
    if ($serialized -match '(?i)(password|secret|token|connectionstring|instrumentationkey|sharedkey|accountkey|sas)') {
        throw 'Sanitized Azure what-if contains a secret-like field.'
    }
}

Assert-AzureCli
Assert-BicepCli

$repositoryRoot = Resolve-RepositoryRoot
Assert-SourceCommit -RepositoryRoot $repositoryRoot -ExpectedCommit $SourceCommit
$subscriptionContext = Get-AzureSubscriptionContext
$null = Resolve-DeploymentPrincipalId `
    -SubscriptionContext $subscriptionContext `
    -ExplicitPrincipalId $DeploymentPrincipalId

$deploymentMode = if ([string]::IsNullOrWhiteSpace($RenderImage)) {
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

$deploymentName = "html2b-004-$($SourceCommit.Substring(0, 12))-$($Operation.ToLowerInvariant())"
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
    location = 'westus2'
    resourceGroup = 'rg-html2b-dev'
    validated = $true
    validatedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
}
$validationPath = Join-Path $resolvedOutputDirectory 'validation.sanitized.json'
[System.IO.File]::WriteAllText(
    $validationPath,
    ($validationEvidence | ConvertTo-Json -Depth 5),
    [System.Text.UTF8Encoding]::new($false))

if ($Operation -eq 'WhatIf') {
    $whatIfArguments = New-DeploymentArguments `
        -AzureOperation 'what-if' `
        -RepositoryRoot $repositoryRoot `
        -DeploymentName $deploymentName `
        -DeploymentMode $deploymentMode `
        -RenderImage $RenderImage
    $rawWhatIf = Invoke-SubscriptionWhatIf -Arguments $whatIfArguments
    $sanitizedWhatIf = ConvertTo-SanitizedWhatIf -WhatIfJson $rawWhatIf
    Assert-SafeWhatIf -WhatIfJson $rawWhatIf -SanitizedWhatIf $sanitizedWhatIf

    $whatIfPath = Join-Path $resolvedOutputDirectory 'what-if.sanitized.json'
    [System.IO.File]::WriteAllText(
        $whatIfPath,
        ($sanitizedWhatIf | ConvertTo-Json -Depth 10),
        [System.Text.UTF8Encoding]::new($false))
    Write-Output "sanitizedWhatIfPath=$whatIfPath"
}

Write-Output "compiledTemplatePath=$compiledTemplatePath"
Write-Output "compiledParametersPath=$compiledParametersPath"
Write-Output "validationEvidencePath=$validationPath"
