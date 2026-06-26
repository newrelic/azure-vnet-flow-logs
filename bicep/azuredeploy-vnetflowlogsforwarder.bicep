@description('Optional. New Relic License Key (modern ingest key). Provide either this or newRelicInsertKey; one of the two is required.')
@secure()
param newRelicLicenseKey string = ''

@description('Optional. Legacy New Relic Insert Key (for older accounts). Provide either this or newRelicLicenseKey; one of the two is required.')
@secure()
param newRelicInsertKey string = ''

@description('Optional. Name of the existing storage account where VNet Flow Logs PT1H.json files are stored. Must be in the same resource group as this deployment. Leave this blank to create a new storage account (its name will start with \'nrvnetflsrc\').')
param sourceStorageAccountName string = ''

@description('Optional. Region where all resources included in this template will be deployed. Leave this blank to use the same region as the one of the resource group.')
param location string = ''

@description('Optional. The Logs API endpoint for your New Relic account region. Select US (default), EU, or JP endpoint.')
@allowed([
  'https://log-api.newrelic.com/log/v1'
  'https://log-api.eu.newrelic.com/log/v1'
  'https://log-api.jp.nr-data.net/log/v1'
])
param newRelicEndpoint string = 'https://log-api.newrelic.com/log/v1'

@description('Optional. Custom tags to add to logs sent to New Relic (semicolon-separated key:value pairs, e.g. env:prod;team:network).')
param newRelicTags string = ''

@description('Optional. Maximum number of retries when sending logs to New Relic.')
param maxRetries int = 3

@description('Optional. Retry interval in milliseconds when sending logs to New Relic.')
param retryInterval int = 2000

@description('Optional. Enable debug logging for troubleshooting.')
param debugEnabled bool = false

@description('Optional. Number of hours to retain blob-cursor records before the cleanup job removes them.')
@minValue(1)
param cursorRetentionHours int = 48

@description('Optional. NCRONTAB schedule for the cursor cleanup timer trigger (default: daily at 03:00 UTC).')
param cursorCleanupSchedule string = '0 0 3 * * *'

@description('Optional. Number of consecutive failures per blob before the forwarder skips it as a poison event.')
@minValue(1)
param maxConsecutiveFailures int = 3

@description('Optional. Maximum number of Flex Consumption instances the function app can scale to. Range: 1 to 1000.')
@minValue(1)
@maxValue(1000)
param maximumInstanceCount int = 100

@description('Optional. Memory allocated per Flex Consumption instance, in MB. Allowed values: 512, 2048, 4096.')
@allowed([
  512
  2048
  4096
])
param instanceMemoryMB int = 2048

@description('Optional. Event Hub scaling profile. \'Basic\' uses 1 throughput unit with 4 partitions and no auto-inflate (suitable for low-to-medium traffic). \'Enterprise\' enables auto-inflate up to 40 throughput units with 32 partitions (recommended for high-throughput / large-scale flow-log volumes). Note: partition count is fixed at Event Hub creation time and cannot be changed by a subsequent deployment.')
@allowed([
  'Basic'
  'Enterprise'
])
param eventHubScalingMode string = 'Basic'

@description('Optional. When enabled, the function storage account, the function app, and the Event Hub are isolated within a private Virtual Network with private endpoints; public network access to them is disabled. The source storage account (containing VNet Flow Logs) is not modified and is expected to have public network access enabled.')
param disablePublicAccessToStorageAccount bool = false

var uniqueResourceNameSuffix = uniqueString(resourceGroup().id)
var effectiveLocation = (empty(location) ? resourceGroup().location : location)
var createNewSourceStorage = empty(sourceStorageAccountName)
var resolvedSourceStorageName = (createNewSourceStorage
  ? 'nrvnetflsrc${uniqueResourceNameSuffix}'
  : sourceStorageAccountName)
