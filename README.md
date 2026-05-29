# Azure VNet Flow Logs Forwarder

Azure Function to collect and forward Azure Virtual Network (VNet) Flow Logs to New Relic using delta-only processing.

## Description

This repository contains an Azure Function app that collects and forwards Azure VNet Flow Logs to New Relic Logs. The function uses delta-only processing to efficiently handle large volumes of flow logs by tracking cursor positions and only processing new data.

### Architecture

The VNet Flow Logs Forwarder consists of two functions:

1. **VNetFlowLogsRelay** (Optional): Event Grid trigger that receives blob creation events and relays them to Event Hub with partition keys
2. **VNetFlowLogsConsumer**: Event Hub trigger that processes flow logs, maintains cursor state, calculates deltas, and forwards to New Relic

### Features

- **Delta-only processing**: Tracks cursor positions to avoid reprocessing data
- **Efficient batching**: Optimizes payload size and message count
- **Automatic retry**: Built-in retry logic for failed deliveries
- **Configurable**: Multiple environment variables for customization
- **Scalable**: Leverages Azure Functions scaling capabilities

## Prerequisites

- Azure subscription
- Node.js 18.x or later
- Azure Functions Core Tools (for local development)
- Azure Storage Account (for VNet Flow Logs and cursor storage)
- Azure Event Hub
- New Relic account with license key

## Configuration

### Environment Variables

Create a `local.settings.json` file for local development (use `local.settings.json.template` as a starting point):

```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "<YOUR_AZURE_WEBJOBS_STORAGE_CONNECTION_STRING>",
    "FUNCTIONS_WORKER_RUNTIME": "node",
    "FUNCTIONS_EXTENSION_VERSION": "~4",
    "VNETFLOWLOGS_RELAY_ENABLED": "false",
    "VNETFLOWLOGS_FORWARDER_ENABLED": "true",
    "SOURCE_STORAGE_CONNECTION": "<YOUR_SOURCE_STORAGE_CONNECTION_STRING>",
    "CURSOR_STORAGE_CONNECTION": "<YOUR_CURSOR_STORAGE_CONNECTION_STRING>",
    "EVENTHUB_CONSUMER_CONNECTION": "<YOUR_EVENTHUB_CONSUMER_CONNECTION_STRING>",
    "EVENTHUB_NAME": "<YOUR_EVENTHUB_NAME>",
    "EVENTHUB_CONSUMER_GROUP": "<YOUR_EVENTHUB_CONSUMER_GROUP>",
    "DEBUG_ENABLED": "false",
    "NR_LICENSE_KEY": "<YOUR_NEW_RELIC_LICENSE_KEY>",
    "NR_ENDPOINT": "https://log-api.newrelic.com/log/v1"
  }
}
```

### Configuration Options

| Variable | Required | Description | Default |
|----------|----------|-------------|---------|
| `NR_LICENSE_KEY` | Yes | New Relic license key | - |
| `NR_ENDPOINT` | No | New Relic logs endpoint | `https://log-api.newrelic.com/log/v1` |
| `SOURCE_STORAGE_CONNECTION` | Yes | Connection string for storage account containing VNet Flow Logs | - |
| `CURSOR_STORAGE_CONNECTION` | Yes | Connection string for storage account to store cursor state | - |
| `EVENTHUB_CONSUMER_CONNECTION` | Yes | Event Hub connection string | - |
| `EVENTHUB_NAME` | Yes | Event Hub name | - |
| `EVENTHUB_CONSUMER_GROUP` | No | Event Hub consumer group | `$Default` |
| `VNETFLOWLOGS_RELAY_ENABLED` | No | Enable the Event Grid relay function | `false` |
| `VNETFLOWLOGS_FORWARDER_ENABLED` | No | Enable the Event Hub consumer function | `true` |
| `DEBUG_ENABLED` | No | Enable debug logging | `false` |
| `CURSOR_TABLE_NAME` | No | Table name for cursor storage | `nrvnetflowlogscursors` |

## Installation

### Local Development

