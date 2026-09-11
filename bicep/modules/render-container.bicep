targetScope = 'resourceGroup'

param location string
param baseTags object
param containerRegistryId string
param registryServer string
param imageRepositoryName string
param containerEnvId string
param renderIdentityName string
param renderContainerAppName string

var repoReaderRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b93aa761-3e63-49ed-ac28-beffa264f7ac'
)
var renderReaderCondition = '((!(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/content/read\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/metadata/read\'})) OR (@Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase \'${imageRepositoryName}\'))'
var renderTags = union(baseTags, {
  Component: 'Render'
})

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2025-11-01' existing = {
  name: last(split(containerRegistryId, '/'))
}

resource renderIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: renderIdentityName
  location: location
  tags: renderTags
}

resource renderRepoReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(
    containerRegistry.id,
    renderIdentity.id,
    repoReaderRoleId,
    imageRepositoryName
  )
  scope: containerRegistry
  properties: {
    principalId: renderIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: repoReaderRoleId
    condition: renderReaderCondition
    conditionVersion: '2.0'
    description: 'Read Html2B images only from ${registryServer}/${imageRepositoryName}.'
  }
}

resource renderContainerApp 'Microsoft.App/containerApps@2026-01-01' = {
  name: renderContainerAppName
  location: location
  tags: renderTags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${renderIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerEnvId
    configuration: {
      activeRevisionsMode: 'Single'
      maxInactiveRevisions: 100
      identitySettings: [
        {
          identity: renderIdentity.id
          lifecycle: 'None'
        }
      ]
      ingress: {
        external: true
        allowInsecure: false
        targetPort: 80
        transport: 'auto'
        exposedPort: 0
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
    }
    template: {
      containers: [
        {
          name: 'html2b-render'
          image: 'mcr.microsoft.com/k8se/quickstart:latest'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 1
        pollingInterval: 30
        cooldownPeriod: 300
        rules: [
          {
            name: 'http-one-render'
            http: {
              metadata: {
                concurrentRequests: '1'
              }
            }
          }
        ]
      }
      terminationGracePeriodSeconds: 30
    }
  }
  dependsOn: [
    renderRepoReaderRole
  ]
}

output renderContainerAppId string = renderContainerApp.id
output renderContainerAppName string = renderContainerApp.name
output renderContainerAppFqdn string = renderContainerApp.properties.configuration.ingress.fqdn
output renderContainerAppUrl string = 'https://${renderContainerApp.properties.configuration.ingress.fqdn}'
