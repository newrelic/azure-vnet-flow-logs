@description('Required. New Relic License Key')
@secure()
param newRelicLicenseKey string

@description('Optional. Name of the existing storage account where VNet Flow Logs PT1H.json files are stored. Must be in the same resource group as this deployment. Leave this blank to create a new storage account (its name will start with \'nrvnetflsrc\').')
param sourceStorageAccountName string = ''

@description('Optional. Region where all resources included in this template will be deployed. Leave this blank to use the same region as the one of the resource group.')
param location string = ''

@description('Optional. The Logs API endpoint for your New Relic account region. Select US (default), EU, or JP endpoint.')
@allowed([
  'https://log-api.newrelic.com/log/v1'
  'https://log-api.eu.newrelic.com/log/v1'
  'https://log-api.jp.newrelic.com/log/v1'
])
param newRelicEndpoint string = 'https://log-api.newrelic.com/log/v1'

@description('Optional. Custom tags to add to logs sent to New Relic (semicolon-separated key:value pairs, e.g. env:prod;team:network).')
param newRelicTags string = ''

@description('Optional. Maximum number of retries when sending logs to New Relic.')
param maxRetries int = 3

@description('Optional. Retry interval in milliseconds when sending logs to New Relic.')
param retryInterval int = 2000

@description('Optional. Maximum number of events to process in a single batch from Event Hub.')
param eventHubBatchSize int = 10

@description('Optional. Number of Event Hub partitions to provision. Sets the maximum parallelism for the consumer function (one Flex Consumption instance can read from each partition concurrently). Default 32 is the Standard tier ceiling and adds no cost. Lower values reduce parallelism only; partition count is fixed at hub creation and cannot be changed later.')
@minValue(1)
@maxValue(32)
param eventHubPartitionCount int = 32

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
var cursorStorageAccountName = 'nrvnetflcur${uniqueResourceNameSuffix}'
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
var vnetFlowLogsForwarderFunctionArtifact = 'https://github.com/newrelic/azure-vnet-flow-logs/releases/latest/download/VNetFlowForwarder.zip'
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
    zoneRedundant: false
  }
}

resource eventHubNamespaceName_eventHub 'Microsoft.EventHub/namespaces/eventhubs@2021-11-01' = {
  parent: eventHubNamespace_resource
  name: resolvedEventHubName
  properties: {
    messageRetentionInDays: 1
    partitionCount: eventHubPartitionCount
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
      'Send'
    ]
  }
}

resource eventGridSystemTopic 'Microsoft.EventGrid/systemTopics@2021-12-01' = {
  name: resolvedSystemTopicName
  location: effectiveLocation
  properties: {
    source: sourceStorageAccountId
    topicType: 'Microsoft.Storage.StorageAccounts'
  }
}

resource cursorStorageAccount 'Microsoft.Storage/storageAccounts@2021-09-01' = {
  name: cursorStorageAccountName
  location: effectiveLocation
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
  location: effectiveLocation
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
          name: 'VNETFLOWLOGS_RELAY_ENABLED'
          value: 'true'
        }
        {
          name: 'VNETFLOWLOGS_FORWARDER_ENABLED'
          value: 'true'
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
          name: 'SOURCE_STORAGE_ACCOUNT_NAME'
          value: resolvedSourceStorageName
        }
        {
          name: 'SOURCE_STORAGE_CONNECTION'
          value: 'DefaultEndpointsProtocol=https;AccountName=${resolvedSourceStorageName};AccountKey=${listKeys(resourceId('Microsoft.Storage/storageAccounts', resolvedSourceStorageName), '2021-09-01').keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'CURSOR_STORAGE_CONNECTION'
          value: 'DefaultEndpointsProtocol=https;AccountName=${cursorStorageAccountName};AccountKey=${cursorStorageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
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

resource functionAppCursorTableContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: cursorStorageAccount
  name: guid(functionApp.id, cursorStorageAccount.id, 'StorageTableDataContributor')
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
    timeout: 'PT30M'
    retentionInterval: 'PT1H'
    cleanupPreference: 'OnSuccess'
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
      {
        name: 'TARGET_FUNCTION'
        value: 'VNetFlowLogsRelay'
      }
    ]
    scriptContent: 'set -euo pipefail\n\necho \'Downloading package via python urllib (curl not preinstalled, python is)...\'\npython3 -c "import os, urllib.request; urllib.request.urlretrieve(os.environ[\'ZIP_URL\'], \'/tmp/package.zip\')"\nls -la /tmp/package.zip\n\necho \'Deploying via az functionapp deployment source config-zip (Flex-supported path)...\'\naz functionapp deployment source config-zip \\\n  --resource-group "$RESOURCE_GROUP" \\\n  --name "$FUNCTION_APP" \\\n  --src /tmp/package.zip \\\n  --build-remote false \\\n  --timeout 900\n\necho "Waiting for $TARGET_FUNCTION to register on the function host..."\nfor i in $(seq 1 60); do\n  if az functionapp function show \\\n       --resource-group "$RESOURCE_GROUP" \\\n       --name "$FUNCTION_APP" \\\n       --function-name "$TARGET_FUNCTION" >/dev/null 2>&1; then\n    echo "$TARGET_FUNCTION registered."\n    exit 0\n  fi\n  echo \'Function not yet registered, sleeping 10s...\'\n  sleep 10\ndone\n\necho "Timed out waiting for $TARGET_FUNCTION to register after 10 minutes."\nexit 1\n'
  }
  dependsOn: [
    functionApp
    deploymentScriptWebsiteContributorAssignment
  ]
}

resource eventGridSystemTopicName_eventGridSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2021-12-01' = {
  parent: eventGridSystemTopic
  name: resolvedSubscriptionName
  properties: {
    destination: {
      endpointType: 'AzureFunction'
      properties: {
        resourceId: resourceId('Microsoft.Web/sites/functions', functionAppName, 'VNetFlowLogsRelay')
        maxEventsPerBatch: 1
        preferredBatchSizeInKilobytes: 64
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
    deploymentScript
  ]
}
