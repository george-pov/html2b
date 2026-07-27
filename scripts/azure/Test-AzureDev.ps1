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
    [string] $ExpectedRenderImage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [version] '7.3') {
    throw 'Test-AzureDev.ps1 requires PowerShell 7.3 or later.'
}

$PSNativeCommandUseErrorActionPreference = $true

$script:FunctionApiVersion = '2024-04-01'
$script:ContainerAppsApiVersion = '2026-01-01'
$script:RenderIdentityName = 'id-html2b-render-dev'
$script:RenderRegistryServer = 'crhtml2bdev.azurecr.io'
$script:MaximumResponseBytes = 16 * 1024 * 1024
$script:ExpectedWidth = 1280
$script:ExpectedHeight = 720
$script:ExpectedPdfWidthPoints = 960
$script:ExpectedPdfHeightPoints = 540

function ConvertTo-CanonicalGuid {
    param(
        [Parameter(Mandatory)]
        [string] $Value,

        [Parameter(Mandatory)]
        [string] $ParameterName
    )

    $parsed = [guid]::Empty
    if (-not [guid]::TryParseExact($Value, 'D', [ref] $parsed)) {
        throw "$ParameterName must be a D-format GUID."
    }

    return $parsed.ToString('D')
}

function Get-OptionalPropertyValue {
    param(
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory)]
        [string] $Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Invoke-AzureCli {
    param(
        [Parameter(Mandatory)]
        [string] $Subscription,

        [Parameter(Mandatory)]
        [string] $Operation,

        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $commandArguments = @($Arguments) + @(
        '--subscription', $Subscription,
        '--only-show-errors'
    )

    try {
        $output = & az @commandArguments 2>&1
    }
    catch {
        throw "Azure CLI operation '$Operation' failed."
    }

    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Azure CLI operation '$Operation' failed with exit code $exitCode."
    }

    return ($output | Out-String).Trim()
}

function ConvertFrom-AzureCliJson {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Json,

        [Parameter(Mandatory)]
        [string] $Operation
    )

    if ([string]::IsNullOrWhiteSpace($Json)) {
        throw "Azure CLI operation '$Operation' returned no JSON."
    }

    try {
        return $Json | ConvertFrom-Json -NoEnumerate
    }
    catch {
        throw "Azure CLI operation '$Operation' returned invalid JSON."
    }
}

function Write-SanitizedJson {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [object] $Value
    )

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -ItemType Directory -Force -Path $parent
    }

    $json = $Value | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText(
        $Path,
        $json,
        [System.Text.UTF8Encoding]::new($false))
}

function Get-AccountState {
    param(
        [Parameter(Mandatory)]
        [string] $Subscription
    )

    $json = Invoke-AzureCli `
        -Subscription $Subscription `
        -Operation 'read selected account' `
        -Arguments @(
            'account', 'show',
            '--query', '{id:id,tenantId:tenantId,state:state,name:name}',
            '--output', 'json'
        )

    return ConvertFrom-AzureCliJson `
        -Json $json `
        -Operation 'read selected account'
}

function Get-FunctionAppState {
    param(
        [Parameter(Mandatory)]
        [string] $Subscription,

        [Parameter(Mandatory)]
        [string] $GroupName,

        [Parameter(Mandatory)]
        [string] $AppName
    )

    $json = Invoke-AzureCli `
        -Subscription $Subscription `
        -Operation 'read Function App state' `
        -Arguments @(
            'resource', 'show',
            '--resource-group', $GroupName,
            '--resource-type', 'Microsoft.Web/sites',
            '--name', $AppName,
            '--api-version', $script:FunctionApiVersion,
            '--query',
            '{id:id,name:name,kind:kind,location:location,identity:identity,properties:{state:properties.state,enabled:properties.enabled,httpsOnly:properties.httpsOnly,publicNetworkAccess:properties.publicNetworkAccess,defaultHostName:properties.defaultHostName,functionAppConfig:properties.functionAppConfig}}',
            '--output', 'json'
        )

    return ConvertFrom-AzureCliJson `
        -Json $json `
        -Operation 'read Function App state'
}