var eventHubNamespaceName = 'nrvnetflowlogs-eventhub-namespace-${uniqueResourceNameSuffix}'
var resolvedEventHubName = 'nrvnetflowlogs-eventhub'
var eventHubConsumerGroupName = 'nrvnetflowlogs-consumergroup'
var eventHubAuthRuleName = 'nrvnetflowlogs-consumer-policy'
var resolvedSystemTopicName = 'nrvnetflowlogs-eventgrid-topic-${uniqueResourceNameSuffix}'
var resolvedSubscriptionName = 'nrvnetflowlogs-eventgrid-subscription-${uniqueResourceNameSuffix}'
var cursorTableName = 'nrvnetflowlogscursors'
var functionStorageAccountName = 'nrvnetflfn${uniqueResourceNameSuffix}'
var servicePlanName = 'nrvnetflowlogs-serviceplan-${uniqueResourceNameSuffix}'
var functionAppName = 'nrvnetflowlogs-forwarder-${uniqueResourceNameSuffix}'
var deploymentIdentityName = 'nrvnetflowlogs-deploy-id-${uniqueResourceNameSuffix}'
var deploymentScriptName = 'nrvnetflowlogs-deploy-script-${uniqueResourceNameSuffix}'
var websiteContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'de139f84-1756-47ae-9be6-808fbbe84772'
)
var storageFileDataPrivilegedContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '69566ab7-960f-475b-8e7c-b3118f30c6bd'
)
var eventHubsDataSenderRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '2b629674-e913-4c01-ae53-ef4638d8f975'
)
var vnetFlowLogsForwarderFunctionArtifact = 'https://github.com/newrelic/azure-vnet-flow-logs/releases/latest/download/VNetFlowForwarder.zip'
var sourceStorageAccountId = sourceStorageAccountNameResolved.id

var virtualNetworkName = 'nrvnetflowlogs-vnet-${uniqueResourceNameSuffix}'
var functionsSubnetName = 'functions-subnet'
var privateEndpointsSubnetName = 'private-endpoints-subnet'
var deploymentScriptsSubnetName = 'deployment-scripts-subnet'
var blobPrivateDnsZoneName = 'privatelink.blob.${environment().suffixes.storage}'
var filePrivateDnsZoneName = 'privatelink.file.${environment().suffixes.storage}'
var queuePrivateDnsZoneName = 'privatelink.queue.${environment().suffixes.storage}'
var tablePrivateDnsZoneName = 'privatelink.table.${environment().suffixes.storage}'
var serviceBusDnsSuffix = {
  AzureCloud: 'servicebus.windows.net'
  AzureUSGovernment: 'servicebus.usgovcloudapi.net'
  AzureChinaCloud: 'servicebus.chinacloudapi.cn'
}
var eventHubPrivateDnsZoneName = 'privatelink.${serviceBusDnsSuffix[environment().name]}'
var appServiceDnsZone = {
  AzureCloud: 'privatelink.azurewebsites.net'
  AzureUSGovernment: 'privatelink.azurewebsites.us'
  AzureChinaCloud: 'privatelink.chinacloudsites.cn'
}
var sitesPrivateDnsZoneName = appServiceDnsZone[environment().name]
var eventHubNamespacePrivateEndpointName = '${eventHubNamespaceName}-namespace-pe'
var functionStorageBlobPrivateEndpointName = '${functionStorageAccountName}-blob-pe'
var functionStorageFilePrivateEndpointName = '${functionStorageAccountName}-file-pe'
var functionStorageQueuePrivateEndpointName = '${functionStorageAccountName}-queue-pe'
var functionStorageTablePrivateEndpointName = '${functionStorageAccountName}-table-pe'
var functionAppPrivateEndpointName = '${functionAppName}-sites-pe'
var flexConsumptionASP = {
  kind: 'functionapp,linux'
  properties: {
    reserved: true
  }
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
}

resource sourceStorageAccountNameResolved 'Microsoft.Storage/storageAccounts@2023-05-01' = if (createNewSourceStorage) {
  name: resolvedSourceStorageName
  location: effectiveLocation
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
    supportsHttpsTrafficOnly: true
    encryption: {
      services: {
        blob: {
          keyType: 'Account'
          enabled: true
        }
      }
      keySource: 'Microsoft.Storage'
    }
    accessTier: 'Hot'
  }
}

resource eventHubNamespace_resource 'Microsoft.EventHub/namespaces@2021-11-01' = {
  name: eventHubNamespaceName
  location: effectiveLocation
  sku: {
    name: 'Standard'
    tier: 'Standard'
    capacity: 1
  }
  properties: {
    minimumTlsVersion: '1.2'
    isAutoInflateEnabled: (eventHubScalingMode == 'Enterprise')
    maximumThroughputUnits: (eventHubScalingMode == 'Enterprise' ? 40 : 0)
  }
}

resource eventHubNamespaceName_eventHub 'Microsoft.EventHub/namespaces/eventhubs@2021-11-01' = {
  parent: eventHubNamespace_resource
  name: resolvedEventHubName
  properties: {
    messageRetentionInDays: 1
    partitionCount: (eventHubScalingMode == 'Enterprise' ? 32 : 4)
  }
}

