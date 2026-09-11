targetScope = 'subscription'

param environmentName string
param location string
param resourceGroupName string
param containerRegistryName string
param imageRepositoryName string
param logWorkspaceName string
param logRetentionDays int
param containerEnvName string
param deploymentIdentityName string
param githubCredentialName string
param githubRepository string
param githubEnvironmentName string
param functionStorageName string
param functionPlanName string
param applicationInsightsName string
param functionAppName string
param functionReleaseContainer string
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
param functionMaxInstances int
@minLength(36)
@maxLength(36)
param renderApiClientId string
param renderIdentityName string
param renderContainerAppName string

var renderServiceAudience = 'api://${renderApiClientId}'

var baseTags = {
  Application: 'Html2B'
  Environment: environmentName
  Region: location
  ManagedBy: 'Bicep'
  Repository: 'george-pov/html2b'
  LogAnalyticsWorkspace: logWorkspaceName
}

var resourceGroupTags = union(baseTags, {
  Component: 'ResourceGroup'
})

resource environmentResourceGroup 'Microsoft.Resources/resourceGroups@2025-04-01' = {
  name: resourceGroupName
  location: location
  tags: resourceGroupTags
}

module platformDeployment 'modules/platform.bicep' = {
  name: 'platform-${environmentName}'
  scope: environmentResourceGroup
  params: {
    location: location
    baseTags: baseTags
    containerRegistryName: containerRegistryName
    logWorkspaceName: logWorkspaceName
    logRetentionDays: logRetentionDays
    containerEnvName: containerEnvName
  }
}

module deployIdentityModule 'modules/deploy-identity.bicep' = {
  name: 'deploy-identity-${environmentName}'
  scope: environmentResourceGroup
  params: {
    location: location
    baseTags: baseTags
    deploymentIdentityName: deploymentIdentityName
    githubCredentialName: githubCredentialName
    githubRepository: githubRepository
    githubEnvironmentName: githubEnvironmentName
    containerRegistryName: platformDeployment.outputs.containerRegistryName
    containerRegistryId: platformDeployment.outputs.containerRegistryId
    imageRepositoryName: imageRepositoryName
  }
}

module renderModule 'modules/render-container.bicep' = {
  name: 'render-container-${environmentName}'
  scope: environmentResourceGroup
  params: {
    location: location
    baseTags: baseTags
    containerRegistryId: platformDeployment.outputs.containerRegistryId
    registryServer: platformDeployment.outputs.registryServer
    imageRepositoryName: imageRepositoryName
    containerEnvId: platformDeployment.outputs.containerEnvId
    renderIdentityName: renderIdentityName
    renderContainerAppName: renderContainerAppName
  }
}

module functionsDeployment 'modules/functions.bicep' = {
  name: 'functions-${environmentName}'
  scope: environmentResourceGroup
  params: {
    location: location
    baseTags: baseTags
    logWorkspaceId: platformDeployment.outputs.logWorkspaceId
    functionStorageName: functionStorageName
    functionPlanName: functionPlanName
    applicationInsightsName: applicationInsightsName
    functionAppName: functionAppName
    functionReleaseContainer: functionReleaseContainer
    functionRuntime: functionRuntime
    functionRuntimeVersion: functionRuntimeVersion
    functionInstanceMemoryMb: functionInstanceMemoryMb
    functionMaxInstances: functionMaxInstances
    renderServiceBaseUrl: renderModule.outputs.renderContainerAppUrl
    renderServiceAudience: renderServiceAudience
  }
}

module renderAuthModule 'modules/render-auth.bicep' = {
  name: 'render-auth-${environmentName}'
  scope: environmentResourceGroup
  params: {
    tenantId: tenant().tenantId
    renderApiClientId: renderApiClientId
    functionPrincipalId: functionsDeployment.outputs.functionPrincipalId
    renderContainerAppName: renderModule.outputs.renderContainerAppName
  }
}

output resourceGroupName string = environmentResourceGroup.name
output functionAppName string = functionsDeployment.outputs.functionAppName
output functionHostName string = functionsDeployment.outputs.functionHostName
output functionPrincipalId string = functionsDeployment.outputs.functionPrincipalId
output renderContainerAppName string = renderModule.outputs.renderContainerAppName
output renderContainerAppFqdn string = renderModule.outputs.renderContainerAppFqdn
output renderContainerAppUrl string = renderModule.outputs.renderContainerAppUrl
output deploymentIdentityName string = deployIdentityModule.outputs.deploymentIdentityName
output deployIdentityClientId string = deployIdentityModule.outputs.deployIdentityClientId
