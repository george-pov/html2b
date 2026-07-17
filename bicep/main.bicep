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
param renderImageRepositoryName string
param renderContainerAppsEnvironmentName string
param renderRuntimeIdentityName string
param renderContainerAppName string
param renderImage string = ''
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

var expectedRenderImagePrefix = '${containerRegistryName}.azurecr.io/${renderImageRepositoryName}@sha256:'
var renderDigest = replace(renderImage, expectedRenderImagePrefix, '')
var renderDigestWithoutHexCharacters = replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(replace(renderDigest, '0', ''), '1', ''), '2', ''), '3', ''), '4', ''), '5', ''), '6', ''), '7', ''), '8', ''), '9', ''), 'a', ''), 'b', ''), 'c', ''), 'd', ''), 'e', ''), 'f', '')

assert exactEnvironment = environmentName == 'dev'
assert exactLocation = location == 'westus2'
assert exactResourceGroup = resourceGroupName == 'rg-html2b-dev'
assert exactVirtualNetwork = virtualNetworkAddressPrefix == '10.40.0.0/24'
assert exactContainerAppsSubnet = containerAppsSubnetAddressPrefix == '10.40.0.0/27'
assert exactFunctionsSubnet = functionsSubnetAddressPrefix == '10.40.0.32/27'
assert dedicatedSubnetsDoNotOverlap = containerAppsSubnetAddressPrefix != functionsSubnetAddressPrefix
assert foundationImageIsBlank = deploymentMode != 'foundation' || empty(renderImage)
assert applicationImageIsImmutable = deploymentMode != 'application' || (startsWith(renderImage, expectedRenderImagePrefix) && length(renderDigest) == 64 && renderDigest == toLower(renderDigest) && empty(renderDigestWithoutHexCharacters))

var baseTags = {
  Application: 'Html2B'
  Environment: environmentName
  Region: location
  ManagedBy: 'Bicep'
  Repository: 'george-pov/html2b'
}

resource environmentResourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
  tags: union(baseTags, {
    Component: 'Environment'
  })
}

module environmentDeployment 'modules/environment.bicep' = {
  name: 'environment'
  scope: environmentResourceGroup
  params: {
    deploymentMode: deploymentMode
    location: location
    containerRegistryName: containerRegistryName
    renderImageRepositoryName: renderImageRepositoryName
    renderContainerAppsEnvironmentName: renderContainerAppsEnvironmentName
    renderRuntimeIdentityName: renderRuntimeIdentityName
    renderContainerAppName: renderContainerAppName
    renderImage: renderImage
    renderCpu: renderCpu
    renderMemory: renderMemory
    renderMinReplicas: renderMinReplicas
    renderMaxReplicas: renderMaxReplicas
    renderHttpConcurrency: renderHttpConcurrency
    logAnalyticsWorkspaceName: logAnalyticsWorkspaceName
    applicationInsightsName: applicationInsightsName
    logRetentionInDays: logRetentionInDays
    virtualNetworkName: virtualNetworkName
    virtualNetworkAddressPrefix: virtualNetworkAddressPrefix
    containerAppsSubnetName: containerAppsSubnetName
    containerAppsSubnetAddressPrefix: containerAppsSubnetAddressPrefix
    functionsSubnetName: functionsSubnetName
    functionsSubnetAddressPrefix: functionsSubnetAddressPrefix
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
    applicationDeploymentIdentityName: applicationDeploymentIdentityName
    githubOidcIssuer: githubOidcIssuer
    githubOidcAudience: githubOidcAudience
    githubOidcSubject: githubOidcSubject
    baseTags: baseTags
  }
}

output resourceGroupName string = environmentResourceGroup.name
output containerRegistryLoginServer string = environmentDeployment.outputs.containerRegistryLoginServer
output renderContainerAppFqdn string = environmentDeployment.outputs.renderContainerAppFqdn
output functionAppName string = environmentDeployment.outputs.functionAppName
output functionAppDefaultHostName string = environmentDeployment.outputs.functionAppDefaultHostName
output applicationDeploymentClientId string = environmentDeployment.outputs.applicationDeploymentClientId
output deployedRenderImage string = environmentDeployment.outputs.deployedRenderImage
