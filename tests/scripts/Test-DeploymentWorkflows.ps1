[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$applicationWorkflowPath = Join-Path `
    $repositoryRoot `
    '.github\workflows\daploy-azure.yml'
$infrastructureWorkflowPath = Join-Path `
    $repositoryRoot `
    '.github\workflows\deploy-azure-infrastructure.yml'

function Assert-Condition {
    param(
        [Parameter(Mandatory)]
        [bool] $Condition,

        [Parameter(Mandatory)]
        [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$applicationWorkflow = Get-Content -LiteralPath $applicationWorkflowPath -Raw
$infrastructureWorkflow = Get-Content `
    -LiteralPath $infrastructureWorkflowPath `
    -Raw

Assert-Condition `
    -Condition ($applicationWorkflow -match '(?m)^\s{2}push:\r?\n\s{4}branches:\r?\n\s{6}- main\r?$') `
    -Message 'Application workflow no longer automatically deploys main.'
Assert-Condition `
    -Condition ($applicationWorkflow -match '(?m)^\s{2}workflow_dispatch:\r?$') `
    -Message 'Application workflow no longer supports manual dispatch.'
Assert-Condition `
    -Condition ($applicationWorkflow -match [regex]::Escape(
        "github.event_name == 'push' && 'dev' || inputs.target_environment")) `
    -Message 'Application workflow target selection drifted.'

$expectedApplicationPaths = @(
    'src/api/**'
    '.dockerignore'
    '.github/workflows/daploy-azure.yml'
)
foreach ($path in $expectedApplicationPaths) {
    $escapedPath = [regex]::Escape($path)
    Assert-Condition `
        -Condition ($applicationWorkflow -match "(?m)^\s+- $escapedPath\r?$") `
        -Message "Application workflow is missing '$path' from its trigger allowlist."
}

$validatorTerms = @(
    'Test-AzureDev'
    'Html2b.AzureDevValidation'
    'Html2b.AzureStateValidation'
    'Html2b.HttpValidation'
    'Html2b.TelemetryEvidence'
    'validation-summary'
    'RunLiveValidation'
    'application-insights'
    'actions/upload-artifact'
)
foreach ($term in $validatorTerms) {
    Assert-Condition `
        -Condition (-not $applicationWorkflow.Contains($term)) `
        -Message "Application workflow retains removed validation term '$term'."
    Assert-Condition `
        -Condition (-not $infrastructureWorkflow.Contains($term)) `
        -Message "Infrastructure workflow retains removed validation term '$term'."
}

foreach ($action in @(
        'actions/checkout@v7.0.1',
        'Azure/login@v3.0.0')) {
    Assert-Condition `
        -Condition ($applicationWorkflow.Contains($action) -and
            $infrastructureWorkflow.Contains($action)) `
        -Message "Deployment workflow action reference drifted: $action"
}
Assert-Condition `
    -Condition ($applicationWorkflow.Contains('actions/setup-dotnet@v6.0.0') -and
        $applicationWorkflow.Contains('Azure/functions-action@v1.5.6')) `
    -Message 'Application workflow action references drifted.'
Assert-Condition `
    -Condition ($applicationWorkflow.Contains(
        'src/api/Html2b.AzureFunctions/Html2b.AzureFunctions.csproj') -and
        $applicationWorkflow.Contains('--output build/release/functions') -and
        $applicationWorkflow.Contains('/p:UseAppHost=false')) `
    -Message 'Application workflow no longer builds the expected Functions package.'
Assert-Condition `
    -Condition (-not $applicationWorkflow.Contains(
        'Publish-Html2bFunctions.ps1')) `
    -Message 'Application workflow retains the retired Functions publish script.'
Assert-Condition `
    -Condition ($applicationWorkflow.Contains('az acr build') -and
        $applicationWorkflow.Contains('az acr repository show') -and
        $applicationWorkflow.Contains('--query digest') -and
        $applicationWorkflow.Contains('az containerapp update')) `
    -Message 'Application workflow no longer deploys Render through a digest-qualified image.'
foreach ($term in @(
        'Publish-Html2bRender.ps1',
        'Update-Html2bRender.ps1',
        'render-image',
        'latestReadyRevisionName',
        'ReadinessTimeoutSeconds')) {
    Assert-Condition `
        -Condition (-not $applicationWorkflow.Contains($term)) `
        -Message "Application workflow retains removed Render deployment term '$term'."
}

Assert-Condition `
    -Condition (-not $applicationWorkflow.Contains('pull_request:')) `
    -Message 'Application workflow must not add a pull request trigger.'
Assert-Condition `
    -Condition ($applicationWorkflow.Contains('queue: max') -and
        $infrastructureWorkflow.Contains('queue: max')) `
    -Message 'Deployment workflows must retain non-cancelling queues.'

Assert-Condition `
    -Condition (-not $infrastructureWorkflow.Contains('run_live_validation')) `
    -Message 'Infrastructure workflow retains the removed live-validation input.'
Assert-Condition `
    -Condition ($infrastructureWorkflow.Contains('render_image:') -and
        $infrastructureWorkflow.Contains('required: true') -and
        $infrastructureWorkflow.Contains('HTML2B_CONTAINER_IMAGE')) `
    -Message 'Infrastructure workflow no longer requires an explicit Render image.'
Assert-Condition `
    -Condition ($infrastructureWorkflow.Contains('az bicep build-params') -and
        $infrastructureWorkflow.Contains('az @deploymentArguments') -and
        $infrastructureWorkflow.Contains('az @applyArguments')) `
    -Message 'Infrastructure workflow no longer compiles and deploys Bicep directly.'
Assert-Condition `
    -Condition ($infrastructureWorkflow.Contains("changeType -ceq 'Delete'") -and
        $infrastructureWorkflow.Contains('Apply is blocked.')) `
    -Message 'Infrastructure workflow no longer blocks Apply after a destructive What-If.'
foreach ($term in @(
        'Build-Html2bBicep.ps1',
        'initial_render_image',
        'deployment sub validate',
        'Container App inventory',
        'render_image=$resolvedImage')) {
    Assert-Condition `
        -Condition (-not $infrastructureWorkflow.Contains($term)) `
        -Message "Infrastructure workflow retains removed deployment term '$term'."
}

$deletedValidatorFiles = @(
    'scripts/azure/Test-AzureDev.ps1'
    'scripts/azure/Html2b.AzureDevValidation.psm1'
    'scripts/azure/Html2b.AzureStateValidation.psm1'
    'scripts/azure/Html2b.HttpValidation.psm1'
    'scripts/azure/Html2b.TelemetryEvidence.psm1'
    'tests/scripts/Test-AzureDevValidation.ps1'
)
foreach ($relativePath in $deletedValidatorFiles) {
    Assert-Condition `
        -Condition (-not (Test-Path (Join-Path $repositoryRoot $relativePath))) `
        -Message "Removed validator file still exists: $relativePath"
}

foreach ($relativePath in @(
        'scripts/github/Publish-Html2bRender.ps1',
        'scripts/github/Update-Html2bRender.ps1',
        'scripts/github/Build-Html2bBicep.ps1')) {
    Assert-Condition `
        -Condition (-not (Test-Path (Join-Path $repositoryRoot $relativePath))) `
        -Message "Removed Render deployment script still exists: $relativePath"
}

Write-Host 'Deployment workflow contracts passed.'
