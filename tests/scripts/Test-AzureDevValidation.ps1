[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$azureScripts = Join-Path $repositoryRoot 'scripts\azure'
Import-Module `
    (Join-Path $azureScripts 'Html2b.OutputContracts.psm1') `
    -Force
Import-Module `
    (Join-Path $azureScripts 'Html2b.AzureStateValidation.psm1') `
    -Force
Import-Module `
    (Join-Path $azureScripts 'Html2b.HttpValidation.psm1') `
    -Force
Import-Module `
    (Join-Path $azureScripts 'Html2b.AzureDevValidation.psm1') `
    -Force

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

$azureValidationModule = Get-Module Html2b.AzureDevValidation
$requiredOrchestrationCommands = @(
    'Assert-AccountConfiguration'
    'Assert-FunctionConfiguration'
    'Assert-RenderAuthenticationConfiguration'
    'Assert-RenderContainerConfiguration'
    'Assert-RenderRevisionState'
    'ConvertTo-CanonicalGuid'
    'Get-AccountState'
    'Get-DependencyTelemetryEvidence'
    'Get-FunctionAppState'
    'Get-FunctionRenderSettings'
    'Get-RenderAuthenticationState'
    'Get-RenderContainerAppState'
    'Get-RenderRevisions'
    'Get-RevisionReplicas'
    'Get-WrongAudienceAccessToken'
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
    -ResourceGroupName 'rg-html2b-dev'
Assert-Equal `
    $expectedIdentityId `
    "/subscriptions/$tenantId/resourceGroups/rg-html2b-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-html2b-render-dev" `
    'Render identity resource ID mismatch.'

$entryScript = Join-Path $azureScripts 'Test-AzureDev.ps1'
Assert-Throws `
    -Action {
        & $entryScript `
            -SubscriptionId $tenantId `
            -ExpectedTenantId $tenantId `
            -RenderApiClientId $clientId `
            -ExpectedRenderImage 'mutable-image:latest'
    } `
    -ExpectedMessage 'ExpectedRenderImage must be the immutable Html2B Render digest.' `
    -Message 'Azure validator entry point did not delegate to the validation module.'

Write-Host "$script:TestCount Azure validator offline tests passed."
