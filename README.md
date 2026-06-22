[![Community header](https://github.com/newrelic/opensource-website/raw/master/src/images/categories/Community_Project.png)](https://opensource.newrelic.com/oss-category/#community-project)

# Azure VNet Flow Logs Forwarder
![GitHub release (latest SemVer including pre-releases)](https://img.shields.io/github/v/release/newrelic/azure-vnet-flow-logs?include_prereleases) [![Known Vulnerabilities](https://snyk.io/test/github/newrelic/azure-vnet-flow-logs/badge.svg?targetFile=package.json)](https://snyk.io/test/github/newrelic/azure-vnet-flow-logs?targetFile=package.json)

This Azure Function collects and forwards Azure VNet Flow Logs to New Relic using efficient delta-only processing.

## Overview

The VNet Flow Logs Forwarder is an event-driven Azure Function that:
1. Listens to Event Grid notifications when new VNet flow log data is written to blob storage
2. Downloads only the new (delta) blocks from the PT1H.json files
3. Parses and enriches the flow log records
4. Forwards them to New Relic Logs API

This architecture ensures efficient processing of high-volume flow logs with minimal latency.

## Features

- **Delta-only processing**: Downloads and processes only new blob blocks since last checkpoint
- **Cursor management**: Tracks processing progress using Azure Table Storage with automatic cleanup
- **Event-driven**: Triggered by Event Grid via Event Hub for near real-time processing
- **Batch delivery**: Compresses and delivers logs to New Relic in optimized batches
- **Retry logic**: Configurable retry with fixed intervals for New Relic delivery
- **Poison event protection**: Skips blobs that fail repeatedly to prevent infinite loops
- **Private networking**: Optional VNet integration with private endpoints for enhanced security

## Prerequisites

- Azure subscription with [VNet Flow Logs](https://learn.microsoft.com/en-us/azure/network-watcher/vnet-flow-logs-overview) enabled
- Storage account where VNet flow logs are stored (PT1H.json files)
- New Relic account with a valid License Key or Insert API Key

## Quick Start - Deploy with ARM/Bicep

The easiest way to deploy is using the provided ARM or Bicep templates, which create all required Azure resources automatically.

### Option 1: Deploy with Bicep

```bash
az deployment group create \
  --resource-group <your-resource-group> \
  --template-file bicep/azuredeploy-vnetflowlogsforwarder.bicep \
  --parameters newRelicLicenseKey='<your-nr-license-key>' \
               sourceStorageAccountName='<existing-storage-with-flow-logs>'
```

### Option 2: Deploy with ARM Template

```bash
az deployment group create \
  --resource-group <your-resource-group> \
  --template-file arm/azuredeploy-vnetflowlogsforwarder.json \
  --parameters newRelicLicenseKey='<your-nr-license-key>' \
               sourceStorageAccountName='<existing-storage-with-flow-logs>'
```

### Template Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `newRelicLicenseKey` | Yes | New Relic License Key |
| `sourceStorageAccountName` | No | Existing storage account with VNet flow logs. Leave blank to create a new one. |
| `location` | No | Azure region (defaults to resource group location) |
| `newRelicEndpoint` | No | NR Logs API endpoint: US (default), EU, or JP |
| `newRelicTags` | No | Custom tags for logs (e.g., `env:prod;team:network`) |
| `maxRetries` | No | Max retries for NR delivery (default: 3) |
| `retryInterval` | No | Retry interval in ms (default: 2000) |
| `debugEnabled` | No | Enable debug logging (default: false) |
| `disablePublicAccessToStorageAccount` | No | Enable private networking with VNet and private endpoints (default: false) |

### Resources Created

The template deploys:
- **Function App** (Flex Consumption plan, Node.js 22)
- **Event Hub Namespace** with Event Hub and consumer group
- **Event Grid System Topic** and subscription (filters for PT1H.json blob events)
- **Storage Account** for function runtime and cursor table
- **Managed Identity** with required role assignments
- **(Optional)** VNet, private DNS zones, and private endpoints when `disablePublicAccessToStorageAccount=true`

## Configuration

### Environment Variables

The function uses the following environment variables (automatically configured by the ARM/Bicep templates):

#### Required

| Variable | Description |
|----------|-------------|
| `NR_LICENSE_KEY` | New Relic License Key (or use `NR_INSERT_KEY` for Insert API Key) |
| `SOURCE_STORAGE_CONNECTION` | Connection string for storage account containing VNet flow logs |
| `CURSOR_STORAGE_CONNECTION` | Connection string for storage account used for cursor tracking |
| `EVENTHUB_CONSUMER_CONNECTION` | Event Hub connection string with Listen permission |
| `EVENTHUB_NAME` | Name of the Event Hub |

#### Optional

| Variable | Description | Default |
|----------|-------------|---------|
| `NR_ENDPOINT` | New Relic Logs API endpoint | `https://log-api.newrelic.com/log/v1` |
| `NR_TAGS` | Custom tags (semicolon-separated `key:value` pairs) | (empty) |
| `NR_MAX_RETRIES` | Max retries for failed NR requests | `3` |
| `NR_RETRY_INTERVAL` | Retry interval in milliseconds | `2000` |
| `EVENTHUB_CONSUMER_GROUP` | Event Hub consumer group | `$Default` |
| `DEBUG_ENABLED` | Enable verbose debug logging | `false` |
| `CURSOR_RETENTION_HOURS` | Hours to retain cursor entries | `48` |
| `CURSOR_CLEANUP_SCHEDULE` | Cron schedule for cursor cleanup | `0 0 3 * * *` (3 AM daily) |
| `MAX_CONSECUTIVE_FAILURES` | Failures before marking blob as poison | `3` |

### New Relic Endpoints

| Region | Endpoint |
|--------|----------|
| US | `https://log-api.newrelic.com/log/v1` |
| EU | `https://log-api.eu.newrelic.com/log/v1` |
| JP | `https://log-api.jp.nr-data.net/log/v1` |

## Manual Deployment

For manual deployment without the ARM/Bicep templates:

### 1. Package the Function

```bash
npm ci --omit=dev
npm run package
```

This creates `VNetFlowForwarder.zip`.

### 2. Deploy to Azure

```bash
az functionapp deployment source config-zip \
  --resource-group <resource-group-name> \
  --name <function-app-name> \
  --src VNetFlowForwarder.zip
```

### 3. Configure Environment Variables

```bash
az functionapp config appsettings set \
  --name <function-app-name> \
  --resource-group <resource-group-name> \
  --settings \
    NR_LICENSE_KEY="<your-nr-license-key>" \
    SOURCE_STORAGE_CONNECTION="<source-storage-connection-string>" \
    CURSOR_STORAGE_CONNECTION="<cursor-storage-connection-string>" \
    EVENTHUB_CONSUMER_CONNECTION="<eventhub-connection-string>" \
    EVENTHUB_NAME="<eventhub-name>"
```

## Testing

Run unit tests:
```bash
npm test
```

Run with coverage:
```bash
npm test -- --coverage
```

Lint code:
```bash
npm run lint
```

## Architecture

```
┌─────────────────┐     ┌──────────────┐     ┌─────────────────┐
│  VNet Flow Logs │────▶│ Blob Storage │────▶│   Event Grid    │
│   (PT1H.json)   │     │              │     │ (BlobCreated)   │
└─────────────────┘     └──────────────┘     └────────┬────────┘
                                                      │
                                                      ▼
┌─────────────────┐     ┌──────────────┐     ┌─────────────────┐
│   New Relic     │◀────│   Function   │◀────│    Event Hub    │
│   Logs API      │     │    App       │     │                 │
└─────────────────┘     └──────────────┘     └─────────────────┘
                               │
                               ▼
                        ┌──────────────┐
                        │ Table Storage│
                        │  (Cursors)   │
                        └──────────────┘
```

### Modules

| Module | Description |
|--------|-------------|
| `index.js` | Function registration (Event Hub trigger + Timer trigger for cleanup) |
| `consumer.js` | Main processing logic: cursor → delta → parse → deliver → commit |
| `parser.js` | Parses VNet flow log JSON and flow tuples into structured records |
| `cursor.js` | Cursor management via Azure Table Storage with cleanup |
| `delta.js` | Downloads only new blob blocks since last cursor position |
| `delivery.js` | Batches, compresses (gzip), and delivers logs to New Relic |
| `config.js` | Centralized configuration from environment variables |

## Log Format

Each flow log record sent to New Relic includes:

| Field | Description |
|-------|-------------|
| `timestamp` | Flow event timestamp (Unix ms) |
| `srcAddr` / `destAddr` | Source and destination IP addresses |
| `srcPort` / `destPort` | Source and destination ports |
| `protocol` | TCP, UDP, or ICMP |
| `direction` | Inbound or Outbound |
| `action` | Allowed or Denied |
| `state` | Begin, Continuing, or End |
| `packetsSrcToDest` / `packetsDestToSrc` | Packet counts |
| `bytesSrcToDest` / `bytesDestToSrc` | Byte counts |
| `subscriptionId` | Azure subscription ID |
| `resourceGroup` | Resource group name |
| `resourceType` | Resource type (e.g., virtualNetworks) |
| `resourceName` | Resource name |
| `rule` | NSG/ACL rule name |
| `flowLogVersion` | Flow log version |

## Data Source

This function is designed to work with [Azure VNet Flow Logs](https://learn.microsoft.com/en-us/azure/network-watcher/vnet-flow-logs-overview), which provide information about IP traffic flowing through virtual networks.

## Contributing

Contributions to improve azure-vnet-flow-logs are encouraged! Keep in mind when you submit your pull request, you'll need to sign the CLA via the click-through using CLA-Assistant. You only have to sign the CLA one time per project.
To execute our corporate CLA, which is required if your contribution is on behalf of a company, or if you have any questions, please drop us an email at open-source@newrelic.com.

Here are some general guidelines
1. PR owners should follow the code review process and standards team has established.
1. Thorough testing must be done by PR owners to ensure the new feature works and has no regressions.
1. Add/Update any applicable tests as part of the PR.
1. Breakdown PRs into multiple PRs if needed to reduce chances of breaking changes. Specifically, refactoring efforts and new feature implementations should always be submitted as distinct PRs

## Community

New Relic hosts and moderates an online forum where customers can interact with New Relic employees as well as other customers to get help and share best practices. Like all official New Relic open source projects, there's a related Community topic in the New Relic Explorers Hub: [Log forwarding](https://discuss.newrelic.com/tag/log-forwarding)

## A note about vulnerabilities

As noted in our [security policy](../../security/policy), New Relic is committed to the privacy and security of our customers and their data. We believe that providing coordinated disclosure by security researchers and engaging with the security community are important means to achieve our security goals.

If you believe you have found a security vulnerability in this project or any of New Relic's products or websites, we welcome and greatly appreciate you reporting it to New Relic through [HackerOne](https://hackerone.com/newrelic).

If you would like to contribute to this project, review [these guidelines](https://opensource.newrelic.com/code-of-conduct/).

## License
azure-vnet-flow-logs is licensed under the [Apache 2.0](http://apache.org/licenses/LICENSE-2.0.txt) License.


