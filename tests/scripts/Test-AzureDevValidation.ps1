[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$azureScripts = Join-Path $repositoryRoot 'scripts\azure'
$entryScript = Join-Path $azureScripts 'Test-AzureDev.ps1'
Import-Module `
    (Join-Path $azureScripts 'Html2b.AzureDevValidation.psm1') `
    -Force
foreach ($focusedModuleName in @(
        'Html2b.OutputContracts.psm1',
        'Html2b.AzureStateValidation.psm1',
        'Html2b.HttpValidation.psm1',
        'Html2b.TelemetryEvidence.psm1')) {
    Import-Module `
        (Join-Path $azureScripts $focusedModuleName) `
        -Force
}

$script:TestCount = 0

function Assert-Equal {
    param(
        [AllowNull()]
        [object] $Actual,

        [AllowNull()]
        [object] $Expected,

        [Parameter(Mandatory)]
        [string] $Message
    )

    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected', received '$Actual'."
    }

    $script:TestCount++
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)]
        [scriptblock] $Action,

        [Parameter(Mandatory)]
        [string] $ExpectedMessage,

        [Parameter(Mandatory)]
        [string] $Message
    )

    $actualMessage = $null
    try {
        $null = & $Action
    }
    catch {
        $actualMessage = $_.Exception.Message
    }

    if ($actualMessage -cne $ExpectedMessage) {
        throw "$Message Expected '$ExpectedMessage', received '$actualMessage'."
    }

    $script:TestCount++
}

function New-TestFunctionState {
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $TenantId,

        [Parameter(Mandatory)]
        [string] $PrincipalId,

        [Parameter(Mandatory)]
        [int] $InstanceMemoryMB,

        [Parameter(Mandatory)]
        [int] $MaximumInstanceCount
    )

    return [pscustomobject]@{
        name = $Name
        kind = 'functionapp,linux'
        identity = [pscustomobject]@{
            type = 'SystemAssigned'
            principalId = $PrincipalId
            tenantId = $TenantId
        }
        properties = [pscustomobject]@{
            state = 'Running'
            enabled = $true
            httpsOnly = $true
            publicNetworkAccess = 'Enabled'
            defaultHostName = "$Name.azurewebsites.net"
            functionAppConfig = [pscustomobject]@{
                runtime = [pscustomobject]@{
                    name = 'dotnet-isolated'
                    version = '10.0'
                }
                scaleAndConcurrency = [pscustomobject]@{
                    instanceMemoryMB = $InstanceMemoryMB
                    maximumInstanceCount = $MaximumInstanceCount
                }
            }
        }
    }
}

function New-TestRenderProbe {
    param(
        [Parameter(Mandatory)]
        [string] $Type,

        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [int] $InitialDelaySeconds,

        [Parameter(Mandatory)]
        [int] $PeriodSeconds,

        [Parameter(Mandatory)]
        [int] $FailureThreshold
    )

    return [pscustomobject]@{
        type = $Type
        httpGet = [pscustomobject]@{
            path = $Path
            port = 8080
            scheme = 'HTTP'
        }
        initialDelaySeconds = $InitialDelaySeconds
        periodSeconds = $PeriodSeconds
        timeoutSeconds = 5
        failureThreshold = $FailureThreshold
        successThreshold = 1
    }
}

