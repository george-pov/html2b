Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$script:FunctionApiVersion = '2024-04-01'
$script:ContainerAppsApiVersion = '2026-01-01'
$script:RenderRegistryServer = 'crhtml2bdev.azurecr.io'
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

function Get-RenderAuthenticationProjection {
    return @(
        '{',
        'platformEnabled:platform.enabled,',
        'unauthenticatedClientAction:globalValidation.unauthenticatedClientAction,',
        'excludedPaths:globalValidation.excludedPaths,',
        'redirectToProvider:globalValidation.redirectToProvider,',
        'requireHttps:httpSettings.requireHttps,',
        'azureActiveDirectoryEnabled:identityProviders.azureActiveDirectory.enabled,',
        'clientId:identityProviders.azureActiveDirectory.registration.clientId,',
        'openIdIssuer:identityProviders.azureActiveDirectory.registration.openIdIssuer,',
        'clientSecretSettingName:identityProviders.azureActiveDirectory.registration.clientSecretSettingName,',
        'allowedAudiences:identityProviders.azureActiveDirectory.validation.allowedAudiences,',
        'allowedApplications:identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications,',
        'allowedPrincipalIdentities:identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedPrincipals.identities,',
        'allowedPrincipalGroups:identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedPrincipals.groups,',
        'tokenStoreEnabled:login.tokenStore.enabled,',
        'tokenStoreBlobSettingName:login.tokenStore.azureBlobStorage.sasUrlSettingName,',
        'tokenStoreFileDirectory:login.tokenStore.fileSystem.directory',
        '}'
    ) -join ''
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

    $authProjection = Get-RenderAuthenticationProjection
    $json = Invoke-AzureCli `
        -Subscription $Subscription `
        -Operation 'read Render authentication configuration' `
        -Arguments @(
            'containerapp', 'auth', 'show',
            '--resource-group', $GroupName,
            '--name', $AppName,
            '--query',
            $authProjection,
            '--output', 'json'
        )

    return ConvertFrom-AzureCliJson `
        -Json $json `
        -Operation 'read Render authentication configuration'
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
    $identityIds = @(
        if ($null -ne $identityMap) {
            $identityMap.PSObject.Properties.Name
        }
    )
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

function Assert-RenderAuthenticationConfiguration {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $State,

        [Parameter(Mandatory)]
        [string] $ExpectedTenantId,

        [Parameter(Mandatory)]
        [string] $ExpectedClientId,

        [Parameter(Mandatory)]
        [string] $ExpectedPrincipalId
    )

    if ($State.platformEnabled -isnot [bool] -or
        $State.platformEnabled -ne $true) {
        throw 'Render authentication platform is not enabled.'
    }
    if ($State.unauthenticatedClientAction -cne 'Return401') {
        throw 'Render authentication does not return 401 for unauthenticated clients.'
    }
    if ($State.requireHttps -isnot [bool] -or
        $State.requireHttps -ne $true) {
        throw 'Render authentication does not require HTTPS.'
    }
    if ($State.azureActiveDirectoryEnabled -isnot [bool] -or
        $State.azureActiveDirectoryEnabled -ne $true) {
        throw 'The Render Microsoft Entra identity provider is not enabled.'
    }

    $expectedIssuer =
        "https://login.microsoftonline.com/$ExpectedTenantId/v2.0"
    if ([string] $State.openIdIssuer -cne $expectedIssuer) {
        throw 'The Render token issuer does not match the selected tenant v2 issuer.'
    }

    $actualClientId = ConvertTo-CanonicalGuid `
        -Value ([string] $State.clientId) `
        -ParameterName 'Render authentication client ID'
    if ($actualClientId -ne $ExpectedClientId) {
        throw 'The Render authentication client ID does not match the Render API.'
    }

    $allowedAudiences = @($State.allowedAudiences)
    if ($allowedAudiences.Count -ne 1) {
        throw 'Render authentication does not contain exactly one allowed audience.'
    }
    $actualAudience = ConvertTo-CanonicalGuid `
        -Value ([string] $allowedAudiences[0]) `
        -ParameterName 'Render authentication allowed audience'
    if ($actualAudience -ne $ExpectedClientId) {
        throw 'The Render allowed audience does not match the Render API client ID.'
    }

    $allowedPrincipalIdentities = @($State.allowedPrincipalIdentities)
    if ($allowedPrincipalIdentities.Count -ne 1) {
        throw 'Render authentication does not contain exactly one allowed identity.'
    }
    $actualPrincipalId = ConvertTo-CanonicalGuid `
        -Value ([string] $allowedPrincipalIdentities[0]) `
        -ParameterName 'Render authentication allowed principal'
    if ($actualPrincipalId -ne $ExpectedPrincipalId) {
        throw 'The Render allowed principal does not match the Function identity.'
    }

    $allowedApplications = @(
        $State.allowedApplications |
            Where-Object { $null -ne $_ }
    )
    if ($allowedApplications.Count -ne 0) {
        throw 'Render authentication unexpectedly allows applications.'
    }
    $allowedPrincipalGroups = @(
        $State.allowedPrincipalGroups |
            Where-Object { $null -ne $_ }
    )
    if ($allowedPrincipalGroups.Count -ne 0) {
        throw 'Render authentication unexpectedly allows groups.'
    }
    $excludedPaths = @(
        $State.excludedPaths |
            Where-Object { $null -ne $_ }
    )
    if ($excludedPaths.Count -ne 0) {
        throw 'Render authentication unexpectedly excludes public paths.'
    }
    if (-not [string]::IsNullOrWhiteSpace(
            [string] $State.redirectToProvider)) {
        throw 'Render authentication unexpectedly redirects to a provider.'
    }
    if (-not [string]::IsNullOrWhiteSpace(
            [string] $State.clientSecretSettingName)) {
        throw 'Render authentication unexpectedly references a client secret.'
    }
    if ($null -ne $State.tokenStoreEnabled -and
        ($State.tokenStoreEnabled -isnot [bool] -or
            $State.tokenStoreEnabled -ne $false)) {
        throw 'Render authentication unexpectedly enables a token store.'
    }
    if (-not [string]::IsNullOrWhiteSpace(
            [string] $State.tokenStoreBlobSettingName) -or
        -not [string]::IsNullOrWhiteSpace(
            [string] $State.tokenStoreFileDirectory)) {
        throw 'Render authentication unexpectedly configures token persistence.'
    }

    return [ordered]@{
        state = 'enabled'
        enabled = $true
        unauthenticatedClientAction =
            [string] $State.unauthenticatedClientAction
        requireHttps = [bool] $State.requireHttps
        issuer = $expectedIssuer
        clientId = $actualClientId
        allowedAudiences = @($actualAudience)
        allowedPrincipals = @($actualPrincipalId)
        allowedApplicationCount = 0
        allowedGroupCount = 0
        excludedPaths = @()
        redirectProviderConfigured = $false
        clientSecretSettingConfigured = $false
        tokenStoreEnabled = $false
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


Export-ModuleMember -Function @(
    'Assert-AccountConfiguration',
    'Assert-FunctionConfiguration',
    'Assert-RenderAuthenticationConfiguration',
    'Assert-RenderContainerConfiguration',
    'Assert-RenderRevisionState',
    'ConvertFrom-AzureCliJson',
    'ConvertTo-CanonicalGuid',
    'Get-AccountState',
    'Get-FunctionAppState',
    'Get-FunctionRenderSettings',
    'Get-RenderAuthenticationState',
    'Get-RenderContainerAppState',
    'Get-RenderRevisions',
    'Get-RevisionReplicas',
    'Invoke-AzureCli',
    'Write-SanitizedJson'
)
