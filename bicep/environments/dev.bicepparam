using '../main.bicep'

param environmentName = 'dev'
param location = 'westus2'
param resourceGroupName = 'rg-html2b-dev'
param containerRegistryName = 'crhtml2bdev'
param imageRepositoryName = 'html2b-render'
param logAnalyticsWorkspaceName = 'log-html2b-dev'
param containerAppsEnvironmentName = 'cae-html2b-dev'
param functionStorageAccountName = 'sthtml2bfuncdev'
param functionPlanName = 'plan-html2b-functions-dev'
param applicationInsightsName = 'appi-html2b-dev'
param functionAppName = 'func-html2b-api-dev'
param functionDeploymentContainerName = 'function-releases'
param functionRuntime = 'dotnet-isolated'
param functionRuntimeVersion = '10.0'
param functionInstanceMemoryMb = 2048
param functionMaximumInstanceCount = 1
param renderIdentityName = 'id-html2b-render-dev'
param renderContainerAppName = 'ca-html2b-render-dev'
param renderCpu = 1
param renderMemory = '2Gi'
param renderMinReplicas = 0
param renderMaxReplicas = 1
param renderHttpConcurrency = 1
