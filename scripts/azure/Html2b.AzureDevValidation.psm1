Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [version] '7.3') {
    throw 'Html2b Azure validation requires PowerShell 7.3 or later.'
}

Import-Module `
    (Join-Path $PSScriptRoot 'Html2b.AzureStateValidation.psm1') `
    -Force
Import-Module `
    (Join-Path $PSScriptRoot 'Html2b.HttpValidation.psm1') `
    -Force
Import-Module `
    (Join-Path $PSScriptRoot 'Html2b.TelemetryEvidence.psm1') `
    -Force

$script:FunctionTelemetryClockSkewGuard = [TimeSpan]::FromSeconds(30)

function Get-ExpectedRenderIdentityId {
    param(
        [Parameter(Mandatory)]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [string] $RenderIdentityName
    )

    return "/subscriptions/$SubscriptionId/" +
        "resourceGroups/$ResourceGroupName/providers/" +
        "Microsoft.ManagedIdentity/userAssignedIdentities/" +
        $RenderIdentityName
}

function Assert-ImmutableRenderImageReference {
    param(
        [Parameter(Mandatory)]
        [string] $Image,

        [Parameter(Mandatory)]
        [string] $RegistryServer,

        [Parameter(Mandatory)]
        [string] $ImageRepository
    )

    $pattern = '^{0}/{1}@sha256:[0-9a-f]{{64}}$' -f (
        [regex]::Escape($RegistryServer)),
        ([regex]::Escape($ImageRepository))
    if ($Image -cnotmatch $pattern) {
        throw (
            'ExpectedRenderImage must use the selected registry and ' +
            'repository with an immutable lowercase sha256 digest.')
    }
}

function Resolve-AzureValidationOutputDirectory {
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [string] $OutputDirectory
    )

    $validationRoot = [System.IO.Path]::GetFullPath(
        (Join-Path $RepositoryRoot 'build\validation'))
    $resolvedOutputDirectory = [System.IO.Path]::GetFullPath(
        $OutputDirectory,
        $RepositoryRoot)
    $validationRootPrefix = $validationRoot.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar

    $pathComparison = if ([System.OperatingSystem]::IsWindows()) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    if (-not $resolvedOutputDirectory.StartsWith(
            $validationRootPrefix,
            $pathComparison)) {
        throw 'Validation output must remain below the repository build/validation directory.'
    }

    return $resolvedOutputDirectory
}

