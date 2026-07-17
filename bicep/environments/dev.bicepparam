using '../main.bicep'

param deploymentMode = 'foundation'
param environmentName = 'dev'
param location = 'westus2'
param resourceGroupName = 'rg-html2b-dev'

param containerRegistryName = 'crhtml2bdev'
param renderImageRepositoryName = 'html2b-render'
param renderContainerAppsEnvironmentName = 'cae-html2b-render-dev'
param renderRuntimeIdentityName = 'id-html2b-render-dev'
param renderContainerAppName = 'ca-html2b-render-dev'
param renderCpu = 1
param renderMemory = '2Gi'
param renderMinReplicas = 0
param renderMaxReplicas = 1
param renderHttpConcurrency = 1

param logAnalyticsWorkspaceName = 'log-html2b-dev'
param applicationInsightsName = 'appi-html2b-dev'
param logRetentionInDays = 30

param virtualNetworkName = 'vnet-html2b-dev'
param virtualNetworkAddressPrefix = '10.40.0.0/24'
param containerAppsSubnetName = 'snet-container-apps-dev'
param containerAppsSubnetAddressPrefix = '10.40.0.0/27'
param functionsSubnetName = 'snet-functions-dev'
param functionsSubnetAddressPrefix = '10.40.0.32/27'

param functionStorageAccountName = 'sthtml2bfuncdev'
param functionDeploymentContainerName = 'func-html2b-api-dev-packages'
param functionRuntimeIdentityName = 'id-html2b-functions-dev'
param functionPlanName = 'plan-html2b-functions-dev'
param functionAppName = 'func-html2b-api-dev'
param functionRuntimeName = 'dotnet-isolated'
param functionRuntimeVersion = '10'
param functionInstanceMemoryMb = 2048
param functionMaximumInstanceCount = 1
param functionHttpConcurrency = 1

param applicationDeploymentIdentityName = 'id-html2b-application-deploy-dev'
param githubOidcIssuer = 'https://token.actions.githubusercontent.com'
param githubOidcAudience = 'api://AzureADTokenExchange'
param githubOidcSubject = 'repo:george-pov/html2b:environment:dev'
