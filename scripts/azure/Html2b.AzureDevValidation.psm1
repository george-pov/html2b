Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [version] '7.3') {
    throw 'Html2b Azure validation requires PowerShell 7.3 or later.'
}

Import-Module `
    (Join-Path $PSScriptRoot 'Html2b.AzureStateValidation.psm1')
Import-Module `
    (Join-Path $PSScriptRoot 'Html2b.HttpValidation.psm1')
Import-Module `
    (Join-Path $PSScriptRoot 'Html2b.TelemetryEvidence.psm1')

$script:RenderIdentityName = 'id-html2b-render-dev'

function Get-ExpectedRenderIdentityId {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName
    )

    return "/subscriptions/$SubscriptionId/" +
        "resourceGroups/$ResourceGroupName/providers/" +
        "Microsoft.ManagedIdentity/userAssignedIdentities/" +
        $script:RenderIdentityName
}

function Wait-RenderScaledToZero {
    param(
        [Parameter(Mandatory)]
        [string] $Subscription,

        [Parameter(Mandatory)]
        [string] $ContainerAppResourceId,

        [Parameter(Mandatory)]
        [string] $RevisionName,

        [TimeSpan] $Timeout = [TimeSpan]::FromMinutes(10)
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed -lt $Timeout) {
        $replicas = @(
            Get-RevisionReplicas `
                -Subscription $Subscription `
                -ContainerAppResourceId $ContainerAppResourceId `
                -RevisionName $RevisionName
        )
        if ($replicas.Count -eq 0) {
            return [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        }
        if ($replicas.Count -gt 1) {
            throw "Render exceeded its replica cap with $($replicas.Count) replicas."
        }

        Start-Sleep -Seconds 15
    }

    throw "Timed out waiting for Render revision $RevisionName to scale to zero."
}

function Resolve-AzureDevValidationOutcome {
    param(
        [Parameter(Mandatory)]
        [object] $Telemetry,

        [Parameter(Mandatory)]
        [object] $WrongPrincipalResult
    )

    $evidenceGaps = @()
    if ($Telemetry.status -eq 'not-observed') {
        $evidenceGaps += [ordered]@{
            code = 'dependency-telemetry-not-observed'
            reason = [string] $Telemetry.reason
            risk = [string] $Telemetry.risk
            recovery = [string] $Telemetry.recovery
        }
    }
    if ($WrongPrincipalResult.status -eq 'skipped') {
        $evidenceGaps += [ordered]@{
            code = 'wrong-principal-403-not-exercised'
            reason = [string] $WrongPrincipalResult.reason
            risk = [string] $WrongPrincipalResult.risk
            recovery =
                'Supply a separately approved Render-audience token from a ' +
                'safe second principal, then rerun the validator.'
        }
    }

    $status = if ($Telemetry.status -eq 'not-observed') {
        'incomplete-telemetry-evidence-gap'
    }
    elseif ($WrongPrincipalResult.status -eq 'skipped') {
        'passed-with-safe-wrong-principal-skip'
    }
    else {
        'passed'
    }

    return [ordered]@{
        status = $status
        evidenceGaps = @($evidenceGaps)
    }
}

function Invoke-Html2bAzureDevValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ExpectedTenantId,

        [ValidateNotNullOrEmpty()]
        [string] $ResourceGroupName = 'rg-html2b-dev',

        [ValidateNotNullOrEmpty()]
        [string] $FunctionAppName = 'func-html2b-api-dev',

        [ValidateNotNullOrEmpty()]
        [string] $RenderContainerAppName = 'ca-html2b-render-dev',

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RenderApiClientId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ExpectedRenderImage,

        [ValidateNotNullOrEmpty()]
        [string] $ApplicationInsightsName = 'appi-html2b-dev',

        [AllowNull()]
        [System.Security.SecureString] $WrongPrincipalRenderToken
    )

$canonicalSubscriptionId = ConvertTo-CanonicalGuid `
    -Value $SubscriptionId `
    -ParameterName 'SubscriptionId'
