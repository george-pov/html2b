[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $RepositoryRoot,

    [Parameter(Mandatory)]
    [AllowEmptyString()]
    [string] $ParametersFile,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,31}$')]
    [string] $TargetEnvironment,

    [Parameter(Mandatory)]
    [ValidateSet('WhatIf', 'Apply')]
    [string] $DeploymentMode,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $CurrentRef,

    [Parameter(Mandatory)]
    [guid] $SubscriptionId,

    [Parameter(Mandatory)]
    [guid] $ExpectedTenantId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-zA-Z0-9._()-]+$')]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9]{5,50}$')]
    [string] $RegistryName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9._/-]*$')]
    [string] $ImageRepository,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z][a-z0-9-]{1,30}[a-z0-9]$')]
    [string] $ContainerAppName,

    [AllowEmptyString()]
    [string] $InitialRenderImage = '',

    [bool] $RunLiveValidation = $false,

    [AllowEmptyString()]
    [string] $GitHubOutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bicepVersion = 'v0.45.15'
$renderContainerName = 'html2b-render'
$containerAppApiVersion = '2026-01-01'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Resolve-Html2bBicepParametersFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $ParametersFile
    )

    if ([string]::IsNullOrWhiteSpace($ParametersFile)) {
        throw 'The selected Environment has no Bicep parameters file.'
    }

    if ($ParametersFile -cne $ParametersFile.Trim()) {
        throw 'The Bicep parameters path must not contain surrounding whitespace.'
    }

    if (
        [System.IO.Path]::IsPathRooted($ParametersFile) -or
        $ParametersFile -match '^[a-zA-Z]:' -or
        $ParametersFile.StartsWith('//', [System.StringComparison]::Ordinal) -or
        $ParametersFile.StartsWith('\\', [System.StringComparison]::Ordinal)
    ) {
        throw 'The Bicep parameters path must be repository-relative.'
    }

    if ($ParametersFile.Contains('\')) {
        throw 'The Bicep parameters path must use forward slashes.'
    }

    if ($ParametersFile -match '[\x00-\x1f\x7f]') {
        throw 'The Bicep parameters path contains a control character.'
    }

    $segments = $ParametersFile.Split('/')
    if (
        $segments.Count -lt 3 -or
        @($segments | Where-Object { $_ -in @('', '.', '..') }).Count -ne 0
    ) {
        throw 'The Bicep parameters path is not normalized.'
    }

    if (
        -not $ParametersFile.StartsWith(
            'bicep/environments/',
            [System.StringComparison]::Ordinal
        )
    ) {
        throw 'The Bicep parameters file must be below bicep/environments/.'
    }

    if (
        -not $ParametersFile.EndsWith(
            '.bicepparam',
            [System.StringComparison]::Ordinal
        )
    ) {
        throw 'The Bicep parameters file must use the .bicepparam extension.'
    }

    if ($ParametersFile -notmatch '^bicep/environments/[a-zA-Z0-9][a-zA-Z0-9._-]*\.bicepparam$') {
        throw 'The Bicep parameters path contains an unsupported character.'
    }

    $resolvedRepositoryRoot = (
        Resolve-Path -LiteralPath $RepositoryRoot
    ).Path
    $environmentDirectory = (
        Resolve-Path -LiteralPath (
            Join-Path $resolvedRepositoryRoot 'bicep/environments'
        )
    ).Path
    $candidatePath = Join-Path $resolvedRepositoryRoot $ParametersFile

    if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
        throw 'The Bicep parameters file does not exist.'
    }

    $resolvedCandidatePath = (Resolve-Path -LiteralPath $candidatePath).Path
    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    $environmentPrefix = $environmentDirectory.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar

    if (-not $resolvedCandidatePath.StartsWith($environmentPrefix, $comparison)) {
        throw 'The resolved Bicep parameters file escapes bicep/environments/.'
    }

    $stageLines = @(
        git -C $resolvedRepositoryRoot `
            ls-files `
            --error-unmatch `
            --stage `
            -- `
            $ParametersFile
    )
    $gitExitCode = $LASTEXITCODE
    if ($gitExitCode -ne 0) {
        throw "Git parameters-file lookup failed with exit code $gitExitCode."
    }

    if ($stageLines.Count -ne 1) {
        throw 'The Bicep parameters file must be tracked exactly once.'
    }

    $stageMatch = [regex]::Match(
        [string] $stageLines[0],
        '^(?<mode>[0-9]{6}) [0-9a-f]{40,64} [0-3]\t(?<path>.+)$'
    )
    if (-not $stageMatch.Success) {
        throw 'Git returned an unexpected parameters-file record.'
    }

    if ($stageMatch.Groups['mode'].Value -cne '100644') {
        throw 'The Bicep parameters file must be a normal tracked file.'
    }

    if ($stageMatch.Groups['path'].Value -cne $ParametersFile) {
        throw 'The Bicep parameters path must match the tracked path exactly.'
    }

    return $resolvedCandidatePath
}

function Invoke-AzureCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Operation,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $CaptureDirectory
    )

    $captureId = [guid]::NewGuid().ToString('N')
    $stdoutPath = Join-Path $CaptureDirectory "$captureId.stdout"
    $stderrPath = Join-Path $CaptureDirectory "$captureId.stderr"

    try {
        & az @Arguments 1> $stdoutPath 2> $stderrPath
        $exitCode = $LASTEXITCODE
        $stdout = if (Test-Path -LiteralPath $stdoutPath) {
            [System.IO.File]::ReadAllText($stdoutPath)
        }
        else {
            ''
        }

        if ($exitCode -ne 0) {
            throw "$Operation failed with exit code $exitCode."
        }

        return $stdout.Trim()
    }
    finally {
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function ConvertFrom-AzureJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Json,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Operation
    )

    if ([string]::IsNullOrWhiteSpace($Json)) {
        throw "$Operation returned no JSON."
    }

    try {
        return $Json | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "$Operation returned invalid JSON."
    }
}

function Install-Html2bBicep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $CaptureDirectory
    )

    $null = Invoke-AzureCli `
        -Arguments @(
            'bicep', 'install',
            '--version', $bicepVersion,
            '--only-show-errors',
            '--output', 'none'
        ) `
        -Operation "Bicep $bicepVersion installation" `
        -CaptureDirectory $CaptureDirectory

    $version = Invoke-AzureCli `
        -Arguments @('bicep', 'version', '--only-show-errors') `
        -Operation 'Bicep version readback' `
        -CaptureDirectory $CaptureDirectory

    if ($version -notmatch '^Bicep CLI version 0\.45\.15 \(') {
        throw "Expected Bicep 0.45.15 but received '$version'."
    }
}

function Assert-AzureContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [guid] $SubscriptionId,

        [Parameter(Mandatory)]
        [guid] $ExpectedTenantId,

        [Parameter(Mandatory)]
        [string] $CaptureDirectory
    )

    $accountJson = Invoke-AzureCli `
        -Arguments @(
            'account', 'show',
            '--subscription', $SubscriptionId.ToString('D'),
            '--output', 'json',
            '--only-show-errors'
        ) `
        -Operation 'Azure account readback' `
        -CaptureDirectory $CaptureDirectory
    $account = ConvertFrom-AzureJson `
        -Json $accountJson `
        -Operation 'Azure account readback'

    if ([guid] $account.id -ne $SubscriptionId) {
        throw 'The active Azure subscription does not match the selected Environment.'
    }
    if ([guid] $account.tenantId -ne $ExpectedTenantId) {
        throw 'The active Azure tenant does not match the selected Environment.'
    }
    if ([string] $account.state -cne 'Enabled') {
        throw 'The selected Azure subscription is not enabled.'
    }
}

