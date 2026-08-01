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
$infrastructureScriptPath = Join-Path `
    $repositoryRoot `
    'scripts\github\Build-Html2bBicep.ps1'

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
$infrastructureScript = Get-Content `
    -LiteralPath $infrastructureScriptPath `
    -Raw

Assert-Condition `
    -Condition ($applicationWorkflow -match '(?m)^\s{2}push:\r?\n\s{4}branches:\r?\n\s{6}- main$') `
    -Message 'Application workflow no longer automatically deploys main.'
Assert-Condition `
    -Condition ($applicationWorkflow -match '(?m)^\s{2}workflow_dispatch:$') `
    -Message 'Application workflow no longer supports manual dispatch.'
Assert-Condition `
    -Condition ($applicationWorkflow -match [regex]::Escape(
        "github.event_name == 'push' && 'dev' || inputs.target_environment")) `
    -Message 'Application workflow target selection drifted.'

$expectedApplicationPaths = @(
    'src/api/**'
    '.dockerignore'
    'scripts/github/Resolve-Html2bDeploymentSource.ps1'
    'scripts/github/Publish-Html2bFunctions.ps1'
    'scripts/github/Publish-Html2bRender.ps1'
    'scripts/github/Update-Html2bRender.ps1'
    '.github/workflows/daploy-azure.yml'
)
foreach ($path in $expectedApplicationPaths) {
    $escapedPath = [regex]::Escape($path)
    Assert-Condition `
        -Condition (($applicationWorkflow -match "(?m)^\s+- $escapedPath$") -and
            ($applicationWorkflow -match "(?m)^\s+'$escapedPath'$")) `
        -Message "Application workflow is missing '$path' from a trigger or guard allowlist."
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
    Assert-Condition `
        -Condition (-not $infrastructureScript.Contains($term)) `
        -Message "Infrastructure deployment script retains removed validation term '$term'."
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
    -Condition (-not $applicationWorkflow.Contains('pull_request:')) `
    -Message 'Application workflow must not add a pull request trigger.'
Assert-Condition `
    -Condition ($applicationWorkflow.Contains('queue: max') -and
        $infrastructureWorkflow.Contains('queue: max')) `
    -Message 'Deployment workflows must retain non-cancelling queues.'

$mixedGuardIndex = $applicationWorkflow.IndexOf(
    '- name: Block mixed application and Bicep changes',
    [StringComparison]::Ordinal)
$azureLoginIndex = $applicationWorkflow.IndexOf(
    '- name: Log in to Azure',
    [StringComparison]::Ordinal)
Assert-Condition `
    -Condition ($mixedGuardIndex -ge 0 -and $azureLoginIndex -gt $mixedGuardIndex) `
    -Message 'Mixed application/Bicep guard must run before Azure login.'
Assert-Condition `
    -Condition ($applicationWorkflow.Contains(
        'Automatic application deployment stopped because this push also changes ')) `
    -Message 'Mixed application/Bicep guard must remain fail-closed.'

Assert-Condition `
    -Condition (-not $infrastructureWorkflow.Contains('run_live_validation')) `
    -Message 'Infrastructure workflow retains the removed live-validation input.'

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

Write-Host 'Deployment workflow contracts passed.'
