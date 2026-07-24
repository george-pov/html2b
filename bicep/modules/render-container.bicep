targetScope = 'resourceGroup'

param location string
param baseTags object
param containerRegistryName string
param imageRepositoryName string
param containerAppsEnvironmentName string
param renderIdentityName string
param renderContainerAppName string
param containerImage string
param renderCpu int
param renderMemory string
param renderMinReplicas int
param renderMaxReplicas int
param renderHttpConcurrency int

var repositoryReaderRoleDefinitionResourceId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b93aa761-3e63-49ed-ac28-beffa264f7ac'
)
var renderRepositoryReaderCondition = '((!(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/content/read\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/metadata/read\'})) OR (@Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase \'${imageRepositoryName}\'))'
var renderTags = union(baseTags, {
  Component: 'Render'
})

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2025-11-01' existing = {
  name: containerRegistryName
}

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2026-01-01' existing = {
  name: containerAppsEnvironmentName
}

resource renderIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: renderIdentityName
  location: location
  tags: renderTags
}

resource renderAcrRepositoryReaderRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(
    containerRegistry.id,
    renderIdentity.id,
    repositoryReaderRoleDefinitionResourceId,
    imageRepositoryName
  )
  scope: containerRegistry
  properties: {
    principalId: renderIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: repositoryReaderRoleDefinitionResourceId
    condition: renderRepositoryReaderCondition
    conditionVersion: '2.0'
    description: 'Read Html2B images only from the ${imageRepositoryName} repository.'
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
    managedEnvironmentId: containerAppsEnvironment.id
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
        targetPort: 8080
        transport: 'auto'
        exposedPort: 0
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      registries: [
        {
          server: '${containerRegistryName}.azurecr.io'
          identity: renderIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'html2b-render'
          image: containerImage
          resources: {
            cpu: renderCpu
            memory: renderMemory
          }
          probes: [
            {
              type: 'Liveness'
              httpGet: {
                path: '/health/live'
                port: 8080
                scheme: 'HTTP'
              }
              initialDelaySeconds: 10
              periodSeconds: 30
              timeoutSeconds: 5
              failureThreshold: 3
              successThreshold: 1
            }
            {
              type: 'Readiness'
              httpGet: {
                path: '/health/ready'
                port: 8080
                scheme: 'HTTP'
              }
              initialDelaySeconds: 1
              periodSeconds: 5
              timeoutSeconds: 5
              failureThreshold: 3
              successThreshold: 1
            }
            {
              type: 'Startup'
              httpGet: {
                path: '/health/ready'
                port: 8080
                scheme: 'HTTP'
              }
              initialDelaySeconds: 1
              periodSeconds: 5
              timeoutSeconds: 5
              failureThreshold: 10
              successThreshold: 1
            }
          ]
        }
      ]
      scale: {
        minReplicas: renderMinReplicas
        maxReplicas: renderMaxReplicas
        pollingInterval: 30
        cooldownPeriod: 300
        rules: [
          {
            name: 'http-one-render'
            http: {
              metadata: {
                concurrentRequests: string(renderHttpConcurrency)
              }
            }
          }
        ]
      }
      terminationGracePeriodSeconds: 30
    }
  }
  dependsOn: [
    renderAcrRepositoryReaderRoleAssignment
  ]
}

output renderContainerAppId string = renderContainerApp.id
output renderContainerAppName string = renderContainerApp.name
output renderContainerAppFqdn string = renderContainerApp.properties.configuration.ingress.fqdn
output renderContainerAppUrl string = 'https://${renderContainerApp.properties.configuration.ingress.fqdn}'
