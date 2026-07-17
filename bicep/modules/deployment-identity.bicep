param location string
param applicationDeploymentIdentityName string
param functionAppName string
param containerRegistryName string
param renderImageRepositoryName string
param githubOidcIssuer string
param githubOidcAudience string
param githubOidcSubject string
param baseTags object

var websiteContributorRoleDefinitionResourceId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'de139f84-1756-47ae-9be6-808fbbe84772'
)
var repositoryWriterRoleDefinitionResourceId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '2a1e307c-b015-4ebd-883e-5b7698a07328'
)
var applicationRenderRepositoryWriterCondition = '((!(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/content/read\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/content/write\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/metadata/read\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/metadata/write\'})) OR (@Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase \'${renderImageRepositoryName}\'))'

assert exactIssuer = githubOidcIssuer == 'https://token.actions.githubusercontent.com'
assert exactAudience = githubOidcAudience == 'api://AzureADTokenExchange'
assert exactSubject = githubOidcSubject == 'repo:george-pov/html2b:environment:dev'

resource functionApp 'Microsoft.Web/sites@2026-03-15' existing = {
  name: functionAppName
}

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2025-11-01' existing = {
  name: containerRegistryName
}

resource applicationDeploymentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: applicationDeploymentIdentityName
  location: location
  tags: union(baseTags, {
    Component: 'Deployment'
  })
}

resource applicationDeploymentFederatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2024-11-30' = {
  parent: applicationDeploymentIdentity
  name: 'github-environment-dev'
  properties: {
    issuer: githubOidcIssuer
    audiences: [
      githubOidcAudience
    ]
    subject: githubOidcSubject
  }
}

resource applicationFunctionWebsiteContributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(functionApp.id, applicationDeploymentIdentity.id, websiteContributorRoleDefinitionResourceId)
  scope: functionApp
  properties: {
    principalId: applicationDeploymentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: websiteContributorRoleDefinitionResourceId
    description: 'Deploy Html2B Functions packages only to func-html2b-api-dev.'
  }
}

resource applicationRenderRepositoryWriterRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, applicationDeploymentIdentity.id, repositoryWriterRoleDefinitionResourceId, renderImageRepositoryName)
  scope: containerRegistry
  properties: {
    principalId: applicationDeploymentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: repositoryWriterRoleDefinitionResourceId
    condition: applicationRenderRepositoryWriterCondition
    conditionVersion: '2.0'
    description: 'Write Html2B images only in the html2b-render repository.'
  }
}

output applicationDeploymentIdentityId string = applicationDeploymentIdentity.id
output applicationDeploymentPrincipalId string = applicationDeploymentIdentity.properties.principalId
output applicationDeploymentClientId string = applicationDeploymentIdentity.properties.clientId
