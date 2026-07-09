@description('Required. New Relic Ingest License Key.')
@secure()
@minLength(1)
param newRelicIngestLicenseKey string

@description('Optional. Authentication method the function uses to connect to the Event Hub and storage accounts. Use \'Managed Identity\' (default) for keyless authentication using the function\'s system-assigned identity, or \'Local Authentication\' to connect via shared-key connection strings.')
@allowed([
  'Local Authentication'
  'Managed Identity'
])
param authenticationMode string = 'Managed Identity'

@description('Optional. The storage account where Azure writes your VNet flow logs. Must be in the same resource group as this deployment. Leave blank to provision a new one.')
param flowLogsStorageAccountName string = ''

@description('Optional. The Logs API endpoint for your New Relic account region.')
@allowed([
  'https://log-api.newrelic.com/log/v1'
  'https://log-api.eu.newrelic.com/log/v1'
  'https://log-api.jp.nr-data.net/log/v1'
])
param newRelicEndpoint string = 'https://log-api.newrelic.com/log/v1'

@description('Optional. Custom tags to attach to every log sent to New Relic. Format: semicolon-separated key:value pairs (e.g. env:prod;team:network).')
param newRelicTags string = ''

@description('Optional. Maximum number of retries when sending logs to New Relic.')
param maxRetries int = 3

@description('Optional. Retry interval in milliseconds when sending logs to New Relic.')
param retryInterval int = 2000

@description('Optional. Default log level for the forwarder.')
@allowed([
  'Trace'
  'Debug'
  'Information'
  'Warning'
  'Error'
])
param functionLogLevel string = 'Information'

@description('Optional. Event Hub scaling profile. Basic uses 1 throughput unit with 4 partitions and no auto-inflate (suitable for low-to-medium traffic). Enterprise enables auto-inflate up to 40 throughput units with 32 partitions (recommended for high-throughput / large-scale flow-log volumes). Note: partition count is fixed at Event Hub creation time and cannot be changed by a subsequent deployment.')
@allowed([
  'Basic'
  'Enterprise'
])
param eventHubScalingMode string = 'Basic'

@description('Optional. Maximum number of Event Grid blob-created notifications delivered to the function in a single invocation. Each notification triggers a blob download, parse, and New Relic delivery, so this is blobs-per-invocation (not log events). Default is 10.')
@minValue(1)
param maxEventBatchSize int = 10

@description('Optional. Minimum number of Event Grid blob-created notifications delivered to the function in a single invocation. The trigger waits to accumulate this many notifications (or until maxWaitTime elapses) before invoking, avoiding a separate invocation per single event. Default is 5.')
@minValue(1)
param minEventBatchSize int = 5

@description('Optional. Maximum amount of time to wait to build up a batch before invoking the function, in HH:MM:SS format. Default is 00:00:30.')
param maxWaitTime string = '00:00:30'

@description('Optional. When enabled, the forwarder runs inside a private virtual network with no public network access. The flow logs storage account itself is not locked down and must remain publicly accessible.')
param disablePublicAccessToStorageAccount bool = false

@description('Optional. Function App hosting plan. FlexConsumption (default) is a modern serverless plan available in ~30 Azure regions as of mid-2026 and is preferred where supported. Additional plans (ElasticPremium, Basic, Consumption) will be added in subsequent releases as fallbacks for regions where FlexConsumption is not yet available.')
@allowed([
  'FlexConsumption'
])
param functionAppPlan string = 'FlexConsumption'

var uniqueResourceNameSuffix = uniqueString(resourceGroup().id)
var effectiveLocation = resourceGroup().location
var createNewFlowLogsStorage = empty(flowLogsStorageAccountName)
var resolvedFlowLogsStorageName = (createNewFlowLogsStorage
  ? 'nrvnetflsrc${uniqueResourceNameSuffix}'
  : flowLogsStorageAccountName)
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
var eventGridDeliveryIdentityName = 'nrvnetflowlogs-eg-delivery-id-${uniqueResourceNameSuffix}'
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
// Built-in role: Azure Event Hubs Data Receiver (immutable, fixed by Microsoft)
var eventHubsDataReceiverRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'a638d3c7-ab3a-418d-83e6-5f17a39d4fde'
)
// Built-in role: Storage Blob Data Reader (immutable, fixed by Microsoft)
var storageBlobDataReaderRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
)
var vnetFlowLogsForwarderFunctionArtifact = 'https://github.com/newrelic/azure-vnet-flow-logs/releases/latest/download/VNetFlowForwarder.zip'
var flowLogsStorageAccountId = flowLogsStorageAccountNameResolved.id

