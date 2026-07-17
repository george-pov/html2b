using '../main.bicep'

param deploymentMode = 'foundation'
param environmentName = 'dev'
param location = 'westus2'
param resourceGroupName = 'rg-html2b-dev'
param containerRegistryName = 'crhtml2bdev'
param imageRepositoryName = 'html2b-api'
param logAnalyticsWorkspaceName = 'log-html2b-dev'
param containerAppsEnvironmentName = 'cae-html2b-dev'
param runtimeIdentityName = 'id-html2b-api-dev'
param containerAppName = 'ca-html2b-dev'
param logRetentionInDays = 30
param containerCpu = 1
param containerMemory = '2Gi'
param minReplicas = 0
param maxReplicas = 1
param httpConcurrency = 1
