[![Community header](https://github.com/newrelic/opensource-website/raw/master/src/images/categories/Community_Project.png)](https://opensource.newrelic.com/oss-category/#community-project)

# Azure VNet Flow Logs Forwarder
![GitHub release (latest SemVer including pre-releases)](https://img.shields.io/github/v/release/newrelic/azure-vnet-flow-logs?include_prereleases) [![Known Vulnerabilities](https://snyk.io/test/github/newrelic/azure-vnet-flow-logs/badge.svg?targetFile=package.json)](https://snyk.io/test/github/newrelic/azure-vnet-flow-logs?targetFile=package.json)

This Azure Function collects and forwards Azure VNet Flow Logs from Azure Event Hubs to New Relic using efficient delta-only processing.

## Overview

The VNet Flow Logs Forwarder consumes VNet flow log data from an Azure Event Hub and forwards it to New Relic Logs. It uses checkpoint management to track processed events and only processes new (delta) flow log data, making it efficient for high-volume environments.

## Features

- **Delta-only processing**: Processes only new flow log data since the last checkpoint
- **Checkpoint management**: Tracks processing progress using Azure Table Storage
- **Event Hub integration**: Consumes VNet flow logs from Azure Event Hub
- **Batch delivery**: Efficiently delivers logs to New Relic in optimized batches
- **Error handling**: Robust error handling and retry logic

## Prerequisites

- Azure subscription with VNet Flow Logs enabled
- Azure Event Hub for receiving VNet flow log data
- Azure Storage Account for checkpoint management
- Azure Functions hosting environment
- New Relic account with a valid License Key or Insert API Key

## Configuration

The function requires the following environment variables to be configured:

### Required Environment Variables

| Variable | Description |
|----------|-------------|
| `EVENTHUB_CONNECTION_STRING` | Connection string for the Event Hub receiving VNet flow logs |
| `EVENTHUB_NAME` | Name of the Event Hub |
| `STORAGE_ACCOUNT_CONNECTION_STRING` | Connection string for Azure Storage (for checkpoints) |
| `NEWRELIC_LICENSE_KEY` | New Relic License Key for sending logs |
| `NEWRELIC_LOGS_ENDPOINT` | New Relic Logs endpoint (default: `https://log-api.newrelic.com/log/v1`) |

### Optional Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `CONSUMER_GROUP` | Event Hub consumer group | `$Default` |
| `LOG_LEVEL` | Logging level (DEBUG, INFO, WARN, ERROR) | `INFO` |

## Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/newrelic/azure-vnet-flow-logs.git
   cd azure-vnet-flow-logs
   ```

2. Install dependencies:
   ```bash
   npm install
   ```

3. Configure local settings (for local development):
   ```bash
   cp local.settings.json.sample local.settings.json
   # Edit local.settings.json with your configuration
   ```

## Deployment

### Package the Function

Create a deployment package:
```bash
npm run package
```

This creates `VNetFlowForwarder.zip` containing the function and all dependencies.

### Deploy to Azure

You can deploy using:

1. **Azure Portal**: Upload the zip file through the Azure Portal
2. **Azure CLI**:
   ```bash
   az functionapp deployment source config-zip \
     --resource-group <resource-group-name> \
     --name <function-app-name> \
     --src VNetFlowForwarder.zip
   ```

3. **VS Code**: Use the Azure Functions extension

### Configure Environment Variables

After deployment, configure the required environment variables in your Azure Function App settings:

```bash
az functionapp config appsettings set \
  --name <function-app-name> \
  --resource-group <resource-group-name> \
  --settings \
    EVENTHUB_CONNECTION_STRING="<your-eventhub-connection-string>" \
    EVENTHUB_NAME="<your-eventhub-name>" \
    STORAGE_ACCOUNT_CONNECTION_STRING="<your-storage-connection-string>" \
    NEWRELIC_LICENSE_KEY="<your-newrelic-license-key>"
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

## Architecture

The VNet Flow Logs Forwarder consists of several modules:

- **index.js**: Azure Function entry point and timer trigger
- **consumer.js**: Event Hub consumer for reading flow log events
- **parser.js**: Parses Azure VNet flow log JSON format
- **cursor.js**: Checkpoint management for tracking processing progress
- **delta.js**: Delta processing logic to handle only new data
- **delivery.js**: Delivers parsed logs to New Relic
- **relay.js**: Coordinates event processing and relay
- **config.js**: Configuration management

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