var useManagedIdentity = (authenticationMode == 'Managed Identity')

// Connection settings selected by authentication mode. Only the branch chosen
// by useManagedIdentity is evaluated by ARM, so listKeys() for the Local
// Authentication path is not invoked when Managed Identity is in use.
var managedIdentityAppSettings = [
  {
    name: 'EVENTHUB_CONSUMER_CONNECTION__fullyQualifiedNamespace'
    value: '${eventHubNamespaceName}.${serviceBusDnsSuffix[environment().name]}'
  }
  {
    // Required on Flex Consumption so the host/scale controller authenticates
    // the Event Hub trigger via the system-assigned managed identity.
    name: 'EVENTHUB_CONSUMER_CONNECTION__credential'
    value: 'managedidentity'
  }
  {
    name: 'SOURCE_STORAGE_BLOB_SERVICE_URI'
    value: 'https://${resolvedFlowLogsStorageName}.blob.${environment().suffixes.storage}'
  }
  {
    name: 'CURSOR_STORAGE_TABLE_SERVICE_URI'
    value: 'https://${functionStorageAccountName}.table.${environment().suffixes.storage}'
  }
]
var localAuthAppSettings = [
  {
    name: 'EVENTHUB_CONSUMER_CONNECTION'
    value: eventHubNamespaceName_eventHubAuthRule.listKeys().primaryConnectionString
  }
  {
    name: 'SOURCE_STORAGE_CONNECTION'
    value: 'DefaultEndpointsProtocol=https;AccountName=${resolvedFlowLogsStorageName};AccountKey=${listKeys(resourceId('Microsoft.Storage/storageAccounts', resolvedFlowLogsStorageName), '2024-01-01').keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
  }
  {
    name: 'CURSOR_STORAGE_CONNECTION'
    value: 'DefaultEndpointsProtocol=https;AccountName=${functionStorageAccountName};AccountKey=${functionStorageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
  }
]

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
var planConfig = {
  FlexConsumption: {
    kind: 'functionapp,linux'
    properties: {
      reserved: true
    }
    sku: {
      tier: 'FlexConsumption'
      name: 'FC1'
    }
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
        maximumInstanceCount: (eventHubScalingMode == 'Enterprise' ? 32 : 4)
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'node'
        version: '22'
      }
    }
  }
}
var pc = planConfig[functionAppPlan]

resource flowLogsStorageAccountNameResolved 'Microsoft.Storage/storageAccounts@2024-01-01' = if (createNewFlowLogsStorage) {
  name: resolvedFlowLogsStorageName
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

// Symbolic reference to the source storage account so a role assignment can be
// scoped to it in Managed Identity mode, whether it is newly created here or a
// pre-existing account named via sourceStorageAccountName.
resource flowLogsStorageRef 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: resolvedFlowLogsStorageName
}

resource eventHubNamespace_resource 'Microsoft.EventHub/namespaces@2024-01-01' = {
  name: eventHubNamespaceName
  location: effectiveLocation
  sku: {
    name: 'Standard'
    tier: 'Standard'
    capacity: 1
  }
  properties: {
    minimumTlsVersion: '1.2'
    publicNetworkAccess: (disablePublicAccessToStorageAccount ? 'Disabled' : 'Enabled')
    isAutoInflateEnabled: (eventHubScalingMode == 'Enterprise')
    maximumThroughputUnits: (eventHubScalingMode == 'Enterprise' ? 40 : 0)
  }
}

resource eventHubNamespaceName_eventHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' = {
  parent: eventHubNamespace_resource
  name: resolvedEventHubName
  properties: {
    messageRetentionInDays: 1
    partitionCount: (eventHubScalingMode == 'Enterprise' ? 32 : 4)
  }
}

resource eventHubNamespaceName_eventHubName_eventHubConsumerGroup 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2024-01-01' = {
  parent: eventHubNamespaceName_eventHub
  name: eventHubConsumerGroupName
  properties: {}
}

resource eventHubNamespaceName_eventHubAuthRule 'Microsoft.EventHub/namespaces/AuthorizationRules@2024-01-01' = {
  parent: eventHubNamespace_resource
  name: eventHubAuthRuleName
  properties: {
    rights: [
      'Listen'
    ]
  }
}