function Get-FunctionRenderSettings {
    param(
        [Parameter(Mandatory)]
        [string] $Subscription,

        [Parameter(Mandatory)]
        [string] $GroupName,

        [Parameter(Mandatory)]
        [string] $AppName
    )

    $json = Invoke-AzureCli `
        -Subscription $Subscription `
        -Operation 'read focused Function settings' `
        -Arguments @(
            'functionapp', 'config', 'appsettings', 'list',
            '--resource-group', $GroupName,
            '--name', $AppName,
            '--query',
            "[?name=='RenderService__BaseUrl' || name=='RenderService__Audience'].{name:name,value:value}",
            '--output', 'json'
        )

    $settings = ConvertFrom-AzureCliJson `
        -Json $json `
        -Operation 'read focused Function settings'
    $settings | ForEach-Object { $_ }
}

function Get-RenderContainerAppState {
    param(
        [Parameter(Mandatory)]
        [string] $Subscription,

        [Parameter(Mandatory)]
        [string] $GroupName,

        [Parameter(Mandatory)]
        [string] $AppName
    )

    $json = Invoke-AzureCli `
        -Subscription $Subscription `
        -Operation 'read Render Container App state' `
        -Arguments @(
            'resource', 'show',
            '--resource-group', $GroupName,
            '--resource-type', 'Microsoft.App/containerApps',
            '--name', $AppName,
            '--api-version', $script:ContainerAppsApiVersion,
            '--query',
            '{id:id,name:name,location:location,identity:identity,properties:{provisioningState:properties.provisioningState,runningStatus:properties.runningStatus,latestRevisionName:properties.latestRevisionName,latestReadyRevisionName:properties.latestReadyRevisionName,configuration:{activeRevisionsMode:properties.configuration.activeRevisionsMode,maxInactiveRevisions:properties.configuration.maxInactiveRevisions,identitySettings:properties.configuration.identitySettings,ingress:properties.configuration.ingress,registries:properties.configuration.registries,secrets:properties.configuration.secrets},template:{containers:properties.template.containers,scale:properties.template.scale,terminationGracePeriodSeconds:properties.template.terminationGracePeriodSeconds}}}',
            '--output', 'json'
        )

    return ConvertFrom-AzureCliJson `
        -Json $json `
        -Operation 'read Render Container App state'
}

function Get-RenderAuthenticationState {
    param(
        [Parameter(Mandatory)]
        [string] $Subscription,

        [Parameter(Mandatory)]
        [string] $GroupName,

        [Parameter(Mandatory)]
        [string] $AppName
    )

    $json = Invoke-AzureCli `
        -Subscription $Subscription `
        -Operation 'read Render authentication configuration' `
        -Arguments @(
            'containerapp', 'auth', 'show',
            '--resource-group', $GroupName,
            '--name', $AppName,
            '--query',
            "{propertyCount:length(keys(@)),hasPlatform:contains(keys(@), 'platform'),platformEnabled:platform.enabled}",
            '--output', 'json'
        )

    $state = ConvertFrom-AzureCliJson `
        -Json $json `
        -Operation 'read Render authentication configuration'
    if ([int] $state.propertyCount -eq 0) {
        return [pscustomobject]@{
            value = @()
        }
    }
    if ($state.hasPlatform -ne $true) {
        throw 'Render authentication exists without a platform configuration.'
    }

    return [pscustomobject]@{
        value = @(
            [pscustomobject]@{
                name = 'current'
                platformEnabled = $state.platformEnabled
            }
        )
    }
}

function Get-RenderRevisions {
    param(
        [Parameter(Mandatory)]
        [string] $Subscription,

        [Parameter(Mandatory)]
        [string] $ContainerAppResourceId
    )

    $uri =
        "$($ContainerAppResourceId.TrimEnd('/'))/revisions" +
        "?api-version=$script:ContainerAppsApiVersion"
    $json = Invoke-AzureCli `
        -Subscription $Subscription `
        -Operation 'list Render revisions' `
        -Arguments @(
            'rest',
            '--method', 'get',
            '--uri', $uri,
            '--query',
            '{value:value[].{name:name,active:properties.active,healthState:properties.healthState,provisioningState:properties.provisioningState}}',
            '--output', 'json'
        )

    return ConvertFrom-AzureCliJson `
        -Json $json `
        -Operation 'list Render revisions'
}

