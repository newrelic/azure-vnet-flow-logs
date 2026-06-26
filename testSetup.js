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

jest.mock('@azure/data-tables', () => ({
  TableClient: {
    fromConnectionString: jest.fn().mockImplementation(() => ({
      getEntity: jest.fn(),
      upsertEntity: jest.fn(),
      listEntities: jest.fn(),
      deleteEntity: jest.fn(),
    })),
  },
}));

jest.mock('@azure/storage-blob', () => ({
  BlobServiceClient: {
    fromConnectionString: jest.fn().mockImplementation(() => ({
      getContainerClient: jest.fn().mockReturnValue({
        getBlobClient: jest.fn().mockReturnValue({
          getBlockList: jest.fn(),
          download: jest.fn(),
        }),
      }),
    })),
  },
}));
