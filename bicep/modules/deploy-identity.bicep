targetScope = 'resourceGroup'

param location string
param baseTags object
param deploymentIdentityName string
param githubCredentialName string
param githubRepository string
param githubEnvironmentName string
param containerRegistryName string
param containerRegistryId string
param imageRepositoryName string

var contributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b24988ac-6180-42a0-ab88-20f7382dd24c'
)
var repoWriterRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '2a1e307c-b015-4ebd-883e-5b7698a07328'
)
var githubTokenIssuer = 'https://token.actions.githubusercontent.com'
var tokenExchangeAudience = 'api://AzureADTokenExchange'
var deployWriterCondition = '((!(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/content/read\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/content/write\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/metadata/read\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/metadata/write\'})) OR (@Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase \'${imageRepositoryName}\'))'

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2025-11-01' existing = {
  name: containerRegistryName
}

resource deploymentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: deploymentIdentityName
  location: location
  tags: union(baseTags, {
    Component: 'Deployment'
  })
}

resource githubCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: deploymentIdentity
  name: githubCredentialName
  properties: {
    issuer: githubTokenIssuer
    subject: 'repo:${githubRepository}:environment:${githubEnvironmentName}'
    audiences: [
      tokenExchangeAudience
    ]
  }
}

resource deployContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, deploymentIdentity.id, contributorRoleId)
  properties: {
    principalId: deploymentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: contributorRoleId
    description: 'Deploy Html2B application resources in this resource group.'
  }
}

resource deployRepoWriterRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistryId, deploymentIdentity.id, repoWriterRoleId, imageRepositoryName)
  scope: containerRegistry
  properties: {
    principalId: deploymentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: repoWriterRoleId
    condition: deployWriterCondition
    conditionVersion: '2.0'
    description: 'Write Html2B images only in the ${imageRepositoryName} repository.'
  }
}

output deploymentIdentityName string = deploymentIdentity.name
output deployIdentityClientId string = deploymentIdentity.properties.clientId
output deployPrincipalId string = deploymentIdentity.properties.principalId