function New-TestRenderState {
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $RegistryServer,

        [Parameter(Mandatory)]
        [string] $IdentityId,

        [Parameter(Mandatory)]
        [string] $Image,

        [Parameter(Mandatory)]
        [double] $Cpu,

        [Parameter(Mandatory)]
        [string] $Memory,

        [Parameter(Mandatory)]
        [int] $MinReplicas,

        [Parameter(Mandatory)]
        [int] $MaxReplicas,

        [Parameter(Mandatory)]
        [int] $HttpConcurrency
    )

    $identityProperties = [ordered]@{}
    $identityProperties[$IdentityId] = [ordered]@{}

    return [pscustomobject]@{
        name = $Name
        identity = [pscustomobject]@{
            type = 'UserAssigned'
            userAssignedIdentities = [pscustomobject] $identityProperties
        }
        properties = [pscustomobject]@{
            provisioningState = 'Succeeded'
            runningStatus = 'Running'
            latestRevisionName = "$Name--revision"
            latestReadyRevisionName = "$Name--revision"
            configuration = [pscustomobject]@{
                activeRevisionsMode = 'Single'
                maxInactiveRevisions = 100
                ingress = [pscustomobject]@{
                    external = $true
                    allowInsecure = $false
                    targetPort = 8080
                    transport = 'auto'
                    fqdn = "$Name.example"
                }
                registries = @(
                    [pscustomobject]@{
                        server = $RegistryServer
                        identity = $IdentityId
                    }
                )
                identitySettings = @(
                    [pscustomobject]@{
                        identity = $IdentityId
                        lifecycle = 'None'
                    }
                )
                secrets = @()
            }
            template = [pscustomobject]@{
                containers = @(
                    [pscustomobject]@{
                        name = 'html2b-render'
                        image = $Image
                        resources = [pscustomobject]@{
                            cpu = $Cpu
                            memory = $Memory
                        }
                        env = @()
                        probes = @(
                            New-TestRenderProbe `
                                -Type 'Startup' `
                                -Path '/health/ready' `
                                -InitialDelaySeconds 1 `
                                -PeriodSeconds 5 `
                                -FailureThreshold 10
                            New-TestRenderProbe `
                                -Type 'Liveness' `
                                -Path '/health/live' `
                                -InitialDelaySeconds 10 `
                                -PeriodSeconds 30 `
                                -FailureThreshold 3
                            New-TestRenderProbe `
                                -Type 'Readiness' `
                                -Path '/health/ready' `
                                -InitialDelaySeconds 1 `
                                -PeriodSeconds 5 `
                                -FailureThreshold 3
                        )
                    }
                )
                terminationGracePeriodSeconds = 30
                scale = [pscustomobject]@{
                    minReplicas = $MinReplicas
                    maxReplicas = $MaxReplicas
                    pollingInterval = 30
                    cooldownPeriod = 300
                    rules = @(
                        [pscustomobject]@{
                            name = 'http-one-render'
                            http = [pscustomobject]@{
                                metadata = [pscustomobject]@{
                                    concurrentRequests =
                                        [string] $HttpConcurrency
                                }
                            }
                        }
                    )
                }
            }
        }
    }
}

$azureValidationModule = Get-Module Html2b.AzureDevValidation
$azureValidationModuleAst =
    $azureValidationModule.SessionState.InvokeCommand.
        GetCommand(
            'Invoke-Html2bAzureDevValidation',
            [System.Management.Automation.CommandTypes]::Function).
        ScriptBlock.Ast.Parent.Parent
$forcedDependencyImports = @(
    $azureValidationModuleAst.FindAll(
        {
            param($Node)

            $Node -is [System.Management.Automation.Language.CommandAst] -and
            $Node.GetCommandName() -eq 'Import-Module'
        },
        $true)
)
Assert-Equal `
    $forcedDependencyImports.Count `
    3 `
    'Azure validation module dependency import count mismatch.'
foreach ($dependencyImport in $forcedDependencyImports) {
    Assert-Equal `
        ($dependencyImport.CommandElements.Extent.Text -contains '-Force') `
        $true `
        'Azure validation module can retain a stale dependency module.'
}
$requiredOrchestrationCommands = @(
    'Assert-AccountConfiguration'
    'Assert-FunctionConfiguration'
    'Assert-RenderAuthenticationConfiguration'
    'Assert-RenderContainerConfiguration'
    'Assert-RenderRevisionState'
    'ConvertTo-CanonicalGuid'
    'Get-AccountState'
    'Get-DependencyTelemetryEvidence'
    'Get-FunctionAuthorizationTelemetryEvidence'
    'Get-FunctionAppState'
    'Get-FunctionRenderSettings'
    'Get-RenderAuthenticationState'
    'Get-RenderContainerAppState'
    'Get-RenderRevisions'
    'Get-RevisionReplicas'
    'Get-WrongAudienceAccessToken'
    'Invoke-ExpectedFunctionAuthorizationRejection'
    'Invoke-FunctionContractValidation'
    'Invoke-HealthContract'
    'Invoke-RenderAuthorizationMatrix'
    'Invoke-RenderContract'
    'New-ValidationHttpClient'
    'Wait-EndpointStatus'
    'Write-SanitizedJson'
)
$missingOrchestrationCommands = @(
    & $azureValidationModule {
        param($CommandNames)

        foreach ($commandName in $CommandNames) {
            if ($null -eq (
                    Get-Command $commandName -ErrorAction SilentlyContinue)) {
                $commandName
            }
        }
    } $requiredOrchestrationCommands
)
Assert-Equal `
    $missingOrchestrationCommands.Count `
    0 `
    'Azure validation module has unresolved orchestration dependencies.'

$entryCommand = Get-Command $entryScript
$entryKeyParameter = $entryCommand.Parameters['FunctionHostKeyName']
$entryKeyValidateSet = @(
    $entryKeyParameter.Attributes |
        Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
)
Assert-Equal `
    ($entryKeyValidateSet[0].ValidValues -join ',') `
    'default' `
    'Azure validator entry key-name contract mismatch.'
$entryKeyParameterAst = @(
    $entryCommand.ScriptBlock.Ast.ParamBlock.Parameters |
        Where-Object {
            $_.Name.VariablePath.UserPath -eq 'FunctionHostKeyName'
        }
)
Assert-Equal `
    $entryKeyParameterAst[0].DefaultValue.Value `
    'default' `
    'Azure validator entry key-name default mismatch.'

$orchestrationCommand = Get-Command Invoke-Html2bAzureDevValidation
$orchestrationKeyParameter =
    $orchestrationCommand.Parameters['FunctionHostKeyName']
$orchestrationKeyValidateSet = @(
    $orchestrationKeyParameter.Attributes |
        Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
)
Assert-Equal `
    ($orchestrationKeyValidateSet[0].ValidValues -join ',') `
    'default' `
    'Azure validation orchestration key-name contract mismatch.'
$orchestrationKeyParameterAst = @(
    $orchestrationCommand.ScriptBlock.Ast.Body.ParamBlock.Parameters |
        Where-Object {
            $_.Name.VariablePath.UserPath -eq 'FunctionHostKeyName'
        }
)
Assert-Equal `
    $orchestrationKeyParameterAst[0].DefaultValue.Value `
    'default' `
    'Azure validation orchestration key-name default mismatch.'

$requiredEnvironmentParameterNames = @(
    'EnvironmentName'
    'SubscriptionId'
    'ExpectedTenantId'
    'ResourceGroupName'
    'FunctionAppName'
    'RenderContainerAppName'
    'RenderApiClientId'
    'RenderRegistryServer'
    'RenderImageRepository'
    'RenderIdentityName'
    'ExpectedRenderImage'
    'ApplicationInsightsName'
    'FunctionInstanceMemoryMB'
    'FunctionMaximumInstanceCount'
    'RenderCpu'
    'RenderMemory'
    'RenderMinReplicas'
    'RenderMaxReplicas'
    'RenderHttpConcurrency'
    'OutputDirectory'
)
foreach ($parameterName in $requiredEnvironmentParameterNames) {
    foreach ($command in @($entryCommand, $orchestrationCommand)) {
        $parameter = $command.Parameters[$parameterName]
        Assert-Equal `
            ($null -ne $parameter) `
            $true `
            "$($command.Name) is missing parameter $parameterName."
        $parameterAttributes = @(
            $parameter.Attributes |
                Where-Object {
                    $_ -is [System.Management.Automation.ParameterAttribute]
                }
        )
        Assert-Equal `
            $parameterAttributes[0].Mandatory `
            $true `
            "$($command.Name) parameter $parameterName is not mandatory."
    }
}

$azureValidationSource = Get-Content `
    -LiteralPath (Join-Path $azureScripts 'Html2b.AzureDevValidation.psm1') `
    -Raw
foreach ($retiredLiteral in @(
        'crhtml2bdev.azurecr.io',
        'id-html2b-render-dev',
        'build\validation\005',
        "'P03'",
        'anonymous-p03')) {
    Assert-Equal `
        $azureValidationSource.Contains($retiredLiteral) `
        $false `
        "Azure validation retained environment-specific literal $retiredLiteral."
}

$applicationWorkflowPath = Join-Path `
    $repositoryRoot `
    '.github/workflows/daploy-azure.yml'
$infrastructureWorkflowPath = Join-Path `
    $repositoryRoot `
    '.github/workflows/deploy-azure-infrastructure.yml'
$applicationWorkflow = Get-Content `
    -LiteralPath $applicationWorkflowPath `
    -Raw
$infrastructureWorkflow = Get-Content `
    -LiteralPath $infrastructureWorkflowPath `
    -Raw
Assert-Equal `
    ($applicationWorkflow -match "'\s*\$\{\{\s*vars\.") `
    $false `
    'Application workflow interpolates an Environment value into PowerShell source.'

$workflowParameterBindings = [ordered]@{
    EnvironmentName = 'TARGET_ENVIRONMENT'
    SubscriptionId = 'AZURE_SUBSCRIPTION_ID'
    ExpectedTenantId = 'AZURE_TENANT_ID'
    ResourceGroupName = 'AZURE_RESOURCE_GROUP_NAME'
    FunctionAppName = 'AZURE_FUNCTION_APP_NAME'
    RenderContainerAppName = 'AZURE_RENDER_CONTAINER_APP_NAME'
    RenderApiClientId = 'AZURE_RENDER_API_CLIENT_ID'
    RenderRegistryServer = 'AZURE_RENDER_REGISTRY_SERVER'
    RenderImageRepository = 'AZURE_RENDER_IMAGE_REPOSITORY'
    RenderIdentityName = 'AZURE_RENDER_IDENTITY_NAME'
    ExpectedRenderImage = 'RENDER_IMAGE'
    ApplicationInsightsName = 'AZURE_APPLICATION_INSIGHTS_NAME'
    FunctionInstanceMemoryMB = 'AZURE_FUNCTION_INSTANCE_MEMORY_MB'
    FunctionMaximumInstanceCount =
        'AZURE_FUNCTION_MAXIMUM_INSTANCE_COUNT'
    RenderCpu = 'AZURE_RENDER_CPU'
    RenderMemory = 'AZURE_RENDER_MEMORY'
    RenderMinReplicas = 'AZURE_RENDER_MIN_REPLICAS'
    RenderMaxReplicas = 'AZURE_RENDER_MAX_REPLICAS'
    RenderHttpConcurrency = 'AZURE_RENDER_HTTP_CONCURRENCY'
}
foreach ($workflow in @(
        [pscustomobject]@{
            name = 'application'
            content = $applicationWorkflow
        },
        [pscustomobject]@{
            name = 'infrastructure'
            content = $infrastructureWorkflow
        })) {
    foreach ($binding in $workflowParameterBindings.GetEnumerator()) {
        $argument = "-$($binding.Key) `$env:$($binding.Value)"
        Assert-Equal `
            $workflow.content.Contains($argument) `
            $true `
            "$($workflow.name) workflow does not explicitly pass $($binding.Key)."
    }
    Assert-Equal `
        $workflow.content.Contains('-OutputDirectory') `
        $true `
        "$($workflow.name) workflow does not pass a validation output directory."
}

$functionAuthorizationCommand = & $azureValidationModule {
    Get-Command Invoke-FunctionAuthorizationValidation
}
$functionAuthorizationSource =
    $functionAuthorizationCommand.ScriptBlock.ToString()
Assert-Equal `
    $azureValidationModule.ExportedCommands.ContainsKey(
        'Invoke-FunctionAuthorizationValidation') `
    $false `
    'Secret-bearing Function authorization orchestration is publicly exported.'
$functionAuthorizationKeyParameter =
    $functionAuthorizationCommand.Parameters['FunctionHostKeyName']
$functionAuthorizationKeyValidateSet = @(
    $functionAuthorizationKeyParameter.Attributes |
        Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] }
)
Assert-Equal `
    ($functionAuthorizationKeyValidateSet[0].ValidValues -join ',') `
    'default' `
    'Function authorization validation key-name contract mismatch.'
$functionAuthorizationKeyParameterAst = @(
    $functionAuthorizationCommand.ScriptBlock.Ast.Body.ParamBlock.Parameters |
        Where-Object {
            $_.Name.VariablePath.UserPath -eq 'FunctionHostKeyName'
        }
)
Assert-Equal `
    $functionAuthorizationKeyParameterAst[0].DefaultValue.Value `
    'default' `
    'Function authorization validation key-name default mismatch.'
Assert-Equal `
    $functionAuthorizationSource.Contains(
        'Assert-ExpectedFunctionBaseUri -BaseUri $BaseUri -AppName $AppName') `
    $true `
    'Function authorization orchestration does not enforce its exact origin.'

$keyHelperSource = & $azureValidationModule {
    (Get-Command Get-ExistingDefaultFunctionHostKey).ScriptBlock.ToString()
}
$keyHelperThrowText = & $azureValidationModule {
    (Get-Command Get-ExistingDefaultFunctionHostKey).ScriptBlock.Ast.FindAll(
        {
            param($Node)
            $Node -is [System.Management.Automation.Language.ThrowStatementAst]
        },
        $true).Extent.Text -join "`n"
}
Assert-Equal `
    $azureValidationModule.ExportedCommands.ContainsKey(
        'Get-ExistingDefaultFunctionHostKey') `
    $false `
    'Plaintext Function host-key retrieval is publicly exported.'
Assert-Equal `
    $azureValidationModule.ExportedCommands.ContainsKey(
        'Test-ExistingDefaultFunctionHostKey') `
    $true `
    'Sanitized Function host-key preflight is not exported.'
Assert-Equal `
    ($keyHelperSource -match 'Invoke-AzureCli') `
    $false `
    'Function host-key retrieval uses the general Azure CLI helper.'
Assert-Equal `
    $keyHelperSource.Contains('& az functionapp keys list') `
    $true `
    'Function host-key retrieval command mismatch.'
Assert-Equal `
    $keyHelperSource.Contains("--query 'functionKeys.default'") `
    $true `
    'Function host-key retrieval query mismatch.'
Assert-Equal `
    $keyHelperSource.Contains('--output tsv') `
    $true `
    'Function host-key retrieval output mode mismatch.'
Assert-Equal `
    $keyHelperSource.Contains('--only-show-errors') `
    $true `
    'Function host-key retrieval error-handling mismatch.'
foreach ($redirectedStream in @(
        '2>$null',
        '3>$null',
        '4>$null',
        '5>$null',
        '6>$null')) {
    Assert-Equal `
        $keyHelperSource.Contains($redirectedStream) `
        $true `
        "Function host-key retrieval does not suppress $redirectedStream."
}
Assert-Equal `
    ($keyHelperThrowText -match '\$functionHostKey') `
    $false `
    'Function host-key failure text can expose captured secret material.'

$sentinelFunctionKey = 'sentinel-function-key-never-emit'
$privateKeyProbe = & $azureValidationModule {
    param($SentinelFunctionKey)

    function az {
        $global:LASTEXITCODE = 0
        $SentinelFunctionKey
    }

    $functionHostKey = $null
    try {
        $functionHostKey = Get-ExistingDefaultFunctionHostKey `
            -Subscription 'subscription-id' `
            -GroupName 'resource-group' `
            -AppName 'func-html2b-api-dev'
        [ordered]@{
            matched = $functionHostKey -ceq $SentinelFunctionKey
        }
    }
    finally {
        $functionHostKey = $null
        Remove-Item Function:\az -ErrorAction SilentlyContinue
        $global:LASTEXITCODE = 0
    }
} $sentinelFunctionKey
Assert-Equal `
    $privateKeyProbe.matched `
    $true `
    'Private Function host-key retrieval did not capture the exact CLI value.'

$safePreflightStreams = @(
    & $azureValidationModule {
        param($SentinelFunctionKey)

        function az {
            Write-Warning $SentinelFunctionKey
            Write-Verbose $SentinelFunctionKey -Verbose
            Write-Debug $SentinelFunctionKey -Debug
            Write-Information $SentinelFunctionKey -InformationAction Continue
            $global:LASTEXITCODE = 0
            $SentinelFunctionKey
        }

        try {
            Test-ExistingDefaultFunctionHostKey `
                -Subscription 'subscription-id' `
                -GroupName 'resource-group' `
                -AppName 'func-html2b-api-dev'
        }
        finally {
            Remove-Item Function:\az -ErrorAction SilentlyContinue
            $global:LASTEXITCODE = 0
        }
    } $sentinelFunctionKey *>&1
)
Assert-Equal `
    $safePreflightStreams.Count `
    1 `
    'Sanitized Function host-key preflight emitted unexpected streams.'
$safePreflight = $safePreflightStreams[0]
Assert-Equal `
    (($safePreflight.Keys | Sort-Object) -join ',') `
    'keyName,status' `
    'Sanitized Function host-key preflight returned unexpected fields.'
Assert-Equal `
    $safePreflight.keyName `
    'default' `
    'Sanitized Function host-key preflight key name mismatch.'
Assert-Equal `
    $safePreflight.status `
    'passed' `
    'Sanitized Function host-key preflight status mismatch.'
Assert-Equal `
    (($safePreflightStreams | ConvertTo-Json -Depth 10) -match
        [regex]::Escape($sentinelFunctionKey)) `
    $false `
    'Sanitized Function host-key preflight exposed secret material.'

Assert-Throws `
    -Action {
        & $azureValidationModule {
            function az {
                $global:LASTEXITCODE = 0
                ' '
            }

            try {
                Test-ExistingDefaultFunctionHostKey `
                    -Subscription 'subscription-id' `
                    -GroupName 'resource-group' `
                    -AppName 'func-html2b-api-dev'
            }
            finally {
                Remove-Item Function:\az -ErrorAction SilentlyContinue
                $global:LASTEXITCODE = 0
            }
        }
    } `
    -ExpectedMessage 'The existing default Function host key is missing.' `
    -Message 'Function host-key preflight accepted blank CLI output.'

Assert-Throws `
    -Action {
        & $azureValidationModule {
            param($SentinelFunctionKey)

            function az {
                $global:LASTEXITCODE = 9
                $SentinelFunctionKey
            }

            try {
                Test-ExistingDefaultFunctionHostKey `
                    -Subscription 'subscription-id' `
                    -GroupName 'resource-group' `
                    -AppName 'func-html2b-api-dev'
            }
            finally {
                Remove-Item Function:\az -ErrorAction SilentlyContinue
                $global:LASTEXITCODE = 0
            }
        } $sentinelFunctionKey
    } `
    -ExpectedMessage 'Unable to read the existing default Function host key.' `
    -Message 'Function host-key preflight exposed nonzero CLI output.'

foreach ($invalidFunctionBaseUri in @(
        [uri] 'http://func-html2b-api-dev.azurewebsites.net/',
        [uri] 'https://attacker.example/')) {
    Assert-Throws `
        -Action {
            & $azureValidationModule {
                param($InvalidFunctionBaseUri)

                Assert-ExpectedFunctionBaseUri `
                    -AppName 'func-html2b-api-dev' `
                    -BaseUri $InvalidFunctionBaseUri
            } $invalidFunctionBaseUri
        } `
        -ExpectedMessage `
            'Function validation requires the expected HTTPS Function origin.' `
        -Message 'Function authorization accepted an unsafe Function origin.'
}

$rendersFunctionSource = Get-Content `
    (Join-Path $repositoryRoot `
        'src\api\Html2b.AzureFunctions\Functions\RendersFunction.cs') `
    -Raw
$healthFunctionsSource = Get-Content `
    (Join-Path $repositoryRoot `
        'src\api\Html2b.AzureFunctions\Functions\HealthFunctions.cs') `
    -Raw
$functionTriggerSource =
    $rendersFunctionSource + "`n" + $healthFunctionsSource
Assert-Equal `
    ([regex]::Matches(
        $functionTriggerSource,
        'AuthorizationLevel\.Function').Count) `
    2 `
    'Function trigger authorization count mismatch.'
Assert-Equal `
    ([regex]::Matches(
        $functionTriggerSource,
        'AuthorizationLevel\.Anonymous').Count) `
    1 `
    'Anonymous Function trigger count mismatch.'
Assert-Equal `
    ($rendersFunctionSource -match
        '(?s)\[Function\("RenderPoc"\)\].+AuthorizationLevel\.Function.+Route = "api/renders/\{format\}"') `
    $true `
    'RenderPoc is not the expected Function-authorized trigger.'
Assert-Equal `
    ($healthFunctionsSource -match
        '(?s)\[Function\("HealthLive"\)\].+?AuthorizationLevel\.Anonymous.+?Route = "health/live"') `
    $true `
    'HealthLive is not the expected anonymous trigger.'
Assert-Equal `
    ($healthFunctionsSource -match
        '(?s)\[Function\("HealthReady"\)\].+?AuthorizationLevel\.Function.+?Route = "health/ready"') `
    $true `
    'HealthReady is not the expected Function-authorized trigger.'

$httpRequestSource = Get-Content `
    (Join-Path $repositoryRoot `
        'src\api\Html2b.AzureFunctions\Html2b.AzureFunctions.http') `
    -Raw
Assert-Equal `
    ([regex]::Matches(
        $httpRequestSource,
        '(?m)^@Html2b\.AzureFunctions_FunctionKey = <function-key>\r?$').Count) `
    1 `
    'Function request samples do not declare the exact key placeholder once.'
Assert-Equal `
    ([regex]::Matches(
        $httpRequestSource,
        '(?m)^x-functions-key: \{\{Html2b\.AzureFunctions_FunctionKey\}\}\r?$').Count) `
    5 `
    'Function request samples do not have the expected placeholder headers.'
$httpRequestBlocks = @(
    $httpRequestSource -split '(?m)^###\s*$'
)
$liveRequestBlock = @(
    $httpRequestBlocks |
        Where-Object { $_ -match '/health/live' }
)
Assert-Equal `
    $liveRequestBlock.Count `
    1 `
    'Function request samples have an invalid liveness block.'
Assert-Equal `
    ($liveRequestBlock[0] -match '(?m)^x-functions-key:') `
    $false `
    'Function liveness request sample unexpectedly sends a key.'
foreach ($keyedPath in @(
        '/health/ready',
        '/api/renders/png',
        '/api/renders/jpeg',
        '/api/renders/pdf',
        '/api/renders/gif')) {
    $keyedRequestBlock = @(
        $httpRequestBlocks |
            Where-Object { $_ -match [regex]::Escape($keyedPath) }
    )
    Assert-Equal `
        $keyedRequestBlock.Count `
        1 `
        "Function request samples have an invalid $keyedPath block."
    Assert-Equal `
        ([regex]::Matches(
            $keyedRequestBlock[0],
            '(?m)^x-functions-key: \{\{Html2b\.AzureFunctions_FunctionKey\}\}\r?$').Count) `
        1 `
        "Function request sample $keyedPath does not send the placeholder key."
}

$azureStateValidationModule = Get-Module Html2b.AzureStateValidation
$authProjection = & $azureStateValidationModule {
    Get-RenderAuthenticationProjection
}
Assert-Equal `
    ($authProjection -match '[\r\n]') `
    $false `
    'Render authentication projection contains a Windows-unsafe line break.'
Assert-Equal `
    ($authProjection.StartsWith('{') -and $authProjection.EndsWith('}')) `
    $true `
    'Render authentication projection is not one JMESPath object.'

$pngBytes = [byte[]]::new(24)
[byte[]] $pngSignature = @(
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
[Array]::Copy($pngSignature, $pngBytes, $pngSignature.Length)
$pngBytes[16] = 0x00
$pngBytes[17] = 0x00
$pngBytes[18] = 0x05
$pngBytes[19] = 0x00
$pngBytes[20] = 0x00
$pngBytes[21] = 0x00
$pngBytes[22] = 0x02
$pngBytes[23] = 0xd0

$pngResult = Assert-Html2bOutputContract `
    -Format 'png' `
    -Bytes $pngBytes `
    -ContentType 'image/png' `
    -FileName 'html2b-poc.png'
Assert-Equal $pngResult.dimensions.width 1280 'PNG width mismatch.'
Assert-Equal $pngResult.dimensions.height 720 'PNG height mismatch.'
Assert-Equal $pngResult.signatureValidated $true 'PNG signature was not validated.'

[byte[]] $jpegBytes = @(
    0xff, 0xd8,
    0xff, 0xc0, 0x00, 0x11, 0x08, 0x02, 0xd0, 0x05, 0x00,
    0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x00, 0x03, 0x11, 0x00,
    0xff, 0xd9)
$jpegResult = Assert-Html2bOutputContract `
    -Format 'jpeg' `
    -Bytes $jpegBytes `
    -ContentType 'image/jpeg' `
    -FileName 'html2b-poc.jpg'
Assert-Equal $jpegResult.dimensions.width 1280 'JPEG width mismatch.'
Assert-Equal $jpegResult.dimensions.height 720 'JPEG height mismatch.'

$pdfText = @'
%PDF-1.7
1 0 obj
<< /MediaBox [0 0 960 540] >>
endobj
'@
$pdfBytes = [System.Text.Encoding]::ASCII.GetBytes($pdfText)
$pdfResult = Assert-Html2bOutputContract `
    -Format 'pdf' `
    -Bytes $pdfBytes `
    -ContentType 'application/pdf' `
    -FileName 'html2b-poc.pdf'
Assert-Equal $pdfResult.dimensions.widthPoints 960 'PDF width mismatch.'
Assert-Equal $pdfResult.dimensions.heightPoints 540 'PDF height mismatch.'

Assert-Throws `
    -Action {
        Assert-Html2bOutputContract `
            -Format 'png' `
            -Bytes $pngBytes `
            -ContentType 'image/png' `
            -FileName 'wrong.png'
    } `
    -ExpectedMessage 'png returned an unexpected filename.' `
    -Message 'Output validation accepted the wrong filename.'

$tenantId = '11111111-1111-1111-1111-111111111111'
$clientId = '22222222-2222-2222-2222-222222222222'
$principalId = '33333333-3333-3333-3333-333333333333'

$environmentContracts = @(
    [pscustomobject]@{
        environment = 'dev'
        resourceGroup = 'rg-render-dev'
        functionName = 'func-render-dev'
        renderName = 'ca-render-dev'
        registryServer = 'registry.dev.azurecr.io'
        imageRepository = 'team/render.v1'
        identityName = 'id-render-dev'
        digestCharacter = 'a'
        functionMemory = 2048
        functionMaximumInstances = 1
        renderCpu = 1.0
        renderMemory = '2Gi'
        renderMinReplicas = 0
        renderMaxReplicas = 1
        renderHttpConcurrency = 1
    },
    [pscustomobject]@{
        environment = 'staging'
        resourceGroup = 'rg-render-staging'
        functionName = 'func-render-staging'
        renderName = 'ca-render-staging'
        registryServer = 'registry.staging.azurecr.io'
        imageRepository = 'products/render.v2'
        identityName = 'id-render-staging'
        digestCharacter = 'b'
        functionMemory = 4096
        functionMaximumInstances = 4
        renderCpu = 0.5
        renderMemory = '1Gi'
        renderMinReplicas = 0
        renderMaxReplicas = 3
        renderHttpConcurrency = 2
    }
)

foreach ($contract in $environmentContracts) {
    $identityId = Get-ExpectedRenderIdentityId `
        -SubscriptionId $tenantId `
        -ResourceGroupName $contract.resourceGroup `
        -RenderIdentityName $contract.identityName
    $image =
        "$($contract.registryServer)/$($contract.imageRepository)" +
        "@sha256:$($contract.digestCharacter * 64)"
    $imageAccepted = & $azureValidationModule {
        param($Image, $RegistryServer, $ImageRepository)

        Assert-ImmutableRenderImageReference `
            -Image $Image `
            -RegistryServer $RegistryServer `
            -ImageRepository $ImageRepository
        return $true
    } $image $contract.registryServer $contract.imageRepository
    Assert-Equal `
        $imageAccepted `
        $true `
        "Immutable image validation rejected $($contract.environment)."

    $renderUrl = "https://$($contract.renderName).example"
    $functionState = New-TestFunctionState `
        -Name $contract.functionName `
        -TenantId $tenantId `
        -PrincipalId $principalId `
        -InstanceMemoryMB $contract.functionMemory `
        -MaximumInstanceCount $contract.functionMaximumInstances
    $functionSettings = @(
        [pscustomobject]@{
            name = 'RenderService__BaseUrl'
            value = $renderUrl
        },
        [pscustomobject]@{
            name = 'RenderService__Audience'
            value = "api://$clientId"
        }
    )
    $functionResult = Assert-FunctionConfiguration `
        -State $functionState `
        -Settings $functionSettings `
        -ExpectedTenant $tenantId `
        -ExpectedRenderUrl $renderUrl `
        -ExpectedAudience "api://$clientId" `
        -ExpectedInstanceMemoryMB $contract.functionMemory `
        -ExpectedMaximumInstanceCount (
            $contract.functionMaximumInstances)
    Assert-Equal `
        $functionResult.scale.instanceMemoryMB `
        $contract.functionMemory `
        "Function memory mismatch for $($contract.environment)."
    Assert-Equal `
        $functionResult.scale.maximumInstanceCount `
        $contract.functionMaximumInstances `
        "Function instance cap mismatch for $($contract.environment)."

    $renderState = New-TestRenderState `
        -Name $contract.renderName `
        -RegistryServer $contract.registryServer `
        -IdentityId $identityId `
        -Image $image `
        -Cpu $contract.renderCpu `
        -Memory $contract.renderMemory `
        -MinReplicas $contract.renderMinReplicas `
        -MaxReplicas $contract.renderMaxReplicas `
        -HttpConcurrency $contract.renderHttpConcurrency
    $renderResult = Assert-RenderContainerConfiguration `
        -State $renderState `
        -ExpectedImage $image `
        -ExpectedIdentityId $identityId `
        -ExpectedRegistryServer $contract.registryServer `
        -ExpectedCpu $contract.renderCpu `
        -ExpectedMemory $contract.renderMemory `
        -ExpectedMinReplicas $contract.renderMinReplicas `
        -ExpectedMaxReplicas $contract.renderMaxReplicas `
        -ExpectedHttpConcurrency $contract.renderHttpConcurrency
    Assert-Equal `
        $renderResult.registryServer `
        $contract.registryServer `
        "Render registry mismatch for $($contract.environment)."
    Assert-Equal `
        $renderResult.scale.maxReplicas `
        $contract.renderMaxReplicas `
        "Render replica cap mismatch for $($contract.environment)."
}

$driftContract = $environmentContracts[0]
$driftIdentityId = Get-ExpectedRenderIdentityId `
    -SubscriptionId $tenantId `
    -ResourceGroupName $driftContract.resourceGroup `
    -RenderIdentityName $driftContract.identityName
$driftImage =
    "$($driftContract.registryServer)/$($driftContract.imageRepository)" +
    "@sha256:$($driftContract.digestCharacter * 64)"
$functionScaleDriftState = New-TestFunctionState `
    -Name $driftContract.functionName `
    -TenantId $tenantId `
    -PrincipalId $principalId `
    -InstanceMemoryMB ($driftContract.functionMemory + 1) `
    -MaximumInstanceCount $driftContract.functionMaximumInstances
$driftFunctionSettings = @(
    [pscustomobject]@{
        name = 'RenderService__BaseUrl'
        value = "https://$($driftContract.renderName).example"
    },
    [pscustomobject]@{
        name = 'RenderService__Audience'
        value = "api://$clientId"
    }
)
Assert-Throws `
    -Action {
        Assert-FunctionConfiguration `
            -State $functionScaleDriftState `
            -Settings $driftFunctionSettings `
            -ExpectedTenant $tenantId `
            -ExpectedRenderUrl (
                "https://$($driftContract.renderName).example") `
            -ExpectedAudience "api://$clientId" `
            -ExpectedInstanceMemoryMB $driftContract.functionMemory `
            -ExpectedMaximumInstanceCount (
                $driftContract.functionMaximumInstances)
    } `
    -ExpectedMessage `
        'The Function App scale contract does not match the selected Environment.' `
    -Message 'Function scale validation accepted Environment drift.'

$renderScaleDriftState = New-TestRenderState `
    -Name $driftContract.renderName `
    -RegistryServer $driftContract.registryServer `
    -IdentityId $driftIdentityId `
    -Image $driftImage `
    -Cpu $driftContract.renderCpu `
    -Memory $driftContract.renderMemory `
    -MinReplicas $driftContract.renderMinReplicas `
    -MaxReplicas ($driftContract.renderMaxReplicas + 1) `
    -HttpConcurrency $driftContract.renderHttpConcurrency
Assert-Throws `
    -Action {
        Assert-RenderContainerConfiguration `
            -State $renderScaleDriftState `
            -ExpectedImage $driftImage `
            -ExpectedIdentityId $driftIdentityId `
            -ExpectedRegistryServer $driftContract.registryServer `
            -ExpectedCpu $driftContract.renderCpu `
            -ExpectedMemory $driftContract.renderMemory `
            -ExpectedMinReplicas $driftContract.renderMinReplicas `
            -ExpectedMaxReplicas $driftContract.renderMaxReplicas `
            -ExpectedHttpConcurrency (
                $driftContract.renderHttpConcurrency)
    } `
    -ExpectedMessage 'Render scale timing or replica limits have drifted.' `
    -Message 'Render scale validation accepted Environment drift.'

$renderIdentityDriftState = New-TestRenderState `
    -Name $driftContract.renderName `
    -RegistryServer $driftContract.registryServer `
    -IdentityId $driftIdentityId `
    -Image $driftImage `
    -Cpu $driftContract.renderCpu `
    -Memory $driftContract.renderMemory `
    -MinReplicas $driftContract.renderMinReplicas `
    -MaxReplicas $driftContract.renderMaxReplicas `
    -HttpConcurrency $driftContract.renderHttpConcurrency
$otherIdentityId = Get-ExpectedRenderIdentityId `
    -SubscriptionId $tenantId `
    -ResourceGroupName $driftContract.resourceGroup `
    -RenderIdentityName 'id-render-other'
Assert-Throws `
    -Action {
        Assert-RenderContainerConfiguration `
            -State $renderIdentityDriftState `
            -ExpectedImage $driftImage `
            -ExpectedIdentityId $otherIdentityId `
            -ExpectedRegistryServer $driftContract.registryServer `
            -ExpectedCpu $driftContract.renderCpu `
            -ExpectedMemory $driftContract.renderMemory `
            -ExpectedMinReplicas $driftContract.renderMinReplicas `
            -ExpectedMaxReplicas $driftContract.renderMaxReplicas `
            -ExpectedHttpConcurrency (
                $driftContract.renderHttpConcurrency)
    } `
    -ExpectedMessage 'Render does not have exactly the selected identity.' `
    -Message 'Render identity validation accepted Environment drift.'

$escapedRegistryServer = 'registry.example.azurecr.io'
$escapedImageRepository = 'team/render.v2'
foreach ($invalidImage in @(
        "registryXexample.azurecr.io/$escapedImageRepository" +
            "@sha256:$('c' * 64)",
        "$escapedRegistryServer/team/renderXv2@sha256:$('c' * 64)",
        "$escapedRegistryServer/$escapedImageRepository:latest",
        "$escapedRegistryServer/$escapedImageRepository@sha256:$('C' * 64)")) {
    Assert-Throws `
        -Action {
            & $azureValidationModule {
                param($Image, $RegistryServer, $ImageRepository)

                Assert-ImmutableRenderImageReference `
                    -Image $Image `
                    -RegistryServer $RegistryServer `
                    -ImageRepository $ImageRepository
            } `
                $invalidImage `
                $escapedRegistryServer `
                $escapedImageRepository
        } `
        -ExpectedMessage (
            'ExpectedRenderImage must use the selected registry and ' +
            'repository with an immutable lowercase sha256 digest.') `
        -Message "Immutable image validation accepted '$invalidImage'."
}

$containedOutput = & $azureValidationModule {
    param($RepositoryRoot, $OutputDirectory)

    Resolve-AzureValidationOutputDirectory `
        -RepositoryRoot $RepositoryRoot `
        -OutputDirectory $OutputDirectory
} `
    $repositoryRoot `
    'build/validation/staging/live'
Assert-Equal `
    $containedOutput `
    ([System.IO.Path]::GetFullPath(
        'build/validation/staging/live',
        $repositoryRoot)) `
    'Validation output containment changed an accepted path.'
foreach ($unsafeOutput in @(
        'build/validation/../outside',
        'build/validation-results/live')) {
    Assert-Throws `
        -Action {
            & $azureValidationModule {
                param($RepositoryRoot, $OutputDirectory)

                Resolve-AzureValidationOutputDirectory `
                    -RepositoryRoot $RepositoryRoot `
                    -OutputDirectory $OutputDirectory
            } $repositoryRoot $unsafeOutput
        } `
        -ExpectedMessage `
            'Validation output must remain below the repository build/validation directory.' `
        -Message "Validation output containment accepted '$unsafeOutput'."
}

$caseMismatchedOutput = 'build/VALIDATION/staging/live'
if ([System.OperatingSystem]::IsWindows()) {
    $caseMismatchedResult = & $azureValidationModule {
        param($RepositoryRoot, $OutputDirectory)

        Resolve-AzureValidationOutputDirectory `
            -RepositoryRoot $RepositoryRoot `
            -OutputDirectory $OutputDirectory
    } $repositoryRoot $caseMismatchedOutput
    Assert-Equal `
        $caseMismatchedResult `
        ([System.IO.Path]::GetFullPath(
            $caseMismatchedOutput,
            $repositoryRoot)) `
        'Windows validation containment rejected a case-equivalent path.'
}
else {
    Assert-Throws `
        -Action {
            & $azureValidationModule {
                param($RepositoryRoot, $OutputDirectory)

                Resolve-AzureValidationOutputDirectory `
                    -RepositoryRoot $RepositoryRoot `
                    -OutputDirectory $OutputDirectory
            } $repositoryRoot $caseMismatchedOutput
        } `
        -ExpectedMessage `
            'Validation output must remain below the repository build/validation directory.' `
        -Message 'Unix validation containment accepted a case-mismatched sibling.'
}

$authState = [pscustomobject]@{
    platformEnabled = $true
    unauthenticatedClientAction = 'Return401'
    excludedPaths = @()
    redirectToProvider = $null
    requireHttps = $true
    azureActiveDirectoryEnabled = $true
    clientId = $clientId
    openIdIssuer = "https://login.microsoftonline.com/$tenantId/v2.0"
    clientSecretSettingName = $null
    allowedAudiences = @($clientId)
    allowedApplications = @()
    allowedPrincipalIdentities = @($principalId)
    allowedPrincipalGroups = @()
    tokenStoreEnabled = $false
    tokenStoreBlobSettingName = $null
    tokenStoreFileDirectory = $null
}
$authResult = Assert-RenderAuthenticationConfiguration `
    -State $authState `
    -ExpectedTenantId $tenantId `
    -ExpectedClientId $clientId `
    -ExpectedPrincipalId $principalId
Assert-Equal $authResult.enabled $true 'Authentication was not normalized as enabled.'
Assert-Equal $authResult.allowedPrincipals.Count 1 'Authentication principal count mismatch.'

$invalidAuthState = $authState | Select-Object *
$invalidAuthState.excludedPaths = @('/health/live')
Assert-Throws `
    -Action {
        Assert-RenderAuthenticationConfiguration `
            -State $invalidAuthState `
            -ExpectedTenantId $tenantId `
            -ExpectedClientId $clientId `
            -ExpectedPrincipalId $principalId
    } `
    -ExpectedMessage 'Render authentication unexpectedly excludes public paths.' `
    -Message 'Authentication validation accepted an excluded path.'

$authorizationCases = @(
    Get-RenderAuthorizationTestCases
)
Assert-Equal $authorizationCases.Count 5 'Authorization matrix size mismatch.'
Assert-Equal `
    @($authorizationCases | Where-Object scenario -EQ 'anonymous').Count `
    3 `
    'Authorization matrix anonymous scenario count mismatch.'
Assert-Equal `
    @($authorizationCases | Where-Object scenario -EQ 'malformed-token').Count `
    1 `
    'Authorization matrix malformed-token scenario count mismatch.'
Assert-Equal `
    @($authorizationCases | Where-Object scenario -EQ 'valid-token-wrong-audience').Count `
    1 `
    'Authorization matrix wrong-audience scenario count mismatch.'
Assert-Equal `
    @($authorizationCases | Where-Object { $_.Contains('bearerToken') }).Count `
    0 `
    'Authorization matrix definition exposed a bearer token.'

if ($null -eq ('Html2b.Tests.AlwaysUnauthorizedHandler' -as [type])) {
    Add-Type -TypeDefinition @'
namespace Html2b.Tests;

using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

public sealed class AlwaysUnauthorizedHandler : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        return Task.FromResult(
            new HttpResponseMessage(HttpStatusCode.Unauthorized));
    }
}

public sealed class AlwaysOkHandler : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        return Task.FromResult(
            new HttpResponseMessage(HttpStatusCode.OK));
    }
}

public sealed class LiveHealthHandler : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        return Task.FromResult(
            new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(
                    "{\"status\":\"live\"}",
                    System.Text.Encoding.UTF8,
                    "application/json"),
            });
    }
}

public sealed class TrackingHandler : HttpMessageHandler
{
    public bool IsDisposed { get; private set; }

    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        return Task.FromResult(
            new HttpResponseMessage(HttpStatusCode.InternalServerError));
    }

    protected override void Dispose(bool disposing)
    {
        IsDisposed = disposing;
        base.Dispose(disposing);
    }
}
'@
}

$authorizationClient = [System.Net.Http.HttpClient]::new(
    [Html2b.Tests.AlwaysUnauthorizedHandler]::new())
try {
    $authorizationResults = @(
        Invoke-RenderAuthorizationMatrix `
            -Client $authorizationClient `
            -BaseUri ([uri] 'https://render.example/') `
            -WrongAudienceToken 'not-a-real-token' `
            -WrongPrincipalToken $null `
            -AllowedPrincipalId $principalId
    )
}
finally {
    $authorizationClient.Dispose()
}
Assert-Equal `
    $authorizationResults.Count `
    6 `
    'Authorization matrix did not complete after sensitive-value cleanup.'
Assert-Equal `
    @($authorizationResults | Where-Object status -EQ 'skipped').Count `
    1 `
    'Authorization matrix did not retain the safe wrong-principal skip.'

$functionRejectionClient = [System.Net.Http.HttpClient]::new(
    [Html2b.Tests.AlwaysUnauthorizedHandler]::new())
try {
    $functionRejectionResults = @(
        Invoke-ExpectedFunctionAuthorizationRejection `
            -Client $functionRejectionClient `
            -Uri ([uri] 'https://function.example/health/ready') `
            -Method 'GET' `
            -Scenario 'ready-without-key'
        Invoke-ExpectedFunctionAuthorizationRejection `
            -Client $functionRejectionClient `
            -Uri ([uri] 'https://function.example/api/renders/png') `
            -Method 'POST' `
            -Scenario 'render-without-key'
    )
}
finally {
    $functionRejectionClient.Dispose()
}
Assert-Equal `
    $functionRejectionResults.Count `
    2 `
    'Function no-key authorization matrix size mismatch.'
Assert-Equal `
    @($functionRejectionResults | Where-Object httpStatus -EQ 401).Count `
    2 `
    'Function no-key authorization result mismatch.'
Assert-Equal `
    (($functionRejectionResults | ConvertTo-Json -Depth 10) -match
        'x-functions-key') `
    $false `
    'Function authorization result serialized a key header.'

$functionOkClient = [System.Net.Http.HttpClient]::new(
    [Html2b.Tests.AlwaysOkHandler]::new())
try {
    Assert-Throws `
        -Action {
            Invoke-ExpectedFunctionAuthorizationRejection `
                -Client $functionOkClient `
                -Uri ([uri] 'https://function.example/health/ready') `
                -Method 'GET' `
                -Scenario 'ready-without-key'
        } `
        -ExpectedMessage `
            'Function ready-without-key returned HTTP 200 instead of 401.' `
        -Message 'Function authorization accepted a non-rejection response.'
}
finally {
    $functionOkClient.Dispose()
}

$liveHealthClient = [System.Net.Http.HttpClient]::new(
    [Html2b.Tests.LiveHealthHandler]::new())
try {
    $liveWait = Wait-EndpointStatus `
        -Client $liveHealthClient `
        -Uri ([uri] 'https://function.example/health/live') `
        -ExpectedBodyStatus 'live' `
        -Timeout ([TimeSpan]::FromSeconds(1))
    Assert-Equal $liveWait.httpStatus 200 'Function live wait status mismatch.'

    $followUpLiveResponse = $liveHealthClient.GetAsync(
        'https://function.example/health/live').GetAwaiter().GetResult()
    try {
        Assert-Equal `
            ([int] $followUpLiveResponse.StatusCode) `
            200 `
            'Wait-EndpointStatus disposed its caller-owned client.'
    }
    finally {
        $followUpLiveResponse.Dispose()
    }
}
finally {
    $liveHealthClient.Dispose()
}

$telemetryModule = Get-Module Html2b.TelemetryEvidence
$telemetryStart = [DateTimeOffset] '2026-07-27T22:00:00Z'
$telemetryEnd = [DateTimeOffset] '2026-07-27T22:05:00Z'
$telemetryQuery = & $telemetryModule {
    param($StartTime, $EndTime)

    New-SanitizedDependencyAnalyticsQuery `
        -StartTime $StartTime `
        -EndTime $EndTime `
        -RenderHostName 'render.example'
} $telemetryStart $telemetryEnd
Assert-Equal `
    ($telemetryQuery -match '[\r\n]') `
    $false `
    'Dependency telemetry query contains a Windows-unsafe line break.'

$telemetryColumns = @(
    'timestamp',
    'name',
    'type',
    'target',
    'resultCode',
    'success',
    'duration',
    'operationId'
)
$telemetryRow = [object[]] @(
    '2026-07-27T22:01:00Z',
    'POST /internal/renders',
    'Http',
    'render.example',
    '200',
    $true,
    '00:00:00.1000000',
    'operation-id'
)
$telemetryResponse = [pscustomobject] @{
    tables = @(
        [pscustomobject] @{
            name = 'PrimaryResult'
            columns = @(
                $telemetryColumns |
                    ForEach-Object {
                        [pscustomobject] @{
                            name = $_
                            type = 'string'
                        }
                    }
            )
            rows = @(, $telemetryRow)
        }
    )
}
$telemetryRecords = @(
    & $telemetryModule {
        param($Response)

        ConvertFrom-SanitizedDependencyQueryResponse -Response $Response
    } $telemetryResponse
)
Assert-Equal $telemetryRecords.Count 1 'Dependency telemetry row count mismatch.'
Assert-Equal `
    $telemetryRecords[0].target `
    'render.example' `
    'Dependency telemetry target mapping mismatch.'

$dependencyQualificationCases = @(
    [pscustomobject]@{
        name = 'POST /internal/renders'
        type = 'Http'
        target = 'RENDER.EXAMPLE'
        resultCode = '200'
        success = $true
        duration = '00:00:00.1000000'
        operationId = 'operation-id'
        expected = $true
        label = 'exact successful dependency'
    },
    [pscustomobject]@{
        name = 'POST /internal/renders'
        type = 'HTTP'
        target = 'render.example'
        resultCode = '200'
        success = $true
        duration = '258.0421'
        operationId = 'operation-id'
        expected = $true
        label = 'numeric millisecond duration'
    },
    [pscustomobject]@{
        name = 'POST /internal/renders'
        type = 'Http'
        target = 'other.example'
        resultCode = '200'
        success = $true
        duration = '00:00:00.1000000'
        operationId = 'operation-id'
        expected = $false
        label = 'wrong target'
    },
    [pscustomobject]@{
        name = 'POST /internal/renders'
        type = 'Http'
        target = 'render.example'
        resultCode = '200'
        success = $false
        duration = '00:00:00.1000000'
        operationId = 'operation-id'
        expected = $false
        label = 'failed dependency'
    },
    [pscustomobject]@{
        name = 'POST /internal/renders'
        type = 'Http'
        target = 'render.example'
        resultCode = '202'
        success = $true
        duration = '00:00:00.1000000'
        operationId = 'operation-id'
        expected = $false
        label = 'non-200 dependency'
    },
    [pscustomobject]@{
        name = 'POST /internal/renders'
        type = 'Http'
        target = 'render.example'
        resultCode = '200'
        success = $true
        duration = '00:00:00.1000000'
        operationId = ' '
        expected = $false
        label = 'uncorrelated dependency'
    },
    [pscustomobject]@{
        name = 'POST /internal/renders'
        type = 'Http'
        target = 'render.example'
        resultCode = '200'
        success = $true
        duration = '0'
        operationId = 'operation-id'
        expected = $false
        label = 'zero-duration dependency'
    },
    [pscustomobject]@{
        name = 'GET /unrelated'
        type = 'Http'
        target = 'render.example'
        resultCode = '200'
        success = $true
        duration = '00:00:00.1000000'
        operationId = 'operation-id'
        expected = $false
        label = 'unexpected Render route'
    }
)
foreach ($case in $dependencyQualificationCases) {
    $isQualifyingDependency = & $telemetryModule {
        param($Record)

        Test-RenderDependencyEvidenceRecord `
            -Record $Record `
            -RenderHostName 'render.example'
    } $case
    Assert-Equal `
        $isQualifyingDependency `
        $case.expected `
        "Dependency telemetry qualification mismatch for $($case.label)."
}

$readinessDependencyRecord = [pscustomobject]@{
    timestamp = '2026-07-27T22:01:00Z'
    name = 'GET /health/ready'
    type = 'Http'
    target = 'render.example'
    resultCode = '200'
    success = $true
    duration = '10.5'
    operationId = 'readiness-operation-id'
}
$renderDependencyRecord = [pscustomobject]@{
    timestamp = '2026-07-27T22:02:00Z'
    name = 'POST /internal/renders'
    type = 'Http'
    target = 'render.example'
    resultCode = '200'
    success = $true
    duration = '20.5'
    operationId = 'render-operation-id'
}
$functionAuthorizationTelemetry = & $telemetryModule {
    param(
        $ReadinessRecord,
        $RenderRecord,
        $NoKeyStartTime,
        $NoKeyEndTime,
        $KeyedStartTime,
        $KeyedEndTime)

    Resolve-FunctionAuthorizationTelemetryEvidence `
        -NoKeyRecords @() `
        -KeyedRecords @($ReadinessRecord, $RenderRecord) `
        -NoKeyStartTime $NoKeyStartTime `
        -NoKeyEndTime $NoKeyEndTime `
        -KeyedStartTime $KeyedStartTime `
        -KeyedEndTime $KeyedEndTime `
        -RenderHostName 'render.example'
} `
    $readinessDependencyRecord `
    $renderDependencyRecord `
    $telemetryStart `
    $telemetryStart.AddMinutes(1) `
    $telemetryStart.AddMinutes(2) `
    $telemetryEnd
Assert-Equal `
    $functionAuthorizationTelemetry.status `
    'available' `
    'Function authorization telemetry did not pass complete evidence.'
Assert-Equal `
    $functionAuthorizationTelemetry.noKey.recordCount `
    0 `
    'Function authorization telemetry retained a no-key dependency.'
Assert-Equal `
    $functionAuthorizationTelemetry.keyed.readinessDependencyCount `
    1 `
    'Function authorization telemetry readiness count mismatch.'
Assert-Equal `
    $functionAuthorizationTelemetry.keyed.renderDependencyCount `
    1 `
    'Function authorization telemetry render count mismatch.'

$missingRenderTelemetry = & $telemetryModule {
    param(
        $ReadinessRecord,
        $NoKeyStartTime,
        $NoKeyEndTime,
        $KeyedStartTime,
        $KeyedEndTime)

    Resolve-FunctionAuthorizationTelemetryEvidence `
        -NoKeyRecords @() `
        -KeyedRecords @($ReadinessRecord) `
        -NoKeyStartTime $NoKeyStartTime `
        -NoKeyEndTime $NoKeyEndTime `
        -KeyedStartTime $KeyedStartTime `
        -KeyedEndTime $KeyedEndTime `
        -RenderHostName 'render.example'
} `
    $readinessDependencyRecord `
    $telemetryStart `
    $telemetryStart.AddMinutes(1) `
    $telemetryStart.AddMinutes(2) `
    $telemetryEnd
Assert-Equal `
    $missingRenderTelemetry.status `
    'not-observed' `
    'Function authorization telemetry accepted incomplete keyed evidence.'
Assert-Equal `
    $missingRenderTelemetry.noKey.status `
    'passed' `
    'Function authorization telemetry masked the independent no-key result.'

Assert-Throws `
    -Action {
        & $telemetryModule {
            param(
                $NoKeyRecord,
                $ReadinessRecord,
                $RenderRecord,
                $NoKeyStartTime,
                $NoKeyEndTime,
                $KeyedStartTime,
                $KeyedEndTime)

            Resolve-FunctionAuthorizationTelemetryEvidence `
                -NoKeyRecords @($NoKeyRecord) `
                -KeyedRecords @($ReadinessRecord, $RenderRecord) `
                -NoKeyStartTime $NoKeyStartTime `
                -NoKeyEndTime $NoKeyEndTime `
                -KeyedStartTime $KeyedStartTime `
                -KeyedEndTime $KeyedEndTime `
                -RenderHostName 'render.example'
        } `
            $renderDependencyRecord `
            $readinessDependencyRecord `
            $renderDependencyRecord `
            $telemetryStart `
            $telemetryStart.AddMinutes(1) `
            $telemetryStart.AddMinutes(2) `
            $telemetryEnd
    } `
    -ExpectedMessage `
        'No-key Function validation produced a Render dependency.' `
    -Message 'Function authorization telemetry accepted a no-key dependency.'

$guardedTelemetryWindows = & $azureValidationModule {
    New-FunctionAuthorizationTelemetryWindows `
        -NoKeyStartTime (
            [DateTimeOffset] '2026-07-27T22:00:10Z') `
        -NoKeyEndTime (
            [DateTimeOffset] '2026-07-27T22:00:20Z') `
        -KeyedStartTime (
            [DateTimeOffset] '2026-07-27T22:01:21Z') `
        -KeyedEndTime (
            [DateTimeOffset] '2026-07-27T22:01:30Z')
}
Assert-Equal `
    $guardedTelemetryWindows.clockSkewGuardSeconds `
    30.0 `
    'Function telemetry clock-skew guard mismatch.'
Assert-Equal `
    $guardedTelemetryWindows.noKeyWindow.startTime.ToString('o') `
    '2026-07-27T21:59:40.0000000+00:00' `
    'No-key telemetry window did not include its leading guard.'
Assert-Equal `
    $guardedTelemetryWindows.noKeyWindow.endTime.ToString('o') `
    '2026-07-27T22:00:50.0000000+00:00' `
    'No-key telemetry window did not include its trailing guard.'
$justOutsideClientNoKeyWindow =
    [DateTimeOffset] '2026-07-27T22:00:40Z'
Assert-Equal `
    ($justOutsideClientNoKeyWindow -le
        $guardedTelemetryWindows.noKeyWindow.endTime) `
    $true `
    'No-key telemetry guard omitted a clock-skewed dependency timestamp.'
Assert-Equal `
    ($guardedTelemetryWindows.noKeyWindow.endTime -lt
        $guardedTelemetryWindows.keyedWindow.startTime) `
    $true `
    'Function authorization telemetry guard windows overlap.'
Assert-Throws `
    -Action {
        & $azureValidationModule {
            New-FunctionAuthorizationTelemetryWindows `
                -NoKeyStartTime (
                    [DateTimeOffset] '2026-07-27T22:00:10Z') `
                -NoKeyEndTime (
                    [DateTimeOffset] '2026-07-27T22:00:20Z') `
                -KeyedStartTime (
                    [DateTimeOffset] '2026-07-27T22:00:50Z') `
                -KeyedEndTime (
                    [DateTimeOffset] '2026-07-27T22:01:00Z')
        }
    } `
    -ExpectedMessage `
        'Function authorization telemetry guard windows overlap.' `
    -Message 'Function telemetry accepted overlapping guarded windows.'

$publicTelemetryEvidence = & $telemetryModule {
    param(
        $NoKeyStartTime,
        $NoKeyEndTime,
        $KeyedStartTime,
        $KeyedEndTime,
        $ReadinessRecord,
        $RenderRecord)

    $script:NoKeyTelemetryProbeCount = 0
    $script:KeyedTelemetryProbeCount = 0
    $script:NoKeyTelemetryProbeStart = $NoKeyStartTime
    $script:PublicReadinessRecord = $ReadinessRecord
    $script:PublicRenderRecord = $RenderRecord
    function Get-SanitizedDependencyTelemetry {
        param(
            [string] $Subscription,
            [string] $GroupName,
            [string] $ApplicationName,
            [DateTimeOffset] $StartTime,
            [DateTimeOffset] $EndTime,
            [string] $RenderHostName
        )

        if ($StartTime -eq $script:NoKeyTelemetryProbeStart) {
            $script:NoKeyTelemetryProbeCount++
            return @()
        }

        $script:KeyedTelemetryProbeCount++
        return @(
            $script:PublicReadinessRecord,
            $script:PublicRenderRecord)
    }

    try {
        $evidence = Get-FunctionAuthorizationTelemetryEvidence `
            -Subscription 'subscription-id' `
            -GroupName 'resource-group' `
            -ApplicationName 'application-insights' `
            -NoKeyStartTime $NoKeyStartTime `
            -NoKeyEndTime $NoKeyEndTime `
            -KeyedStartTime $KeyedStartTime `
            -KeyedEndTime $KeyedEndTime `
            -RenderHostName 'render.example' `
            -Timeout ([TimeSpan]::FromMilliseconds(250))
        return [ordered]@{
            evidence = $evidence
            noKeyProbeCount = $script:NoKeyTelemetryProbeCount
            keyedProbeCount = $script:KeyedTelemetryProbeCount
        }
    }
    finally {
        Remove-Item Function:\Get-SanitizedDependencyTelemetry `
            -ErrorAction SilentlyContinue
        Remove-Variable NoKeyTelemetryProbeCount `
            -Scope Script `
            -ErrorAction SilentlyContinue
        Remove-Variable KeyedTelemetryProbeCount `
            -Scope Script `
            -ErrorAction SilentlyContinue
        Remove-Variable NoKeyTelemetryProbeStart `
            -Scope Script `
            -ErrorAction SilentlyContinue
        Remove-Variable PublicReadinessRecord `
            -Scope Script `
            -ErrorAction SilentlyContinue
        Remove-Variable PublicRenderRecord `
            -Scope Script `
            -ErrorAction SilentlyContinue
    }
} `
    $telemetryStart `
    $telemetryStart.AddMinutes(1) `
    $telemetryStart.AddMinutes(2) `
    $telemetryEnd `
    $readinessDependencyRecord `
    $renderDependencyRecord
Assert-Equal `
    $publicTelemetryEvidence.evidence.status `
    'available' `
    'Public Function authorization telemetry did not pass complete evidence.'
Assert-Equal `
    ($publicTelemetryEvidence.noKeyProbeCount -gt 1) `
    $true `
    'Public telemetry did not hold the no-key absence observation.'
Assert-Equal `
    ($publicTelemetryEvidence.keyedProbeCount -gt 1) `
    $true `
    'Public telemetry did not continue polling keyed evidence.'

Assert-Throws `
    -Action {
        & $telemetryModule {
            param(
                $NoKeyStartTime,
                $NoKeyEndTime,
                $KeyedStartTime,
                $KeyedEndTime,
                $ReadinessRecord,
                $RenderRecord)

            $script:DelayedNoKeyProbeCount = 0
            $script:DelayedNoKeyProbeStart = $NoKeyStartTime
            $script:DelayedNoKeyRecord = $RenderRecord
            $script:DelayedReadinessRecord = $ReadinessRecord
            function Get-SanitizedDependencyTelemetry {
                param(
                    [string] $Subscription,
                    [string] $GroupName,
                    [string] $ApplicationName,
                    [DateTimeOffset] $StartTime,
                    [DateTimeOffset] $EndTime,
                    [string] $RenderHostName
                )

                if ($StartTime -eq $script:DelayedNoKeyProbeStart) {
                    $script:DelayedNoKeyProbeCount++
                    if ($script:DelayedNoKeyProbeCount -gt 1) {
                        return @($script:DelayedNoKeyRecord)
                    }

                    return @()
                }

                return @(
                    $script:DelayedReadinessRecord,
                    $script:DelayedNoKeyRecord)
            }

            try {
                Get-FunctionAuthorizationTelemetryEvidence `
                    -Subscription 'subscription-id' `
                    -GroupName 'resource-group' `
                    -ApplicationName 'application-insights' `
                    -NoKeyStartTime $NoKeyStartTime `
                    -NoKeyEndTime $NoKeyEndTime `
                    -KeyedStartTime $KeyedStartTime `
                    -KeyedEndTime $KeyedEndTime `
                    -RenderHostName 'render.example' `
                    -Timeout ([TimeSpan]::FromMilliseconds(250))
            }
            finally {
                Remove-Item Function:\Get-SanitizedDependencyTelemetry `
                    -ErrorAction SilentlyContinue
                Remove-Variable DelayedNoKeyProbeCount `
                    -Scope Script `
                    -ErrorAction SilentlyContinue
                Remove-Variable DelayedNoKeyProbeStart `
                    -Scope Script `
                    -ErrorAction SilentlyContinue
                Remove-Variable DelayedNoKeyRecord `
                    -Scope Script `
                    -ErrorAction SilentlyContinue
                Remove-Variable DelayedReadinessRecord `
                    -Scope Script `
                    -ErrorAction SilentlyContinue
            }
        } `
            $telemetryStart `
            $telemetryStart.AddMinutes(1) `
            $telemetryStart.AddMinutes(2) `
            $telemetryEnd `
            $readinessDependencyRecord `
            $renderDependencyRecord
    } `
    -ExpectedMessage `
        'No-key Function validation produced a Render dependency.' `
    -Message 'Public telemetry accepted a delayed no-key dependency.'

$noKeyQueryGap = & $telemetryModule {
    param(
        $NoKeyStartTime,
        $NoKeyEndTime,
        $KeyedStartTime,
        $KeyedEndTime,
        $ReadinessRecord,
        $RenderRecord)

    $script:FailingNoKeyProbeStart = $NoKeyStartTime
    $script:GapReadinessRecord = $ReadinessRecord
    $script:GapRenderRecord = $RenderRecord
    function Get-SanitizedDependencyTelemetry {
        param(
            [string] $Subscription,
            [string] $GroupName,
            [string] $ApplicationName,
            [DateTimeOffset] $StartTime,
            [DateTimeOffset] $EndTime,
            [string] $RenderHostName
        )

        if ($StartTime -eq $script:FailingNoKeyProbeStart) {
            throw 'no-key-query-sentinel'
        }

        return @(
            $script:GapReadinessRecord,
            $script:GapRenderRecord)
    }

    try {
        Get-FunctionAuthorizationTelemetryEvidence `
            -Subscription 'subscription-id' `
            -GroupName 'resource-group' `
            -ApplicationName 'application-insights' `
            -NoKeyStartTime $NoKeyStartTime `
            -NoKeyEndTime $NoKeyEndTime `
            -KeyedStartTime $KeyedStartTime `
            -KeyedEndTime $KeyedEndTime `
            -RenderHostName 'render.example' `
            -Timeout ([TimeSpan]::Zero)
    }
    finally {
        Remove-Item Function:\Get-SanitizedDependencyTelemetry `
            -ErrorAction SilentlyContinue
        Remove-Variable FailingNoKeyProbeStart `
            -Scope Script `
            -ErrorAction SilentlyContinue
        Remove-Variable GapReadinessRecord `
            -Scope Script `
            -ErrorAction SilentlyContinue
        Remove-Variable GapRenderRecord `
            -Scope Script `
            -ErrorAction SilentlyContinue
    }
} `
    $telemetryStart `
    $telemetryStart.AddMinutes(1) `
    $telemetryStart.AddMinutes(2) `
    $telemetryEnd `
    $readinessDependencyRecord `
    $renderDependencyRecord
Assert-Equal `
    $noKeyQueryGap.classification `
    'evidence-gap' `
    'Public telemetry masked a no-key query failure.'
Assert-Equal `
    $noKeyQueryGap.noKey.status `
    'not-observed' `
    'Public telemetry marked a failed no-key query as passed.'
Assert-Equal `
    $noKeyQueryGap.keyed.status `
    'available' `
    'Public telemetry masked independent keyed proof.'

$keyedQueryGap = & $telemetryModule {
    param(
        $NoKeyStartTime,
        $NoKeyEndTime,
        $KeyedStartTime,
        $KeyedEndTime)

    $script:PassingNoKeyProbeStart = $NoKeyStartTime
    function Get-SanitizedDependencyTelemetry {
        param(
            [string] $Subscription,
            [string] $GroupName,
            [string] $ApplicationName,
            [DateTimeOffset] $StartTime,
            [DateTimeOffset] $EndTime,
            [string] $RenderHostName
        )

        if ($StartTime -eq $script:PassingNoKeyProbeStart) {
            return @()
        }

        throw 'keyed-query-sentinel'
    }

    try {
        Get-FunctionAuthorizationTelemetryEvidence `
            -Subscription 'subscription-id' `
            -GroupName 'resource-group' `
            -ApplicationName 'application-insights' `
            -NoKeyStartTime $NoKeyStartTime `
            -NoKeyEndTime $NoKeyEndTime `
            -KeyedStartTime $KeyedStartTime `
            -KeyedEndTime $KeyedEndTime `
            -RenderHostName 'render.example' `
            -Timeout ([TimeSpan]::Zero)
    }
    finally {
        Remove-Item Function:\Get-SanitizedDependencyTelemetry `
            -ErrorAction SilentlyContinue
        Remove-Variable PassingNoKeyProbeStart `
            -Scope Script `
            -ErrorAction SilentlyContinue
    }
} `
    $telemetryStart `
    $telemetryStart.AddMinutes(1) `
    $telemetryStart.AddMinutes(2) `
    $telemetryEnd
Assert-Equal `
    $keyedQueryGap.classification `
    'evidence-gap' `
    'Public telemetry masked a keyed query failure.'
Assert-Equal `
    $keyedQueryGap.noKey.status `
    'passed' `
    'Public telemetry masked independent no-key proof.'
Assert-Equal `
    $keyedQueryGap.keyed.status `
    'not-observed' `
    'Public telemetry marked a failed keyed query as available.'

Assert-Throws `
    -Action {
        & $telemetryModule {
            param($StartTime, $EndTime)

            function Get-SanitizedDependencyTelemetry {
                throw 'An invalid telemetry window reached the query path.'
            }

            try {
                Get-FunctionAuthorizationTelemetryEvidence `
                    -Subscription 'subscription-id' `
                    -GroupName 'resource-group' `
                    -ApplicationName 'application-insights' `
                    -NoKeyStartTime $StartTime `
                    -NoKeyEndTime $StartTime.AddMinutes(3) `
                    -KeyedStartTime $StartTime.AddMinutes(2) `
                    -KeyedEndTime $EndTime `
                    -RenderHostName 'render.example' `
                    -Timeout ([TimeSpan]::Zero)
            }
            finally {
                Remove-Item Function:\Get-SanitizedDependencyTelemetry `
                    -ErrorAction SilentlyContinue
            }
        } $telemetryStart $telemetryEnd
    } `
    -ExpectedMessage 'Function authorization telemetry windows are invalid.' `
    -Message 'Public telemetry accepted overlapping query windows.'

$emptyTelemetryResponse = [pscustomobject] @{
    tables = @(
        [pscustomobject] @{
            name = 'PrimaryResult'
            columns = @($telemetryResponse.tables[0].columns)
            rows = @()
        }
    )
}
$emptyTelemetryRecords = @(
    & $telemetryModule {
        param($Response)

        ConvertFrom-SanitizedDependencyQueryResponse -Response $Response
    } $emptyTelemetryResponse
)
Assert-Equal `
    $emptyTelemetryRecords.Count `
    0 `
    'Dependency telemetry zero-row response was not preserved.'

$malformedTelemetryResponse = [pscustomobject] @{
    tables = @(
        [pscustomobject] @{
            name = 'PrimaryResult'
            columns = @(
                $telemetryResponse.tables[0].columns |
                    Select-Object -First 7
            )
            rows = @()
        }
    )
}
Assert-Throws `
    -Action {
        & $telemetryModule {
            param($Response)

            ConvertFrom-SanitizedDependencyQueryResponse -Response $Response
        } $malformedTelemetryResponse
    } `
    -ExpectedMessage `
        'The sanitized dependency query returned an unexpected schema.' `
    -Message 'Dependency telemetry accepted a malformed schema.'

$telemetryGap = [pscustomobject]@{
    status = 'not-observed'
    reason = 'No dependency rows.'
    risk = 'No independent dependency proof.'
    recovery = 'Enable dependency collection.'
}
$wrongPrincipalSkip = [pscustomobject]@{
    status = 'skipped'
    reason = 'No second principal token.'
    risk = 'The 403 branch was not exercised.'
}
$combinedOutcome = Resolve-AzureDevValidationOutcome `
    -Telemetry $telemetryGap `
    -WrongPrincipalResult $wrongPrincipalSkip
Assert-Equal `
    $combinedOutcome.status `
    'incomplete-telemetry-evidence-gap' `
    'Combined evidence-gap status mismatch.'
Assert-Equal $combinedOutcome.evidenceGaps.Count 2 'Combined evidence gaps were masked.'
Assert-Equal `
    ($combinedOutcome.evidenceGaps.code -join ',') `
    'dependency-telemetry-not-observed,wrong-principal-403-not-exercised' `
    'Combined evidence-gap codes mismatch.'

$availableTelemetry = [pscustomobject]@{ status = 'available' }
$wrongPrincipalPass = [pscustomobject]@{ status = 'passed' }
$passedOutcome = Resolve-AzureDevValidationOutcome `
    -Telemetry $availableTelemetry `
    -WrongPrincipalResult $wrongPrincipalPass
Assert-Equal $passedOutcome.status 'passed' 'Passing outcome status mismatch.'
Assert-Equal $passedOutcome.evidenceGaps.Count 0 'Passing outcome retained an evidence gap.'

$wrongPrincipalOnlyOutcome = Resolve-AzureDevValidationOutcome `
    -Telemetry $availableTelemetry `
    -WrongPrincipalResult $wrongPrincipalSkip
Assert-Equal `
    $wrongPrincipalOnlyOutcome.status `
    'passed-with-safe-wrong-principal-skip' `
    'Wrong-principal-only status mismatch.'
Assert-Equal `
    $wrongPrincipalOnlyOutcome.evidenceGaps.Count `
    1 `
    'Wrong-principal-only evidence gap count mismatch.'

$telemetryOnlyOutcome = Resolve-AzureDevValidationOutcome `
    -Telemetry $telemetryGap `
    -WrongPrincipalResult $wrongPrincipalPass
Assert-Equal `
    $telemetryOnlyOutcome.status `
    'incomplete-telemetry-evidence-gap' `
    'Telemetry-only status mismatch.'
Assert-Equal `
    $telemetryOnlyOutcome.evidenceGaps.Count `
    1 `
    'Telemetry-only evidence gap count mismatch.'

$expectedIdentityId = Get-ExpectedRenderIdentityId `
    -SubscriptionId $tenantId `
    -ResourceGroupName 'rg-html2b-dev' `
    -RenderIdentityName 'id-html2b-render-dev'
Assert-Equal `
    $expectedIdentityId `
    "/subscriptions/$tenantId/resourceGroups/rg-html2b-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-html2b-render-dev" `
    'Render identity resource ID mismatch.'

$entryValidationArguments = @{
    EnvironmentName = 'dev'
    SubscriptionId = $tenantId
    ExpectedTenantId = $tenantId
    ResourceGroupName = 'rg-html2b-dev'
    FunctionAppName = 'func-html2b-api-dev'
    RenderContainerAppName = 'ca-html2b-render-dev'
    RenderApiClientId = $clientId
    RenderRegistryServer = 'crhtml2bdev.azurecr.io'
    RenderImageRepository = 'html2b-render'
    RenderIdentityName = 'id-html2b-render-dev'
    ApplicationInsightsName = 'appi-html2b-dev'
    FunctionInstanceMemoryMB = 2048
    FunctionMaximumInstanceCount = 1
    RenderCpu = 1
    RenderMemory = '2Gi'
    RenderMinReplicas = 0
    RenderMaxReplicas = 1
    RenderHttpConcurrency = 1
    OutputDirectory = 'build/validation/dev/offline'
}
Assert-Throws `
    -Action {
        & $entryScript @entryValidationArguments `
            -ExpectedRenderImage 'mutable-image:latest'
    } `
    -ExpectedMessage (
        'ExpectedRenderImage must use the selected registry and repository ' +
        'with an immutable lowercase sha256 digest.') `
    -Message 'Azure validator entry point did not delegate to the validation module.'

$nonZeroMinReplicaArguments = $entryValidationArguments.Clone()
$nonZeroMinReplicaArguments.RenderMinReplicas = 1
Assert-Throws `
    -Action {
        & $entryScript @nonZeroMinReplicaArguments `
            -ExpectedRenderImage (
                'crhtml2bdev.azurecr.io/html2b-render@sha256:' +
                ('d' * 64))
    } `
    -ExpectedMessage `
        'RenderMinReplicas must be zero for the cold-start validation contract.' `
    -Message 'Azure validator accepted a nonzero cold-start replica floor.'

$functionAuthorizationProbe = & $azureValidationModule {
    param($SentinelFunctionKey)

    $originalClockSkewGuard = $script:FunctionTelemetryClockSkewGuard
    $script:FunctionTelemetryClockSkewGuard = [TimeSpan]::Zero
    $script:AuthorizationProbeSentinel = $SentinelFunctionKey
    $script:AuthorizationProbeFailKeyedContract = $false
    $script:AuthorizationProbeImmediateReady = $false

    function script:Get-AuthorizationProbeHeaderState {
        param(
            [Parameter(Mandatory)]
            [System.Net.Http.HttpClient] $Client
        )

        if (-not $Client.DefaultRequestHeaders.Contains('x-functions-key')) {
            return 'anonymous'
        }

        $headerValues = @(
            $Client.DefaultRequestHeaders.GetValues('x-functions-key'))
        if ($headerValues.Count -ne 1 -or
            $headerValues[0] -cne $script:AuthorizationProbeSentinel) {
            throw 'The Function authorization probe received an invalid key header.'
        }

        return 'keyed'
    }

    function script:New-ValidationHttpClient {
        $handler = [Html2b.Tests.TrackingHandler]::new()
        $client = [System.Net.Http.HttpClient]::new($handler)
        $script:AuthorizationProbeHandlers.Add($handler)
        $script:AuthorizationProbeClients.Add($client)
        $script:AuthorizationProbeEvents.Add('client-created')
        return $client
    }

    function script:Wait-EndpointStatus {
        param(
            [System.Net.Http.HttpClient] $Client,
            [uri] $Uri,
            [string] $ExpectedBodyStatus,
            [TimeSpan] $Timeout
        )

        $headerState = Get-AuthorizationProbeHeaderState -Client $Client
        $script:AuthorizationProbeEvents.Add(
            "wait:$($Uri.AbsolutePath):$headerState")
        return [ordered]@{
            path = $Uri.AbsolutePath
            httpStatus = 200
            bodyStatus = $ExpectedBodyStatus
            elapsedMilliseconds = 1
        }
    }

    function script:Invoke-HealthContract {
        param(
            [System.Net.Http.HttpClient] $Client,
            [uri] $Uri,
            [string] $ExpectedBodyStatus,
            [string] $Phase,
            [string] $HostLabel,
            [switch] $ReturnFailure
        )

        $headerState = Get-AuthorizationProbeHeaderState -Client $Client
        $script:AuthorizationProbeEvents.Add(
            "health:${Phase}:$headerState")
        if ($Phase -eq 'keyed-cold-readiness' -and
            -not $script:AuthorizationProbeImmediateReady) {
            return [ordered]@{
                host = $HostLabel
                phase = $Phase
                path = $Uri.AbsolutePath
                httpStatus = 503
                bodyStatus = 'not-ready'
                elapsedMilliseconds = 2
            }
        }

        return [ordered]@{
            host = $HostLabel
            phase = $Phase
            path = $Uri.AbsolutePath
            httpStatus = 200
            bodyStatus = $ExpectedBodyStatus
            elapsedMilliseconds = 1
        }
    }

    function script:Invoke-ExpectedFunctionAuthorizationRejection {
        param(
            [System.Net.Http.HttpClient] $Client,
            [uri] $Uri,
            [string] $Method,
            [string] $Scenario
        )

        $headerState = Get-AuthorizationProbeHeaderState -Client $Client
        $script:AuthorizationProbeEvents.Add(
            "reject:${Scenario}:$headerState")
        return [ordered]@{
            scenario = $Scenario
            method = $Method
            path = $Uri.AbsolutePath
            httpStatus = 401
        }
    }

    function script:Wait-RenderScaledToZero {
        param(
            [string] $Subscription,
            [string] $ContainerAppResourceId,
            [string] $RevisionName,
            [int] $MaximumReplicaCount,
            [TimeSpan] $Timeout
        )

        if ($MaximumReplicaCount -ne 3) {
            throw 'The Function authorization probe received the wrong replica cap.'
        }
        $script:AuthorizationProbeEvents.Add('scale-to-zero')
        return 0.0
    }

    function script:Get-ExistingDefaultFunctionHostKey {
        param(
            [string] $Subscription,
            [string] $GroupName,
            [string] $AppName
        )

        $script:AuthorizationProbeEvents.Add('key-read')
        return $script:AuthorizationProbeSentinel
    }

    function script:Invoke-FunctionContractValidation {
        param(
            [System.Net.Http.HttpClient] $Client,
            [uri] $BaseUri,
            [string] $Phase,
            [switch] $SkipLiveness
        )

        $headerState = Get-AuthorizationProbeHeaderState -Client $Client
        $script:AuthorizationProbeEvents.Add(
            "function-contract:$headerState")
        if (-not $SkipLiveness) {
            throw 'The keyed Function probe unexpectedly included liveness.'
        }
        if ($script:AuthorizationProbeFailKeyedContract) {
            throw 'Mock keyed Function contract failure.'
        }

        return @(
            [ordered]@{
                phase = $Phase
                path = '/health/ready'
                httpStatus = 200
            },
            [ordered]@{
                phase = $Phase
                path = '/api/renders/png'
                httpStatus = 200
            },
            [ordered]@{
                phase = $Phase
                path = '/api/renders/jpeg'
                httpStatus = 200
            },
            [ordered]@{
                phase = $Phase
                path = '/api/renders/pdf'
                httpStatus = 200
            })
    }

    function script:Invoke-RenderContract {
        param(
            [System.Net.Http.HttpClient] $Client,
            [uri] $Uri,
            [string] $Format,
            [string] $Phase,
            [string] $HostLabel
        )

        $headerState = Get-AuthorizationProbeHeaderState -Client $Client
        $script:AuthorizationProbeEvents.Add(
            "render:${Phase}:$headerState")
        return [ordered]@{
            host = $HostLabel
            phase = $Phase
            path = $Uri.AbsolutePath
            format = $Format
            httpStatus = 200
        }
    }

    try {
        $script:AuthorizationProbeEvents =
            [System.Collections.Generic.List[string]]::new()
        $script:AuthorizationProbeClients =
            [System.Collections.Generic.List[
                System.Net.Http.HttpClient]]::new()
        $script:AuthorizationProbeHandlers =
            [System.Collections.Generic.List[
                Html2b.Tests.TrackingHandler]]::new()
        $successResult = Invoke-FunctionAuthorizationValidation `
            -Subscription 'subscription-id' `
            -GroupName 'resource-group' `
            -AppName 'func-html2b-api-dev' `
            -BaseUri (
                [uri] 'https://func-html2b-api-dev.azurewebsites.net/') `
            -ContainerAppResourceId 'container-app-resource-id' `
            -RevisionName 'revision-name' `
            -RenderMaximumReplicaCount 3
        $successEvents = @($script:AuthorizationProbeEvents)
        $successClients = @($script:AuthorizationProbeClients)
        $successHandlers = @($script:AuthorizationProbeHandlers)

        $script:AuthorizationProbeEvents =
            [System.Collections.Generic.List[string]]::new()
        $script:AuthorizationProbeClients =
            [System.Collections.Generic.List[
                System.Net.Http.HttpClient]]::new()
        $script:AuthorizationProbeHandlers =
            [System.Collections.Generic.List[
                Html2b.Tests.TrackingHandler]]::new()
        $script:AuthorizationProbeImmediateReady = $true
        $immediateReadyResult = Invoke-FunctionAuthorizationValidation `
            -Subscription 'subscription-id' `
            -GroupName 'resource-group' `
            -AppName 'func-html2b-api-dev' `
            -BaseUri (
                [uri] 'https://func-html2b-api-dev.azurewebsites.net/') `
            -ContainerAppResourceId 'container-app-resource-id' `
            -RevisionName 'revision-name' `
            -RenderMaximumReplicaCount 3
        $immediateReadyEvents = @($script:AuthorizationProbeEvents)
        $immediateReadyClients = @($script:AuthorizationProbeClients)
        $immediateReadyHandlers = @($script:AuthorizationProbeHandlers)

        $script:AuthorizationProbeEvents =
            [System.Collections.Generic.List[string]]::new()
        $script:AuthorizationProbeClients =
            [System.Collections.Generic.List[
                System.Net.Http.HttpClient]]::new()
        $script:AuthorizationProbeHandlers =
            [System.Collections.Generic.List[
                Html2b.Tests.TrackingHandler]]::new()
        $script:AuthorizationProbeFailKeyedContract = $true
        $failureMessage = $null
        try {
            $null = Invoke-FunctionAuthorizationValidation `
                -Subscription 'subscription-id' `
                -GroupName 'resource-group' `
                -AppName 'func-html2b-api-dev' `
                -BaseUri (
                    [uri] 'https://func-html2b-api-dev.azurewebsites.net/') `
                -ContainerAppResourceId 'container-app-resource-id' `
                -RevisionName 'revision-name' `
                -RenderMaximumReplicaCount 3
        }
        catch {
            $failureMessage = $_.Exception.Message
        }
        $failureClients = @($script:AuthorizationProbeClients)
        $failureHandlers = @($script:AuthorizationProbeHandlers)

        return [ordered]@{
            successResult = $successResult
            successEvents = $successEvents
            successClientCount = $successClients.Count
            successClientsDisposed =
                @($successHandlers | Where-Object IsDisposed).Count
            successKeyHeaderRemaining =
                $successClients[1].DefaultRequestHeaders.Contains(
                    'x-functions-key')
            successSerialized = $successResult | ConvertTo-Json -Depth 20
            immediateReadyResult = $immediateReadyResult
            immediateReadyEvents = $immediateReadyEvents
            immediateReadyClientCount = $immediateReadyClients.Count
            immediateReadyClientsDisposed =
                @($immediateReadyHandlers | Where-Object IsDisposed).Count
            immediateReadyKeyHeaderRemaining =
                $immediateReadyClients[1].DefaultRequestHeaders.Contains(
                    'x-functions-key')
            failureMessage = $failureMessage
            failureClientCount = $failureClients.Count
            failureClientsDisposed =
                @($failureHandlers | Where-Object IsDisposed).Count
            failureKeyHeaderRemaining =
                $failureClients[1].DefaultRequestHeaders.Contains(
                    'x-functions-key')
        }
    }
    finally {
        $script:FunctionTelemetryClockSkewGuard = $originalClockSkewGuard
        $script:AuthorizationProbeSentinel = $null
        Remove-Variable AuthorizationProbeFailKeyedContract `
            -Scope Script `
            -ErrorAction SilentlyContinue
        Remove-Variable AuthorizationProbeImmediateReady `
            -Scope Script `
            -ErrorAction SilentlyContinue
        Remove-Variable AuthorizationProbeEvents `
            -Scope Script `
            -ErrorAction SilentlyContinue
        Remove-Variable AuthorizationProbeClients `
            -Scope Script `
            -ErrorAction SilentlyContinue
        Remove-Variable AuthorizationProbeHandlers `
            -Scope Script `
            -ErrorAction SilentlyContinue
    }
} $sentinelFunctionKey
Assert-Equal `
    $functionAuthorizationProbe.successResult.contracts.Count `
    11 `
    'Function authorization orchestration contract count mismatch.'
Assert-Equal `
    $functionAuthorizationProbe.successResult.waits.Count `
    2 `
    'Function authorization orchestration wait count mismatch.'
