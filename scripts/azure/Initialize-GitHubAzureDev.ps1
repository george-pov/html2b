[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Plan', 'Apply', 'Verify')]
    [string] $Operation,

    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string] $Repository = 'george-pov/html2b',

    [ValidatePattern('^[A-Za-z0-9_.-]+$')]
    [string] $EnvironmentName = 'dev',

    [ValidatePattern('^[A-Za-z0-9-]+$')]
    [string] $InfrastructureIdentityName = 'id-html2b-infrastructure-dev'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resourceGroupName = 'rg-html2b-dev'
$rulesetName = 'Protect main'
$federatedCredentialName = 'github-environment-dev'
$oidcIssuer = 'https://token.actions.githubusercontent.com'
$oidcAudience = 'api://AzureADTokenExchange'
$oidcSubject = 'repo:george-pov/html2b:environment:dev'
$contributorRoleId = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
$rbacAdministratorRoleId = 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'
$githubVariableNames = @(
    'AZURE_INFRA_CLIENT_ID',
    'AZURE_TENANT_ID',
    'AZURE_SUBSCRIPTION_ID'
)

function Resolve-RepositoryRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Invoke-AzureCli {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $AllowFailure
    )

    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        if ($AllowFailure) {
            return $null
        }
        throw "Azure CLI operation failed with exit code $exitCode. Output was suppressed."
    }
    return ($output | Out-String).Trim()
}

function Invoke-GitHubCli {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $AllowFailure
    )

    $output = & gh @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        if ($AllowFailure) {
            return $null
        }
        throw "GitHub CLI operation failed with exit code $exitCode. Output was suppressed."
    }
    return ($output | Out-String).Trim()
}

function Invoke-GitHubApiJson {
    param(
        [Parameter(Mandatory)][ValidateSet('POST', 'PUT', 'PATCH')][string] $Method,
        [Parameter(Mandatory)][string] $Endpoint,
        [Parameter(Mandatory)][object] $Body
    )

    $repositoryRoot = Resolve-RepositoryRoot
    $requestDirectory = Join-Path $repositoryRoot 'build/validation/004/p01/bootstrap/requests'
    $null = New-Item -ItemType Directory -Force -Path $requestDirectory
    $requestPath = Join-Path $requestDirectory "$([guid]::NewGuid().ToString('N')).json"
    try {
        [System.IO.File]::WriteAllText(
            $requestPath,
            ($Body | ConvertTo-Json -Depth 30 -Compress),
            [System.Text.UTF8Encoding]::new($false))
        return Invoke-GitHubCli -Arguments @(
            'api', '--method', $Method,
            $Endpoint,
            '--input', $requestPath
        )
    }
    finally {
        if (Test-Path -LiteralPath $requestPath) {
            Remove-Item -LiteralPath $requestPath -Force
        }
    }
}

function Get-GitHubRepositoryState {
    $repositoryState = Invoke-GitHubCli -Arguments @(
        'repo', 'view', $Repository,
        '--json', 'nameWithOwner,visibility,defaultBranchRef'
    ) | ConvertFrom-Json
    if ($repositoryState.nameWithOwner -ne $Repository -or
        $repositoryState.visibility -ne 'PUBLIC' -or
        $repositoryState.defaultBranchRef.name -ne 'main') {
        throw 'GitHub repository visibility or default branch differs from the approved baseline.'
    }

    $rulesets = @(Invoke-GitHubCli -Arguments @(
            'api', "repos/$Repository/rulesets"
        ) | ConvertFrom-Json)
    $ruleset = @($rulesets | Where-Object name -eq $rulesetName)
    if ($ruleset.Count -gt 1) {
        throw "Multiple GitHub rulesets are named '$rulesetName'."
    }

    $environmentJson = Invoke-GitHubCli -AllowFailure -Arguments @(
        'api', "repos/$Repository/environments/$EnvironmentName"
    )
    $environment = if ([string]::IsNullOrWhiteSpace($environmentJson)) {
        $null
    }
    else {
        $environmentJson | ConvertFrom-Json
    }

    $branchPoliciesJson = if ($null -eq $environment) {
        $null
    }
    else {
        Invoke-GitHubCli -AllowFailure -Arguments @(
            'api', "repos/$Repository/environments/$EnvironmentName/deployment-branch-policies"
        )
    }
    $branchPolicies = if ([string]::IsNullOrWhiteSpace($branchPoliciesJson)) {
        @()
    }
    else {
        @((($branchPoliciesJson | ConvertFrom-Json).branch_policies))
    }

    $variables = @{}
    foreach ($name in $githubVariableNames) {
        $variableJson = Invoke-GitHubCli -AllowFailure -Arguments @(
            'api', "repos/$Repository/environments/$EnvironmentName/variables/$name"
        )
        if (-not [string]::IsNullOrWhiteSpace($variableJson)) {
            $variable = $variableJson | ConvertFrom-Json
            $variables[$name] = [string] $variable.value
        }
    }

    return [pscustomobject]@{
        Ruleset = if ($ruleset.Count -eq 1) { $ruleset[0] } else { $null }
        Environment = $environment
        BranchPolicies = $branchPolicies
        Variables = $variables
    }
}

