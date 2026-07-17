param location string
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
param functionsSubnetId string
param applicationInsightsName string
param baseTags object

var storageBlobDataOwnerRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
)
var storageTableDataContributorRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
)
var monitoringMetricsPublisherRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '3913510d-42f4-4e42-8a64-420c390055eb'
)

assert exactRuntime = functionRuntimeName == 'dotnet-isolated' && functionRuntimeVersion == '10'
assert exactInstanceMemory = functionInstanceMemoryMb == 2048
assert boundedDevScale = functionMaximumInstanceCount == 1 && functionHttpConcurrency == 1
resource applicationInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: applicationInsightsName
}

resource functionStorageAccount 'Microsoft.Storage/storageAccounts@2026-04-01' = {
  name: functionStorageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  tags: union(baseTags, {
    Component: 'Functions'
  })
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    dnsEndpointType: 'Standard'
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
  }
}

resource functionBlobService 'Microsoft.Storage/storageAccounts/blobServices@2026-04-01' = {
  parent: functionStorageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: false
    }
  }
}

resource functionDeploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2026-04-01' = {
  parent: functionBlobService
  name: functionDeploymentContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource functionRuntimeIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: functionRuntimeIdentityName
  location: location
  tags: union(baseTags, {
    Component: 'Functions'
  })
}

resource functionStorageBlobDataOwnerRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(functionStorageAccount.id, functionRuntimeIdentity.id, storageBlobDataOwnerRoleDefinitionId)
  scope: functionStorageAccount
  properties: {
    roleDefinitionId: storageBlobDataOwnerRoleDefinitionId
    principalId: functionRuntimeIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    description: 'Allow the Html2B Functions runtime to use host and deployment Blob storage.'
  }
}

resource functionStorageTableDataContributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(functionStorageAccount.id, functionRuntimeIdentity.id, storageTableDataContributorRoleDefinitionId)
  scope: functionStorageAccount
  properties: {
    roleDefinitionId: storageTableDataContributorRoleDefinitionId
    principalId: functionRuntimeIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    description: 'Allow the Html2B Functions runtime to use host Table storage.'
  }
}

resource functionMonitoringMetricsPublisherRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(applicationInsights.id, functionRuntimeIdentity.id, monitoringMetricsPublisherRoleDefinitionId)
  scope: applicationInsights
  properties: {
    roleDefinitionId: monitoringMetricsPublisherRoleDefinitionId
    principalId: functionRuntimeIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    description: 'Allow the Html2B Functions runtime to publish Application Insights telemetry.'
  }
}

resource functionPlan 'Microsoft.Web/serverFarms@2026-03-15' = {
  name: functionPlanName
  location: location
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  tags: union(baseTags, {
    Component: 'Functions'
  })
  properties: {
    reserved: true
    zoneRedundant: false
  }
}

var foundationAppSettings = [
  {
    name: 'FUNCTIONS_EXTENSION_VERSION'
    value: '~4'
  }
  {
    name: 'FUNCTIONS_WORKER_RUNTIME'
    value: functionRuntimeName
  }
  {
    name: 'AzureWebJobsStorage__accountName'
    value: functionStorageAccountName
  }
  {
    name: 'AzureWebJobsStorage__credential'
    value: 'managedidentity'
  }
  {
    name: 'AzureWebJobsStorage__clientId'
    value: functionRuntimeIdentity.properties.clientId
  }
  {
    name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING'
    value: 'Authorization=AAD;ClientId=${functionRuntimeIdentity.properties.clientId}'
  }
]

resource functionApp 'Microsoft.Web/sites@2026-03-15' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  tags: union(baseTags, {
    Component: 'Functions'
  })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${functionRuntimeIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: functionPlan.id
    virtualNetworkSubnetId: functionsSubnetId
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    clientAffinityEnabled: false
    siteConfig: {
      alwaysOn: false
      appSettings: foundationAppSettings
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      vnetRouteAllEnabled: true
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${functionStorageAccount.properties.primaryEndpoints.blob}${functionDeploymentContainerName}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: functionRuntimeIdentity.id
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: functionMaximumInstanceCount
        instanceMemoryMB: functionInstanceMemoryMb
        alwaysReady: []
        triggers: {
          http: {
            perInstanceConcurrency: functionHttpConcurrency
          }
        }
      }
      runtime: {
        name: functionRuntimeName
        version: functionRuntimeVersion
      }
    }
  }
  dependsOn: [
    functionDeploymentContainer
    functionStorageBlobDataOwnerRoleAssignment
    functionStorageTableDataContributorRoleAssignment
    functionMonitoringMetricsPublisherRoleAssignment
  ]
}

output functionAppName string = functionApp.name
output functionAppDefaultHostName string = functionApp.properties.defaultHostName
output functionRuntimeIdentityId string = functionRuntimeIdentity.id
output functionRuntimeIdentityClientId string = functionRuntimeIdentity.properties.clientId
