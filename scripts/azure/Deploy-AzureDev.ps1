[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Validate', 'WhatIf', 'ApplyFoundation', 'Apply')]
    [string] $Operation,

    [string] $ContainerImage = ''
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

        throw "Azure CLI failed with exit code $exitCode.`n$text"
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
    $accountJson = Invoke-AzureCli -Arguments @('account', 'show', '--output', 'json')
    $account = $accountJson | ConvertFrom-Json

    if ($account.state -ne 'Enabled') {
        throw "The selected Azure subscription is not enabled: $($account.name)."
    }

    return [pscustomobject]@{
        Name = [string] $account.name
        Id = [string] $account.id
        TenantId = [string] $account.tenantId
    }
}

function Get-DeploymentOperatorPrincipalId {
    $principalId = Invoke-AzureCli -Arguments @(
        'ad', 'signed-in-user', 'show',
        '--query', 'id',
        '--output', 'tsv'
    )

    if ($principalId -notmatch '^[0-9a-fA-F-]{36}$') {
        throw 'Could not resolve the signed-in Azure user object ID.'
    }

    return $principalId.ToLowerInvariant()
}

function Get-ActiveContainerImage {
    param(
        [string] $ResourceGroupName = 'rg-html2b-dev',
        [string] $ContainerAppName = 'ca-html2b-dev'
    )

    $groupExists = Invoke-AzureCli -Arguments @(
        'group', 'exists',
        '--name', $ResourceGroupName,
        '--output', 'tsv'
    )

    if ($groupExists -ne 'true') {
        return $null
    }

    $containerAppId = Invoke-AzureCli -AllowFailure -Arguments @(
        'resource', 'show',
        '--resource-group', $ResourceGroupName,
        '--resource-type', 'Microsoft.App/containerApps',
        '--name', $ContainerAppName,
        '--api-version', '2026-01-01',
        '--query', 'id',
        '--output', 'tsv'
    )

    if ([string]::IsNullOrWhiteSpace($containerAppId)) {
        return $null
    }

    $image = Invoke-AzureCli -Arguments @(
        'resource', 'show',
        '--ids', $containerAppId,
        '--api-version', '2026-01-01',
        '--query', 'properties.template.containers[0].image',
        '--output', 'tsv'
    )

    if ([string]::IsNullOrWhiteSpace($image)) {
        throw 'The active Container App exists but its image could not be read.'
    }

    return $image
}

function Assert-ImmutableContainerImage {
    param(
        [Parameter(Mandatory)]
        [string] $Value
    )

    $pattern = '^crhtml2bdev\.azurecr\.io/html2b-api@sha256:[0-9a-f]{64}$'
    if ($Value -cnotmatch $pattern) {
        throw 'Application deployment requires crhtml2bdev.azurecr.io/html2b-api@sha256:<64 lowercase hexadecimal characters>.'
    }
}

function Assert-FoundationTargetState {
    param(
        [switch] $AllowContainerApp
    )

    $resourceGroupName = 'rg-html2b-dev'
    $groupExists = Invoke-AzureCli -Arguments @(
        'group', 'exists',
        '--name', $resourceGroupName,
        '--output', 'tsv'
    )

    if ($groupExists -ne 'true') {
        return
    }

    $inventoryJson = Invoke-AzureCli -Arguments @(
        'resource', 'list',
        '--resource-group', $resourceGroupName,
        '--query', '[].{id:id,name:name,type:type}',
        '--output', 'json'
    )
    $inventory = @($inventoryJson | ConvertFrom-Json)
    $approvedResources = @{
        'microsoft.containerregistry/registries' = 'crhtml2bdev'
        'microsoft.operationalinsights/workspaces' = 'log-html2b-dev'
        'microsoft.managedidentity/userassignedidentities' = 'id-html2b-api-dev'
        'microsoft.app/managedenvironments' = 'cae-html2b-dev'
    }
    if ($AllowContainerApp) {
        $approvedResources['microsoft.app/containerapps'] = 'ca-html2b-dev'
    }
    $unexpected = [System.Collections.Generic.List[string]]::new()

    foreach ($resource in $inventory) {
        $type = ([string] $resource.type).ToLowerInvariant()
        $name = [string] $resource.name

        if ($type -eq 'microsoft.authorization/roleassignments' -and
            ([string] $resource.id) -like '*/registries/crhtml2bdev/providers/Microsoft.Authorization/roleAssignments/*') {
            continue
        }

        if (-not $approvedResources.ContainsKey($type) -or
            $approvedResources[$type] -ne $name) {
            $unexpected.Add("$($resource.type)/$name")
        }
    }

    if ($unexpected.Count -gt 0) {
        throw "Foundation apply refused because rg-html2b-dev contains unexpected resources: $($unexpected -join ', ')."
    }
}

