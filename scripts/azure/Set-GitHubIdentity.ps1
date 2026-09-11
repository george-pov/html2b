[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SubscriptionId,

    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [string] $DeploymentIdentityName,

    [Parameter(Mandatory)]
    [string] $Repository,

    [Parameter(Mandatory)]
    [string] $EnvironmentName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Assert-CommandAvailable {
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    if (-not (Get-Command $Name `
            -CommandType Application, ExternalScript `
            -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' is not available."
    }
}

function Invoke-AzureCli {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $output = @(& az @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed with exit code $LASTEXITCODE."
    }

    return [string]::Join([Environment]::NewLine, $output)
}

function Invoke-GitHubCli {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $output = @(& gh @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI command failed with exit code $LASTEXITCODE."
    }

    return [string]::Join([Environment]::NewLine, $output)
}

function Get-AzureContext {
    $json = Invoke-AzureCli -Arguments @(
        'account', 'show', '--output', 'json', '--only-show-errors'
    )

    try {
        return $json | ConvertFrom-Json -Depth 20
    }
    catch {
        throw 'Azure CLI returned an invalid account context.'
    }
}

function Get-GitHubRepo {
    param(
        [Parameter(Mandatory)]
        [string] $Name
    )

    return (Invoke-GitHubCli -Arguments @(
        'repo', 'view', $Name, '--json', 'nameWithOwner',
        '--jq', '.nameWithOwner'
    )).Trim()
}

function Get-DeployClientId {
    $json = Invoke-AzureCli -Arguments @(
        'identity', 'list',
        '--resource-group', $ResourceGroupName,
        '--output', 'json',
        '--only-show-errors'
    )

    try {
        $identities = @($json | ConvertFrom-Json -Depth 20) |
            Where-Object { [string] $_.name -ceq $DeploymentIdentityName }
    }
    catch {
        throw 'Azure CLI returned an invalid identity result.'
    }

    if ($identities.Count -ne 1) {
        throw 'Exactly one selected deployment identity must exist.'
    }

    $clientId = [string] $identities[0].clientId
    $guid = [guid]::Empty
    if (-not [guid]::TryParseExact($clientId, 'D', [ref] $guid)) {
        throw 'The selected deployment identity has an invalid client ID.'
    }

    return $clientId
}

function Get-GitHubClientId {
    return (Invoke-GitHubCli -Arguments @(
        'variable', 'get', 'AZURE_INFRA_CLIENT_ID',
        '--repo', $Repository,
        '--env', $EnvironmentName
    )).Trim()
}

function Set-GitHubClientId {
    param(
        [Parameter(Mandatory)]
        [string] $ClientId
    )

    $null = Invoke-GitHubCli -Arguments @(
        'variable', 'set', 'AZURE_INFRA_CLIENT_ID',
        '--repo', $Repository,
        '--env', $EnvironmentName,
        '--body', $ClientId
    )
}

try {
    $selectedValues = @(
        $SubscriptionId,
        $ResourceGroupName,
        $DeploymentIdentityName,
        $Repository,
        $EnvironmentName
    )
    if ($selectedValues.Where({
                [string]::IsNullOrWhiteSpace($_) -or $_ -match '[\x00-\x1f\x7f]'
            }).Count -ne 0) {
        throw 'Selected values must be non-empty and contain no control characters.'
    }
    if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw 'Repository must be an exact owner/name value.'
    }

    Assert-CommandAvailable -Name 'az'
    Assert-CommandAvailable -Name 'gh'

    $azureContext = Get-AzureContext
    if ([string] $azureContext.state -cne 'Enabled') {
        throw 'The current Azure account is not enabled.'
    }
    if ([string] $azureContext.id -cne $SubscriptionId) {
        throw 'The current Azure subscription does not match the selected subscription.'
    }

    $githubRepo = Get-GitHubRepo -Name $Repository
    if ($githubRepo -cne $Repository) {
        throw 'The active GitHub session does not match the selected repository.'
    }

    $escapedEnv = [uri]::EscapeDataString($EnvironmentName)
    $githubEnv = (Invoke-GitHubCli -Arguments @(
        'api', "repos/$Repository/environments/$escapedEnv",
        '--jq', '.name'
    )).Trim()
    if ($githubEnv -cne $EnvironmentName) {
        throw 'The selected GitHub Environment does not exist.'
    }

    $clientId = Get-DeployClientId
    Set-GitHubClientId -ClientId $clientId
    $savedClientId = Get-GitHubClientId
    if ($savedClientId -cne $clientId) {
        throw 'GitHub Environment client ID readback did not match.'
    }

    Write-Host 'GitHub Environment deployment identity was linked and verified.'
}
catch {
    throw ('{0} Correct the CLI context or permissions and rerun only this script.' -f `
        $_.Exception.Message)
}