function Get-RegistryLoginServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [guid] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $RegistryName,

        [Parameter(Mandatory)]
        [string] $CaptureDirectory
    )

    $loginServer = Invoke-AzureCli `
        -Arguments @(
            'acr', 'show',
            '--subscription', $SubscriptionId.ToString('D'),
            '--name', $RegistryName,
            '--query', 'loginServer',
            '--output', 'tsv',
            '--only-show-errors'
        ) `
        -Operation 'Container Registry readback' `
        -CaptureDirectory $CaptureDirectory

    if ($loginServer -cnotmatch '^[a-z0-9.-]+(?::[0-9]+)?$') {
        throw 'Azure returned an invalid Container Registry login server.'
    }

    return $loginServer
}

function Assert-ImmutableRenderImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Image,

        [Parameter(Mandatory)]
        [string] $LoginServer,

        [Parameter(Mandatory)]
        [string] $ImageRepository
    )

    $pattern = '^{0}/{1}@sha256:[0-9a-f]{{64}}$' -f (
        [regex]::Escape($LoginServer)),
        ([regex]::Escape($ImageRepository))

    if ($Image -cnotmatch $pattern) {
        throw (
            'The Render image must use the selected registry and repository ' +
            'with an immutable lowercase sha256 digest.'
        )
    }
}

function Get-RenderContainerApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [guid] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $ContainerAppName,

        [Parameter(Mandatory)]
        [string] $CaptureDirectory
    )

    $resourcesJson = Invoke-AzureCli `
        -Arguments @(
            'resource', 'list',
            '--subscription', $SubscriptionId.ToString('D'),
            '--name', $ContainerAppName,
            '--resource-type', 'Microsoft.App/containerApps',
            '--output', 'json',
            '--only-show-errors'
        ) `
        -Operation 'Container App inventory' `
        -CaptureDirectory $CaptureDirectory
    $resources = @(
        ConvertFrom-AzureJson `
            -Json $resourcesJson `
            -Operation 'Container App inventory'
    )
    $targets = @(
        $resources | Where-Object {
            $_.name -ieq $ContainerAppName -and
            $_.resourceGroup -ieq $ResourceGroupName
        }
    )

    if ($targets.Count -gt 1) {
        throw 'Azure returned the target Container App more than once.'
    }
    if ($targets.Count -eq 0) {
        return $null
    }

    $containerAppJson = Invoke-AzureCli `
        -Arguments @(
            'resource', 'show',
            '--ids', [string] $targets[0].id,
            '--api-version', $containerAppApiVersion,
            '--output', 'json',
            '--only-show-errors'
        ) `
        -Operation 'Container App readback' `
        -CaptureDirectory $CaptureDirectory

    return ConvertFrom-AzureJson `
        -Json $containerAppJson `
        -Operation 'Container App readback'
}

function Get-RenderContainerImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject] $ContainerApp,

        [Parameter(Mandatory)]
        [string] $ContainerName
    )

    $containers = @(
        $ContainerApp.properties.template.containers |
            Where-Object { $_.name -ceq $ContainerName }
    )

    if ($containers.Count -ne 1) {
        throw "Render container $ContainerName was not found exactly once."
    }

    return ([string] $containers[0].image).Trim()
}

function Assert-InitialImageManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [guid] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $RegistryName,

        [Parameter(Mandatory)]
        [string] $ImageRepository,

        [Parameter(Mandatory)]
        [string] $Image,

        [Parameter(Mandatory)]
        [string] $CaptureDirectory
    )

    $digest = $Image.Substring($Image.LastIndexOf('@') + 1)
    $observedDigest = Invoke-AzureCli `
        -Arguments @(
            'acr', 'repository', 'show',
            '--subscription', $SubscriptionId.ToString('D'),
            '--name', $RegistryName,
            '--image', "$ImageRepository@$digest",
            '--query', 'digest',
            '--output', 'tsv',
            '--only-show-errors'
        ) `
        -Operation 'Initial Render manifest readback' `
        -CaptureDirectory $CaptureDirectory

    if ($observedDigest -cne $digest) {
        throw 'The selected initial Render manifest could not be verified.'
    }
}