// User-assigned identity used by the Event Grid system topic to deliver events into
// the Event Hub. Declared up front (no dependencies) so its principal exists in Entra ID
// at the start of the deploy — this lets the Data Sender role assignment below propagate
// in Entra ID while the rest of the resources (namespace, private endpoints, function app,
// storage) are still provisioning, eliminating the identity-propagation race that a
// system-assigned identity on the topic would otherwise cause.
resource eventGridDeliveryIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: eventGridDeliveryIdentityName
  location: effectiveLocation
}

resource eventGridSystemTopic 'Microsoft.EventGrid/systemTopics@2025-02-15' = {
  name: resolvedSystemTopicName
  location: effectiveLocation
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${eventGridDeliveryIdentity.id}': {}
    }
  }
  properties: {
    source: flowLogsStorageAccountId
    topicType: 'Microsoft.Storage.StorageAccounts'
  }
}

resource functionStorageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' = {
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

resource functionStorageAccountName_default 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: functionStorageAccount
  name: 'default'
  properties: {}
}

resource functionStorageAccountName_default_deployments 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: functionStorageAccountName_default
  name: 'deployments'
  properties: {
    publicAccess: 'None'
  }
}

resource functionStorageTableServices 'Microsoft.Storage/storageAccounts/tableServices@2024-01-01' = {
  parent: functionStorageAccount
  name: 'default'
  properties: {}
}

resource cursorTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2024-01-01' = {
  parent: functionStorageTableServices
  name: cursorTableName
  properties: {}
}

resource servicePlan 'Microsoft.Web/serverfarms@2024-11-01' = {
  name: servicePlanName
  location: effectiveLocation
  kind: pc.kind
  properties: pc.properties
  sku: pc.sku
}

