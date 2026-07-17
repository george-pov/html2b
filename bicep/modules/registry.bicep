param location string
param containerRegistryName string
param imageRepositoryName string
param deploymentOperatorPrincipalId string
param baseTags object

var repositoryWriterRoleDefinitionResourceId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '2a1e307c-b015-4ebd-883e-5b7698a07328'
)
var operatorRepositoryWriterCondition = '((!(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/content/read\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/content/write\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/metadata/read\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/metadata/write\'})) OR (@Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase \'${imageRepositoryName}\'))'

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2025-11-01' = {
  name: containerRegistryName
  location: location
  tags: union(baseTags, {
    Component: 'Registry'
  })
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled'
    roleAssignmentMode: 'AbacRepositoryPermissions'
    policies: {
      azureADAuthenticationAsArmPolicy: {
        status: 'enabled'
      }
    }
  }
}

resource operatorRepositoryWriterRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deploymentOperatorPrincipalId)) {
  name: guid(containerRegistry.id, deploymentOperatorPrincipalId, repositoryWriterRoleDefinitionResourceId, imageRepositoryName)
  scope: containerRegistry
  properties: {
    principalId: deploymentOperatorPrincipalId
    principalType: 'User'
    roleDefinitionId: repositoryWriterRoleDefinitionResourceId
    condition: operatorRepositoryWriterCondition
    conditionVersion: '2.0'
    description: 'Write Html2B images only in the html2b-api repository.'
  }
}

output containerRegistryId string = containerRegistry.id
output containerRegistryName string = containerRegistry.name
output containerRegistryLoginServer string = containerRegistry.properties.loginServer