function Write-CompiledBicep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $MainBicepPath,

        [Parameter(Mandatory)]
        [string] $ParametersFilePath,

        [Parameter(Mandatory)]
        [string] $CompiledTemplatePath,

        [Parameter(Mandatory)]
        [string] $CompiledParametersPath,

        [Parameter(Mandatory)]
        [string] $CaptureDirectory
    )

    $templateJson = Invoke-AzureCli `
        -Arguments @(
            'bicep', 'build',
            '--file', $MainBicepPath,
            '--no-restore',
            '--stdout',
            '--only-show-errors'
        ) `
        -Operation 'Bicep template compilation' `
        -CaptureDirectory $CaptureDirectory
    $compiledTemplate = ConvertFrom-AzureJson `
        -Json $templateJson `
        -Operation 'Bicep template compilation'
    [System.IO.File]::WriteAllText(
        $CompiledTemplatePath,
        $templateJson,
        $utf8NoBom
    )

    $wrapperJson = Invoke-AzureCli `
        -Arguments @(
            'bicep', 'build-params',
            '--file', $ParametersFilePath,
            '--no-restore',
            '--stdout',
            '--only-show-errors'
        ) `
        -Operation 'Bicep parameters compilation' `
        -CaptureDirectory $CaptureDirectory
    $wrapper = ConvertFrom-AzureJson `
        -Json $wrapperJson `
        -Operation 'Bicep parameters compilation'

    if (
        $wrapper.PSObject.Properties.Name -notcontains 'parametersJson' -or
        [string]::IsNullOrWhiteSpace([string] $wrapper.parametersJson)
    ) {
        throw 'Bicep parameters compilation returned no parameter document.'
    }
    if (
        $wrapper.PSObject.Properties.Name -notcontains 'templateJson' -or
        [string]::IsNullOrWhiteSpace([string] $wrapper.templateJson)
    ) {
        throw 'Bicep parameters compilation returned no template document.'
    }

    $compiledParameters = ConvertFrom-AzureJson `
        -Json ([string] $wrapper.parametersJson) `
        -Operation 'Compiled Bicep parameters'
    $parameterTemplate = ConvertFrom-AzureJson `
        -Json ([string] $wrapper.templateJson) `
        -Operation 'Compiled Bicep parameter template'
    $compiledTemplateCanonical = $compiledTemplate |
        ConvertTo-Json -Depth 100 -Compress
    $parameterTemplateCanonical = $parameterTemplate |
        ConvertTo-Json -Depth 100 -Compress
    if ($compiledTemplateCanonical -cne $parameterTemplateCanonical) {
        throw 'The Bicep parameters file does not target bicep/main.bicep.'
    }
    [System.IO.File]::WriteAllText(
        $CompiledParametersPath,
        [string] $wrapper.parametersJson,
        $utf8NoBom
    )

    return $compiledParameters
}