Assert-Equal `
    ($functionAuthorizationProbe.successResult.coldWake.
        firstReadinessAttemptRetried) `
    $true `
    'Function authorization orchestration did not exercise 503 convergence.'
Assert-Equal `
    $functionAuthorizationProbe.successClientCount `
    2 `
    'Function authorization orchestration did not isolate its HTTP clients.'
Assert-Equal `
    $functionAuthorizationProbe.successClientsDisposed `
    2 `
    'Function authorization orchestration did not dispose successful clients.'
Assert-Equal `
    $functionAuthorizationProbe.successKeyHeaderRemaining `
    $false `
    'Function authorization orchestration retained its successful key header.'
Assert-Equal `
    ($functionAuthorizationProbe.successSerialized -match
        [regex]::Escape($sentinelFunctionKey)) `
    $false `
    'Function authorization orchestration serialized the Function host key.'
Assert-Equal `
    ($functionAuthorizationProbe.successSerialized -match 'x-functions-key') `
    $false `
    'Function authorization orchestration serialized a key header.'
$lastNoKeyEventIndex = [Math]::Max(
    [array]::IndexOf(
        $functionAuthorizationProbe.successEvents,
        'reject:ready-without-key:anonymous'),
    [array]::IndexOf(
        $functionAuthorizationProbe.successEvents,
        'reject:render-without-key:anonymous'))
