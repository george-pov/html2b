[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$applicationWorkflowPath = Join-Path `
    $repositoryRoot `
    '.github\workflows\daploy-azure.yml'
$renderYamlPath = Join-Path `
    $repositoryRoot `
    'deployment\azure\render-app.yaml'

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
$renderYaml = Get-Content -LiteralPath $renderYamlPath -Raw

Assert-Condition `
    -Condition (-not (Test-Path (Join-Path `
        $repositoryRoot '.github\workflows\deploy-azure-infrastructure.yml'))) `
    -Message 'The retired infrastructure workflow still exists.'
Assert-Condition `
    -Condition ($applicationWorkflow -match `
        '(?m)^\s{2}push:\r?\n\s{4}branches:\r?\n\s{6}- main\r?$') `
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
    'deployment/azure/render-app.yaml'
)
foreach ($path in $expectedApplicationPaths) {
    Assert-Condition `
        -Condition ($applicationWorkflow -match `
            "(?m)^\s+- $([regex]::Escape($path))\r?$") `
        -Message "Application workflow is missing '$path' from push.paths."
}

foreach ($action in @(
        'actions/checkout@v7.0.1'
        'actions/setup-dotnet@v6.0.0'
        'Azure/login@v3.0.0'
        'Azure/functions-action@v1.5.6')) {
    Assert-Condition `
        -Condition $applicationWorkflow.Contains($action) `
        -Message "Application workflow action reference drifted: $action"
}
Assert-Condition `
    -Condition ($applicationWorkflow.Contains('queue: max') -and
        $applicationWorkflow.Contains(
            'src/api/Html2b.AzureFunctions/Html2b.AzureFunctions.csproj') -and
        $applicationWorkflow.Contains('--output build/release/functions')) `
    -Message 'Application workflow lost queue or direct Functions publish behavior.'

foreach ($term in @(
        'az bicep'
        'deployment sub'
        'deploy-infrastructure'
        'Set-GitHubIdentity'
        'gh variable'
        'az login'
        'workflow run'
        'Test-AzureDev'
        'actions/upload-artifact'
        'pull_request:')) {
    Assert-Condition `
        -Condition (-not $applicationWorkflow.Contains($term)) `
        -Message "Application workflow contains forbidden term '$term'."
}

$buildAt = $applicationWorkflow.IndexOf('az acr build')
$digestAt = $applicationWorkflow.IndexOf('az acr repository show')
$yamlAt = $applicationWorkflow.IndexOf('$yamlTemplate')
$updateAt = $applicationWorkflow.IndexOf('az containerapp update')
$functionsAt = $applicationWorkflow.IndexOf('- name: Deploy Functions')
Assert-Condition `
    -Condition (0 -le $buildAt -and $buildAt -lt $digestAt -and
        $digestAt -lt $yamlAt -and $yamlAt -lt $updateAt -and
        $updateAt -lt $functionsAt) `
    -Message 'Build, digest, YAML, Container App, and Functions order drifted.'
Assert-Condition `
    -Condition ([regex]::Matches(
        $applicationWorkflow, 'az containerapp update').Count -eq 1) `
    -Message 'Application workflow must contain one Container App update.'
Assert-Condition `
    -Condition ($applicationWorkflow.Contains('--yaml $yamlPath') -and
        -not $applicationWorkflow.Contains('--container-name html2b-render') -and
        $applicationWorkflow.Contains('$env:RUNNER_TEMP') -and
        -not $applicationWorkflow.Contains(
            'WriteAllText($yamlTemplate')) `
    -Message 'Application workflow must apply only runner-local YAML.'
Assert-Condition `
    -Condition ($applicationWorkflow.Contains(
        "@sha256:[a-f0-9]{{64}}$") -and
        $applicationWorkflow.Contains('AZURE_RENDER_IDENTITY_NAME') -and
        $applicationWorkflow.Contains('az identity show')) `
    -Message 'Digest or Render identity resolution is incomplete.'

foreach ($token in @(
        '__RENDER_IMAGE__'
        '__RENDER_ID__'
        '__ACR_SERVER__')) {
    Assert-Condition `
        -Condition ([regex]::Matches(
            $renderYaml, [regex]::Escape($token)).Count -eq 1) `
        -Message "Render YAML must contain '$token' exactly once."
    Assert-Condition `
        -Condition $applicationWorkflow.Contains("'$token'") `
        -Message "Application workflow does not replace '$token'."
}

$yamlTerms = @(
    'type: UserAssigned'
    'userAssignedIdentities:'
    'activeRevisionsMode: Single'
    'maxInactiveRevisions: 100'
    'lifecycle: None'
    'external: true'
    'allowInsecure: false'
    'targetPort: 8080'
    'transport: auto'
    'latestRevision: true'
    'weight: 100'
    'name: html2b-render'
    'cpu: 1'
    'memory: 2Gi'
    'type: Liveness'
    'path: /health/live'
    'type: Readiness'
    'type: Startup'
    'path: /health/ready'
    'minReplicas: 0'
    'maxReplicas: 1'
    'pollingInterval: 30'
    'cooldownPeriod: 300'
    'name: http-one-render'
    "concurrentRequests: '1'"
    'terminationGracePeriodSeconds: 30'
)
foreach ($term in $yamlTerms) {
    Assert-Condition `
        -Condition $renderYaml.Contains($term) `
        -Message "Render YAML is missing contract term '$term'."
}
Assert-Condition `
    -Condition (-not $renderYaml.Contains('authConfigs') -and
        $renderYaml -notmatch `
            '(?i)(password|client.?secret|connection.?string|shared.?key)\s*:') `
    -Message 'Render YAML contains auth ownership or credential-shaped data.'

$removedRepositoryFiles = @(
    'scripts/azure/Deploy-AzureDev.ps1'
    'scripts/azure/Html2b.OutputContracts.psm1'
    'scripts/azure/Publish-Html2bImage.ps1'
    'scripts/azure/Test-AzureDev.ps1'
    'scripts/azure/Html2b.AzureDevValidation.psm1'
    'scripts/azure/Html2b.AzureStateValidation.psm1'
    'scripts/azure/Html2b.HttpValidation.psm1'
    'scripts/azure/Html2b.TelemetryEvidence.psm1'
    'scripts/github/Build-Html2bBicep.ps1'
    'scripts/github/Publish-Html2bRender.ps1'
    'scripts/github/Update-Html2bRender.ps1'
    'tests/scripts/Test-AzureDevValidation.ps1'
)
foreach ($relativePath in $removedRepositoryFiles) {
    Assert-Condition `
        -Condition (-not (Test-Path (Join-Path $repositoryRoot $relativePath))) `
        -Message "Removed repository file still exists: $relativePath"
}

Write-Host 'Deployment workflow contracts passed.'