function Assert-ApplicationTargetState {
    Assert-FoundationTargetState -AllowContainerApp

    $resourceGroupName = 'rg-html2b-dev'
    $groupExists = Invoke-AzureCli -Arguments @(
        'group', 'exists',
        '--name', $resourceGroupName,
        '--output', 'tsv'
    )
    if ($groupExists -ne 'true') {
        throw 'Application apply requires the approved image-ready foundation to exist first.'
    }

    $requiredFoundationResources = @(
        @{ Type = 'Microsoft.ContainerRegistry/registries'; Name = 'crhtml2bdev' },
        @{ Type = 'Microsoft.OperationalInsights/workspaces'; Name = 'log-html2b-dev' },
        @{ Type = 'Microsoft.ManagedIdentity/userAssignedIdentities'; Name = 'id-html2b-api-dev' },
        @{ Type = 'Microsoft.App/managedEnvironments'; Name = 'cae-html2b-dev' })
    foreach ($resource in $requiredFoundationResources) {
        $resourceId = Invoke-AzureCli -AllowFailure -Arguments @(
            'resource', 'show',
            '--resource-group', $resourceGroupName,
            '--resource-type', $resource.Type,
            '--name', $resource.Name,
            '--query', 'id',
            '--output', 'tsv'
        )
        if ([string]::IsNullOrWhiteSpace($resourceId)) {
            throw "Application apply requires foundation resource $($resource.Type)/$($resource.Name)."
        }
    }
}

function Invoke-BicepBuild {
    param(
        [Parameter(Mandatory)]
        [string] $BicepFile,

        [Parameter(Mandatory)]
        [string] $OutputFile
    )

    $null = Invoke-AzureCli -Arguments @(
        'bicep', 'build',
        '--file', $BicepFile,
        '--outfile', $OutputFile
    )
}

function Invoke-BicepParameterBuild {
    param(
        [Parameter(Mandatory)]
        [string] $ParameterFile,

        [Parameter(Mandatory)]
        [string] $OutputFile
    )

    $null = Invoke-AzureCli -Arguments @(
        'bicep', 'build-params',
        '--file', $ParameterFile,
        '--outfile', $OutputFile
    )
}

