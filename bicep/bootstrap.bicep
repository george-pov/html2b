targetScope = 'subscription'

param resourceGroupName string
param containerRegistryName string
param imageRepositoryName string

@minLength(36)
@maxLength(36)
param deploymentOperatorPrincipalId string

resource environmentResourceGroup 'Microsoft.Resources/resourceGroups@2025-04-01' existing = {
  name: resourceGroupName
}

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2025-11-01' existing = {
  name: containerRegistryName
  scope: environmentResourceGroup
}

module acrOperatorAccessDeployment 'modules/acr-operator-access.bicep' = {
  name: 'acr-operator-access'
  scope: environmentResourceGroup
  params: {
    containerRegistryName: containerRegistry.name
    containerRegistryResourceId: containerRegistry.id
    imageRepositoryName: imageRepositoryName
    deploymentOperatorPrincipalId: deploymentOperatorPrincipalId
  }
}

output roleAssignmentId string = acrOperatorAccessDeployment.outputs.roleAssignmentId
output roleDefinitionId string = acrOperatorAccessDeployment.outputs.roleDefinitionId
output principalId string = deploymentOperatorPrincipalId
output imageRepositoryName string = imageRepositoryName