function Get-RevisionReplicas {
    param(
        [Parameter(Mandatory)]
        [string] $Subscription,

        [Parameter(Mandatory)]
        [string] $ContainerAppResourceId,

        [Parameter(Mandatory)]
        [string] $RevisionName
    )

    $escapedRevision = [uri]::EscapeDataString($RevisionName)
    $uri =
        "$($ContainerAppResourceId.TrimEnd('/'))/revisions/" +
        "$escapedRevision/replicas?api-version=$script:ContainerAppsApiVersion"
    $json = Invoke-AzureCli `
        -Subscription $Subscription `
        -Operation 'list Render revision replicas' `
        -Arguments @(
            'rest',
            '--method', 'get',
            '--uri', $uri,
            '--query',
            '{value:value[].{name:name,runningState:properties.runningState}}',
            '--output', 'json'
        )
    $state = ConvertFrom-AzureCliJson `
        -Json $json `
        -Operation 'list Render revision replicas'

    return @($state.value)
}

function Assert-AccountConfiguration {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $State,

        [Parameter(Mandatory)]
        [string] $ExpectedSubscription,

        [Parameter(Mandatory)]
        [string] $ExpectedTenant
    )

    $actualSubscription = ConvertTo-CanonicalGuid `
        -Value ([string] $State.id) `
        -ParameterName 'Azure account subscription ID'
    $actualTenant = ConvertTo-CanonicalGuid `
        -Value ([string] $State.tenantId) `
        -ParameterName 'Azure account tenant ID'

    if ($actualSubscription -ne $ExpectedSubscription) {
        throw 'Azure CLI returned a different subscription than requested.'
    }
    if ($actualTenant -ne $ExpectedTenant) {
        throw 'The selected subscription belongs to a different tenant.'
    }
    if ([string] $State.state -ne 'Enabled') {
        throw "The selected subscription state is '$($State.state)'."
    }

    return [ordered]@{
        subscriptionId = $actualSubscription
        tenantId = $actualTenant
        state = [string] $State.state
        name = [string] $State.name
    }
}

function Assert-FunctionConfiguration {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $State,

        [Parameter(Mandatory)]
        [object[]] $Settings,

        [Parameter(Mandatory)]
        [string] $ExpectedTenant,

        [Parameter(Mandatory)]
        [string] $ExpectedRenderUrl,

        [Parameter(Mandatory)]
        [string] $ExpectedAudience
    )

    if ($State.properties.state -ne 'Running' -or
        $State.properties.enabled -ne $true) {
        throw 'The Function App is not running and enabled.'
    }
    if ($State.properties.httpsOnly -ne $true -or
        $State.properties.publicNetworkAccess -ne 'Enabled') {
        throw 'The Function App is not public and HTTPS-only.'
    }
    if ([string] $State.kind -notmatch 'functionapp' -or
        [string] $State.kind -notmatch 'linux') {
        throw "The Function App kind '$($State.kind)' is not Linux Functions."
    }
    if ([string]::IsNullOrWhiteSpace(
            [string] $State.properties.defaultHostName)) {
        throw 'The Function App has no default host name.'
    }

    $runtime = $State.properties.functionAppConfig.runtime
    if ($runtime.name -ne 'dotnet-isolated' -or
        [string] $runtime.version -ne '10.0') {
        throw 'The Function App runtime is not .NET isolated 10.0.'
    }

    $scale = $State.properties.functionAppConfig.scaleAndConcurrency
    if ([int] $scale.instanceMemoryMB -ne 2048 -or
        [int] $scale.maximumInstanceCount -ne 1) {
        throw 'The Function App scale contract is not 2048 MiB and one instance.'
    }

    $identity = $State.identity
    if ($null -eq $identity -or $identity.type -ne 'SystemAssigned') {
        throw 'The Function App does not have exactly a system-assigned identity.'
    }
    $userAssigned = Get-OptionalPropertyValue `
        -InputObject $identity `
        -Name 'userAssignedIdentities'
    if ($null -ne $userAssigned -and
        @($userAssigned.PSObject.Properties.Name).Count -ne 0) {
        throw 'The Function App unexpectedly has a user-assigned identity.'
    }

    $principalId = ConvertTo-CanonicalGuid `
        -Value ([string] $identity.principalId) `
        -ParameterName 'Function principal ID'
    $identityTenant = ConvertTo-CanonicalGuid `
        -Value ([string] $identity.tenantId) `
        -ParameterName 'Function identity tenant ID'
    if ($identityTenant -ne $ExpectedTenant) {
        throw 'The Function identity belongs to a different tenant.'
    }

    $baseUrlSettings = @(
        $Settings | Where-Object name -EQ 'RenderService__BaseUrl'
    )
    $audienceSettings = @(
        $Settings | Where-Object name -EQ 'RenderService__Audience'
    )
    if ($baseUrlSettings.Count -ne 1 -or
        [string] $baseUrlSettings[0].value -cne $ExpectedRenderUrl) {
        throw 'RenderService__BaseUrl does not match the deployed Render URL.'
    }
    if ($audienceSettings.Count -ne 1 -or
        [string] $audienceSettings[0].value -cne $ExpectedAudience) {
        throw 'RenderService__Audience does not match the Render API audience.'
    }

    return [ordered]@{
        name = [string] $State.name
        state = [string] $State.properties.state
        httpsOnly = [bool] $State.properties.httpsOnly
        publicNetworkAccess = [string] $State.properties.publicNetworkAccess
        runtime = [ordered]@{
            name = [string] $runtime.name
            version = [string] $runtime.version
        }
        identity = [ordered]@{
            type = [string] $identity.type
            principalId = $principalId
            tenantId = $identityTenant
        }
        renderSettings = [ordered]@{
            baseUrl = $ExpectedRenderUrl
            audience = $ExpectedAudience
        }
    }
}

function Assert-RenderContainerConfiguration {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $State,

        [Parameter(Mandatory)]
        [string] $ExpectedImage,

        [Parameter(Mandatory)]
        [string] $ExpectedIdentityId
    )

    if ($State.properties.provisioningState -ne 'Succeeded') {
        throw "Render provisioning state is '$($State.properties.provisioningState)'."
    }

    $identity = $State.identity
    if ($null -eq $identity -or $identity.type -ne 'UserAssigned') {
        throw 'Render does not have exactly a user-assigned identity.'
    }
    $identityMap = Get-OptionalPropertyValue `
        -InputObject $identity `
        -Name 'userAssignedIdentities'
    $identityIds = if ($null -eq $identityMap) {
        @()
    }
    else {
        @($identityMap.PSObject.Properties.Name)
    }
    if ($identityIds.Count -ne 1 -or
        $identityIds[0] -ine $ExpectedIdentityId) {
        throw 'Render does not have exactly the planned ACR identity.'
    }

    $configuration = $State.properties.configuration
    if ($configuration.activeRevisionsMode -ne 'Single') {
        throw 'Render active revision mode is not Single.'
    }
    if ([int] $configuration.maxInactiveRevisions -ne 100) {
        throw 'Render max inactive revisions is not 100.'
    }

    $ingress = $configuration.ingress
    if ($ingress.external -ne $true -or
        $ingress.allowInsecure -ne $false -or
        [int] $ingress.targetPort -ne 8080 -or
        $ingress.transport -ne 'auto') {
        throw 'Render ingress is not external HTTPS on target port 8080.'
    }
    if ([string]::IsNullOrWhiteSpace([string] $ingress.fqdn)) {
        throw 'Render has no ingress FQDN.'
    }

    $registries = @($configuration.registries)
    if ($registries.Count -ne 1 -or
        $registries[0].server -cne $script:RenderRegistryServer -or
        $registries[0].identity -ine $ExpectedIdentityId) {
        throw 'Render registry configuration does not use its planned identity.'
    }

    $identitySettings = @($configuration.identitySettings)
    if ($identitySettings.Count -ne 1 -or
        $identitySettings[0].identity -ine $ExpectedIdentityId -or
        $identitySettings[0].lifecycle -ne 'None') {
        throw 'Render application identity lifecycle is not restricted to None.'
    }

    $secrets = Get-OptionalPropertyValue `
        -InputObject $configuration `
        -Name 'secrets'
    if ($null -ne $secrets -and @($secrets).Count -ne 0) {
        throw 'Render unexpectedly contains secrets.'
    }

    $containers = @($State.properties.template.containers)
    if ($containers.Count -ne 1 -or
        $containers[0].name -ne 'html2b-render') {
        throw 'Render does not contain exactly the html2b-render container.'
    }
    $container = $containers[0]
    if ($container.image -cne $ExpectedImage) {
        throw "Render image '$($container.image)' does not match the expected digest."
    }
    if ([double] $container.resources.cpu -ne 1 -or
        $container.resources.memory -ne '2Gi') {
        throw 'Render resources do not match 1 vCPU and 2Gi.'
    }

    $environment = Get-OptionalPropertyValue `
        -InputObject $container `
        -Name 'env'
    if ($null -ne $environment -and @($environment).Count -ne 0) {
        throw 'Render unexpectedly contains application settings.'
    }

    $expectedProbes = @{
        Startup = @{
            Path = '/health/ready'
            Initial = 1
            Period = 5
            Timeout = 5
            Failure = 10
        }
        Liveness = @{
            Path = '/health/live'
            Initial = 10
            Period = 30
            Timeout = 5
            Failure = 3
        }
        Readiness = @{
            Path = '/health/ready'
            Initial = 1
            Period = 5
            Timeout = 5
            Failure = 3
        }
    }
    $probes = @($container.probes)
    if ($probes.Count -ne 3) {
        throw "Render exposes $($probes.Count) probes instead of three."
    }
    foreach ($probe in $probes) {
        $probeType = [string] $probe.type
        if (-not $expectedProbes.ContainsKey($probeType)) {
            throw "Render contains unexpected probe '$probeType'."
        }
        $expected = $expectedProbes[$probeType]
        if ($probe.httpGet.path -ne $expected.Path -or
            [int] $probe.httpGet.port -ne 8080 -or
            $probe.httpGet.scheme -ne 'HTTP' -or
            [int] $probe.initialDelaySeconds -ne $expected.Initial -or
            [int] $probe.periodSeconds -ne $expected.Period -or
            [int] $probe.timeoutSeconds -ne $expected.Timeout -or
            [int] $probe.failureThreshold -ne $expected.Failure -or
            [int] $probe.successThreshold -ne 1) {
            throw "Render $probeType probe does not match the Bicep contract."
        }
    }

    $template = $State.properties.template
    if ([int] $template.terminationGracePeriodSeconds -ne 30) {
        throw 'Render termination grace period is not 30 seconds.'
    }
    $scale = $template.scale
    if ([int] $scale.minReplicas -ne 0 -or
        [int] $scale.maxReplicas -ne 1 -or
        [int] $scale.pollingInterval -ne 30 -or
        [int] $scale.cooldownPeriod -ne 300) {
        throw 'Render scale timing or replica limits have drifted.'
    }
    $rules = @($scale.rules)
    if ($rules.Count -ne 1 -or
        $rules[0].name -ne 'http-one-render' -or
        [string] $rules[0].http.metadata.concurrentRequests -ne '1') {
        throw 'Render HTTP concurrency contract is not one active render.'
    }

    if ([string]::IsNullOrWhiteSpace(
            [string] $State.properties.latestRevisionName) -or
        $State.properties.latestRevisionName -ne
            $State.properties.latestReadyRevisionName) {
        throw 'The latest Render revision is not the latest ready revision.'
    }

    return [ordered]@{
        name = [string] $State.name
        provisioningState = [string] $State.properties.provisioningState
        runningStatus = [string] $State.properties.runningStatus
        image = [string] $container.image
        identityId = $ExpectedIdentityId
        ingress = [ordered]@{
            external = [bool] $ingress.external
            allowInsecure = [bool] $ingress.allowInsecure
            targetPort = [int] $ingress.targetPort
            transport = [string] $ingress.transport
            fqdn = [string] $ingress.fqdn
        }
        revision = [string] $State.properties.latestRevisionName
        scale = [ordered]@{
            minReplicas = [int] $scale.minReplicas
            maxReplicas = [int] $scale.maxReplicas
            concurrentRequests = [string] $rules[0].http.metadata.concurrentRequests
        }
    }
}

function Assert-RenderAuthenticationDisabled {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $State
    )

    $configurations = @($State.value)
    if ($configurations.Count -eq 0) {
        return [ordered]@{
            state = 'absent'
            enabled = $false
        }
    }
    if ($configurations.Count -ne 1 -or
        $configurations[0].name -ne 'current') {
        throw 'Render contains unexpected authentication configurations.'
    }
    if ($configurations[0].platformEnabled -isnot [bool] -or
        $configurations[0].platformEnabled -ne $false) {
        throw 'Render authentication is not explicitly disabled before the P02 cutover.'
    }

    return [ordered]@{
        state = 'disabled'
        enabled = $false
    }
}

function Assert-RenderRevisionState {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $State,

        [Parameter(Mandatory)]
        [string] $LatestRevisionName
    )

    $revisions = @($State.value)
    $latest = @(
        $revisions | Where-Object name -EQ $LatestRevisionName
    )
    if ($latest.Count -ne 1 -or
        $latest[0].active -ne $true -or
        $latest[0].healthState -ne 'Healthy' -or
        $latest[0].provisioningState -notin @('Provisioned', 'Succeeded')) {
        throw 'The latest Render revision is not active, healthy, and provisioned.'
    }
    if (@($revisions | Where-Object active -EQ $true).Count -ne 1) {
        throw 'Render does not have exactly one active revision.'
    }

    return [ordered]@{
        name = [string] $latest[0].name
        active = [bool] $latest[0].active
        healthState = [string] $latest[0].healthState
        provisioningState = [string] $latest[0].provisioningState
    }
}

function New-ValidationHttpClient {
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(95)
    return $client
}

function ConvertFrom-HealthBody {
    param(
        [Parameter(Mandatory)]
        [string] $Body,

        [Parameter(Mandatory)]
        [string] $Path
    )

    try {
        $result = $Body | ConvertFrom-Json
    }
    catch {
        throw "$Path did not return valid health JSON."
    }

    return [string] $result.status
}

function Wait-EndpointStatus {
    param(
        [Parameter(Mandatory)]
        [uri] $Uri,

        [Parameter(Mandatory)]
        [string] $ExpectedBodyStatus,

        [TimeSpan] $Timeout = [TimeSpan]::FromMinutes(4)
    )

    $client = New-ValidationHttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(20)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastStatus = $null

    try {
        while ($stopwatch.Elapsed -lt $Timeout) {
            try {
                $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
                try {
                    $lastStatus = [int] $response.StatusCode
                    if ($lastStatus -eq 200) {
                        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                        $status = ConvertFrom-HealthBody `
                            -Body $body `
                            -Path $Uri.AbsolutePath
                        if ($status -eq $ExpectedBodyStatus) {
                            return [ordered]@{
                                path = $Uri.AbsolutePath
                                httpStatus = $lastStatus
                                bodyStatus = $status
                                elapsedMilliseconds =
                                    [Math]::Round(
                                        $stopwatch.Elapsed.TotalMilliseconds,
                                        1)
                            }
                        }
                    }
                }
                finally {
                    $response.Dispose()
                }
            }
            catch [System.Net.Http.HttpRequestException] {
                $lastStatus = $null
            }
            catch [System.Threading.Tasks.TaskCanceledException] {
                $lastStatus = $null
            }

            Start-Sleep -Seconds 3
        }
    }
    finally {
        $client.Dispose()
    }

    throw "Timed out waiting for $($Uri.AbsolutePath); last status was $lastStatus."
}

function Assert-ContentDisposition {
    param(
        [AllowNull()]
        [System.Net.Http.Headers.ContentDispositionHeaderValue] $Disposition,

        [Parameter(Mandatory)]
        [string] $ExpectedFileName
    )

    if ($null -eq $Disposition) {
        throw "Response omitted Content-Disposition for $ExpectedFileName."
    }
    $actualFileName = if (
        -not [string]::IsNullOrWhiteSpace($Disposition.FileNameStar)) {
        $Disposition.FileNameStar
    }
    else {
        $Disposition.FileName
    }
    if ([string]::IsNullOrWhiteSpace($actualFileName) -or
        $actualFileName.Trim('"') -ne $ExpectedFileName) {
        throw "Response filename did not match $ExpectedFileName."
    }
}

function Get-BigEndianUInt16 {
    param(
        [Parameter(Mandatory)]
        [byte[]] $Bytes,

        [Parameter(Mandatory)]
        [int] $Offset
    )

    return ([int] $Bytes[$Offset] -shl 8) -bor
        [int] $Bytes[$Offset + 1]
}

function Get-BigEndianUInt32 {
    param(
        [Parameter(Mandatory)]
        [byte[]] $Bytes,

        [Parameter(Mandatory)]
        [int] $Offset
    )

    return ([int64] $Bytes[$Offset] -shl 24) -bor
        ([int64] $Bytes[$Offset + 1] -shl 16) -bor
        ([int64] $Bytes[$Offset + 2] -shl 8) -bor
        [int64] $Bytes[$Offset + 3]
}

function Assert-FileSignature {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('png', 'jpeg', 'pdf')]
        [string] $Format,

        [Parameter(Mandatory)]
        [byte[]] $Bytes
    )

    if ($Bytes.Length -eq 0) {
        throw "$Format response was empty."
    }
    if ($Format -eq 'png') {
        if ($Bytes.Length -lt 24) {
            throw 'PNG response was too short.'
        }
        $signature = [byte[]] @(
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
        for ($index = 0; $index -lt $signature.Length; $index++) {
            if ($Bytes[$index] -ne $signature[$index]) {
                throw 'PNG signature validation failed.'
            }
        }
    }
    elseif ($Format -eq 'jpeg') {
        if ($Bytes.Length -lt 4 -or
            $Bytes[0] -ne 0xff -or
            $Bytes[1] -ne 0xd8 -or
            $Bytes[-2] -ne 0xff -or
            $Bytes[-1] -ne 0xd9) {
            throw 'JPEG signature validation failed.'
        }
    }
    else {
        if ($Bytes.Length -lt 5 -or
            [System.Text.Encoding]::ASCII.GetString($Bytes, 0, 5) -ne
                '%PDF-') {
            throw 'PDF signature validation failed.'
        }
    }
}

function Assert-RasterDimensions {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('png', 'jpeg')]
        [string] $Format,

        [Parameter(Mandatory)]
        [byte[]] $Bytes
    )

    if ($Format -eq 'png') {
        $width = Get-BigEndianUInt32 -Bytes $Bytes -Offset 16
        $height = Get-BigEndianUInt32 -Bytes $Bytes -Offset 20
    }
    else {
        $offset = 2
        $width = 0
        $height = 0
        $startOfFrameMarkers = @(
            0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7,
            0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf)
        while ($offset + 8 -lt $Bytes.Length) {
            if ($Bytes[$offset] -ne 0xff) {
                $offset++
                continue
            }
            while ($offset -lt $Bytes.Length -and
                $Bytes[$offset] -eq 0xff) {
                $offset++
            }
            if ($offset -ge $Bytes.Length) {
                break
            }
            $marker = $Bytes[$offset]
            $offset++
            if ($marker -eq 0xd8 -or
                $marker -eq 0xd9 -or
                ($marker -ge 0xd0 -and $marker -le 0xd7)) {
                continue
            }
            if ($offset + 1 -ge $Bytes.Length) {
                break
            }
            $segmentLength = Get-BigEndianUInt16 `
                -Bytes $Bytes `
                -Offset $offset
            if ($startOfFrameMarkers -contains $marker) {
                if ($offset + 6 -ge $Bytes.Length) {
                    break
                }
                $height = Get-BigEndianUInt16 `
                    -Bytes $Bytes `
                    -Offset ($offset + 3)
                $width = Get-BigEndianUInt16 `
                    -Bytes $Bytes `
                    -Offset ($offset + 5)
                break
            }
            if ($segmentLength -lt 2) {
                break
            }
            $offset += $segmentLength
        }
    }

    if ($width -ne $script:ExpectedWidth -or
        $height -ne $script:ExpectedHeight) {
        throw "$Format dimensions were ${width}x${height}, expected 1280x720."
    }

    return [ordered]@{
        width = $width
        height = $height
    }
}

function Assert-PdfPageSize {
    param(
        [Parameter(Mandatory)]
        [byte[]] $Bytes
    )

    $pdfText = [System.Text.Encoding]::ASCII.GetString($Bytes)
    $mediaBoxes = [regex]::Matches(
        $pdfText,
        '/MediaBox\s*\[\s*([-+]?\d*\.?\d+)\s+([-+]?\d*\.?\d+)\s+([-+]?\d*\.?\d+)\s+([-+]?\d*\.?\d+)\s*\]')
    foreach ($mediaBox in $mediaBoxes) {
        $values = 1..4 | ForEach-Object {
            [double]::Parse(
                $mediaBox.Groups[$_].Value,
                [System.Globalization.CultureInfo]::InvariantCulture)
        }
        if ([Math]::Abs($values[0]) -lt 0.1 -and
            [Math]::Abs($values[1]) -lt 0.1 -and
            [Math]::Abs(
                $values[2] - $script:ExpectedPdfWidthPoints) -lt 0.1 -and
            [Math]::Abs(
                $values[3] - $script:ExpectedPdfHeightPoints) -lt 0.1) {
            return [ordered]@{
                widthPoints = $script:ExpectedPdfWidthPoints
                heightPoints = $script:ExpectedPdfHeightPoints
            }
        }
    }

    throw 'PDF page box did not match 960x540 points.'
}

function Invoke-HealthContract {
    param(
        [Parameter(Mandatory)]
        [System.Net.Http.HttpClient] $Client,

        [Parameter(Mandatory)]
        [uri] $Uri,

        [Parameter(Mandatory)]
        [string] $ExpectedBodyStatus,

        [Parameter(Mandatory)]
        [string] $Phase,

        [Parameter(Mandatory)]
        [string] $Host,

        [switch] $ReturnFailure
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $response = $Client.GetAsync($Uri).GetAwaiter().GetResult()
    try {
        $httpStatus = [int] $response.StatusCode
        $elapsedMilliseconds =
            [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 1)
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $bodyStatus = $null
        try {
            $bodyStatus = ConvertFrom-HealthBody `
                -Body $body `
                -Path $Uri.AbsolutePath
        }
        catch {
            if (-not $ReturnFailure) {
                throw
            }
        }

        $result = [ordered]@{
            host = $Host
            phase = $Phase
            method = 'GET'
            path = $Uri.AbsolutePath
            httpStatus = $httpStatus
            bodyStatus = $bodyStatus
            elapsedMilliseconds = $elapsedMilliseconds
        }

        if ($httpStatus -ne 200 -or
            $bodyStatus -ne $ExpectedBodyStatus) {
            if ($ReturnFailure) {
                return $result
            }

            throw "$Host $Phase $($Uri.AbsolutePath) returned HTTP $httpStatus with health status '$bodyStatus' after $elapsedMilliseconds ms."
        }

        return $result
    }
    finally {
        $response.Dispose()
    }
}

function Invoke-RenderContract {
    param(
        [Parameter(Mandatory)]
        [System.Net.Http.HttpClient] $Client,

        [Parameter(Mandatory)]
        [uri] $Uri,

        [Parameter(Mandatory)]
        [ValidateSet('png', 'jpeg', 'pdf')]
        [string] $Format,

        [Parameter(Mandatory)]
        [string] $Phase,

        [Parameter(Mandatory)]
        [string] $Host,

        [switch] $DirectRender
    )

    $contracts = @{
        png = @{
            ContentType = 'image/png'
            FileName = 'html2b-poc.png'
        }
        jpeg = @{
            ContentType = 'image/jpeg'
            FileName = 'html2b-poc.jpg'
        }
        pdf = @{
            ContentType = 'application/pdf'
            FileName = 'html2b-poc.pdf'
        }
    }
    $contract = $contracts[$Format]
    [System.Net.Http.HttpContent] $content = $null
    if ($DirectRender) {
        $payload = @{ format = $Format } | ConvertTo-Json -Compress
        $content = [System.Net.Http.StringContent]::new(
            $payload,
            [System.Text.Encoding]::UTF8,
            'application/json')
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $response = $Client.PostAsync($Uri, $content).GetAwaiter().GetResult()
        try {
            $httpStatus = [int] $response.StatusCode
            if ($httpStatus -ne 200) {
                throw "$Host $Phase $Format returned HTTP $httpStatus."
            }

            $contentType = $response.Content.Headers.ContentType
            if ($null -eq $contentType -or
                $contentType.MediaType -ne $contract.ContentType) {
                throw "$Host $Format returned an unexpected content type."
            }
            Assert-ContentDisposition `
                -Disposition $response.Content.Headers.ContentDisposition `
                -ExpectedFileName $contract.FileName

            $response.Content.LoadIntoBufferAsync(
                $script:MaximumResponseBytes).GetAwaiter().GetResult()
            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            if ($bytes.Length -gt $script:MaximumResponseBytes) {
                throw "$Host $Format exceeded the 16 MiB response limit."
            }
            Assert-FileSignature -Format $Format -Bytes $bytes
            $dimensions = if ($Format -eq 'pdf') {
                Assert-PdfPageSize -Bytes $bytes
            }
            else {
                Assert-RasterDimensions -Format $Format -Bytes $bytes
            }

            return [ordered]@{
                host = $Host
                phase = $Phase
                method = 'POST'
                path = $Uri.AbsolutePath
                format = $Format
                httpStatus = $httpStatus
                contentType = [string] $contentType.MediaType
                fileName = [string] $contract.FileName
                byteCount = $bytes.Length
                signatureValidated = $true
                dimensions = $dimensions
                elapsedMilliseconds =
                    [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 1)
            }
        }
        finally {
            $response.Dispose()
        }
    }
    finally {
        if ($null -ne $content) {
            $content.Dispose()
        }
    }
}

function Invoke-FunctionContractValidation {
    param(
        [Parameter(Mandatory)]
        [System.Net.Http.HttpClient] $Client,

        [Parameter(Mandatory)]
        [uri] $BaseUri,

        [string] $Phase = 'warm'
    )

    $results = @()
    $results += Invoke-HealthContract `
        -Client $Client `
        -Uri ([uri]::new($BaseUri, 'health/live')) `
        -ExpectedBodyStatus 'live' `
        -Phase $Phase `
        -Host 'Function'
    $results += Invoke-HealthContract `
        -Client $Client `
        -Uri ([uri]::new($BaseUri, 'health/ready')) `
        -ExpectedBodyStatus 'ready' `
        -Phase $Phase `
        -Host 'Function'
    foreach ($format in @('png', 'jpeg', 'pdf')) {
        $results += Invoke-RenderContract `
            -Client $Client `
            -Uri ([uri]::new($BaseUri, "api/renders/$format")) `
            -Format $format `
            -Phase $Phase `
            -Host 'Function'
    }

    return $results
}