resource eventHubNamespaceName_eventHubName_eventHubConsumerGroup 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2021-11-01' = {
  parent: eventHubNamespaceName_eventHub
  name: eventHubConsumerGroupName
  properties: {}
}

resource eventHubNamespaceName_eventHubAuthRule 'Microsoft.EventHub/namespaces/AuthorizationRules@2021-11-01' = {
  parent: eventHubNamespace_resource
  name: eventHubAuthRuleName
  properties: {
    rights: [
      'Listen'
    ]
  }
}

resource eventGridSystemTopic 'Microsoft.EventGrid/systemTopics@2021-12-01' = {
  name: resolvedSystemTopicName
  location: effectiveLocation
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    source: sourceStorageAccountId
    topicType: 'Microsoft.Storage.StorageAccounts'
  }
}

resource functionStorageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: functionStorageAccountName
  location: effectiveLocation
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    publicNetworkAccess: (disablePublicAccessToStorageAccount ? 'Disabled' : 'Enabled')
    networkAcls: (disablePublicAccessToStorageAccount ? {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    } : {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    })
    supportsHttpsTrafficOnly: true
    encryption: {
      services: {
        file: {
          keyType: 'Account'
          enabled: true
        }
        blob: {
          keyType: 'Account'
          enabled: true
        }
        table: {
          keyType: 'Account'
          enabled: true
        }
      }
      keySource: 'Microsoft.Storage'
    }
    accessTier: 'Hot'
  }
}

resource functionStorageAccountName_default 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: functionStorageAccount
  name: 'default'
  properties: {}
}

resource functionStorageAccountName_default_deployments 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: functionStorageAccountName_default
  name: 'deployments'
  properties: {
    publicAccess: 'None'
  }
}

resource functionStorageTableServices 'Microsoft.Storage/storageAccounts/tableServices@2022-09-01' = {
  parent: functionStorageAccount
  name: 'default'
  properties: {}
}

resource cursorTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2022-09-01' = {
  parent: functionStorageTableServices
  name: cursorTableName
  properties: {}
}

resource servicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: servicePlanName
  location: effectiveLocation
  kind: flexConsumptionASP.kind
  properties: flexConsumptionASP.properties
  sku: flexConsumptionASP.sku
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: effectiveLocation
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: servicePlan.id
    httpsOnly: true
    publicNetworkAccess: (disablePublicAccessToStorageAccount ? 'Disabled' : 'Enabled')
    virtualNetworkSubnetId: (disablePublicAccessToStorageAccount ? functionsSubnet.id : null)
    vnetRouteAllEnabled: disablePublicAccessToStorageAccount
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: 'https://${functionStorageAccountName}.blob.${environment().suffixes.storage}/deployments'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: maximumInstanceCount
        instanceMemoryMB: instanceMemoryMB
      }
      runtime: {
        name: 'node'
        version: '22'
      }
    }
    siteConfig: {
      appSettings: [
        {
          name: 'AzureWebJobsStorage__accountName'
          value: functionStorageAccountName
        }
        {
          name: 'EVENTHUB_NAME'
          value: resolvedEventHubName
        }
        {
          name: 'EVENTHUB_CONSUMER_CONNECTION'
          value: eventHubNamespaceName_eventHubAuthRule.listKeys().primaryConnectionString
        }
        {
          name: 'EVENTHUB_CONSUMER_GROUP'
          value: eventHubConsumerGroupName
        }
        {
          name: 'SOURCE_STORAGE_CONNECTION'
          value: 'DefaultEndpointsProtocol=https;AccountName=${resolvedSourceStorageName};AccountKey=${listKeys(resourceId('Microsoft.Storage/storageAccounts', resolvedSourceStorageName), '2023-05-01').keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'CURSOR_STORAGE_CONNECTION'
          value: 'DefaultEndpointsProtocol=https;AccountName=${functionStorageAccountName};AccountKey=${functionStorageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'CURSOR_RETENTION_HOURS'
          value: string(cursorRetentionHours)
        }
        {
          name: 'CURSOR_CLEANUP_SCHEDULE'
          value: cursorCleanupSchedule
        }
        {
          name: 'MAX_CONSECUTIVE_FAILURES'
          value: string(maxConsecutiveFailures)
        }
        {
          name: 'NR_LICENSE_KEY'
          value: newRelicLicenseKey
        }
        {
          name: 'NR_INSERT_KEY'
          value: newRelicInsertKey
        }
        {
          name: 'NR_ENDPOINT'
          value: newRelicEndpoint
        }
        {
          name: 'NR_TAGS'
          value: newRelicTags
        }
        {
          name: 'NR_MAX_RETRIES'
          value: string(maxRetries)
        }
        {
          name: 'NR_RETRY_INTERVAL'
          value: string(retryInterval)
        }
        {
          name: 'DEBUG_ENABLED'
          value: string(debugEnabled)
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
      ]
      ftpsState: 'Disabled'
    }
  }
  dependsOn: [
    functionStorageAccountName_default_deployments
    cursorTable
    functionStorageBlobPrivateEndpointDnsGroup
    functionStorageFilePrivateEndpointDnsGroup
    functionStorageQueuePrivateEndpointDnsGroup
    functionStorageTablePrivateEndpointDnsGroup
  ]
}

resource functionAppStorageBlobDataOwnerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: functionStorageAccount
  name: guid(functionApp.id, functionStorageAccount.id, 'StorageBlobDataOwner')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
    )
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource functionAppStorageQueueDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: functionStorageAccount
  name: guid(functionApp.id, functionStorageAccount.id, 'StorageQueueDataContributor')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
    )
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource functionAppStorageTableDataContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: functionStorageAccount
  name: guid(functionApp.id, functionStorageAccount.id, 'StorageTableDataContributor')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
    )
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource deploymentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: deploymentIdentityName
  location: effectiveLocation
}

resource deploymentScriptWebsiteContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: functionApp
  name: guid(functionApp.id, deploymentIdentityName, 'WebsiteContributor')
  properties: {
    roleDefinitionId: websiteContributorRoleId
    principalId: deploymentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Required when the deployment script runs in a subnet against a firewalled storage account:
// the script's UAMI authenticates to the storage's file share via SMB.
resource deploymentScriptStorageFileContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (disablePublicAccessToStorageAccount) {
  scope: functionStorageAccount
  name: guid(functionStorageAccount.id, deploymentIdentityName, 'StorageFileDataPrivilegedContributor')
  properties: {
    roleDefinitionId: storageFileDataPrivilegedContributorRoleId
    principalId: deploymentIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Lets Event Grid deliver events to the Event Hub via deliveryWithResourceIdentity
resource eventGridSystemTopicEventHubsDataSenderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: eventHubNamespace_resource
  name: guid(eventHubNamespace_resource.id, resolvedSystemTopicName, 'EventHubsDataSender')
  properties: {
    roleDefinitionId: eventHubsDataSenderRoleId
    principalId: eventGridSystemTopic.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ===== Private networking (conditional on disablePublicAccessToStorageAccount) =====

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-09-01' = if (disablePublicAccessToStorageAccount) {
  name: virtualNetworkName
  location: effectiveLocation
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: functionsSubnetName
        properties: {
          addressPrefix: '10.0.0.0/24'
          delegations: [
            {
              name: 'delegation'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: privateEndpointsSubnetName
        properties: {
          addressPrefix: '10.0.1.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Disabled'
        }
      }
      {
        name: deploymentScriptsSubnetName
        properties: {
          addressPrefix: '10.0.2.0/28'
          delegations: [
            {
              name: 'delegation'
              properties: {
                serviceName: 'Microsoft.ContainerInstance/containerGroups'
              }
            }
          ]
        }
      }
    ]
  }
}

// Subnet symbolic refs (existing) so the function app + deployment script can reference IDs
resource functionsSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: virtualNetwork
  name: functionsSubnetName
}

resource deploymentScriptsSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: virtualNetwork
  name: deploymentScriptsSubnetName
}

resource privateEndpointsSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: virtualNetwork
  name: privateEndpointsSubnetName
}

resource blobPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (disablePublicAccessToStorageAccount) {
  name: blobPrivateDnsZoneName
  location: 'global'
}

resource filePrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (disablePublicAccessToStorageAccount) {
  name: filePrivateDnsZoneName
  location: 'global'
}

resource queuePrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (disablePublicAccessToStorageAccount) {
  name: queuePrivateDnsZoneName
  location: 'global'
}

resource tablePrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (disablePublicAccessToStorageAccount) {
  name: tablePrivateDnsZoneName
  location: 'global'
}

resource sitesPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (disablePublicAccessToStorageAccount) {
  name: sitesPrivateDnsZoneName
  location: 'global'
}

