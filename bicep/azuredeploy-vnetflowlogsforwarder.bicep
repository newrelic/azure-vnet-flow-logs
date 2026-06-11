@description('Required. New Relic License Key')
@secure()
param newRelicLicenseKey string

@description('Optional. Name of the existing storage account where VNet Flow Logs PT1H.json files are stored. Must be in the same resource group as this deployment. Leave this blank to create a new storage account (its name will start with \'nrvnetflsrc\').')
param sourceStorageAccountName string = ''

@description('Optional. Event Hub Namespace where VNet Flow Log events will be sent. Leave this blank for a new namespace to be created automatically (its name will start with \'nrvnetflowlogs-eventhub-namespace-\').')
param eventHubNamespace string = ''

@description('Optional. Event Hub where VNet Flow Log events are sent. Leave this blank for a new Event Hub to be created automatically (its name will be \'nrvnetflowlogs-eventhub\').')
param eventHubName string = ''

@description('Optional. Name for the Event Grid System Topic that will be created to monitor blob events from the source storage account. Leave this blank to auto-generate a unique name (its name will start with \'nrvnetflowlogs-eventgrid-topic-\').')
param eventGridSystemTopicName string = ''

@description('Optional. Name for the Event Grid Subscription that will be created to filter PT1H.json files. Leave this blank to auto-generate a unique name (its name will start with \'nrvnetflowlogs-eventgrid-subscription-\').')
param eventGridSubscriptionName string = ''

@description('Optional. Region where all resources included in this template will be deployed. Leave this blank to use the same region as the one of the resource group.')
param location string = ''

@description('Optional. The Logs API endpoint for your New Relic account region. Select US (default), EU, or JP endpoint.')
@allowed([
  'https://log-api.newrelic.com/log/v1'
  'https://log-api.eu.newrelic.com/log/v1'
  'https://log-api.jp.newrelic.com/log/v1'
])
param newRelicEndpoint string = 'https://log-api.newrelic.com/log/v1'

@description('Optional. The scaling for the resources. In Flex Consumption plan, both Basic and Enterprise modes use the same FC1 SKU with different instance limits.')
@allowed([
  'Basic'
  'Enterprise'
])
param scalingMode string = 'Basic'

@description('Optional. Custom tags to add to logs sent to New Relic (semicolon-separated key:value pairs, e.g. env:prod;team:network).')
param newRelicTags string = ''

@description('Optional. Maximum number of retries when sending logs to New Relic.')
param maxRetries int = 3

@description('Optional. Retry interval in milliseconds when sending logs to New Relic.')
param retryInterval int = 2000

@description('Optional. Maximum number of events to process in a single batch from Event Hub.')
param eventHubBatchSize int = 10

@description('Optional. Enable debug logging for troubleshooting.')
param debugEnabled bool = false

@description('Optional. Maximum number of instances for Flex Consumption plan.')
@minValue(1)
@maxValue(1000)
param maximumInstanceCount int = 100

@description('Optional. Memory allocation per instance in MB. Recommended: 2048MB.')
@allowed([
  512
  2048
  4096
])
param instanceMemoryMB int = 2048

var uniqueResourceNameSuffix = uniqueString(resourceGroup().id)
var location_var = (empty(location) ? resourceGroup().location : location)
var createNewSourceStorage = empty(sourceStorageAccountName)
var sourceStorageAccountNameResolved_var = (createNewSourceStorage
  ? 'nrvnetflsrc${uniqueResourceNameSuffix}'
  : sourceStorageAccountName)
var createNewEventHubNamespace = empty(eventHubNamespace)
var createNewEventHub = (empty(eventHubNamespace) || empty(eventHubName))
var eventHubNamespaceName = (createNewEventHubNamespace
  ? 'nrvnetflowlogs-eventhub-namespace-${uniqueResourceNameSuffix}'
  : eventHubNamespace)
var eventHubName_var = (createNewEventHub ? 'nrvnetflowlogs-eventhub' : eventHubName)
var eventHubConsumerGroupName = 'nrvnetflowlogs-consumergroup'
var eventHubAuthRuleName = 'nrvnetflowlogs-consumer-policy'
var eventGridSystemTopicName_var = (empty(eventGridSystemTopicName)
  ? 'nrvnetflowlogs-eventgrid-topic-${uniqueResourceNameSuffix}'
  : eventGridSystemTopicName)
var eventGridSubscriptionName_var = (empty(eventGridSubscriptionName)
  ? 'nrvnetflowlogs-eventgrid-subscription-${uniqueResourceNameSuffix}'
  : eventGridSubscriptionName)
var cursorStorageAccountName = 'nrvnetflcur${uniqueResourceNameSuffix}'
var cursorTableName = 'nrvnetflowlogscursors'
var functionStorageAccountName = 'nrvnetflfn${uniqueResourceNameSuffix}'
var servicePlanName = 'nrvnetflowlogs-serviceplan-${uniqueResourceNameSuffix}'
var functionAppName = 'nrvnetflowlogs-forwarder-${uniqueResourceNameSuffix}'
var sourceStorageAccountId = sourceStorageAccountNameResolved.id
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