function Get-CompiledParameterValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject] $CompiledParameters,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $parameter = $CompiledParameters.parameters.PSObject.Properties[$Name]
    if ($null -eq $parameter) {
        throw "Compiled Bicep parameters do not contain $Name."
    }

    return $parameter.Value.value
}

function Assert-CompiledParameter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject] $CompiledParameters,

        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $ExpectedValue
    )

    $actualValue = [string] (
        Get-CompiledParameterValue `
            -CompiledParameters $CompiledParameters `
            -Name $Name
    )
    if ($actualValue -cne $ExpectedValue) {
        throw "Compiled Bicep parameter $Name does not match the selected Environment."
    }
}

function New-DeploymentArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('validate', 'what-if', 'create')]
        [string] $Verb,

        [Parameter(Mandatory)]
        [guid] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $DeploymentName,

        [Parameter(Mandatory)]
        [string] $Location,

        [Parameter(Mandatory)]
        [string] $CompiledTemplatePath,

        [Parameter(Mandatory)]
        [string] $CompiledParametersPath
    )

    return @(
        'deployment', 'sub', $Verb,
        '--subscription', $SubscriptionId.ToString('D'),
        '--name', $DeploymentName,
        '--location', $Location,
        '--template-file', $CompiledTemplatePath,
        '--parameters', "@$CompiledParametersPath",
        '--no-prompt', 'true',
        '--only-show-errors',
        '--output', 'json'
    )
}