function Get-GitHubOidcSubjectState {
    $customization = Invoke-GitHubCli -Arguments @(
        'api', "repos/$Repository/actions/oidc/customization/sub"
    ) | ConvertFrom-Json

    return [pscustomobject]@{
        UsesDefaultSubject = [bool] $customization.use_default
        ExpectedSubject = $oidcSubject
    }
}

function Assert-ExpectedOidcSubject {
    param([Parameter(Mandatory)][pscustomobject] $State)
    if (-not $State.UsesDefaultSubject -or $State.ExpectedSubject -ne $oidcSubject) {
        throw 'GitHub OIDC subject configuration differs from the approved environment subject.'
    }
}

function Get-AzureBootstrapState {
    $account = Invoke-AzureCli -Arguments @(
        'account', 'show',
        '--query', '{id:id,tenantId:tenantId,name:name,state:state}',
        '--output', 'json'
    ) | ConvertFrom-Json
    if ($account.state -ne 'Enabled') {
        throw 'The selected Azure subscription is not enabled.'
    }

    $identityJson = Invoke-AzureCli -AllowFailure -Arguments @(
        'identity', 'show',
        '--resource-group', $resourceGroupName,
        '--name', $InfrastructureIdentityName,
        '--output', 'json'
    )
    $identity = if ([string]::IsNullOrWhiteSpace($identityJson)) {
        $null
    }
    else {
        $identityJson | ConvertFrom-Json
    }

    $federatedCredentialJson = if ($null -eq $identity) {
        $null
    }
    else {
        Invoke-AzureCli -AllowFailure -Arguments @(
            'identity', 'federated-credential', 'show',
            '--resource-group', $resourceGroupName,
            '--identity-name', $InfrastructureIdentityName,
            '--name', $federatedCredentialName,
            '--output', 'json'
        )
    }
    $federatedCredential = if ([string]::IsNullOrWhiteSpace($federatedCredentialJson)) {
        $null
    }
    else {
        $federatedCredentialJson | ConvertFrom-Json
    }

    $roleAssignments = if ($null -eq $identity) {
        @()
    }
    else {
        @((Invoke-AzureCli -Arguments @(
                    'role', 'assignment', 'list',
                    '--assignee-object-id', $identity.principalId,
                    '--scope', "/subscriptions/$($account.id)",
                    '--query', '[].{roleDefinitionId:roleDefinitionId,scope:scope}',
                    '--output', 'json'
                ) | ConvertFrom-Json))
    }

    return [pscustomobject]@{
        Subscription = $account
        Identity = $identity
        FederatedCredential = $federatedCredential
        RoleAssignments = $roleAssignments
    }
}