$canonicalTenantId = ConvertTo-CanonicalGuid `
    -Value $ExpectedTenantId `
    -ParameterName 'ExpectedTenantId'
$canonicalRenderApiClientId = ConvertTo-CanonicalGuid `
    -Value $RenderApiClientId `
    -ParameterName 'RenderApiClientId'

if ($ExpectedRenderImage -cnotmatch
    '^crhtml2bdev\.azurecr\.io/html2b-render@sha256:[0-9a-f]{64}$') {
    throw 'ExpectedRenderImage must be the immutable Html2B Render digest.'
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required.'
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$outputDirectory =
    Join-Path $repositoryRoot 'build\validation\005\p02\live'
$summaryPath = Join-Path $outputDirectory 'validation-summary.json'
$validation = [ordered]@{
    phase = 'P02'
    status = 'running'
    account = $null
    function = $null
    render = $null
    renderAuthentication = $null
    revision = $null
    waits = @()
    contracts = @()
    coldWake = $null
    telemetry = $null
    evidenceGaps = @()
    failure = $null
}

try {
    $accountState = Get-AccountState `
        -Subscription $canonicalSubscriptionId
    $validation.account = Assert-AccountConfiguration `
        -State $accountState `
        -ExpectedSubscription $canonicalSubscriptionId `
        -ExpectedTenant $canonicalTenantId

    $functionState = Get-FunctionAppState `
        -Subscription $canonicalSubscriptionId `
        -GroupName $ResourceGroupName `
        -AppName $FunctionAppName
    $functionSettings = @(
        Get-FunctionRenderSettings `
            -Subscription $canonicalSubscriptionId `
            -GroupName $ResourceGroupName `
            -AppName $FunctionAppName
    )
    $renderState = Get-RenderContainerAppState `
        -Subscription $canonicalSubscriptionId `
        -GroupName $ResourceGroupName `
        -AppName $RenderContainerAppName
    $renderAuthenticationState = Get-RenderAuthenticationState `
        -Subscription $canonicalSubscriptionId `
        -GroupName $ResourceGroupName `
        -AppName $RenderContainerAppName

    $renderFqdn =
        [string] $renderState.properties.configuration.ingress.fqdn
    $renderUrl = "https://$renderFqdn"
    $renderAudience = "api://$canonicalRenderApiClientId"
    $expectedRenderIdentityId = Get-ExpectedRenderIdentityId `
        -SubscriptionId $canonicalSubscriptionId `
        -ResourceGroupName $ResourceGroupName

    $validation.function = Assert-FunctionConfiguration `
        -State $functionState `
        -Settings $functionSettings `
        -ExpectedTenant $canonicalTenantId `
        -ExpectedRenderUrl $renderUrl `
        -ExpectedAudience $renderAudience
    $validation.render = Assert-RenderContainerConfiguration `
        -State $renderState `
        -ExpectedImage $ExpectedRenderImage `
        -ExpectedIdentityId $expectedRenderIdentityId
    $validation.renderAuthentication =
        Assert-RenderAuthenticationConfiguration `
            -State $renderAuthenticationState `
            -ExpectedTenantId $canonicalTenantId `
            -ExpectedClientId $canonicalRenderApiClientId `
            -ExpectedPrincipalId $validation.function.identity.principalId

    $revisionState = Get-RenderRevisions `
        -Subscription $canonicalSubscriptionId `
        -ContainerAppResourceId $renderState.id
    $validation.revision = Assert-RenderRevisionState `
        -State $revisionState `
        -LatestRevisionName $renderState.properties.latestRevisionName
    $initialReplicas = @(
        Get-RevisionReplicas `
            -Subscription $canonicalSubscriptionId `
            -ContainerAppResourceId $renderState.id `
            -RevisionName $renderState.properties.latestRevisionName
    )
    if ($initialReplicas.Count -gt 1) {
        throw "Render exceeded its replica cap with $($initialReplicas.Count) replicas."
    }

    $functionBaseUri = [uri] "https://$($functionState.properties.defaultHostName)/"
    $renderBaseUri = [uri] "$renderUrl/"
    $liveValidationStartedAt = [DateTimeOffset]::UtcNow
    $liveValidationEndedAt = $null
    $validation.waits += Wait-EndpointStatus `
        -Uri ([uri]::new($functionBaseUri, 'health/live')) `
        -ExpectedBodyStatus 'live'

    $client = New-ValidationHttpClient
    try {
        $coldReadyScaleSeconds = Wait-RenderScaledToZero `
            -Subscription $canonicalSubscriptionId `
            -ContainerAppResourceId $renderState.id `
            -RevisionName $renderState.properties.latestRevisionName
        $validation.coldWake = [ordered]@{
            readinessScaleToZeroSeconds = $coldReadyScaleSeconds
            readinessElapsedMilliseconds = $null
            readinessConvergenceMilliseconds = $null
            pngScaleToZeroSeconds = $null
            firstReadinessAttemptRetried = $false
            firstPngAttemptRetried = $false
        }
        $coldReady = Invoke-HealthContract `
            -Client $client `
            -Uri ([uri]::new($functionBaseUri, 'health/ready')) `
            -ExpectedBodyStatus 'ready' `
            -Phase 'cold-readiness' `
            -HostLabel 'Function' `
            -ReturnFailure
        $validation.contracts += @($coldReady)
        $validation.coldWake.readinessElapsedMilliseconds =
            $coldReady.elapsedMilliseconds
        $coldReadySucceeded =
            $coldReady.httpStatus -eq 200 -and
            $coldReady.bodyStatus -eq 'ready'
        if (-not $coldReadySucceeded) {
            if ($coldReady.httpStatus -ne 503 -or
                $coldReady.bodyStatus -ne 'not-ready') {
                throw "Cold Function readiness returned unexpected HTTP $($coldReady.httpStatus) with health status '$($coldReady.bodyStatus)' after $($coldReady.elapsedMilliseconds) ms."
            }

            $validation.coldWake.firstReadinessAttemptRetried = $true
            $readinessConvergence = Wait-EndpointStatus `
                -Uri ([uri]::new($functionBaseUri, 'health/ready')) `
                -ExpectedBodyStatus 'ready' `
                -Timeout ([TimeSpan]::FromSeconds(60))
            $validation.waits += $readinessConvergence
            $validation.coldWake.readinessConvergenceMilliseconds =
                $readinessConvergence.elapsedMilliseconds
        }
        $warmReady = Invoke-HealthContract `
            -Client $client `
            -Uri ([uri]::new($functionBaseUri, 'health/ready')) `
            -ExpectedBodyStatus 'ready' `
            -Phase 'warm-after-cold-readiness' `
            -HostLabel 'Function'
        $validation.contracts += @($warmReady)

        $validation.contracts += @(
            Invoke-FunctionContractValidation `
                -Client $client `
                -BaseUri $functionBaseUri
        )
        $wrongAudienceToken = $null
        try {
            $wrongAudienceToken = Get-WrongAudienceAccessToken `
                -Subscription $canonicalSubscriptionId
            $authorizationResults = @(
                Invoke-RenderAuthorizationMatrix `
                    -Client $client `
                    -BaseUri $renderBaseUri `
                    -WrongAudienceToken $wrongAudienceToken `
                    -WrongPrincipalToken $WrongPrincipalRenderToken `
                    -AllowedPrincipalId $validation.function.identity.principalId
            )
            $validation.contracts += $authorizationResults
            $wrongPrincipalResult = @(
                $authorizationResults |
                    Where-Object scenario -EQ 'valid-token-wrong-principal'
            )
            if ($wrongPrincipalResult.Count -ne 1) {
                throw 'The authorization matrix returned an invalid wrong-principal result.'
            }
        }
        finally {
            $wrongAudienceToken = $null
        }

        $coldPngScaleSeconds = Wait-RenderScaledToZero `
            -Subscription $canonicalSubscriptionId `
            -ContainerAppResourceId $renderState.id `
            -RevisionName $renderState.properties.latestRevisionName
        $validation.coldWake.pngScaleToZeroSeconds =
            $coldPngScaleSeconds
        $coldPng = Invoke-RenderContract `
            -Client $client `
            -Uri ([uri]::new($functionBaseUri, 'api/renders/png')) `
            -Format 'png' `
            -Phase 'cold-png' `
            -HostLabel 'Function'
        $warmPng = Invoke-RenderContract `
            -Client $client `
            -Uri ([uri]::new($functionBaseUri, 'api/renders/png')) `
            -Format 'png' `
            -Phase 'warm-after-cold-png' `
            -HostLabel 'Function'

        $validation.contracts += @(
            $coldPng,
            $warmPng
        )
        $liveValidationEndedAt = [DateTimeOffset]::UtcNow
    }
    finally {
        $client.Dispose()
    }

    $finalRenderState = Get-RenderContainerAppState `
        -Subscription $canonicalSubscriptionId `
        -GroupName $ResourceGroupName `
        -AppName $RenderContainerAppName
    $null = Assert-RenderContainerConfiguration `
        -State $finalRenderState `
        -ExpectedImage $ExpectedRenderImage `
        -ExpectedIdentityId $expectedRenderIdentityId
    if ($finalRenderState.properties.latestRevisionName -ne
        $renderState.properties.latestRevisionName) {
        throw 'The Render revision changed during validation.'
    }
    $finalReplicas = @(
        Get-RevisionReplicas `
            -Subscription $canonicalSubscriptionId `
            -ContainerAppResourceId $finalRenderState.id `
            -RevisionName $finalRenderState.properties.latestRevisionName
    )
    if ($finalReplicas.Count -gt 1) {
        throw "Render exceeded its replica cap with $($finalReplicas.Count) replicas."
    }
    $validation.render.replicaCountAfterValidation = $finalReplicas.Count

    $validation.telemetry = Get-DependencyTelemetryEvidence `
        -Subscription $canonicalSubscriptionId `
        -GroupName $ResourceGroupName `
        -ApplicationName $ApplicationInsightsName `
        -StartTime $liveValidationStartedAt `
        -EndTime $liveValidationEndedAt `
        -RenderHostName $renderFqdn
    $outcome = Resolve-AzureDevValidationOutcome `
        -Telemetry $validation.telemetry `
        -WrongPrincipalResult $wrongPrincipalResult[0]
    $validation.status = $outcome.status
    $validation.evidenceGaps = $outcome.evidenceGaps
    foreach ($gap in $validation.evidenceGaps) {
        Write-Warning "$($gap.code): $($gap.reason)"
    }
    Write-SanitizedJson -Path $summaryPath -Value $validation
}
catch {
    $validation.status = 'failed'
    $validation.failure = $_.Exception.Message
    Write-SanitizedJson -Path $summaryPath -Value $validation
    throw
}

Write-Host "Function App: $FunctionAppName"
Write-Host "Render Container App: $RenderContainerAppName"
Write-Host "Render image: $ExpectedRenderImage"
Write-Host "Sanitized validation: $summaryPath"
if ($validation.evidenceGaps.Count -gt 0) {
    $evidenceGapCodes = $validation.evidenceGaps.code -join ', '
    Write-Warning (
        'P02 HTTP, auth-policy, revision, probe, and replica validation passed, ' +
        "but evidence gaps remain: $evidenceGapCodes.")
}
else {
    Write-Host 'P02 protected-Render Azure validation passed.'
}
}

Export-ModuleMember -Function @(
    'Get-ExpectedRenderIdentityId',
    'Invoke-Html2bAzureDevValidation',
    'Resolve-AzureDevValidationOutcome'
)