function Assert-DeploymentSucceeded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject] $Deployment,

        [Parameter(Mandatory)]
        [string] $Operation
    )

    if ([string] $Deployment.properties.provisioningState -cne 'Succeeded') {
        throw "$Operation did not report a succeeded provisioning state."
    }
}

function Assert-WhatIfAllowsApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject] $WhatIf
    )

    if ([string] $WhatIf.status -cne 'Succeeded') {
        throw 'Azure What-If did not report success.'
    }

    if ($WhatIf.PSObject.Properties.Name -notcontains 'changes') {
        throw 'Azure What-If returned no changes collection.'
    }
    if ($WhatIf.changes -isnot [System.Array]) {
        throw 'Azure What-If returned an invalid changes collection.'
    }
    if ($WhatIf.PSObject.Properties.Name -contains 'potentialChanges') {
        $potentialChanges = @(
            $WhatIf.potentialChanges |
                Where-Object { $null -ne $_ }
        )
        if ($potentialChanges.Count -ne 0) {
            throw 'Azure What-If returned unresolved potential changes.'
        }
    }

    $changes = @($WhatIf.changes)
    $knownChangeTypes = @(
        'Create',
        'Delete',
        'Deploy',
        'Ignore',
        'Modify',
        'NoEffect',
        'NoChange'
    )
    $unknownChanges = @(
        $changes | Where-Object {
            [string] $_.changeType -cnotin $knownChangeTypes
        }
    )
    if ($unknownChanges.Count -ne 0) {
        throw 'Azure What-If returned an unsupported change type.'
    }

    $counts = [ordered] @{}
    foreach ($changeType in $knownChangeTypes) {
        $counts[$changeType] = @(
            $changes | Where-Object {
                [string] $_.changeType -ceq $changeType
            }
        ).Count
    }

    Write-Host (
        'What-If summary: ' +
        (($knownChangeTypes | ForEach-Object {
                    "$_=$($counts[$_])"
                }) -join ', ')
    )
    foreach ($change in @(
        $changes | Where-Object {
                [string] $_.changeType -notin @(
                    'Ignore',
                    'NoChange',
                    'NoEffect'
                )
            }
        )) {
        Write-Host "$($change.changeType): $($change.resourceId)"
    }

    if ($counts['Delete'] -ne 0) {
        throw 'Azure What-If contains a resource deletion; Apply is blocked.'
    }
}

function Get-DeploymentOutputValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject] $Deployment,

        [Parameter(Mandatory)]
        [string] $Name
    )

    $output = $Deployment.properties.outputs.PSObject.Properties[$Name]
    if ($null -eq $output) {
        throw "Azure deployment output $Name is missing."
    }

    $value = [string] $output.Value.value
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Azure deployment output $Name is empty."
    }

    return $value
}

