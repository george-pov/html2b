targetScope = 'subscription'

@allowed([
  'foundation'
  'application'
])
param deploymentMode string = 'foundation'

param environmentName string
param location string
param resourceGroupName string
param containerRegistryName string
param imageRepositoryName string
param logAnalyticsWorkspaceName string
param containerAppsEnvironmentName string
param runtimeIdentityName string
param containerAppName string
param deploymentOperatorPrincipalId string = ''
param containerImage string = ''
param logRetentionInDays int
param containerCpu int
param containerMemory string
param minReplicas int
param maxReplicas int
param httpConcurrency int

var expectedContainerImagePrefix = 'crhtml2bdev.azurecr.io/html2b-api@sha256:'
var containerImageWithoutAllowedCharacters = replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(containerImage, expectedContainerImagePrefix, ''), '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', ''), 'a', ''), 'b', ''), 'c', ''), 'd', ''), 'e', ''), 'f', '')

assert applicationImageIsImmutable = deploymentMode == 'foundation' || (length(containerImage) == length(expectedContainerImagePrefix) + 64 && containerImage == toLower(containerImage) && empty(containerImageWithoutAllowedCharacters))

var baseTags = {
  Application: 'Html2B'
  Environment: environmentName
  Region: location
  ManagedBy: 'Bicep'
  Repository: 'george-pov/html2b'
}

var environmentTags = union(baseTags, {
  Component: 'Environment'
})

resource environmentResourceGroup 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: resourceGroupName
  location: location
  tags: environmentTags
}

module environmentDeployment 'modules/environment.bicep' = {
  name: 'environment'
  scope: environmentResourceGroup
  params: {
    deploymentMode: deploymentMode
    location: location
    containerRegistryName: containerRegistryName
    imageRepositoryName: imageRepositoryName
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    containerAppsEnvironmentName: containerAppsEnvironmentName
    runtimeIdentityName: runtimeIdentityName
    containerAppName: containerAppName
    deploymentOperatorPrincipalId: deploymentOperatorPrincipalId
    containerImage: containerImage
    logRetentionInDays: logRetentionInDays
    containerCpu: containerCpu
    containerMemory: containerMemory
    minReplicas: minReplicas
    maxReplicas: maxReplicas
    httpConcurrency: httpConcurrency
    baseTags: baseTags
  }
}

output resourceGroupName string = environmentResourceGroup.name
output containerRegistryName string = environmentDeployment.outputs.containerRegistryName
output containerRegistryLoginServer string = environmentDeployment.outputs.containerRegistryLoginServer
output logAnalyticsWorkspaceName string = environmentDeployment.outputs.logAnalyticsWorkspaceName
output containerAppsEnvironmentName string = environmentDeployment.outputs.containerAppsEnvironmentName
output runtimeIdentityName string = environmentDeployment.outputs.runtimeIdentityName
output containerAppName string = environmentDeployment.outputs.containerAppName
output containerAppFqdn string = environmentDeployment.outputs.containerAppFqdn
output deployedContainerImage string = environmentDeployment.outputs.deployedContainerImage