resource functionApp 'Microsoft.Web/sites@2024-11-01' = {
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
    functionAppConfig: pc.functionAppConfig
    siteConfig: {
      appSettings: concat([
        {
          name: 'AzureWebJobsStorage__accountName'
          value: functionStorageAccountName
        }
        {
          name: 'AUTHENTICATION_MODE'
          value: authenticationMode
        }
        {
          name: 'EVENTHUB_NAME'
          value: resolvedEventHubName
        }
        {
          name: 'EVENTHUB_CONSUMER_GROUP'
          value: eventHubConsumerGroupName
        }
        {
          name: 'CURSOR_RETENTION_HOURS'
          value: '48'
        }
        {
          name: 'CURSOR_CLEANUP_SCHEDULE'
          value: '0 0 3 * * *'
        }
        {
          name: 'MAX_CONSECUTIVE_FAILURES'
          value: '5'
        }
        {
          name: 'NR_LICENSE_KEY'
          value: newRelicIngestLicenseKey
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
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'AzureFunctionsJobHost__logging__logLevel__default'
          value: functionLogLevel
        }
        {
          name: 'AzureFunctionsJobHost__extensions__eventHubs__maxEventBatchSize'
          value: string(maxEventBatchSize)
        }
        {
          name: 'AzureFunctionsJobHost__extensions__eventHubs__minEventBatchSize'
          value: string(minEventBatchSize)
        }
        {
          name: 'AzureFunctionsJobHost__extensions__eventHubs__maxWaitTime'
          value: maxWaitTime
        }
      ], useManagedIdentity ? managedIdentityAppSettings : localAuthAppSettings)
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
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

// Managed Identity mode: allow the function to receive Event Hub messages
// without a shared-access-key connection string.
resource functionAppEventHubsDataReceiverAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useManagedIdentity) {
  scope: eventHubNamespace_resource
  name: guid(eventHubNamespace_resource.id, functionApp.id, 'EventHubsDataReceiver')
  properties: {
    roleDefinitionId: eventHubsDataReceiverRoleId
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Managed Identity mode: allow the function to read VNet Flow Log blobs from
// the source storage account without a shared-key connection string.
resource functionAppSourceStorageBlobDataReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useManagedIdentity) {
  scope: flowLogsStorageRef
  name: guid(flowLogsStorageRef.id, functionApp.id, 'StorageBlobDataReader')
  properties: {
    roleDefinitionId: storageBlobDataReaderRoleId
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
  dependsOn: [
    flowLogsStorageAccountNameResolved
  ]
}

resource deploymentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
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

// Lets Event Grid deliver events to the Event Hub via deliveryWithResourceIdentity.
// Grants Data Sender to the UAMI declared for EG delivery (see comment on the UAMI
// resource for why UAMI instead of the system topic's SAMI).
resource eventGridSystemTopicEventHubsDataSenderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: eventHubNamespace_resource
  name: guid(eventHubNamespace_resource.id, eventGridDeliveryIdentityName, 'EventHubsDataSender')
  properties: {
    roleDefinitionId: eventHubsDataSenderRoleId
    principalId: eventGridDeliveryIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ===== Private networking (conditional on disablePublicAccessToStorageAccount) =====

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = if (disablePublicAccessToStorageAccount) {
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
resource functionsSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: virtualNetwork
  name: functionsSubnetName
}

resource deploymentScriptsSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: virtualNetwork
  name: deploymentScriptsSubnetName
}

resource privateEndpointsSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: virtualNetwork
  name: privateEndpointsSubnetName
}

resource blobPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (disablePublicAccessToStorageAccount) {
  name: blobPrivateDnsZoneName
  location: 'global'
}

resource filePrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (disablePublicAccessToStorageAccount) {
  name: filePrivateDnsZoneName
  location: 'global'
}

resource queuePrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (disablePublicAccessToStorageAccount) {
  name: queuePrivateDnsZoneName
  location: 'global'
}

resource tablePrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (disablePublicAccessToStorageAccount) {
  name: tablePrivateDnsZoneName
  location: 'global'
}

resource sitesPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (disablePublicAccessToStorageAccount) {
  name: sitesPrivateDnsZoneName
  location: 'global'
}

resource blobDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (disablePublicAccessToStorageAccount) {
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

resource fileDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (disablePublicAccessToStorageAccount) {
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

resource queueDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (disablePublicAccessToStorageAccount) {
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

resource tableDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (disablePublicAccessToStorageAccount) {
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

resource sitesDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (disablePublicAccessToStorageAccount) {
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

resource functionStorageBlobPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = if (disablePublicAccessToStorageAccount) {
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

resource functionStorageFilePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = if (disablePublicAccessToStorageAccount) {
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

resource functionStorageQueuePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = if (disablePublicAccessToStorageAccount) {
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

resource functionStorageTablePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = if (disablePublicAccessToStorageAccount) {
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

resource functionAppPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = if (disablePublicAccessToStorageAccount) {
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

resource functionStorageBlobPrivateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (disablePublicAccessToStorageAccount) {
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

resource functionStorageFilePrivateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (disablePublicAccessToStorageAccount) {
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

resource functionStorageQueuePrivateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (disablePublicAccessToStorageAccount) {
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

resource functionStorageTablePrivateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (disablePublicAccessToStorageAccount) {
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

resource functionAppPrivateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (disablePublicAccessToStorageAccount) {
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

resource eventHubNamespaceNetworkRuleSet 'Microsoft.EventHub/namespaces/networkRuleSets@2024-01-01' = if (disablePublicAccessToStorageAccount) {
  parent: eventHubNamespace_resource
  name: 'default'
  properties: {
    publicNetworkAccess: 'Disabled'
    defaultAction: 'Deny'
    trustedServiceAccessEnabled: true
  }
}

resource eventHubPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (disablePublicAccessToStorageAccount) {
  name: eventHubPrivateDnsZoneName
  location: 'global'
}

resource eventHubDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (disablePublicAccessToStorageAccount) {
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

resource eventHubNamespacePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = if (disablePublicAccessToStorageAccount) {
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

resource eventHubNamespacePrivateEndpointDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (disablePublicAccessToStorageAccount) {
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
    scriptContent: 'set -euo pipefail\n\necho \'Downloading package...\'\npython3 -c "import os, urllib.request; urllib.request.urlretrieve(os.environ[\'ZIP_URL\'], \'/tmp/package.zip\')"\nls -la /tmp/package.zip\n\necho \'Deploying via az functionapp deployment source config-zip...\'\naz functionapp deployment source config-zip \\\n  --resource-group "$RESOURCE_GROUP" \\\n  --name "$FUNCTION_APP" \\\n  --src /tmp/package.zip \\\n  --build-remote false \\\n  --timeout 300\n'
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

resource eventGridSystemTopicName_eventGridSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2025-02-15' = {
  parent: eventGridSystemTopic
  name: resolvedSubscriptionName
  properties: {
    deliveryWithResourceIdentity: {
      identity: {
        type: 'UserAssigned'
        userAssignedIdentity: eventGridDeliveryIdentity.id
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