function Assert-DeploymentOutputs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject] $Deployment,

        [Parameter(Mandatory)]
        [string] $ExpectedResourceGroupName,

        [Parameter(Mandatory)]
        [string] $ExpectedFunctionAppName,

        [Parameter(Mandatory)]
        [string] $ExpectedContainerAppName
    )

    if (
        (
            Get-DeploymentOutputValue `
                -Deployment $Deployment `
                -Name 'resourceGroupName'
        ) -cne $ExpectedResourceGroupName
    ) {
        throw 'Azure returned an unexpected resource group output.'
    }
    if (
        (
            Get-DeploymentOutputValue `
                -Deployment $Deployment `
                -Name 'functionAppName'
        ) -cne $ExpectedFunctionAppName
    ) {
        throw 'Azure returned an unexpected Function App output.'
    }
    if (
        (
            Get-DeploymentOutputValue `
                -Deployment $Deployment `
                -Name 'renderContainerAppName'
        ) -cne $ExpectedContainerAppName
    ) {
        throw 'Azure returned an unexpected Container App output.'
    }

    $functionPrincipalId = Get-DeploymentOutputValue `
        -Deployment $Deployment `
        -Name 'functionPrincipalId'
    $parsedPrincipalId = [guid]::Empty
    if (-not [guid]::TryParse($functionPrincipalId, [ref] $parsedPrincipalId)) {
        throw 'Azure returned an invalid Function principal output.'
    }

    $functionHostName = Get-DeploymentOutputValue `
        -Deployment $Deployment `
        -Name 'functionAppDefaultHostName'
    if ($functionHostName -cnotmatch '^[a-z0-9.-]+$') {
        throw 'Azure returned an invalid Function hostname output.'
    }

    $renderFqdn = Get-DeploymentOutputValue `
        -Deployment $Deployment `
        -Name 'renderContainerAppFqdn'
    if ($renderFqdn -cnotmatch '^[a-z0-9.-]+$') {
        throw 'Azure returned an invalid Render hostname output.'
    }

    $renderUrl = Get-DeploymentOutputValue `
        -Deployment $Deployment `
        -Name 'renderContainerAppUrl'
    $parsedRenderUrl = [uri] $renderUrl
    if (
        $parsedRenderUrl.Scheme -cne 'https' -or
        $parsedRenderUrl.AbsolutePath -cne '/' -or
        $parsedRenderUrl.Query.Length -ne 0 -or
        $parsedRenderUrl.Fragment.Length -ne 0 -or
        $parsedRenderUrl.Host -cne $renderFqdn
    ) {
        throw 'Azure returned an invalid Render URL output.'
    }
}

$resolvedRepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
$resolvedParametersFile = Resolve-Html2bBicepParametersFile `
    -RepositoryRoot $resolvedRepositoryRoot `
    -ParametersFile $ParametersFile

if ($CurrentRef -cne 'refs/heads/main') {
    throw 'Infrastructure deployment must be dispatched from main.'
}
if ($RunLiveValidation -and $DeploymentMode -cne 'Apply') {
    throw 'Live validation can be selected only with Apply.'
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required.'
}

$runId = if (
    -not [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID) -and
    -not [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ATTEMPT)
) {
    "$($env:GITHUB_RUN_ID)-$($env:GITHUB_RUN_ATTEMPT)"
}
else {
    [guid]::NewGuid().ToString('N')
}
$outputDirectory = Join-Path `
    $resolvedRepositoryRoot `
    "build/github/infrastructure/$runId"
$null = [System.IO.Directory]::CreateDirectory($outputDirectory)
$compiledTemplatePath = Join-Path $outputDirectory 'main.json'
$compiledParametersPath = Join-Path $outputDirectory 'parameters.json'
$mainBicepPath = Join-Path $resolvedRepositoryRoot 'bicep/main.bicep'

if (-not (Test-Path -LiteralPath $mainBicepPath -PathType Leaf)) {
    throw "Bicep entry point was not found at $mainBicepPath."
}

Install-Html2bBicep -CaptureDirectory $outputDirectory
Assert-AzureContext `
    -SubscriptionId $SubscriptionId `
    -ExpectedTenantId $ExpectedTenantId `
    -CaptureDirectory $outputDirectory

$loginServer = Get-RegistryLoginServer `
    -SubscriptionId $SubscriptionId `
    -RegistryName $RegistryName `
    -CaptureDirectory $outputDirectory
