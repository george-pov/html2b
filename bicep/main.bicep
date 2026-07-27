targetScope = 'subscription'

param environmentName string
param location string
param resourceGroupName string
param containerRegistryName string
param imageRepositoryName string
param logAnalyticsWorkspaceName string
param containerAppsEnvironmentName string
param functionStorageAccountName string
param functionPlanName string
param applicationInsightsName string
param functionAppName string
param functionDeploymentContainerName string
param functionRuntime string
param functionRuntimeVersion string
@allowed([
  512
  2048
  4096
])
param functionInstanceMemoryMb int
@minValue(1)
@maxValue(1000)
param functionMaximumInstanceCount int
@minLength(36)
@maxLength(36)
param renderApiClientId string
param renderAuthenticationEnabled bool
param renderIdentityName string
param renderContainerAppName string
param renderCpu int
param renderMemory string
param renderMinReplicas int
param renderMaxReplicas int
param renderHttpConcurrency int
param containerImage string = ''

var renderServiceAudience = 'api://${renderApiClientId}'
var normalizedRenderApiClientId = toLower(renderApiClientId)
var renderApiClientIdWithoutSeparators = replace(normalizedRenderApiClientId, '-', '')
var renderApiClientIdWithoutAllowedCharacters = replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(renderApiClientIdWithoutSeparators, '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', ''), 'a', ''), 'b', ''), 'c', ''), 'd', ''), 'e', ''), 'f', '')
var expectedContainerImagePrefix = '${containerRegistryName}.azurecr.io/${imageRepositoryName}@sha256:'
var containerImageWithoutAllowedCharacters = replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(containerImage, expectedContainerImagePrefix, ''), '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', ''), 'a', ''), 'b', ''), 'c', ''), 'd', ''), 'e', ''), 'f', '')

assert renderApiClientIdIsDFormatGuid = length(renderApiClientIdWithoutSeparators) == 32 && empty(renderApiClientIdWithoutAllowedCharacters) && substring(renderApiClientId, 8, 1) == '-' && substring(renderApiClientId, 13, 1) == '-' && substring(renderApiClientId, 18, 1) == '-' && substring(renderApiClientId, 23, 1) == '-'
assert containerImageIsEmptyOrImmutable = empty(containerImage) || (startsWith(containerImage, expectedContainerImagePrefix) && length(containerImage) == length(expectedContainerImagePrefix) + 64 && containerImage == toLower(containerImage) && empty(containerImageWithoutAllowedCharacters))

var baseTags = {
  Application: 'Html2B'
  Environment: environmentName
  Region: location
  ManagedBy: 'Bicep'
  Repository: 'george-pov/html2b'
  LogAnalyticsWorkspace: logAnalyticsWorkspaceName
}

var resourceGroupTags = union(baseTags, {
  Component: 'ResourceGroup'
})

resource environmentResourceGroup 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: resourceGroupName
  location: location
  tags: resourceGroupTags
}

module renderContainerDeployment 'modules/render-container.bicep' = {
  name: 'render-container-${environmentName}'
  scope: environmentResourceGroup
  params: {
    location: location
    baseTags: baseTags
    containerRegistryName: containerRegistryName
    imageRepositoryName: imageRepositoryName
    containerAppsEnvironmentName: containerAppsEnvironmentName
    renderIdentityName: renderIdentityName
    renderContainerAppName: renderContainerAppName
    containerImage: containerImage
    renderCpu: renderCpu
    renderMemory: renderMemory
    renderMinReplicas: renderMinReplicas
    renderMaxReplicas: renderMaxReplicas
    renderHttpConcurrency: renderHttpConcurrency
  }
}

module functionsDeployment 'modules/functions.bicep' = {
  name: 'functions-${environmentName}'
  scope: environmentResourceGroup
  params: {
    location: location
    baseTags: baseTags
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    functionStorageAccountName: functionStorageAccountName
    functionPlanName: functionPlanName
    applicationInsightsName: applicationInsightsName
    functionAppName: functionAppName
    functionDeploymentContainerName: functionDeploymentContainerName
    functionRuntime: functionRuntime
    functionRuntimeVersion: functionRuntimeVersion
    functionInstanceMemoryMb: functionInstanceMemoryMb
    functionMaximumInstanceCount: functionMaximumInstanceCount
    renderServiceBaseUrl: renderContainerDeployment.outputs.renderContainerAppUrl
    renderServiceAudience: renderServiceAudience
  }
}

module renderAuthenticationDeployment 'modules/render-auth.bicep' = {
  name: 'render-auth-${environmentName}'
  scope: environmentResourceGroup
  params: {
    enabled: renderAuthenticationEnabled
    tenantId: tenant().tenantId
    renderApiClientId: renderApiClientId
    functionPrincipalId: functionsDeployment.outputs.functionPrincipalId
    renderContainerAppName: renderContainerDeployment.outputs.renderContainerAppName
  }
}

output resourceGroupName string = environmentResourceGroup.name
output functionAppName string = functionsDeployment.outputs.functionAppName
output functionAppDefaultHostName string = functionsDeployment.outputs.functionAppDefaultHostName
output functionPrincipalId string = functionsDeployment.outputs.functionPrincipalId
output renderContainerAppName string = renderContainerDeployment.outputs.renderContainerAppName
output renderContainerAppFqdn string = renderContainerDeployment.outputs.renderContainerAppFqdn
output renderContainerAppUrl string = renderContainerDeployment.outputs.renderContainerAppUrl