$firstScaleToZeroIndex = [array]::IndexOf(
    $functionAuthorizationProbe.successEvents,
    'scale-to-zero')
$keyReadIndex = [array]::IndexOf(
    $functionAuthorizationProbe.successEvents,
    'key-read')
Assert-Equal `
    ($keyReadIndex -gt $lastNoKeyEventIndex) `
    $true `
    'Function host key was read before no-key validation completed.'
Assert-Equal `
    ($keyReadIndex -gt $firstScaleToZeroIndex) `
    $true `
    'Function host key was read before the first cold boundary completed.'
Assert-Equal `
    (@(
        $functionAuthorizationProbe.successEvents |
            Where-Object { $_ -match ':keyed$' }).Count -gt 0) `
    $true `
    'Function authorization orchestration did not exercise keyed calls.'
Assert-Equal `
    ($functionAuthorizationProbe.successResult.noKeyWindow.endTime -lt
        $functionAuthorizationProbe.successResult.keyedWindow.startTime) `
    $true `
    'Function authorization orchestration returned overlapping windows.'
Assert-Equal `
    $functionAuthorizationProbe.immediateReadyResult.contracts.Count `
    11 `
    'Immediate-ready Function authorization contract count mismatch.'
Assert-Equal `
    $functionAuthorizationProbe.immediateReadyResult.waits.Count `
    1 `
    'Immediate-ready Function authorization added a convergence wait.'