function Invoke-DirectRenderContractValidation {
    param(
        [Parameter(Mandatory)]
        [System.Net.Http.HttpClient] $Client,

        [Parameter(Mandatory)]
        [uri] $BaseUri,

        [string] $Phase = 'temporary-anonymous-p01'
    )

    $results = @()
    $results += Invoke-HealthContract `
        -Client $Client `
        -Uri ([uri]::new($BaseUri, 'health/live')) `
        -ExpectedBodyStatus 'live' `
        -Phase $Phase `
        -Host 'Render'
    $results += Invoke-HealthContract `
        -Client $Client `
        -Uri ([uri]::new($BaseUri, 'health/ready')) `
        -ExpectedBodyStatus 'ready' `
        -Phase $Phase `
        -Host 'Render'
    foreach ($format in @('png', 'jpeg', 'pdf')) {
        $results += Invoke-RenderContract `
            -Client $Client `
            -Uri ([uri]::new($BaseUri, 'internal/renders')) `
            -Format $format `
            -Phase $Phase `
            -Host 'Render' `
            -DirectRender
    }

    return $results
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
    Join-Path $repositoryRoot 'build\validation\005\p01\live'
$summaryPath = Join-Path $outputDirectory 'validation-summary.json'
$validation = [ordered]@{
    phase = 'P01'
    status = 'running'
    account = $null
    function = $null
    render = $null
    renderAuthentication = $null
    revision = $null
    waits = @()
    contracts = @()
    coldWake = $null
    telemetry = [ordered]@{
        status = 'skipped'
        reason =
            'The P01 validator does not query dependency telemetry because ' +
            'worker-originated Application Insights dependency collection ' +
            'is not established by this phase.'
    }
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
    $expectedRenderIdentityId =
        "/subscriptions/$canonicalSubscriptionId/" +
        "resourceGroups/$ResourceGroupName/providers/" +
        "Microsoft.ManagedIdentity/userAssignedIdentities/" +
        $script:RenderIdentityName

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
        Assert-RenderAuthenticationDisabled `
            -State $renderAuthenticationState

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
            pngScaleToZeroSeconds = $null
            firstReadinessAttemptRetried = $false
            firstPngAttemptRetried = $false
        }
        $coldReady = Invoke-HealthContract `
            -Client $client `
            -Uri ([uri]::new($functionBaseUri, 'health/ready')) `
            -ExpectedBodyStatus 'ready' `
            -Phase 'cold-readiness' `
            -Host 'Function' `
            -ReturnFailure
        $validation.contracts += @($coldReady)
        $validation.coldWake.readinessElapsedMilliseconds =
            $coldReady.elapsedMilliseconds
        if ($coldReady.httpStatus -ne 200 -or
            $coldReady.bodyStatus -ne 'ready') {
            throw "Cold Function readiness returned HTTP $($coldReady.httpStatus) with health status '$($coldReady.bodyStatus)' after $($coldReady.elapsedMilliseconds) ms; the first attempt was not retried."
        }
        if ([double] $coldReady.elapsedMilliseconds -gt 2000) {
            throw "Cold Function readiness took $($coldReady.elapsedMilliseconds) ms and exceeded the 2-second dependency budget."
        }
        $warmReady = Invoke-HealthContract `
            -Client $client `
            -Uri ([uri]::new($functionBaseUri, 'health/ready')) `
            -ExpectedBodyStatus 'ready' `
            -Phase 'warm-after-cold-readiness' `
            -Host 'Function'
        $validation.contracts += @($warmReady)

        $validation.contracts += @(
            Invoke-FunctionContractValidation `
                -Client $client `
                -BaseUri $functionBaseUri
        )
        $validation.contracts += @(
            Invoke-DirectRenderContractValidation `
                -Client $client `
                -BaseUri $renderBaseUri
        )

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
            -Host 'Function'
        $warmPng = Invoke-RenderContract `
            -Client $client `
            -Uri ([uri]::new($functionBaseUri, 'api/renders/png')) `
            -Format 'png' `
            -Phase 'warm-after-cold-png' `
            -Host 'Function'

        $validation.contracts += @(
            $coldPng,
            $warmPng
        )
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

    $validation.status = 'passed-with-skips'
    Write-Warning $validation.telemetry.reason
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
Write-Host 'P01 two-host Azure validation passed with dependency telemetry skipped.'
