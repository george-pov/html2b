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

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [version] '7.3') {
    throw 'Test-AzureDev.ps1 requires PowerShell 7.3 or later.'
}

$modulePath = Join-Path $PSScriptRoot 'Html2b.AzureDevValidation.psm1'
Import-Module $modulePath -Force

Invoke-Html2bAzureDevValidation @PSBoundParameters
