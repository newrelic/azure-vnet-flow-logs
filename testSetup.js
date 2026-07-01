'use strict';

// Mock environment before requiring modules
process.env.NR_LICENSE_KEY = 'test-license-key';
process.env.SOURCE_STORAGE_CONNECTION =
  'DefaultEndpointsProtocol=https;AccountName=test;AccountKey=dGVzdA==;EndpointSuffix=core.windows.net';
process.env.CURSOR_STORAGE_CONNECTION =
  'DefaultEndpointsProtocol=https;AccountName=test;AccountKey=dGVzdA==;EndpointSuffix=core.windows.net';
process.env.EVENTHUB_CONSUMER_CONNECTION =
  'Endpoint=sb://test.servicebus.windows.net/;SharedAccessKeyName=test;SharedAccessKey=dGVzdA==';
process.env.EVENTHUB_NAME = 'eh-vnetflow';
process.env.VNETFLOWLOGS_FORWARDER_ENABLED = 'true';

// Mock Azure SDK modules before requiring application modules
jest.mock('@azure/event-hubs', () => ({
  EventHubProducerClient: jest.fn().mockImplementation(() => ({
    createBatch: jest.fn(),
    sendBatch: jest.fn(),
  })),
}));

jest.mock('@azure/data-tables', () => {
  const newTableClientInstance = () => ({
    getEntity: jest.fn(),
    upsertEntity: jest.fn(),
    listEntities: jest.fn(),
    deleteEntity: jest.fn(),
  });
  // Constructor form (Managed Identity) + static fromConnectionString (Local Auth)
  const TableClient = jest
    .fn()
    .mockImplementation(() => newTableClientInstance());
  TableClient.fromConnectionString = jest
    .fn()
    .mockImplementation(() => newTableClientInstance());
  return { TableClient };
});

jest.mock('@azure/storage-blob', () => {
  const newBlobServiceClientInstance = () => ({
    getContainerClient: jest.fn().mockReturnValue({
      getBlockBlobClient: jest.fn().mockReturnValue({
        getBlockList: jest.fn(),
      }),
    }),
  });
  // Constructor form (Managed Identity) + static fromConnectionString (Local Auth)
  const BlobServiceClient = jest
    .fn()
    .mockImplementation(() => newBlobServiceClientInstance());
  BlobServiceClient.fromConnectionString = jest
    .fn()
    .mockImplementation(() => newBlobServiceClientInstance());
  return { BlobServiceClient };
});

jest.mock('@azure/identity', () => ({
  DefaultAzureCredential: jest.fn().mockImplementation(() => ({})),
}));