function Assert-NoUnexpectedExistingState {
    param(
        [Parameter(Mandatory)][pscustomobject] $GitHubState,
        [Parameter(Mandatory)][pscustomobject] $AzureState
    )

    if ($null -ne $GitHubState.Ruleset) {
        $details = Invoke-GitHubCli -Arguments @(
            'api', "repos/$Repository/rulesets/$($GitHubState.Ruleset.id)"
        ) | ConvertFrom-Json
        $ruleTypes = @($details.rules.type)
        $requiredContext = @($details.rules | Where-Object type -eq 'required_status_checks').parameters.required_status_checks.context
        if ($details.enforcement -ne 'active' -or
            $details.target -ne 'branch' -or
            $ruleTypes -notcontains 'deletion' -or
            $ruleTypes -notcontains 'non_fast_forward' -or
            $ruleTypes -notcontains 'pull_request' -or
            $ruleTypes -notcontains 'required_status_checks' -or
            $requiredContext -notcontains 'Repository validation') {
            throw "Existing ruleset '$rulesetName' differs from the approved contract."
        }
    }

    if ($null -ne $GitHubState.Environment) {
        $policy = $GitHubState.Environment.deployment_branch_policy
        $policyNames = @($GitHubState.BranchPolicies.name)
        $protectionRuleTypes = @($GitHubState.Environment.protection_rules.type)
        if ($policy.protected_branches -ne $false -or
            $policy.custom_branch_policies -ne $true -or
            $policyNames.Count -ne 1 -or
            $policyNames[0] -ne 'main' -or
            $protectionRuleTypes.Count -ne 1 -or
            $protectionRuleTypes[0] -ne 'branch_policy') {
            throw "Existing Environment '$EnvironmentName' differs from the approved contract."
        }
    }

    if ($null -ne $AzureState.Identity) {
        if ($AzureState.Identity.name -ne $InfrastructureIdentityName -or
            $AzureState.Identity.resourceGroup -ne $resourceGroupName -or
            $AzureState.Identity.location -replace '\s', '' -ine 'westus2') {
            throw "Existing identity '$InfrastructureIdentityName' differs from the approved target."
        }
    }

    if ($null -ne $AzureState.FederatedCredential) {
        if ($AzureState.FederatedCredential.issuer -ne $oidcIssuer -or
            $AzureState.FederatedCredential.subject -ne $oidcSubject -or
            @($AzureState.FederatedCredential.audiences).Count -ne 1 -or
            @($AzureState.FederatedCredential.audiences)[0] -ne $oidcAudience) {
            throw 'Existing infrastructure federated credential differs from the approved trust.'
        }
    }

    if ($null -ne $AzureState.Identity) {
        $expectedRoleSuffixes = @($contributorRoleId, $rbacAdministratorRoleId)
        $subscriptionScope = "/subscriptions/$($AzureState.Subscription.id)"
        $directAssignments = @($AzureState.RoleAssignments | Where-Object scope -ieq $subscriptionScope)
        foreach ($assignment in $directAssignments) {
            $roleId = ([string] $assignment.roleDefinitionId -split '/')[-1]
            if ($roleId -notin $expectedRoleSuffixes) {
                throw "Infrastructure identity has unexpected subscription role '$roleId'."
            }
        }
    }

    $expectedVariables = if ($null -eq $AzureState.Identity) {
        @{}
    }
    else {
        @{
            AZURE_INFRA_CLIENT_ID = [string] $AzureState.Identity.clientId
            AZURE_TENANT_ID = [string] $AzureState.Subscription.tenantId
            AZURE_SUBSCRIPTION_ID = [string] $AzureState.Subscription.id
        }
    }
    foreach ($name in @($GitHubState.Variables.Keys)) {
        if (-not $expectedVariables.ContainsKey($name) -or
            $GitHubState.Variables[$name] -ne $expectedVariables[$name]) {
            throw "Existing GitHub Environment variable '$name' differs from the selected Azure state."
        }
    }
}

function Set-MainRuleset {
    param([Parameter(Mandatory)][pscustomobject] $GitHubState)
    if ($null -ne $GitHubState.Ruleset) {
        return
    }

    if ($PSCmdlet.ShouldProcess("$Repository ruleset '$rulesetName'", 'Create exact main branch ruleset')) {
        $body = [ordered]@{
            name = $rulesetName
            target = 'branch'
            enforcement = 'active'
            bypass_actors = @()
            conditions = @{
                ref_name = @{
                    include = @('~DEFAULT_BRANCH')
                    exclude = @()
                }
            }
            rules = @(
                @{ type = 'deletion' },
                @{ type = 'non_fast_forward' },
                @{
                    type = 'pull_request'
                    parameters = @{
                        dismiss_stale_reviews_on_push = $false
                        require_code_owner_review = $false
                        require_last_push_approval = $false
                        required_approving_review_count = 0
                        required_review_thread_resolution = $false
                    }
                },
                @{
                    type = 'required_status_checks'
                    parameters = @{
                        strict_required_status_checks_policy = $true
                        do_not_enforce_on_create = $false
                        required_status_checks = @(
                            @{ context = 'Repository validation' }
                        )
                    }
                }
            )
        }
        $null = Invoke-GitHubApiJson -Method POST -Endpoint "repos/$Repository/rulesets" -Body $body
    }
}

