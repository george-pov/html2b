param deploymentMode string
param location string
param containerRegistryName string
param imageRepositoryName string
param logAnalyticsWorkspaceName string
param containerAppsEnvironmentName string
param runtimeIdentityName string
param containerAppName string
param deploymentOperatorPrincipalId string
param containerImage string
param logRetentionInDays int
param containerCpu int
param containerMemory string
param minReplicas int
param maxReplicas int
param httpConcurrency int
param baseTags object

module registryDeployment 'registry.bicep' = if (deploymentMode == 'foundation') {
  name: 'registry'
  params: {
    location: location
    containerRegistryName: containerRegistryName
    imageRepositoryName: imageRepositoryName
    deploymentOperatorPrincipalId: deploymentOperatorPrincipalId
    baseTags: baseTags
  }
}

module monitoringDeployment 'monitoring.bicep' = if (deploymentMode == 'foundation') {
  name: 'monitoring'
  params: {
    location: location
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    logRetentionInDays: logRetentionInDays
    baseTags: baseTags
  }
}

module containerAppsDeployment 'container-apps.bicep' = {
  name: 'container-apps'
  params: {
    deploymentMode: deploymentMode
    location: location
    containerRegistryName: containerRegistryName
    imageRepositoryName: imageRepositoryName
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    containerAppsEnvironmentName: containerAppsEnvironmentName
    runtimeIdentityName: runtimeIdentityName
    containerAppName: containerAppName
    containerImage: containerImage
    containerCpu: containerCpu
    containerMemory: containerMemory
    minReplicas: minReplicas
    maxReplicas: maxReplicas
    httpConcurrency: httpConcurrency
    baseTags: baseTags
  }
  dependsOn: [
    registryDeployment
    monitoringDeployment
  ]
}

output containerRegistryName string = containerRegistryName
output containerRegistryLoginServer string = '${containerRegistryName}.azurecr.io'
output logAnalyticsWorkspaceName string = logAnalyticsWorkspaceName
output containerAppsEnvironmentName string = containerAppsDeployment.outputs.containerAppsEnvironmentName
output runtimeIdentityName string = containerAppsDeployment.outputs.runtimeIdentityName
output containerAppName string = containerAppsDeployment.outputs.containerAppName
output containerAppFqdn string = containerAppsDeployment.outputs.containerAppFqdn
output deployedContainerImage string = containerAppsDeployment.outputs.deployedContainerImage
