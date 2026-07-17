param location string
param virtualNetworkName string
param virtualNetworkAddressPrefix string
param containerAppsSubnetName string
param containerAppsSubnetAddressPrefix string
param functionsSubnetName string
param functionsSubnetAddressPrefix string
param baseTags object

assert exactVirtualNetworkRange = virtualNetworkAddressPrefix == '10.40.0.0/24'
assert exactContainerAppsSubnetRange = containerAppsSubnetAddressPrefix == '10.40.0.0/27'
assert exactFunctionsSubnetRange = functionsSubnetAddressPrefix == '10.40.0.32/27'
assert dedicatedSubnets = containerAppsSubnetName != functionsSubnetName && containerAppsSubnetAddressPrefix != functionsSubnetAddressPrefix

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2026-01-01' = {
  name: virtualNetworkName
  location: location
  tags: union(baseTags, {
    Component: 'Network'
  })
  properties: {
    addressSpace: {
      addressPrefixes: [
        virtualNetworkAddressPrefix
      ]
    }
    dhcpOptions: {
      dnsServers: []
    }
  }
}

resource containerAppsSubnet 'Microsoft.Network/virtualNetworks/subnets@2026-01-01' = {
  parent: virtualNetwork
  name: containerAppsSubnetName
  properties: {
    addressPrefix: containerAppsSubnetAddressPrefix
    delegations: [
      {
        name: 'container-apps-environments'
        properties: {
          serviceName: 'Microsoft.App/environments'
        }
      }
    ]
    serviceEndpoints: []
    privateEndpointNetworkPolicies: 'Enabled'
    privateLinkServiceNetworkPolicies: 'Enabled'
  }
}

resource functionsSubnet 'Microsoft.Network/virtualNetworks/subnets@2026-01-01' = {
  parent: virtualNetwork
  name: functionsSubnetName
  properties: {
    addressPrefix: functionsSubnetAddressPrefix
    delegations: [
      {
        name: 'functions-flex-environments'
        properties: {
          serviceName: 'Microsoft.App/environments'
        }
      }
    ]
    serviceEndpoints: []
    privateEndpointNetworkPolicies: 'Enabled'
    privateLinkServiceNetworkPolicies: 'Enabled'
  }
}

output virtualNetworkId string = virtualNetwork.id
output containerAppsSubnetId string = containerAppsSubnet.id
output functionsSubnetId string = functionsSubnet.id