1. Clone this repository:
   ```bash
   git clone https://github.com/yourusername/azure-vnet-flow-logs.git
   cd azure-vnet-flow-logs
   ```

2. Install dependencies:
   ```bash
   npm install
   ```

3. Copy the template and configure your local settings:
   ```bash
   cp local.settings.json.template local.settings.json
   # Edit local.settings.json with your actual values
   ```

4. Start the function locally:
   ```bash
   func start
   ```

### Azure Deployment

1. Create a Function App in Azure:
   ```bash
   az functionapp create \
     --resource-group <RESOURCE_GROUP> \
     --consumption-plan-location <LOCATION> \
     --runtime node \
     --runtime-version 18 \
     --functions-version 4 \
     --name <FUNCTION_APP_NAME> \
     --storage-account <STORAGE_ACCOUNT>
   ```

2. Configure application settings:
   ```bash
   az functionapp config appsettings set \
     --name <FUNCTION_APP_NAME> \
     --resource-group <RESOURCE_GROUP> \
     --settings \
       NR_LICENSE_KEY=<YOUR_KEY> \
       SOURCE_STORAGE_CONNECTION=<CONNECTION_STRING> \
       # ... add other settings
   ```

3. Package and deploy:
   ```bash
   npm run package
   az functionapp deployment source config-zip \
     --resource-group <RESOURCE_GROUP> \
     --name <FUNCTION_APP_NAME> \
     --src VNetFlowForwarder.zip
   ```

## Testing

Run the test suite:

```bash
npm test
```

Run with coverage:

```bash
npm test -- --coverage
```

## Project Structure

```
azure-vnet-flow-logs/
├── VNetFlowForwarder/          # Main function code
│   ├── index.js                # Function registration
│   ├── config.js               # Configuration management
│   ├── consumer.js             # Event Hub consumer handler
│   ├── relay.js                # Event Grid relay handler
│   ├── cursor.js               # Cursor state management
│   ├── delta.js                # Delta processing logic
│   ├── parser.js               # Flow log parsing
│   └── delivery.js             # New Relic delivery
├── __tests__/                  # Test files
│   └── vnetFlowForwarder.unit.test.js
├── host.json                   # Function app configuration
├── package.json                # Dependencies and scripts
├── local.settings.json.template # Configuration template
└── README.md                   # This file
```

## How It Works

1. **Data Flow**:
   - VNet Flow Logs are written to Azure Storage as append blobs
   - Event Grid triggers (optional) send blob creation events to Event Hub
   - Event Hub consumer function processes messages
   - Function reads the blob, maintains cursor position, and calculates delta
   - New flow records are parsed and batched
   - Batches are sent to New Relic Logs API

2. **Cursor Management**:
   - Cursor positions are stored in Azure Table Storage
   - Each blob has a unique cursor tracking its last processed byte offset
   - Only new data (delta) is processed on subsequent runs

3. **Delta Processing**:
   - Calculates the difference between last cursor position and current blob size
   - Downloads only the new data
   - Parses and transforms the new flow log records

## Troubleshooting

### Enable Debug Logging

Set `DEBUG_ENABLED=true` in your configuration to see detailed logs.

### Check Cursor State

Query the cursor table in Azure Table Storage to see current cursor positions:
- Table name: `nrvnetflowlogscursors` (or your configured value)
- Partition key: Container name
- Row key: Blob name

### Common Issues

1. **No data forwarded**: Check that `VNETFLOWLOGS_FORWARDER_ENABLED=true`
2. **Connection errors**: Verify all connection strings are correct
3. **Authentication errors**: Ensure New Relic license key is valid
4. **Missing events**: Check Event Hub consumer group configuration

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.

## Support

For issues and questions:
- Open an issue in this repository
- Contact your New Relic account team

## Related Resources

- [Azure VNet Flow Logs Documentation](https://learn.microsoft.com/en-us/azure/network-watcher/vnet-flow-logs-overview)
- [New Relic Logs API](https://docs.newrelic.com/docs/logs/log-api/introduction-log-api/)
- [Azure Functions Documentation](https://learn.microsoft.com/en-us/azure/azure-functions/)