$existingContainerApp = Get-RenderContainerApp `
    -SubscriptionId $SubscriptionId `
    -ResourceGroupName $ResourceGroupName `
    -ContainerAppName $ContainerAppName `
    -CaptureDirectory $outputDirectory

$resolvedImage = ''
if ($null -ne $existingContainerApp) {
    if (-not [string]::IsNullOrWhiteSpace($InitialRenderImage)) {
        throw 'An initial Render image cannot override an existing Container App.'
    }

    $resolvedImage = Get-RenderContainerImage `
        -ContainerApp $existingContainerApp `
        -ContainerName $renderContainerName
    Assert-ImmutableRenderImage `
        -Image $resolvedImage `
        -LoginServer $loginServer `
        -ImageRepository $ImageRepository
}
else {
    $resolvedImage = $InitialRenderImage.Trim()
    if ([string]::IsNullOrWhiteSpace($resolvedImage)) {
        throw 'Initial provisioning requires an immutable Render image.'
    }

    Assert-ImmutableRenderImage `
        -Image $resolvedImage `
        -LoginServer $loginServer `
        -ImageRepository $ImageRepository
    Assert-InitialImageManifest `
        -SubscriptionId $SubscriptionId `
        -RegistryName $RegistryName `
        -ImageRepository $ImageRepository `
        -Image $resolvedImage `
        -CaptureDirectory $outputDirectory
}

$hadContainerImage = Test-Path -LiteralPath Env:HTML2B_CONTAINER_IMAGE
$previousContainerImage = if ($hadContainerImage) {
    $env:HTML2B_CONTAINER_IMAGE
}
else {
    $null
}

try {
    $env:HTML2B_CONTAINER_IMAGE = $resolvedImage

    $compiledParameters = Write-CompiledBicep `
        -MainBicepPath $mainBicepPath `
        -ParametersFilePath $resolvedParametersFile `
        -CompiledTemplatePath $compiledTemplatePath `
        -CompiledParametersPath $compiledParametersPath `
        -CaptureDirectory $outputDirectory

    foreach ($contract in @(
            @{
                Name = 'environmentName'
                Value = $TargetEnvironment
            },
            @{
                Name = 'resourceGroupName'
                Value = $ResourceGroupName
            },
            @{
                Name = 'containerRegistryName'
                Value = $RegistryName
            },
            @{
                Name = 'imageRepositoryName'
                Value = $ImageRepository
            },
            @{
                Name = 'renderContainerAppName'
                Value = $ContainerAppName
            },
            @{
                Name = 'containerImage'
                Value = $resolvedImage
            }
        )) {
        Assert-CompiledParameter `
            -CompiledParameters $compiledParameters `
            -Name $contract.Name `
            -ExpectedValue $contract.Value
    }

    $location = [string] (
        Get-CompiledParameterValue `
            -CompiledParameters $compiledParameters `
            -Name 'location'
    )
    if ($location -cnotmatch '^[a-z0-9]+$') {
        throw 'Compiled Bicep location has an invalid shape.'
    }
    $expectedFunctionAppName = [string] (
        Get-CompiledParameterValue `
            -CompiledParameters $compiledParameters `
            -Name 'functionAppName'
    )
    if ([string]::IsNullOrWhiteSpace($expectedFunctionAppName)) {
        throw 'Compiled Bicep Function App name is empty.'
    }

    $deploymentName = 'html2b-{0}-infra-{1}' -f (
        $TargetEnvironment),
        ([DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmss'))

    Write-Host "Environment: $TargetEnvironment"
    Write-Host "Parameters file: $ParametersFile"
    Write-Host "Deployment mode: $DeploymentMode"
    Write-Host "Deployment name: $deploymentName"

    $validationArguments = New-DeploymentArguments `
        -Verb 'validate' `
        -SubscriptionId $SubscriptionId `
        -DeploymentName $deploymentName `
        -Location $location `
        -CompiledTemplatePath $compiledTemplatePath `
        -CompiledParametersPath $compiledParametersPath
    $validationArguments += @('--validation-level', 'Provider')
    $validationJson = Invoke-AzureCli `
        -Arguments $validationArguments `
        -Operation 'Subscription deployment validation' `
        -CaptureDirectory $outputDirectory
    $validation = ConvertFrom-AzureJson `
        -Json $validationJson `
        -Operation 'Subscription deployment validation'
    Assert-DeploymentSucceeded `
        -Deployment $validation `
        -Operation 'Subscription deployment validation'

    $whatIfArguments = New-DeploymentArguments `
        -Verb 'what-if' `
        -SubscriptionId $SubscriptionId `
        -DeploymentName $deploymentName `
        -Location $location `
        -CompiledTemplatePath $compiledTemplatePath `
        -CompiledParametersPath $compiledParametersPath
    $whatIfArguments += @(
        '--result-format', 'ResourceIdOnly',
        '--no-pretty-print'
    )
    $whatIfJson = Invoke-AzureCli `
        -Arguments $whatIfArguments `
        -Operation 'Subscription deployment What-If' `
        -CaptureDirectory $outputDirectory
    $whatIf = ConvertFrom-AzureJson `
        -Json $whatIfJson `
        -Operation 'Subscription deployment What-If'
    Assert-WhatIfAllowsApply -WhatIf $whatIf

    if ($DeploymentMode -ceq 'WhatIf') {
        Write-Host 'What-If completed; no infrastructure Apply was requested.'
    }
    else {
        $deploymentArguments = New-DeploymentArguments `
            -Verb 'create' `
            -SubscriptionId $SubscriptionId `
            -DeploymentName $deploymentName `
            -Location $location `
            -CompiledTemplatePath $compiledTemplatePath `
            -CompiledParametersPath $compiledParametersPath
        $deploymentJson = Invoke-AzureCli `
            -Arguments $deploymentArguments `
            -Operation 'Subscription deployment Apply' `
            -CaptureDirectory $outputDirectory
        $deployment = ConvertFrom-AzureJson `
            -Json $deploymentJson `
            -Operation 'Subscription deployment Apply'
        Assert-DeploymentSucceeded `
            -Deployment $deployment `
            -Operation 'Subscription deployment Apply'
        Assert-DeploymentOutputs `
            -Deployment $deployment `
            -ExpectedResourceGroupName $ResourceGroupName `
            -ExpectedFunctionAppName $expectedFunctionAppName `
            -ExpectedContainerAppName $ContainerAppName

        $appliedContainerApp = Get-RenderContainerApp `
            -SubscriptionId $SubscriptionId `
            -ResourceGroupName $ResourceGroupName `
            -ContainerAppName $ContainerAppName `
            -CaptureDirectory $outputDirectory
        if ($null -eq $appliedContainerApp) {
            throw 'The Render Container App was absent after Apply.'
        }
        if (
            [string] $appliedContainerApp.properties.provisioningState -cne
                'Succeeded'
        ) {
            throw 'The Render Container App did not reach a succeeded state.'
        }

        $appliedImage = Get-RenderContainerImage `
            -ContainerApp $appliedContainerApp `
            -ContainerName $renderContainerName
        if ($appliedImage -cne $resolvedImage) {
            throw 'Apply did not preserve the selected immutable Render image.'
        }

        Write-Host 'Infrastructure Apply and Render image readback succeeded.'
    }

    if (-not [string]::IsNullOrWhiteSpace($GitHubOutputPath)) {
        [System.IO.File]::AppendAllText(
            $GitHubOutputPath,
            "render_image=$resolvedImage`n",
            $utf8NoBom
        )
    }
}
finally {
    if ($hadContainerImage) {
        $env:HTML2B_CONTAINER_IMAGE = $previousContainerImage
    }
    else {
        Remove-Item `
            -LiteralPath Env:HTML2B_CONTAINER_IMAGE `
            -ErrorAction SilentlyContinue
    }
}
