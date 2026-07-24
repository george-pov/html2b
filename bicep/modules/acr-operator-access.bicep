targetScope = 'resourceGroup'

param containerRegistryName string
param containerRegistryResourceId string
param imageRepositoryName string
param deploymentOperatorPrincipalId string

var repositoryWriterRoleDefinitionResourceId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '2a1e307c-b015-4ebd-883e-5b7698a07328'
)
var operatorRepositoryWriterCondition = '((!(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/content/read\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/content/write\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/metadata/read\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/metadata/write\'})) OR (@Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase \'${imageRepositoryName}\'))'

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2025-11-01' existing = {
  name: containerRegistryName
}

resource operatorRepositoryWriterRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(
    containerRegistryResourceId,
    deploymentOperatorPrincipalId,
    repositoryWriterRoleDefinitionResourceId,
    imageRepositoryName
  )
  scope: containerRegistry
  properties: {
    principalId: deploymentOperatorPrincipalId
    principalType: 'User'
    roleDefinitionId: repositoryWriterRoleDefinitionResourceId
    condition: operatorRepositoryWriterCondition
    conditionVersion: '2.0'
    description: 'Write Html2B images only in the ${imageRepositoryName} repository.'
  }
}

output roleAssignmentId string = operatorRepositoryWriterRoleAssignment.id
output roleDefinitionId string = repositoryWriterRoleDefinitionResourceId
