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
