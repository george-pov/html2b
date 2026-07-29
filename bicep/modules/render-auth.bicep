targetScope = 'resourceGroup'

param tenantId string
param renderApiClientId string
param functionPrincipalId string
param renderContainerAppName string

resource renderContainerApp 'Microsoft.App/containerApps@2026-01-01' existing = {
  name: renderContainerAppName
}

resource renderAuthConfig 'Microsoft.App/containerApps/authConfigs@2026-01-01' = {
  parent: renderContainerApp
  name: 'current'
  properties: {
    globalValidation: {
      excludedPaths: []
      unauthenticatedClientAction: 'Return401'
    }
    httpSettings: {
      requireHttps: true
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: renderApiClientId
          #disable-next-line no-hardcoded-env-urls
          openIdIssuer: 'https://login.microsoftonline.com/${tenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [
            renderApiClientId
          ]
          defaultAuthorizationPolicy: {
            allowedPrincipals: {
              identities: [
                functionPrincipalId
              ]
            }
          }
        }
      }
    }
    platform: {
      enabled: true
    }
  }
}