function Set-DevEnvironment {
    param([Parameter(Mandatory)][pscustomobject] $GitHubState)
    if ($null -ne $GitHubState.Environment) {
        return
    }

    if ($PSCmdlet.ShouldProcess("$Repository Environment '$EnvironmentName'", 'Create exact main-only deployment Environment')) {
        $body = [ordered]@{
            wait_timer = 0
            prevent_self_review = $false
            reviewers = @()
            deployment_branch_policy = @{
                protected_branches = $false
                custom_branch_policies = $true
            }
        }
        $null = Invoke-GitHubApiJson -Method PUT -Endpoint "repos/$Repository/environments/$EnvironmentName" -Body $body
        $null = Invoke-GitHubApiJson `
            -Method POST `
            -Endpoint "repos/$Repository/environments/$EnvironmentName/deployment-branch-policies" `
            -Body @{ name = 'main'; type = 'branch' }
    }
}

function Set-InfrastructureIdentity {
    param([Parameter(Mandatory)][pscustomobject] $AzureState)
    if ($null -ne $AzureState.Identity) {
        return
    }

    if ($PSCmdlet.ShouldProcess("$resourceGroupName/$InfrastructureIdentityName", 'Create infrastructure deployment identity')) {
        $null = Invoke-AzureCli -Arguments @(
            'identity', 'create',
            '--resource-group', $resourceGroupName,
            '--name', $InfrastructureIdentityName,
            '--location', 'westus2',
            '--tags',
            'Application=Html2B',
            'Environment=dev',
            'Region=westus2',
            'ManagedBy=Bootstrap',
            'Repository=george-pov/html2b',
            'Component=Deployment',
            '--output', 'none'
        )
    }
}

function Set-InfrastructureFederatedCredential {
    param([Parameter(Mandatory)][pscustomobject] $AzureState)
    if ($null -ne $AzureState.FederatedCredential) {
        return
    }

    if ($PSCmdlet.ShouldProcess("$InfrastructureIdentityName/$federatedCredentialName", 'Create exact GitHub Environment federated credential')) {
        $null = Invoke-AzureCli -Arguments @(
            'identity', 'federated-credential', 'create',
            '--resource-group', $resourceGroupName,
            '--identity-name', $InfrastructureIdentityName,
            '--name', $federatedCredentialName,
            '--issuer', $oidcIssuer,
            '--subject', $oidcSubject,
            '--audiences', $oidcAudience,
            '--output', 'none'
        )
    }
}

function Set-InfrastructureRoleAssignments {
    param([Parameter(Mandatory)][pscustomobject] $AzureState)
    $identity = $AzureState.Identity
    if ($null -eq $identity) {
        throw 'Infrastructure identity must exist before assigning roles.'
    }
    $subscriptionScope = "/subscriptions/$($AzureState.Subscription.id)"
    $existingRoleIds = @($AzureState.RoleAssignments | Where-Object scope -ieq $subscriptionScope | ForEach-Object {
            ([string] $_.roleDefinitionId -split '/')[-1]
        })

    foreach ($roleId in @($contributorRoleId, $rbacAdministratorRoleId)) {
        if ($existingRoleIds -contains $roleId) {
            continue
        }
        if ($PSCmdlet.ShouldProcess("$InfrastructureIdentityName at subscription scope", "Assign role $roleId")) {
            $null = Invoke-AzureCli -Arguments @(
                'role', 'assignment', 'create',
                '--assignee-object-id', $identity.principalId,
                '--assignee-principal-type', 'ServicePrincipal',
                '--role', $roleId,
                '--scope', $subscriptionScope,
                '--output', 'none'
            )
        }
    }
}

function Set-GitHubEnvironmentVariables {
    param(
        [Parameter(Mandatory)][pscustomobject] $GitHubState,
        [Parameter(Mandatory)][pscustomobject] $AzureState
    )
    $values = @{
        AZURE_INFRA_CLIENT_ID = [string] $AzureState.Identity.clientId
        AZURE_TENANT_ID = [string] $AzureState.Subscription.tenantId
        AZURE_SUBSCRIPTION_ID = [string] $AzureState.Subscription.id
    }
    foreach ($name in $githubVariableNames) {
        if ($GitHubState.Variables.ContainsKey($name)) {
            continue
        }
        if ($PSCmdlet.ShouldProcess("$Repository Environment '$EnvironmentName' variable '$name'", 'Create public Azure identifier variable')) {
            $null = Invoke-GitHubApiJson `
                -Method POST `
                -Endpoint "repos/$Repository/environments/$EnvironmentName/variables" `
                -Body @{ name = $name; value = $values[$name] }
        }
    }
}

