param deploymentMode string
param location string
param containerRegistryName string
param renderImageRepositoryName string
param logAnalyticsWorkspaceName string
param renderContainerAppsEnvironmentName string
param renderRuntimeIdentityName string
param renderContainerAppName string
param containerAppsSubnetId string
param renderImage string
param renderCpu int
param renderMemory string
param renderMinReplicas int
param renderMaxReplicas int
param renderHttpConcurrency int
param baseTags object

var repositoryReaderRoleDefinitionResourceId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b93aa761-3e63-49ed-ac28-beffa264f7ac'
)
var renderRepositoryReaderCondition = '((!(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/content/read\'}) AND !(ActionMatches{\'Microsoft.ContainerRegistry/registries/repositories/metadata/read\'})) OR (@Request[Microsoft.ContainerRegistry/registries/repositories:name] StringEqualsIgnoreCase \'${renderImageRepositoryName}\'))'

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2025-11-01' existing = {
  name: containerRegistryName
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource renderRuntimeIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: renderRuntimeIdentityName
  location: location
  tags: union(baseTags, {
    Component: 'Render'
  })
}

resource renderRepositoryReaderRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, renderRuntimeIdentity.id, repositoryReaderRoleDefinitionResourceId, renderImageRepositoryName)
  scope: containerRegistry
  properties: {
    principalId: renderRuntimeIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: repositoryReaderRoleDefinitionResourceId
    condition: renderRepositoryReaderCondition
    conditionVersion: '2.0'
    description: 'Read Html2B images only from the html2b-render repository.'
  }
}

resource renderContainerAppsEnvironment 'Microsoft.App/managedEnvironments@2026-01-01' = {
  name: renderContainerAppsEnvironmentName
  location: location
  tags: union(baseTags, {
    Component: 'Render'
  })
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalyticsWorkspace.properties.customerId
        sharedKey: logAnalyticsWorkspace.listKeys().primarySharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: containerAppsSubnetId
      internal: true
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    zoneRedundant: false
  }
}

resource renderContainerApp 'Microsoft.App/containerApps@2026-01-01' = if (deploymentMode == 'application') {
  name: renderContainerAppName
  location: location
  tags: union(baseTags, {
    Component: 'Render'
  })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${renderRuntimeIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: renderContainerAppsEnvironment.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      maxInactiveRevisions: 100
      identitySettings: [
        {
          identity: renderRuntimeIdentity.id
          lifecycle: 'None'
        }
      ]
      ingress: {
        external: true
        allowInsecure: true
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
          server: containerRegistry.properties.loginServer
          identity: renderRuntimeIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'html2b-render'
          image: renderImage
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
}

output renderEnvironmentDefaultDomain string = renderContainerAppsEnvironment.properties.defaultDomain
output renderEnvironmentStaticIp string = renderContainerAppsEnvironment.properties.staticIp
output renderContainerAppFqdn string = renderContainerApp.?properties.configuration.ingress.fqdn ?? ''
output deployedRenderImage string = deploymentMode == 'application' ? renderImage : ''
