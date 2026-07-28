targetScope = 'resourceGroup'

param location string
param baseTags object
param logAnalyticsWorkspaceName string
param functionStorageAccountName string
param functionPlanName string
param applicationInsightsName string
param functionAppName string
param functionDeploymentContainerName string
param functionRuntime string
param functionRuntimeVersion string
@allowed([
  512
  2048
  4096
])
param functionInstanceMemoryMb int
@minValue(1)
@maxValue(1000)
param functionMaximumInstanceCount int
param renderServiceBaseUrl string
param renderServiceAudience string

var functionTags = union(baseTags, {
  Component: 'Functions'
})
var functionStorageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${functionStorage.name};AccountKey=${functionStorage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2025-02-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource functionStorage 'Microsoft.Storage/storageAccounts@2025-08-01' = {
  name: functionStorageAccountName
  location: location
  tags: functionTags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowSharedKeyAccess: true
    defaultToOAuthAuthentication: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
  }
}

resource functionBlobService 'Microsoft.Storage/storageAccounts/blobServices@2025-08-01' = {
  parent: functionStorage
  name: 'default'
  properties: {}
}

resource functionDeploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-08-01' = {
  parent: functionBlobService
  name: functionDeploymentContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource functionPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: functionPlanName
  location: location
  tags: functionTags
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: applicationInsightsName
  location: location
  tags: functionTags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    Flow_Type: 'Bluefield'
    Request_Source: 'rest'
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  tags: union(functionTags, {
    'hidden-link: /app-insights-resource-id': applicationInsights.id
  })
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: functionPlan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    siteConfig: {
      minTlsVersion: '1.2'
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: functionStorageConnectionString
        }
        {
          name: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          value: functionStorageConnectionString
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsights.properties.ConnectionString
        }
        {
          name: 'RenderService__BaseUrl'
          value: renderServiceBaseUrl
        }
        {
          name: 'RenderService__Audience'
          value: renderServiceAudience
        }
      ]
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${functionStorage.properties.primaryEndpoints.blob}${functionDeploymentContainerName}'
          authentication: {
            type: 'StorageAccountConnectionString'
            storageAccountConnectionStringName: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          }
        }
      }
      scaleAndConcurrency: {
        instanceMemoryMB: functionInstanceMemoryMb
        maximumInstanceCount: functionMaximumInstanceCount
      }
      runtime: {
        name: functionRuntime
        version: functionRuntimeVersion
      }
    }
  }
  dependsOn: [
    functionDeploymentContainer
  ]
}

output functionAppName string = functionApp.name
output functionAppDefaultHostName string = functionApp.properties.defaultHostName
output functionPrincipalId string = functionApp.identity.principalId