function Wait-RenderScaledToZero {
    param(
        [Parameter(Mandatory)]
        [string] $Subscription,

        [Parameter(Mandatory)]
        [string] $ContainerAppResourceId,

        [Parameter(Mandatory)]
        [string] $RevisionName,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $MaximumReplicaCount,

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
        if ($replicas.Count -gt $MaximumReplicaCount) {
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

function Get-ExistingDefaultFunctionHostKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Subscription,

        [Parameter(Mandatory)]
        [string] $GroupName,

        [Parameter(Mandatory)]
        [string] $AppName
    )

    $functionHostKeyOutput = $null
    $functionHostKey = $null
    try {
        try {
            $functionHostKeyOutput = & az functionapp keys list `
                --subscription $Subscription `
                --resource-group $GroupName `
                --name $AppName `
                --query 'functionKeys.default' `
                --output tsv `
                --only-show-errors `
                2>$null 3>$null 4>$null 5>$null 6>$null
        }
        catch {
            throw 'Unable to read the existing default Function host key.'
        }

        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to read the existing default Function host key.'
        }

        $functionHostKey =
            ($functionHostKeyOutput | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($functionHostKey)) {
            throw 'The existing default Function host key is missing.'
        }
        if ($functionHostKey -match '\s') {
            throw 'The existing default Function host key is invalid.'
        }

        return $functionHostKey
    }
    finally {
        $functionHostKey = $null
        $functionHostKeyOutput = $null
    }
}

function Test-ExistingDefaultFunctionHostKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Subscription,

        [Parameter(Mandatory)]
        [string] $GroupName,

        [Parameter(Mandatory)]
        [string] $AppName
    )

    $functionHostKey = $null
    try {
        $functionHostKey = Get-ExistingDefaultFunctionHostKey `
            -Subscription $Subscription `
            -GroupName $GroupName `
            -AppName $AppName

        return [ordered]@{
            keyName = 'default'
            status = 'passed'
        }
    }
    finally {
        $functionHostKey = $null
    }
}

function Assert-ExpectedFunctionBaseUri {
    param(
        [Parameter(Mandatory)]
        [uri] $BaseUri,

        [Parameter(Mandatory)]
        [string] $AppName
    )

    $expectedHostName = "$AppName.azurewebsites.net"
    if (-not $BaseUri.IsAbsoluteUri -or
        -not [string]::Equals(
            $BaseUri.Scheme,
            [uri]::UriSchemeHttps,
            [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals(
            $BaseUri.Host,
            $expectedHostName,
            [StringComparison]::OrdinalIgnoreCase) -or
        $BaseUri.Port -ne 443 -or
        -not [string]::IsNullOrEmpty($BaseUri.UserInfo) -or
        $BaseUri.AbsolutePath -cne '/' -or
        -not [string]::IsNullOrEmpty($BaseUri.Query) -or
        -not [string]::IsNullOrEmpty($BaseUri.Fragment)) {
        throw 'Function validation requires the expected HTTPS Function origin.'
    }
}

function New-FunctionAuthorizationTelemetryWindows {
    param(
        [Parameter(Mandatory)]
        [DateTimeOffset] $NoKeyStartTime,

        [Parameter(Mandatory)]
        [DateTimeOffset] $NoKeyEndTime,

        [Parameter(Mandatory)]
        [DateTimeOffset] $KeyedStartTime,

        [Parameter(Mandatory)]
        [DateTimeOffset] $KeyedEndTime
    )

    $noKeyWindow = [ordered]@{
        startTime =
            $NoKeyStartTime.Subtract($script:FunctionTelemetryClockSkewGuard)
        endTime =
            $NoKeyEndTime.Add($script:FunctionTelemetryClockSkewGuard)
    }
    $keyedWindow = [ordered]@{
        startTime =
            $KeyedStartTime.Subtract($script:FunctionTelemetryClockSkewGuard)
        endTime =
            $KeyedEndTime.Add($script:FunctionTelemetryClockSkewGuard)
    }
    if ($noKeyWindow.endTime -ge $keyedWindow.startTime) {
        throw 'Function authorization telemetry guard windows overlap.'
    }

    return [ordered]@{
        clockSkewGuardSeconds =
            $script:FunctionTelemetryClockSkewGuard.TotalSeconds
        noKeyWindow = $noKeyWindow
        keyedWindow = $keyedWindow
    }
}

function Invoke-FunctionAuthorizationValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Subscription,

        [Parameter(Mandatory)]
        [string] $GroupName,

        [Parameter(Mandatory)]
        [string] $AppName,

        [Parameter(Mandatory)]
        [uri] $BaseUri,

        [Parameter(Mandatory)]
        [string] $ContainerAppResourceId,

        [Parameter(Mandatory)]
        [string] $RevisionName,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $RenderMaximumReplicaCount,

        [ValidateSet('default')]
        [string] $FunctionHostKeyName = 'default'
    )

    Assert-ExpectedFunctionBaseUri -BaseUri $BaseUri -AppName $AppName

    $contracts = @()
    $waits = @()
    $functionHostKey = $null
    [System.Net.Http.HttpClient] $anonymousClient = $null
    [System.Net.Http.HttpClient] $keyedClient = $null
    try {
        $anonymousClient = New-ValidationHttpClient
        $waits += Wait-EndpointStatus `
            -Client $anonymousClient `
            -Uri ([uri]::new($BaseUri, 'health/live')) `
            -ExpectedBodyStatus 'live'

        $noKeyStartTime = [DateTimeOffset]::UtcNow
        $contracts += Invoke-HealthContract `
            -Client $anonymousClient `
            -Uri ([uri]::new($BaseUri, 'health/live')) `
            -ExpectedBodyStatus 'live' `
            -Phase 'anonymous-pre-key' `
            -HostLabel 'Function'

        $contracts += Invoke-ExpectedFunctionAuthorizationRejection `
            -Client $anonymousClient `
            -Uri ([uri]::new($BaseUri, 'health/ready')) `
            -Method 'GET' `
            -Scenario 'ready-without-key'
        $contracts += Invoke-ExpectedFunctionAuthorizationRejection `
            -Client $anonymousClient `
            -Uri ([uri]::new($BaseUri, 'api/renders/png')) `
            -Method 'POST' `
            -Scenario 'render-without-key'
        $noKeyEndTime = [DateTimeOffset]::UtcNow

        $coldReadyScaleSeconds = Wait-RenderScaledToZero `
            -Subscription $Subscription `
            -ContainerAppResourceId $ContainerAppResourceId `
            -RevisionName $RevisionName `
            -MaximumReplicaCount $RenderMaximumReplicaCount
        $earliestKeyedStartTime =
            $noKeyEndTime.Add($script:FunctionTelemetryClockSkewGuard)
        $earliestKeyedStartTime =
            $earliestKeyedStartTime.Add(
                $script:FunctionTelemetryClockSkewGuard)
        $earliestKeyedStartTime = $earliestKeyedStartTime.AddTicks(1)
        while ($true) {
            $remainingSeparationMilliseconds =
                ($earliestKeyedStartTime - [DateTimeOffset]::UtcNow).
                    TotalMilliseconds
            if ($remainingSeparationMilliseconds -le 0) {
                break
            }

            Start-Sleep -Milliseconds (
                [int] [Math]::Ceiling(
                    [Math]::Min(1000.0, $remainingSeparationMilliseconds)))
        }
        $coldWake = [ordered]@{
            readinessScaleToZeroSeconds = $coldReadyScaleSeconds
            readinessElapsedMilliseconds = $null
            readinessConvergenceMilliseconds = $null
            pngScaleToZeroSeconds = $null
            firstReadinessAttemptRetried = $false
            firstPngAttemptRetried = $false
        }

        $functionHostKey = Get-ExistingDefaultFunctionHostKey `
            -Subscription $Subscription `
            -GroupName $GroupName `
            -AppName $AppName
        $keyedClient = New-ValidationHttpClient
        if (-not $keyedClient.DefaultRequestHeaders.TryAddWithoutValidation(
                'x-functions-key',
                $functionHostKey)) {
            throw 'Unable to configure the approved Function host key.'
        }
        $functionHostKey = $null

        $keyedStartTime = [DateTimeOffset]::UtcNow
        $coldReady = Invoke-HealthContract `
            -Client $keyedClient `
            -Uri ([uri]::new($BaseUri, 'health/ready')) `
            -ExpectedBodyStatus 'ready' `
            -Phase 'keyed-cold-readiness' `
            -HostLabel 'Function' `
            -ReturnFailure
        $contracts += @($coldReady)
        $coldWake.readinessElapsedMilliseconds =
            $coldReady.elapsedMilliseconds
        $coldReadySucceeded =
            $coldReady.httpStatus -eq 200 -and
            $coldReady.bodyStatus -eq 'ready'
        if (-not $coldReadySucceeded) {
            if ($coldReady.httpStatus -ne 503 -or
                $coldReady.bodyStatus -ne 'not-ready') {
                throw "Cold keyed Function readiness returned unexpected HTTP $($coldReady.httpStatus) with health status '$($coldReady.bodyStatus)' after $($coldReady.elapsedMilliseconds) ms."
            }

            $coldWake.firstReadinessAttemptRetried = $true
            $readinessConvergence = Wait-EndpointStatus `
                -Client $keyedClient `
                -Uri ([uri]::new($BaseUri, 'health/ready')) `
                -ExpectedBodyStatus 'ready' `
                -Timeout ([TimeSpan]::FromSeconds(60))
            $waits += $readinessConvergence
            $coldWake.readinessConvergenceMilliseconds =
                $readinessConvergence.elapsedMilliseconds
        }

        $contracts += Invoke-HealthContract `
            -Client $keyedClient `
            -Uri ([uri]::new($BaseUri, 'health/ready')) `
            -ExpectedBodyStatus 'ready' `
            -Phase 'keyed-warm-after-cold-readiness' `
            -HostLabel 'Function'
        $contracts += @(
            Invoke-FunctionContractValidation `
                -Client $keyedClient `
                -BaseUri $BaseUri `
                -Phase 'keyed-warm' `
                -SkipLiveness
        )

        $coldPngScaleSeconds = Wait-RenderScaledToZero `
            -Subscription $Subscription `
            -ContainerAppResourceId $ContainerAppResourceId `
            -RevisionName $RevisionName `
            -MaximumReplicaCount $RenderMaximumReplicaCount
        $coldWake.pngScaleToZeroSeconds = $coldPngScaleSeconds
        $contracts += Invoke-RenderContract `
            -Client $keyedClient `
            -Uri ([uri]::new($BaseUri, 'api/renders/png')) `
            -Format 'png' `
            -Phase 'keyed-cold-png' `
            -HostLabel 'Function'
        $contracts += Invoke-RenderContract `
            -Client $keyedClient `
            -Uri ([uri]::new($BaseUri, 'api/renders/png')) `
            -Format 'png' `
            -Phase 'keyed-warm-after-cold-png' `
            -HostLabel 'Function'
        $keyedEndTime = [DateTimeOffset]::UtcNow
        $telemetryWindows = New-FunctionAuthorizationTelemetryWindows `
            -NoKeyStartTime $noKeyStartTime `
            -NoKeyEndTime $noKeyEndTime `
            -KeyedStartTime $keyedStartTime `
            -KeyedEndTime $keyedEndTime

        return [ordered]@{
            keyName = $FunctionHostKeyName
            contracts = @($contracts)
            waits = @($waits)
            coldWake = $coldWake
            clockSkewGuardSeconds =
                $telemetryWindows.clockSkewGuardSeconds
            noKeyWindow = $telemetryWindows.noKeyWindow
            keyedWindow = $telemetryWindows.keyedWindow
        }
    }
    finally {
        $functionHostKey = $null
        if ($null -ne $keyedClient) {
            $null = $keyedClient.DefaultRequestHeaders.Remove(
                'x-functions-key')
            $keyedClient.Dispose()
        }
        if ($null -ne $anonymousClient) {
            $anonymousClient.Dispose()
        }
    }
}

function Invoke-Html2bAzureDevValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $EnvironmentName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $SubscriptionId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ExpectedTenantId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ResourceGroupName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $FunctionAppName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RenderContainerAppName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RenderApiClientId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RenderRegistryServer,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RenderImageRepository,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RenderIdentityName,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ExpectedRenderImage,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $ApplicationInsightsName,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $FunctionInstanceMemoryMB,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $FunctionMaximumInstanceCount,

        [Parameter(Mandatory)]
        [ValidateScript({ $_ -gt 0 })]
        [double] $RenderCpu,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $RenderMemory,

        [Parameter(Mandatory)]
        [ValidateRange(0, [int]::MaxValue)]
        [int] $RenderMinReplicas,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $RenderMaxReplicas,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $RenderHttpConcurrency,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $OutputDirectory,

        [ValidateSet('default')]
        [string] $FunctionHostKeyName = 'default',

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

if ($RenderMinReplicas -ne 0) {
    throw 'RenderMinReplicas must be zero for the cold-start validation contract.'
}
$null = Assert-ImmutableRenderImageReference `
    -Image $ExpectedRenderImage `
    -RegistryServer $RenderRegistryServer `
    -ImageRepository $RenderImageRepository

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$resolvedOutputDirectory = Resolve-AzureValidationOutputDirectory `
    -RepositoryRoot $repositoryRoot `
    -OutputDirectory $OutputDirectory
$summaryPath = Join-Path $resolvedOutputDirectory 'validation-summary.json'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required.'
}

$validation = [ordered]@{
    environment = $EnvironmentName
    status = 'running'
    account = $null
    function = $null
    functionAuthorization = $null
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
        -ResourceGroupName $ResourceGroupName `
        -RenderIdentityName $RenderIdentityName

    $validation.function = Assert-FunctionConfiguration `
        -State $functionState `
        -Settings $functionSettings `
        -ExpectedTenant $canonicalTenantId `
        -ExpectedRenderUrl $renderUrl `
        -ExpectedAudience $renderAudience `
        -ExpectedInstanceMemoryMB $FunctionInstanceMemoryMB `
        -ExpectedMaximumInstanceCount $FunctionMaximumInstanceCount
    $validation.render = Assert-RenderContainerConfiguration `
        -State $renderState `
        -ExpectedImage $ExpectedRenderImage `
        -ExpectedIdentityId $expectedRenderIdentityId `
        -ExpectedRegistryServer $RenderRegistryServer `
        -ExpectedCpu $RenderCpu `
        -ExpectedMemory $RenderMemory `
        -ExpectedMinReplicas $RenderMinReplicas `
        -ExpectedMaxReplicas $RenderMaxReplicas `
        -ExpectedHttpConcurrency $RenderHttpConcurrency
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
    if ($initialReplicas.Count -gt $RenderMaxReplicas) {
        throw "Render exceeded its replica cap with $($initialReplicas.Count) replicas."
    }

    $functionBaseUri = [uri] "https://$($functionState.properties.defaultHostName)/"
    $renderBaseUri = [uri] "$renderUrl/"
    $functionAuthorization =
        Invoke-FunctionAuthorizationValidation `
            -Subscription $canonicalSubscriptionId `
            -GroupName $ResourceGroupName `
            -AppName $FunctionAppName `
            -BaseUri $functionBaseUri `
            -ContainerAppResourceId $renderState.id `
            -RevisionName $renderState.properties.latestRevisionName `
            -RenderMaximumReplicaCount $RenderMaxReplicas `
            -FunctionHostKeyName $FunctionHostKeyName
    $validation.functionAuthorization = [ordered]@{
        keyName = $functionAuthorization.keyName
        clockSkewGuardSeconds =
            $functionAuthorization.clockSkewGuardSeconds
        noKeyWindow = $functionAuthorization.noKeyWindow
        keyedWindow = $functionAuthorization.keyedWindow
    }
    $validation.waits += @($functionAuthorization.waits)
    $validation.contracts += @($functionAuthorization.contracts)
    $validation.coldWake = $functionAuthorization.coldWake

    $client = New-ValidationHttpClient
    try {
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
        -ExpectedIdentityId $expectedRenderIdentityId `
        -ExpectedRegistryServer $RenderRegistryServer `
        -ExpectedCpu $RenderCpu `
        -ExpectedMemory $RenderMemory `
        -ExpectedMinReplicas $RenderMinReplicas `
        -ExpectedMaxReplicas $RenderMaxReplicas `
        -ExpectedHttpConcurrency $RenderHttpConcurrency
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
    if ($finalReplicas.Count -gt $RenderMaxReplicas) {
        throw "Render exceeded its replica cap with $($finalReplicas.Count) replicas."
    }
    $validation.render.replicaCountAfterValidation = $finalReplicas.Count

    $validation.telemetry = Get-FunctionAuthorizationTelemetryEvidence `
        -Subscription $canonicalSubscriptionId `
        -GroupName $ResourceGroupName `
        -ApplicationName $ApplicationInsightsName `
        -NoKeyStartTime $functionAuthorization.noKeyWindow.startTime `
        -NoKeyEndTime $functionAuthorization.noKeyWindow.endTime `
        -KeyedStartTime $functionAuthorization.keyedWindow.startTime `
        -KeyedEndTime $functionAuthorization.keyedWindow.endTime `
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
        'HTTP, auth-policy, revision, probe, and replica validation passed, ' +
        "but evidence gaps remain: $evidenceGapCodes.")
}
else {
    Write-Host 'Function-key and protected-Render Azure validation passed.'
}
}

Export-ModuleMember -Function @(
    'Get-ExpectedRenderIdentityId',
    'Invoke-Html2bAzureDevValidation',
    'Resolve-AzureDevValidationOutcome',
    'Test-ExistingDefaultFunctionHostKey'
)
