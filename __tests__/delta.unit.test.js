'use strict';

require('../testSetup');

const { BlobServiceClient } = require('@azure/storage-blob');
const { DefaultAzureCredential } = require('@azure/identity');
const delta = require('../VNetFlowForwarder/delta');
const config = require('../VNetFlowForwarder/config');

describe('Delta', () => {
  describe('client construction', () => {
    afterEach(() => {
      delta.resetClient();
      jest.clearAllMocks();
      config.authenticationMode = 'Local Authentication';
    });

    it('uses a connection string in Local Authentication mode', async () => {
      config.authenticationMode = 'Local Authentication';
      // getBlockList triggers lazy client creation (the bare mock rejects;
      // we only care that the client was constructed correctly).
      await delta.getBlockList('container', 'blob').catch(() => {});
      expect(BlobServiceClient.fromConnectionString).toHaveBeenCalledWith(
        config.sourceStorageConnection
      );
      expect(BlobServiceClient).not.toHaveBeenCalled();
    });

    it('uses DefaultAzureCredential against the blob endpoint in Managed Identity mode', async () => {
      config.authenticationMode = 'Managed Identity';
      config.sourceStorageBlobServiceUri = 'https://src.blob.core.windows.net';
      await delta.getBlockList('container', 'blob').catch(() => {});
      expect(BlobServiceClient).toHaveBeenCalledWith(
        'https://src.blob.core.windows.net',
        expect.any(Object)
      );
      expect(DefaultAzureCredential).toHaveBeenCalled();
      expect(BlobServiceClient.fromConnectionString).not.toHaveBeenCalled();
    });
  });

  describe('parseBlobPath', () => {
    it('should parse Event Grid subject format', () => {
      const subject =
        '/blobServices/default/containers/insights-logs-flowlogflowevent/blobs/resourceId=/SUBSCRIPTIONS/sub/RESOURCEGROUPS/rg/PT1H.json';
      const result = delta.parseBlobPath(subject);

      expect(result.containerName).toBe('insights-logs-flowlogflowevent');
      expect(result.blobName).toBe(
        'resourceId=/SUBSCRIPTIONS/sub/RESOURCEGROUPS/rg/PT1H.json'
      );
    });

    it('should handle simple container/blob format', () => {
      const path = 'mycontainer/path/to/file.json';
      const result = delta.parseBlobPath(path);

      expect(result.containerName).toBe('mycontainer');
      expect(result.blobName).toBe('path/to/file.json');
    });

    it('should throw for invalid path with no slash', () => {
      expect(() => delta.parseBlobPath('nocontainer')).toThrow(
        'Invalid blob path'
      );
    });
  });
});