resource blobDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (disablePublicAccessToStorageAccount) {
  parent: blobPrivateDnsZone
  name: 'link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource fileDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (disablePublicAccessToStorageAccount) {
  parent: filePrivateDnsZone
  name: 'link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource queueDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (disablePublicAccessToStorageAccount) {
  parent: queuePrivateDnsZone
  name: 'link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource tableDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (disablePublicAccessToStorageAccount) {
  parent: tablePrivateDnsZone
  name: 'link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource sitesDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (disablePublicAccessToStorageAccount) {
  parent: sitesPrivateDnsZone
  name: 'link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource functionStorageBlobPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = if (disablePublicAccessToStorageAccount) {
  name: functionStorageBlobPrivateEndpointName
  location: effectiveLocation
  properties: {
    subnet: {
      id: privateEndpointsSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: {
          privateLinkServiceId: functionStorageAccount.id
          groupIds: [ 'blob' ]
        }
      }
    ]
  }
}

resource functionStorageFilePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = if (disablePublicAccessToStorageAccount) {
  name: functionStorageFilePrivateEndpointName
  location: effectiveLocation
  properties: {
    subnet: {
      id: privateEndpointsSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'file'
        properties: {
          privateLinkServiceId: functionStorageAccount.id
          groupIds: [ 'file' ]
        }
      }
    ]
  }
}

resource functionStorageQueuePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = if (disablePublicAccessToStorageAccount) {
  name: functionStorageQueuePrivateEndpointName
  location: effectiveLocation
  properties: {
    subnet: {
      id: privateEndpointsSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'queue'
        properties: {
          privateLinkServiceId: functionStorageAccount.id
          groupIds: [ 'queue' ]
        }
      }
    ]
  }
}

resource functionStorageTablePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = if (disablePublicAccessToStorageAccount) {
  name: functionStorageTablePrivateEndpointName
  location: effectiveLocation
  properties: {
    subnet: {
      id: privateEndpointsSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'table'
        properties: {
          privateLinkServiceId: functionStorageAccount.id
          groupIds: [ 'table' ]
        }
      }
    ]
  }
}

resource functionAppPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = if (disablePublicAccessToStorageAccount) {
  name: functionAppPrivateEndpointName
  location: effectiveLocation
  properties: {
    subnet: {
      id: privateEndpointsSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'sites'
        properties: {
          privateLinkServiceId: functionApp.id
          groupIds: [ 'sites' ]
        }
      }
    ]
  }
}

resource functionStorageBlobPrivateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (disablePublicAccessToStorageAccount) {
  parent: functionStorageBlobPrivateEndpoint
  name: 'default'
  dependsOn: [
    blobDnsZoneVnetLink
  ]
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: blobPrivateDnsZone.id
        }
      }
    ]
  }
}

resource functionStorageFilePrivateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (disablePublicAccessToStorageAccount) {
  parent: functionStorageFilePrivateEndpoint
  name: 'default'
  dependsOn: [
    fileDnsZoneVnetLink
  ]
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'file'
        properties: {
          privateDnsZoneId: filePrivateDnsZone.id
        }
      }
    ]
  }
}

resource functionStorageQueuePrivateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (disablePublicAccessToStorageAccount) {
  parent: functionStorageQueuePrivateEndpoint
  name: 'default'
  dependsOn: [
    queueDnsZoneVnetLink
  ]
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'queue'
        properties: {
          privateDnsZoneId: queuePrivateDnsZone.id
        }
      }
    ]
  }
}

resource functionStorageTablePrivateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (disablePublicAccessToStorageAccount) {
  parent: functionStorageTablePrivateEndpoint
  name: 'default'
  dependsOn: [
    tableDnsZoneVnetLink
  ]
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'table'
        properties: {
          privateDnsZoneId: tablePrivateDnsZone.id
        }
      }
    ]
  }
}

resource functionAppPrivateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (disablePublicAccessToStorageAccount) {
  parent: functionAppPrivateEndpoint
  name: 'default'
  dependsOn: [
    sitesDnsZoneVnetLink
  ]
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sites'
        properties: {
          privateDnsZoneId: sitesPrivateDnsZone.id
        }
      }
    ]
  }
}

// Explicit Allow rule set so Azure's PE-attach flow doesn't implicitly try to flip the namespace
// to a Deny rule set (which then fails validation: Deny + zero IP/VNet rules is rejected).
resource eventHubNamespaceNetworkRuleSet 'Microsoft.EventHub/namespaces/networkRuleSets@2021-11-01' = if (disablePublicAccessToStorageAccount) {
  parent: eventHubNamespace_resource
  name: 'default'
  properties: {
    publicNetworkAccess: 'Enabled'
    defaultAction: 'Allow'
    trustedServiceAccessEnabled: true
  }
}

