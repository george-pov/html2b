[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $ContainerAppName,

    [Parameter(Mandatory)]
    [ValidatePattern(
        '^[a-z0-9.-]+(?::[0-9]+)?/[a-z0-9][a-z0-9._/-]*@sha256:[0-9a-f]{64}$'
    )]
    [string] $Image,

    [ValidatePattern('^[a-z0-9][a-z0-9-]*$')]
    [string] $ContainerName = 'html2b-render',

    [ValidateRange(60, 1800)]
    [int] $ReadinessTimeoutSeconds = 600
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

az containerapp update `
    --subscription $SubscriptionId `
    --resource-group $ResourceGroupName `
    --name $ContainerAppName `
    --container-name $ContainerName `
    --image $Image `
    --only-show-errors `
    --output none
if ($LASTEXITCODE -ne 0) {
    throw "Render Container App update failed with exit code $LASTEXITCODE."
}

$deadline = [DateTimeOffset]::UtcNow.AddSeconds($ReadinessTimeoutSeconds)
$lastState = $null

do {
    $stateJsonLines = @(
        az containerapp show `
            --subscription $SubscriptionId `
            --resource-group $ResourceGroupName `
            --name $ContainerAppName `
            --output json `
            --only-show-errors
    )
    if ($LASTEXITCODE -ne 0) {
        throw "Render Container App readback failed with exit code $LASTEXITCODE."
    }

    $lastState = ($stateJsonLines -join "`n") |
        ConvertFrom-Json -Depth 100
    $container = @(
        $lastState.properties.template.containers |
            Where-Object name -CEQ $ContainerName
    )

    if ($container.Count -ne 1) {
        throw "Render container $ContainerName was not found exactly once."
    }

    $isReady = (
        $container[0].image -ceq $Image -and
        $lastState.properties.provisioningState -ceq 'Succeeded' -and
        -not [string]::IsNullOrWhiteSpace(
            $lastState.properties.latestRevisionName
        ) -and
        $lastState.properties.latestRevisionName -ceq
            $lastState.properties.latestReadyRevisionName
    )

    if ($isReady) {
        Write-Host "Render revision ready: $($lastState.properties.latestRevisionName)"
        return
    }

    Start-Sleep -Seconds 10
}
while ([DateTimeOffset]::UtcNow -lt $deadline)

throw (
    'Render did not become ready within the deployment timeout. ' +
    "Provisioning state: $($lastState.properties.provisioningState); " +
    "latest revision: $($lastState.properties.latestRevisionName); " +
    "latest ready revision: $($lastState.properties.latestReadyRevisionName)."
)
