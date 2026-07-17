param deploymentMode string
param location string
param containerRegistryName string
param renderImageRepositoryName string
param renderContainerAppsEnvironmentName string
param renderRuntimeIdentityName string
param renderContainerAppName string
param renderImage string
param renderCpu int
param renderMemory string
param renderMinReplicas int
param renderMaxReplicas int
param renderHttpConcurrency int
param logAnalyticsWorkspaceName string
param applicationInsightsName string
param logRetentionInDays int
param virtualNetworkName string
param virtualNetworkAddressPrefix string
param containerAppsSubnetName string
param containerAppsSubnetAddressPrefix string
param functionsSubnetName string
param functionsSubnetAddressPrefix string
param functionStorageAccountName string
param functionDeploymentContainerName string
param functionRuntimeIdentityName string
param functionPlanName string
param functionAppName string
param functionRuntimeName string
param functionRuntimeVersion string
param functionInstanceMemoryMb int
param functionMaximumInstanceCount int
param functionHttpConcurrency int
param applicationDeploymentIdentityName string
param githubOidcIssuer string
param githubOidcAudience string
param githubOidcSubject string
param baseTags object

module registryDeployment 'registry.bicep' = {
  name: 'registry'
  params: {
    location: location
    containerRegistryName: containerRegistryName
    baseTags: baseTags
  }
}

module monitoringDeployment 'monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    applicationInsightsName: applicationInsightsName
    logRetentionInDays: logRetentionInDays
    baseTags: baseTags
  }
}

module networkDeployment 'network.bicep' = {
  name: 'network'
  params: {
    location: location
    virtualNetworkName: virtualNetworkName
    virtualNetworkAddressPrefix: virtualNetworkAddressPrefix
    containerAppsSubnetName: containerAppsSubnetName
    containerAppsSubnetAddressPrefix: containerAppsSubnetAddressPrefix
    functionsSubnetName: functionsSubnetName
    functionsSubnetAddressPrefix: functionsSubnetAddressPrefix
    baseTags: baseTags
  }
}

module renderDeployment 'container-apps.bicep' = {
  name: 'render'
  params: {
    deploymentMode: deploymentMode
    location: location
    containerRegistryName: containerRegistryName
    renderImageRepositoryName: renderImageRepositoryName
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    renderContainerAppsEnvironmentName: renderContainerAppsEnvironmentName
    renderRuntimeIdentityName: renderRuntimeIdentityName
    renderContainerAppName: renderContainerAppName
    containerAppsSubnetId: networkDeployment.outputs.containerAppsSubnetId
    renderImage: renderImage
    renderCpu: renderCpu
    renderMemory: renderMemory
    renderMinReplicas: renderMinReplicas
    renderMaxReplicas: renderMaxReplicas
    renderHttpConcurrency: renderHttpConcurrency
    baseTags: baseTags
  }
  dependsOn: [
    registryDeployment
    monitoringDeployment
  ]
}

module privateDnsDeployment 'private-dns.bicep' = {
  name: 'private-dns'
  params: {
    environmentDefaultDomain: renderDeployment.outputs.renderEnvironmentDefaultDomain
    environmentStaticIp: renderDeployment.outputs.renderEnvironmentStaticIp
    virtualNetworkId: networkDeployment.outputs.virtualNetworkId
    baseTags: baseTags
  }
}

module functionsDeployment 'functions.bicep' = {
  name: 'functions'
  params: {
    location: location
    functionStorageAccountName: functionStorageAccountName
    functionDeploymentContainerName: functionDeploymentContainerName
    functionRuntimeIdentityName: functionRuntimeIdentityName
    functionPlanName: functionPlanName
    functionAppName: functionAppName
    functionRuntimeName: functionRuntimeName
    functionRuntimeVersion: functionRuntimeVersion
    functionInstanceMemoryMb: functionInstanceMemoryMb
    functionMaximumInstanceCount: functionMaximumInstanceCount
    functionHttpConcurrency: functionHttpConcurrency
    functionsSubnetId: networkDeployment.outputs.functionsSubnetId
    applicationInsightsName: applicationInsightsName
    baseTags: baseTags
  }
}

module functionAppSettingsDeployment 'function-app-settings.bicep' = {
  name: 'function-app-settings'
  params: {
    deploymentMode: deploymentMode
    functionAppName: functionAppName
    functionRuntimeName: functionRuntimeName
    functionStorageAccountName: functionStorageAccountName
    functionRuntimeIdentityClientId: functionsDeployment.outputs.functionRuntimeIdentityClientId
    applicationInsightsConnectionString: monitoringDeployment.outputs.applicationInsightsConnectionString
    renderServiceBaseUrl: deploymentMode == 'application'
      ? 'http://${renderDeployment.outputs.renderContainerAppFqdn}'
      : ''
  }
}

module applicationDeploymentIdentityDeployment 'deployment-identity.bicep' = {
  name: 'application-deployment-identity'
  params: {
    location: location
    applicationDeploymentIdentityName: applicationDeploymentIdentityName
    functionAppName: functionAppName
    containerRegistryName: containerRegistryName
    renderImageRepositoryName: renderImageRepositoryName
    githubOidcIssuer: githubOidcIssuer
    githubOidcAudience: githubOidcAudience
    githubOidcSubject: githubOidcSubject
    baseTags: baseTags
  }
  dependsOn: [
    registryDeployment
    functionsDeployment
    functionAppSettingsDeployment
  ]
}

output containerRegistryLoginServer string = registryDeployment.outputs.containerRegistryLoginServer
output renderContainerAppFqdn string = renderDeployment.outputs.renderContainerAppFqdn
output functionAppName string = functionsDeployment.outputs.functionAppName
output functionAppDefaultHostName string = functionsDeployment.outputs.functionAppDefaultHostName
output applicationDeploymentClientId string = applicationDeploymentIdentityDeployment.outputs.applicationDeploymentClientId
output deployedRenderImage string = renderDeployment.outputs.deployedRenderImage
