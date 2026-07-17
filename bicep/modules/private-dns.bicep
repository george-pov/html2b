param environmentDefaultDomain string
param environmentStaticIp string
param virtualNetworkId string
param baseTags object

assert generatedDomainIsValid = endsWith(environmentDefaultDomain, '.azurecontainerapps.io')
assert environmentIpIsPresent = !empty(environmentStaticIp)

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: environmentDefaultDomain
  location: 'global'
  tags: union(baseTags, {
    Component: 'Network'
  })
}

resource wildcardRecord 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: privateDnsZone
  name: '*'
  properties: {
    ttl: 3600
    aRecords: [
      {
        ipv4Address: environmentStaticIp
      }
    ]
  }
}

resource virtualNetworkLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone
  name: 'vnet-html2b-dev-link'
  location: 'global'
  tags: union(baseTags, {
    Component: 'Network'
  })
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetworkId
    }
  }
}

output privateDnsZoneName string = privateDnsZone.name
