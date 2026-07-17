param deploymentMode string
param functionAppName string
param functionRuntimeName string
param functionStorageAccountName string
param functionRuntimeIdentityClientId string
param applicationInsightsConnectionString string
param renderServiceBaseUrl string

assert foundationHasNoRenderUrl = deploymentMode != 'foundation' || empty(renderServiceBaseUrl)
assert applicationHasPrivateRenderUrl = deploymentMode != 'application' || startsWith(renderServiceBaseUrl, 'http://')

resource functionApp 'Microsoft.Web/sites@2026-03-15' existing = {
  name: functionAppName
}

var foundationAppSettings = {
  FUNCTIONS_EXTENSION_VERSION: '~4'
  FUNCTIONS_WORKER_RUNTIME: functionRuntimeName
  AzureWebJobsStorage__accountName: functionStorageAccountName
  AzureWebJobsStorage__credential: 'managedidentity'
  AzureWebJobsStorage__clientId: functionRuntimeIdentityClientId
  APPLICATIONINSIGHTS_CONNECTION_STRING: applicationInsightsConnectionString
  APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD;ClientId=${functionRuntimeIdentityClientId}'
}

resource functionAppSettings 'Microsoft.Web/sites/config@2024-11-01' = {
  parent: functionApp
  name: 'appsettings'
  properties: union(
    foundationAppSettings,
    deploymentMode == 'application'
      ? {
          RenderService__BaseUrl: renderServiceBaseUrl
        }
      : {}
  )
}