resource sourceStorageAccountNameResolved 'Microsoft.Storage/storageAccounts@2021-09-01' = if (createNewSourceStorage) {
  name: sourceStorageAccountNameResolved_var
  location: location_var
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

resource eventHubNamespace_resource 'Microsoft.EventHub/namespaces@2021-11-01' = if (createNewEventHubNamespace) {
  name: eventHubNamespaceName
  location: location_var
  sku: {
    name: 'Standard'
    tier: 'Standard'
    capacity: 1
  }
  properties: {
    minimumTlsVersion: '1.2'
    isAutoInflateEnabled: ((scalingMode == 'Enterprise') ? true : false)
    maximumThroughputUnits: ((scalingMode == 'Enterprise') ? 40 : 0)
    zoneRedundant: false
  }
}

resource eventHubNamespaceName_eventHub 'Microsoft.EventHub/namespaces/eventhubs@2021-11-01' = if (createNewEventHub) {
  parent: eventHubNamespace_resource
  name: '${eventHubName_var}'
  location: location_var
  properties: {
    messageRetentionInDays: 1
    partitionCount: ((scalingMode == 'Enterprise') ? 32 : 4)
  }
}

resource eventHubNamespaceName_eventHubName_eventHubConsumerGroup 'Microsoft.EventHub/namespaces/eventhubs/consumergroups@2021-11-01' = {
  parent: eventHubNamespaceName_eventHub
  name: eventHubConsumerGroupName
  properties: {}
}

resource eventHubNamespaceName_eventHubAuthRule 'Microsoft.EventHub/namespaces/AuthorizationRules@2021-11-01' = {
  parent: eventHubNamespace_resource
  name: '${eventHubAuthRuleName}'
  properties: {
    rights: [
      'Listen'
      'Send'
    ]
  }
}

resource eventGridSystemTopic 'Microsoft.EventGrid/systemTopics@2021-12-01' = {
  name: eventGridSystemTopicName_var
  location: location_var
  properties: {
    source: sourceStorageAccountId
    topicType: 'Microsoft.Storage.StorageAccounts'
  }
}

resource eventGridSystemTopicName_eventGridSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2021-12-01' = {
  parent: eventGridSystemTopic
  name: '${eventGridSubscriptionName_var}'
  properties: {
    destination: {
      endpointType: 'EventHub'
      properties: {
        resourceId: eventHubNamespaceName_eventHub.id
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
}

resource cursorStorageAccount 'Microsoft.Storage/storageAccounts@2021-09-01' = {
  name: cursorStorageAccountName
  location: location_var
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
    supportsHttpsTrafficOnly: true
    encryption: {
      services: {
        table: {
          keyType: 'Account'
          enabled: true
        }
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

resource cursorStorageAccountName_default 'Microsoft.Storage/storageAccounts/tableServices@2022-09-01' = {
  parent: cursorStorageAccount
  name: 'default'
  properties: {}
}

resource cursorStorageAccountName_default_cursorTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2022-09-01' = {
  parent: cursorStorageAccountName_default
  name: cursorTableName
  properties: {}
}

resource functionStorageAccount 'Microsoft.Storage/storageAccounts@2021-09-01' = {
  name: functionStorageAccountName
  location: location_var
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
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

resource servicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: servicePlanName
  location: location_var
  kind: flexConsumptionASP.kind
  properties: flexConsumptionASP.properties
  sku: flexConsumptionASP.sku
}

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location_var
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: servicePlan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: 'https://${functionStorageAccountName}.blob.core.windows.net/deployments'
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
          name: 'VNETFLOWLOGS_RELAY_ENABLED'
          value: 'true'
        }
        {
          name: 'VNETFLOWLOGS_FORWARDER_ENABLED'
          value: 'true'
        }
        {
          name: 'EVENTHUB_NAME'
          value: eventHubName_var
        }
        {
          name: 'EVENTHUB_CONSUMER_CONNECTION'
          value: listKeys(eventHubNamespaceName_eventHubAuthRule.id, '2021-11-01').primaryConnectionString
        }
        {
          name: 'EVENTHUB_CONSUMER_GROUP'
          value: eventHubConsumerGroupName
        }
        {
          name: 'SOURCE_STORAGE_ACCOUNT_NAME'
          value: sourceStorageAccountNameResolved_var
        }
        {
          name: 'SOURCE_STORAGE_CONNECTION'
          value: 'DefaultEndpointsProtocol=https;AccountName=${sourceStorageAccountNameResolved_var};AccountKey=${listKeys(sourceStorageAccountNameResolved.id,'2021-09-01').keys[0].value};EndpointSuffix=core.windows.net'
        }
        {
          name: 'CURSOR_STORAGE_CONNECTION'
          value: 'DefaultEndpointsProtocol=https;AccountName=${cursorStorageAccountName};AccountKey=${listKeys(cursorStorageAccount.id,'2021-09-01').keys[0].value};EndpointSuffix=core.windows.net'
        }
        {
          name: 'CURSOR_TABLE_NAME'
          value: cursorTableName
        }
        {
          name: 'NR_LICENSE_KEY'
          value: newRelicLicenseKey
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
          name: 'AzureFunctionsJobHost__extensions__eventHubs__maxEventBatchSize'
          value: string(eventHubBatchSize)
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
    functionStorageAccount
    functionStorageAccountName_default_deployments

    cursorStorageAccountName_default_cursorTable
  ]
}

resource Microsoft_Web_sites_functionAppName_Microsoft_Storage_storageAccounts_functionStorageAccountName_StorageBlobDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: functionStorageAccount
  name: guid(functionApp.id, functionStorageAccount.id, 'StorageBlobDataOwner')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
    )
    principalId: reference(functionApp.id, '2023-12-01', 'Full').identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource Microsoft_Web_sites_functionAppName_Microsoft_Storage_storageAccounts_cursorStorageAccountName_StorageTableDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: cursorStorageAccount
  name: guid(functionApp.id, cursorStorageAccount.id, 'StorageTableDataContributor')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
    )
    principalId: reference(functionApp.id, '2023-12-01', 'Full').identity.principalId
    principalType: 'ServicePrincipal'
  }
}