resource eventHubPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (disablePublicAccessToStorageAccount) {
  name: eventHubPrivateDnsZoneName
  location: 'global'
}

resource eventHubDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (disablePublicAccessToStorageAccount) {
  parent: eventHubPrivateDnsZone
  name: 'link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource eventHubNamespacePrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = if (disablePublicAccessToStorageAccount) {
  name: eventHubNamespacePrivateEndpointName
  location: effectiveLocation
  properties: {
    subnet: {
      id: privateEndpointsSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'namespace'
        properties: {
          privateLinkServiceId: eventHubNamespace_resource.id
          groupIds: [ 'namespace' ]
        }
      }
    ]
  }
}

resource eventHubNamespacePrivateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (disablePublicAccessToStorageAccount) {
  parent: eventHubNamespacePrivateEndpoint
  name: 'default'
  dependsOn: [
    eventHubDnsZoneVnetLink
  ]
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'namespace'
        properties: {
          privateDnsZoneId: eventHubPrivateDnsZone.id
        }
      }
    ]
  }
}

resource deploymentScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: deploymentScriptName
  location: effectiveLocation
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${deploymentIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.61.0'
    timeout: 'PT15M'
    retentionInterval: 'PT1H'
    cleanupPreference: 'OnSuccess'
    containerSettings: (disablePublicAccessToStorageAccount ? {
      subnetIds: [
        {
          id: deploymentScriptsSubnet.id
        }
      ]
    } : null)
    storageAccountSettings: (disablePublicAccessToStorageAccount ? {
      storageAccountName: functionStorageAccountName
    } : null)
    environmentVariables: [
      {
        name: 'ZIP_URL'
        value: vnetFlowLogsForwarderFunctionArtifact
      }
      {
        name: 'FUNCTION_APP'
        value: functionAppName
      }
      {
        name: 'RESOURCE_GROUP'
        value: resourceGroup().name
      }
    ]
    scriptContent: 'set -euo pipefail\n\necho \'Downloading package via python urllib (curl not preinstalled, python is)...\'\npython3 -c "import os, urllib.request; urllib.request.urlretrieve(os.environ[\'ZIP_URL\'], \'/tmp/package.zip\')"\nls -la /tmp/package.zip\n\necho \'Deploying via az functionapp deployment source config-zip (Flex-supported path)...\'\naz functionapp deployment source config-zip \\\n  --resource-group "$RESOURCE_GROUP" \\\n  --name "$FUNCTION_APP" \\\n  --src /tmp/package.zip \\\n  --build-remote false \\\n  --timeout 300\n'
  }
  dependsOn: [
    functionApp
    deploymentScriptWebsiteContributorAssignment
    deploymentScriptStorageFileContributorAssignment
    functionAppPrivateEndpointDnsGroup
    functionStorageBlobPrivateEndpointDnsGroup
    functionStorageFilePrivateEndpointDnsGroup
    functionStorageQueuePrivateEndpointDnsGroup
    functionStorageTablePrivateEndpointDnsGroup
  ]
}

resource eventGridSystemTopicName_eventGridSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2021-12-01' = {
  parent: eventGridSystemTopic
  name: resolvedSubscriptionName
  properties: {
    deliveryWithResourceIdentity: {
      identity: {
        type: 'SystemAssigned'
      }
      destination: {
        endpointType: 'EventHub'
        properties: {
          resourceId: eventHubNamespaceName_eventHub.id
          deliveryAttributeMappings: [
            {
              name: 'PartitionKey'
              type: 'Dynamic'
              properties: {
                sourceField: 'subject'
              }
            }
          ]
        }
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.Storage.BlobCreated'
      ]
      enableAdvancedFilteringOnArrays: true
      advancedFilters: [
        {
          operatorType: 'StringContains'
          key: 'subject'
          values: [
            'insights-logs-flowlogflowevent'
          ]
        }
      ]
      subjectEndsWith: 'PT1H.json'
    }
    labels: []
    eventDeliverySchema: 'EventGridSchema'
    retryPolicy: {
      maxDeliveryAttempts: 30
      eventTimeToLiveInMinutes: 1440
    }
  }
  dependsOn: [
    eventGridSystemTopicEventHubsDataSenderAssignment
  ]
}