function New-DeploymentArguments {
    param(
        [Parameter(Mandatory)]
        [string] $Verb,

        [Parameter(Mandatory)]
        [string] $DeploymentName,

        [Parameter(Mandatory)]
        [string] $TemplateFile,

        [Parameter(Mandatory)]
        [string] $ParameterFile,

        [Parameter(Mandatory)]
        [string] $DeploymentMode,

        [Parameter(Mandatory)]
        [string] $OperatorPrincipalId,

        [string] $Image = ''
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    foreach ($argument in @(
        'deployment', 'sub', $Verb,
        '--name', $DeploymentName,
        '--location', 'westus2',
        '--template-file', $TemplateFile,
        '--parameters', $ParameterFile,
        '--parameters', "deploymentMode=$DeploymentMode",
        "deploymentOperatorPrincipalId=$OperatorPrincipalId",
        "containerImage=$Image"
    )) {
        $arguments.Add($argument)
    }

    return $arguments.ToArray()
}

function Invoke-SubscriptionValidation {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    return Invoke-AzureCli -Arguments ($Arguments + @('--output', 'json'))
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

function Assert-WhatIfHasNoEffectiveChanges {
    param(
        [Parameter(Mandatory)]
        [string] $WhatIfJson
    )

    $result = $WhatIfJson | ConvertFrom-Json
    if ($result.status -ne 'Succeeded') {
        throw "Azure what-if status was '$($result.status)'."
    }

    $effectiveChanges = @($result.changes | Where-Object {
            $_.changeType -notin @('NoChange', 'Ignore')
        })
    if ($effectiveChanges.Count -ne 0) {
        $summary = $effectiveChanges | ForEach-Object {
            "$($_.changeType): $($_.resourceId)"
        }
        throw "Active-digest apply requires an empty what-if. Effective changes:`n$($summary -join "`n")"
    }
}

function Invoke-SubscriptionDeployment {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    return Invoke-AzureCli -Arguments ($Arguments + @('--output', 'json'))
}

$isApplyOperation = $Operation -in @('ApplyFoundation', 'Apply')
if ($isApplyOperation -and
    $PSBoundParameters.ContainsKey('Confirm') -and
    -not [bool] $PSBoundParameters['Confirm']) {
    throw 'Apply operations reject -Confirm:$false. Interactive confirmation is required.'
}

Assert-AzureCli
Assert-BicepCli

$repositoryRoot = Resolve-RepositoryRoot
$mainBicep = Join-Path $repositoryRoot 'bicep\main.bicep'
$parameterFile = Join-Path $repositoryRoot 'bicep\environments\dev.bicepparam'
$bicepOutputDirectory = Join-Path $repositoryRoot 'build\validation\002\p01\bicep'
$null = [System.IO.Directory]::CreateDirectory($bicepOutputDirectory)
$compiledTemplateFile = Join-Path $bicepOutputDirectory 'main.json'
$compiledParameterFile = Join-Path $bicepOutputDirectory 'dev.parameters.json'

$context = Get-AzureSubscriptionContext
$operatorPrincipalId = Get-DeploymentOperatorPrincipalId
$resolvedContainerImage = $ContainerImage.Trim()
$deploymentMode = 'foundation'

if ($Operation -eq 'ApplyFoundation') {
    Assert-FoundationTargetState -AllowContainerApp
    $resolvedContainerImage = ''
}
elseif ($Operation -eq 'Apply') {
    Assert-ApplicationTargetState

    if (-not [string]::IsNullOrWhiteSpace($resolvedContainerImage)) {
        Assert-ImmutableContainerImage -Value $resolvedContainerImage
        $deploymentMode = 'application'
    }
    else {
        $activeImage = Get-ActiveContainerImage
        if ([string]::IsNullOrWhiteSpace($activeImage)) {
            throw 'Apply requires an immutable image digest, and no active Container App image could be discovered.'
        }

        Assert-ImmutableContainerImage -Value $activeImage
        $resolvedContainerImage = $activeImage
        $deploymentMode = 'application'
    }
}
elseif (-not [string]::IsNullOrWhiteSpace($resolvedContainerImage)) {
    Assert-ImmutableContainerImage -Value $resolvedContainerImage
    $deploymentMode = 'application'
}
else {
    $activeImage = Get-ActiveContainerImage
    if (-not [string]::IsNullOrWhiteSpace($activeImage)) {
        Assert-ImmutableContainerImage -Value $activeImage
        $resolvedContainerImage = $activeImage
        $deploymentMode = 'application'
    }
}

Invoke-BicepBuild `
    -BicepFile $mainBicep `
    -OutputFile $compiledTemplateFile
Invoke-BicepParameterBuild `
    -ParameterFile $parameterFile `
    -OutputFile $compiledParameterFile

$deploymentName = 'html2b-dev-{0}-{1}' -f (
    $Operation.ToLowerInvariant()),
    (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss')

Write-Host "Environment: dev"
Write-Host "Location: westus2"
Write-Host "Resource group: rg-html2b-dev"
Write-Host "Subscription: $($context.Name) ($($context.Id))"
Write-Host "Tenant: $($context.TenantId)"
Write-Host "Operation: $Operation"
Write-Host "Deployment mode: $deploymentMode"
Write-Host "Deployment name: $deploymentName"
Write-Host "Container image: $resolvedContainerImage"

$validationArguments = New-DeploymentArguments `
    -Verb 'validate' `
    -DeploymentName $deploymentName `
    -TemplateFile $compiledTemplateFile `
    -ParameterFile $compiledParameterFile `
    -DeploymentMode $deploymentMode `
    -OperatorPrincipalId $operatorPrincipalId `
    -Image $resolvedContainerImage
$validationResult = Invoke-SubscriptionValidation -Arguments $validationArguments

if ($Operation -eq 'Validate') {
    Write-Output $validationResult
    return
}

$whatIfArguments = New-DeploymentArguments `
    -Verb 'what-if' `
    -DeploymentName $deploymentName `
    -TemplateFile $compiledTemplateFile `
    -ParameterFile $compiledParameterFile `
    -DeploymentMode $deploymentMode `
    -OperatorPrincipalId $operatorPrincipalId `
    -Image $resolvedContainerImage
$whatIfResult = Invoke-SubscriptionWhatIf -Arguments $whatIfArguments

if ($Operation -eq 'Apply' -and [string]::IsNullOrWhiteSpace($ContainerImage)) {
    Assert-WhatIfHasNoEffectiveChanges -WhatIfJson $whatIfResult
}

if ($Operation -eq 'WhatIf') {
    Write-Output $whatIfResult
    return
}

Write-Output $whatIfResult
$description = if ($Operation -eq 'ApplyFoundation') {
    'Create or converge the Html2B image-ready dev foundation and its repository role assignments'
}
else {
    "Create or converge the Html2B dev Container App using $resolvedContainerImage"
}
$target = "subscription '$($context.Name)' ($($context.Id)), resource group 'rg-html2b-dev'"

if ($PSCmdlet.ShouldProcess($target, $description)) {
    $deploymentArguments = New-DeploymentArguments `
        -Verb 'create' `
        -DeploymentName $deploymentName `
        -TemplateFile $compiledTemplateFile `
        -ParameterFile $compiledParameterFile `
        -DeploymentMode $deploymentMode `
        -OperatorPrincipalId $operatorPrincipalId `
        -Image $resolvedContainerImage
    Write-Output (Invoke-SubscriptionDeployment -Arguments $deploymentArguments)
}