Assert-Equal `
    ($functionAuthorizationProbe.immediateReadyResult.coldWake.
        firstReadinessAttemptRetried) `
    $false `
    'Immediate-ready Function authorization unexpectedly retried readiness.'
Assert-Equal `
    (@(
        $functionAuthorizationProbe.immediateReadyEvents |
            Where-Object { $_ -eq 'wait:/health/ready:keyed' }).Count) `
    0 `
    'Immediate-ready Function authorization ran the 503 convergence wait.'
Assert-Equal `
    $functionAuthorizationProbe.immediateReadyClientCount `
    2 `
    'Immediate-ready Function authorization did not isolate its clients.'
Assert-Equal `
    $functionAuthorizationProbe.immediateReadyClientsDisposed `
    2 `
    'Immediate-ready Function authorization did not dispose both clients.'
Assert-Equal `
    $functionAuthorizationProbe.immediateReadyKeyHeaderRemaining `
    $false `
    'Immediate-ready Function authorization retained its key header.'
Assert-Equal `
    $functionAuthorizationProbe.failureMessage `
    'Mock keyed Function contract failure.' `
    'Function authorization failure probe did not reach its keyed branch.'
Assert-Equal `
    $functionAuthorizationProbe.failureClientCount `
    2 `
    'Function authorization failure did not isolate its HTTP clients.'
Assert-Equal `
    $functionAuthorizationProbe.failureClientsDisposed `
    2 `
    'Function authorization failure did not dispose both clients.'
Assert-Equal `
    $functionAuthorizationProbe.failureKeyHeaderRemaining `
    $false `
    'Function authorization failure retained its key header.'

Write-Host "$script:TestCount Azure validator offline tests passed."
