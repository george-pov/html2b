param deploymentMode string
param location string
param containerRegistryName string
param imageRepositoryName string
param logAnalyticsWorkspaceName string
param containerAppsEnvironmentName string
param runtimeIdentityName string
param containerAppName string
param containerImage string
param containerCpu int
param containerMemory string
param minReplicas int
param maxReplicas int
param httpConcurrency int
param baseTags object

var repositoryReaderRoleDefinitionResourceId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b93aa761-3e63-49ed-ac28-beffa264f7ac'
)
var runtimeRepositoryReaderCondition = '((!(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/content/read\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/metadata/read\'})) OR (@Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase \'${imageRepositoryName}\'))'

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2025-11-01' existing = {
  name: containerRegistryName
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource runtimeIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = if (deploymentMode == 'foundation') {
  name: runtimeIdentityName
  location: location
  tags: union(baseTags, {
    Component: 'Api'
  })
}

resource existingRuntimeIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = if (deploymentMode == 'application') {
  name: runtimeIdentityName
}

resource runtimeRepositoryReaderRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deploymentMode == 'foundation') {
  name: guid(containerRegistry.id, runtimeIdentity.id, repositoryReaderRoleDefinitionResourceId, imageRepositoryName)
  scope: containerRegistry
  properties: {
    principalId: runtimeIdentity.?properties.principalId ?? ''
    principalType: 'ServicePrincipal'
    roleDefinitionId: repositoryReaderRoleDefinitionResourceId
    condition: runtimeRepositoryReaderCondition
    conditionVersion: '2.0'
    description: 'Read Html2B images only from the html2b-api repository.'
  }
}

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2026-01-01' = if (deploymentMode == 'foundation') {
  name: containerAppsEnvironmentName
  location: location
  tags: union(baseTags, {
    Component: 'Runtime'
  })
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspace.properties.customerId
        sharedKey: logAnalyticsWorkspace.listKeys().primarySharedKey
      }
    }
  }
}

resource existingContainerAppsEnvironment 'Microsoft.App/managedEnvironments@2026-01-01' existing = if (deploymentMode == 'application') {
  name: containerAppsEnvironmentName
}

resource containerApp 'Microsoft.App/containerApps@2026-01-01' = if (deploymentMode == 'application') {
  name: containerAppName
  location: location
  tags: union(baseTags, {
    Component: 'Api'
  })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${existingRuntimeIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: existingContainerAppsEnvironment.id
    configuration: {
      activeRevisionsMode: 'Single'
      maxInactiveRevisions: 100
      identitySettings: [
        {
          identity: existingRuntimeIdentity.id
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
          identity: existingRuntimeIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'html2b-api'
          image: containerImage
          resources: {
            cpu: containerCpu
            memory: containerMemory
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
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        pollingInterval: 30
        cooldownPeriod: 300
        rules: [
          {
            name: 'http-one-render'
            http: {
              metadata: {
                concurrentRequests: string(httpConcurrency)
              }
            }
          }
        ]
      }
      terminationGracePeriodSeconds: 30
    }
  }
}

output runtimeIdentityName string = deploymentMode == 'foundation' ? runtimeIdentity.name : existingRuntimeIdentity.name
output containerAppsEnvironmentName string = deploymentMode == 'foundation' ? containerAppsEnvironment.name : existingContainerAppsEnvironment.name
output containerAppName string = containerApp.?name ?? ''
output containerAppFqdn string = containerApp.?properties.configuration.ingress.fqdn ?? ''
output deployedContainerImage string = deploymentMode == 'application' ? containerImage : ''
