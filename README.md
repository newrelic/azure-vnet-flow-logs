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
- New Relic account with a valid Ingest License Key

## Quick Start - Deploy with ARM/Bicep

The easiest way to deploy is using the provided ARM or Bicep templates, which create all required Azure resources automatically.

### Option 1: Deploy with Bicep

```bash
az deployment group create \
  --resource-group <your-resource-group> \
  --template-file bicep/azuredeploy-vnetflowlogsforwarder.bicep \
  --parameters newRelicIngestLicenseKey='<your-nr-license-key>' \
               flowLogsStorageAccountName='<existing-storage-with-flow-logs>'
```

### Option 2: Deploy with ARM Template

```bash
az deployment group create \
  --resource-group <your-resource-group> \
  --template-file arm/azuredeploy-vnetflowlogsforwarder.json \
  --parameters newRelicIngestLicenseKey='<your-nr-license-key>' \
               flowLogsStorageAccountName='<existing-storage-with-flow-logs>'
```

### Template Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `newRelicIngestLicenseKey` | Yes | New Relic Ingest License Key |
| `flowLogsStorageAccountName` | No | Existing storage account where Azure writes your VNet flow logs. Leave blank to create a new one. |
| `newRelicEndpoint` | No | NR Logs API endpoint: US (default), EU, or JP |
| `newRelicTags` | No | Custom tags for logs (e.g., `env:prod;team:network`) |
| `maxRetries` | No | Max retries for NR delivery (default: 3) |
| `retryInterval` | No | Retry interval in ms (default: 2000) |
| `maxEventBatchSize` | No | Max Event Grid blob-created notifications per function invocation (blobs-per-invocation, not log events). Overrides `host.json`. (default: 100) |
| `minEventBatchSize` | No | Min Event Grid blob-created notifications per function invocation. Overrides `host.json`. (default: 20) |
| `maxWaitTime` | No | Max time to build up a batch before invoking the function, in `HH:MM:SS`. Overrides `host.json`. (default: 00:00:30) |
| `functionAppPlan` | No | Function App hosting plan: `FlexConsumption` (default), `ElasticPremium`, `Basic`, or `Consumption`. See [Function App plan](#function-app-plan). |
| `functionLogLevel` | No | Default log level for the forwarder: `Trace`, `Debug`, `Information` (default), `Warning`, or `Error` |
| `eventHubScalingMode` | No | Event Hub scaling profile: `Basic` (default, 4 partitions) or `Enterprise` (32 partitions, auto-inflate) |
| `disablePublicAccessToStorageAccount` | No | Enable private networking with VNet and private endpoints (default: false) |
| `authenticationMode` | No | How the function authenticates to the Event Hub and storage accounts: `Managed Identity` (default, keyless, via the function's system-assigned identity) or `Local Authentication` (shared-key connection strings). See [Authentication mode](#authentication-mode). |

### Resources Created

The template deploys:
- **Function App** on the hosting plan selected via `functionAppPlan` (default: Flex Consumption on Linux; non-Flex plans run Windows). Node.js 22.
- **Event Hub Namespace** with Event Hub and consumer group
- **Event Grid System Topic** and subscription (filters for PT1H.json blob events)
- **Storage Account** for function runtime and cursor table
- **Managed Identity** with required role assignments
- **(Optional)** VNet, private DNS zones, and private endpoints when `disablePublicAccessToStorageAccount=true`

### Authentication mode

The `authenticationMode` parameter selects how the function authenticates to the Event Hub and the source/cursor storage accounts.

- **`Managed Identity`** (default): no secrets are stored. The function authenticates with its system-assigned identity and the template grants the required RBAC roles:
  - **`Azure Event Hubs Data Receiver`** on the Event Hub namespace — so the trigger can receive messages.
  - **`Storage Blob Data Reader`** on the source storage account — so the forwarder can read the VNet Flow Log blobs.
  - The cursor table uses the **`Storage Table Data Contributor`** role the function already holds on its own storage account.

  In this mode the connection strings are replaced by service-endpoint settings (`EVENTHUB_CONSUMER_CONNECTION__fullyQualifiedNamespace` + `EVENTHUB_CONSUMER_CONNECTION__credential=managedidentity`, `SOURCE_STORAGE_BLOB_SERVICE_URI`, `CURSOR_STORAGE_TABLE_SERVICE_URI`). The `__credential=managedidentity` setting is required on the Flex Consumption plan so the host and scale controller authenticate the Event Hub trigger via the managed identity.
- **`Local Authentication`**: the function uses shared-key connection strings (`EVENTHUB_CONSUMER_CONNECTION`, `SOURCE_STORAGE_CONNECTION`, `CURSOR_STORAGE_CONNECTION`). Use this when the deploying principal cannot grant the role assignments Managed Identity requires — for example on a bring-your-own flow-logs storage account where the deployer lacks `roleAssignments/write`.

  Deploy with Local Authentication by adding `authenticationMode='Local Authentication'` to the `--parameters` of either deployment command above.

### Function App plan

The `functionAppPlan` parameter selects the Azure Functions hosting plan for the forwarder. Four options are available:

| Plan | When to pick | Cold starts | Private networking | Cost profile |
|------|--------------|-------------|--------------------|--------------|
| **FlexConsumption** (default) | Any region where Flex Consumption is Generally Available (~30 regions as of mid-2026). Modern serverless with native VNet integration; scales elastically. | Reduced | Supported | Pay-per-execution + memory-second billing |
| **ElasticPremium** | Production or bursty workloads in regions where Flex is not GA (e.g. Azure Gov, Azure China, some EU/APAC secondary regions), or workloads with a strict no-cold-start SLA. | None (pre-warmed) | Supported | ~$150/mo baseline (EP1) plus per-instance scale-out |
| **Basic** | Small tenants or dev/test that need private networking but can't justify Elastic Premium's baseline. Not suitable for high-throughput. | Yes on scale-out (mitigated by `alwaysOn: true`) | Supported | ~$13/mo (B1, always-on) |
| **Consumption** | Public-network workloads where private networking is not required and pay-per-execution billing is preferred. | Yes, per invocation | **Not supported** | Pay-per-execution (free grant included) |

Deploy with a specific plan by adding `functionAppPlan='<plan-name>'` to the `--parameters` of either deployment command above.

**Notes:**

- **Consumption + private networking is architecturally unsupported.** If you combine `functionAppPlan=Consumption` with `disablePublicAccessToStorageAccount=true`, the deployment fails within the first minute with a clear error message. Use `FlexConsumption`, `ElasticPremium`, or `Basic` for private-mode deployments.

## Configuration

### Environment Variables

The function uses the following environment variables (automatically configured by the ARM/Bicep templates):

#### Required

| Variable | Description |
|----------|-------------|
| `NR_LICENSE_KEY` | New Relic Ingest License Key |
| `EVENTHUB_NAME` | Name of the Event Hub |
| `SOURCE_STORAGE_CONNECTION` | Connection string for the storage account containing VNet flow logs |
| `CURSOR_STORAGE_CONNECTION` | Connection string for the storage account used for cursor tracking |
| `EVENTHUB_CONSUMER_CONNECTION` | Event Hub connection string with Listen permission |

> In `Managed Identity` mode the three connection strings above are replaced by `SOURCE_STORAGE_BLOB_SERVICE_URI`, `CURSOR_STORAGE_TABLE_SERVICE_URI`, and `EVENTHUB_CONSUMER_CONNECTION__fullyQualifiedNamespace`. See [Authentication mode](#authentication-mode).

#### Optional

| Variable | Description | Default |
|----------|-------------|---------|
| `NR_ENDPOINT` | New Relic Logs API endpoint | `https://log-api.newrelic.com/log/v1` |
| `NR_TAGS` | Custom tags (semicolon-separated `key:value` pairs) | (empty) |
| `NR_MAX_RETRIES` | Max retries for failed NR requests | `3` |
| `NR_RETRY_INTERVAL` | Retry interval in milliseconds | `2000` |
| `AUTHENTICATION_MODE` | `Local Authentication` or `Managed Identity` | `Managed Identity` |
| `EVENTHUB_CONSUMER_GROUP` | Event Hub consumer group | `$Default` |
| `CURSOR_RETENTION_HOURS` | Hours to retain cursor entries | `48` |
| `CURSOR_CLEANUP_SCHEDULE` | Cron schedule for cursor cleanup | `0 0 3 * * *` (3 AM daily) |
| `MAX_CONSECUTIVE_FAILURES` | Failures before marking blob as poison | `5` |

### Logging Level Configuration

Debug output is controlled through logging levels rather than a runtime debug flag. The default level is set at deploy time via the `functionLogLevel` parameter, which maps to the `AzureFunctionsJobHost__logging__logLevel__default` app setting.

The default `host.json` configuration in this repo uses `Information` level.
To temporarily enable debug logs at runtime, set app settings such as:

- `AzureFunctionsJobHost__logging__logLevel__Function=Debug`
- `AzureFunctionsJobHost__logging__logLevel__default=Information`

This enables `context.debug()` messages while keeping host-level noise lower.

### Failure and Recovery Behavior

- New Relic delivery is retried first in the NR client (for 429, 5xx, and retryable network errors).
- The blob failure counter is incremented only when those delivery retries are fully exhausted, or when another hard failure occurs in processing.
- Default poison threshold is `MAX_CONSECUTIVE_FAILURES=5`. After this threshold, that blob path is skipped to prevent infinite retries on permanently bad data.
- If New Relic is unavailable only briefly, retries usually succeed and no blob failure increment occurs.
- If a blob reaches poison threshold, that blob data may be skipped until operator intervention (for example, raising `MAX_CONSECUTIVE_FAILURES` and replaying from storage/event source).
- If data is sent successfully but cursor commit fails, duplicate delivery is possible on retry (at-least-once behavior).
- Processing does not require new events for retry behavior itself, but replay/recovery of already skipped blobs requires an operator-triggered replay strategy.

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
| `log-forwarder.js` | Main processing logic: cursor → delta → parse → deliver → commit |
| `parser.js` | Parses VNet flow log JSON and flow tuples into structured records |
| `cursor.js` | Cursor management via Azure Table Storage with cleanup |
| `delta.js` | Downloads only new blob blocks since last cursor position |
| `nr-client.js` | Batches, compresses (gzip), and delivers logs to New Relic |
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
| `flowState` | Begin, Continuing, End, or Deny (VNet flow logs have no separate Allow/Deny field — a blocked flow is `Deny`) |
| `encryption` | Encrypted, Not Encrypted, or an `NX_*` reason code |
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