function Test-BootstrapState {
    param(
        [Parameter(Mandatory)][pscustomobject] $GitHubState,
        [Parameter(Mandatory)][pscustomobject] $AzureState,
        [switch] $RequireComplete
    )

    Assert-NoUnexpectedExistingState -GitHubState $GitHubState -AzureState $AzureState
    if (-not $RequireComplete) {
        return
    }

    if ($null -eq $GitHubState.Ruleset -or
        $null -eq $GitHubState.Environment -or
        $null -eq $AzureState.Identity -or
        $null -eq $AzureState.FederatedCredential) {
        throw 'Bootstrap state is incomplete.'
    }
    if (@($GitHubState.Variables.Keys).Count -ne 3) {
        throw 'GitHub Environment does not contain exactly the three approved Azure variables.'
    }

    $subscriptionScope = "/subscriptions/$($AzureState.Subscription.id)"
    $roleIds = @($AzureState.RoleAssignments | Where-Object scope -ieq $subscriptionScope | ForEach-Object {
            ([string] $_.roleDefinitionId -split '/')[-1]
        })
    if ($roleIds.Count -ne 2 -or
        $roleIds -notcontains $contributorRoleId -or
        $roleIds -notcontains $rbacAdministratorRoleId) {
        throw 'Infrastructure identity does not have exactly the two approved subscription roles.'
    }
}

if ($Repository -ne 'george-pov/html2b' -or
    $EnvironmentName -ne 'dev' -or
    $InfrastructureIdentityName -ne 'id-html2b-infrastructure-dev') {
    throw 'Bootstrap targets must exactly match george-pov/html2b, dev, and id-html2b-infrastructure-dev.'
}
if ($Operation -eq 'Apply' -and
    $PSBoundParameters.ContainsKey('Confirm') -and
    -not [bool] $PSBoundParameters['Confirm']) {
    throw 'Bootstrap Apply rejects -Confirm:$false.'
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue) -or
    -not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI and Azure CLI are required.'
}

$oidcState = Get-GitHubOidcSubjectState
Assert-ExpectedOidcSubject -State $oidcState
$githubState = Get-GitHubRepositoryState
$azureState = Get-AzureBootstrapState
Test-BootstrapState `
    -GitHubState $githubState `
    -AzureState $azureState `
    -RequireComplete:($Operation -eq 'Verify')

$plan = [ordered]@{
    repository = $Repository
    ruleset = $rulesetName
    requiredCheck = 'Repository validation'
    environment = $EnvironmentName
    deploymentBranch = 'main'
    requiredReviewers = 0
    infrastructureIdentity = $InfrastructureIdentityName
    federatedCredential = $federatedCredentialName
    issuer = $oidcIssuer
    audience = $oidcAudience
    subject = $oidcSubject
    subscriptionRoles = @(
        'Contributor',
        'Role Based Access Control Administrator'
    )
    githubVariables = $githubVariableNames
}
$plan | ConvertTo-Json -Depth 10

if ($Operation -eq 'Plan') {
    return
}
if ($Operation -eq 'Verify') {
    Write-Output 'bootstrapVerification=passed'
    return
}

Write-Host "Repository: $Repository"
Write-Host "Ruleset: $rulesetName"
Write-Host "Environment and branch: $EnvironmentName / main"
Write-Host "Identity: $resourceGroupName/$InfrastructureIdentityName"
Write-Host "Federated subject: $oidcSubject"
Write-Host 'Subscription roles: Contributor; Role Based Access Control Administrator'
Write-Host "GitHub variables: $($githubVariableNames -join ', ')"

Set-MainRuleset -GitHubState $githubState
Set-DevEnvironment -GitHubState $githubState
Set-InfrastructureIdentity -AzureState $azureState

# Re-read Azure after identity creation so later operations use the actual
# principal/client IDs without exposing them.
$azureState = Get-AzureBootstrapState
Set-InfrastructureFederatedCredential -AzureState $azureState
Set-InfrastructureRoleAssignments -AzureState $azureState

# Re-read both systems after Environment and identity creation.
$githubState = Get-GitHubRepositoryState
$azureState = Get-AzureBootstrapState
Set-GitHubEnvironmentVariables -GitHubState $githubState -AzureState $azureState

$githubState = Get-GitHubRepositoryState
$azureState = Get-AzureBootstrapState
Test-BootstrapState -GitHubState $githubState -AzureState $azureState -RequireComplete
Write-Output 'bootstrapApply=passed'
