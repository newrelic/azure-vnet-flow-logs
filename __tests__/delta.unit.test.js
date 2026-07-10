'use strict';

require('../testSetup');

const { Readable } = require('stream');
const { BlobServiceClient } = require('@azure/storage-blob');
const { DefaultAzureCredential } = require('@azure/identity');
const delta = require('../VNetFlowForwarder/delta');
const config = require('../VNetFlowForwarder/config');

// Azure flow-log block ids: opener "A0…", data "D…", trailing closer "Z0…".
const b64 = (s) => Buffer.from(s, 'latin1').toString('base64');
const OPENER = { name: b64('A' + '0'.repeat(32)), size: 12 };
const CLOSER = { name: b64('Z' + '0'.repeat(32)), size: 2 };
const dataBlock = (id, size) => ({ name: b64('D' + id), size });

/**
 * Wire up the mocked BlobServiceClient so delta.downloadDelta sees a specific
 * committed block list and returns a captured (offset, count) on download.
 */
function mockBlob({ blocks, data = '{}' }) {
  const getBlockList = jest.fn().mockResolvedValue({ committedBlocks: blocks });
  const download = jest.fn().mockResolvedValue({
    readableStreamBody: Readable.from([Buffer.from(data)]),
  });

  BlobServiceClient.fromConnectionString.mockReturnValue({
    getContainerClient: () => ({
      getBlockBlobClient: () => ({ getBlockList }),
      getBlobClient: () => ({ download }),
    }),
  });
  delta.resetClient();
  return { getBlockList, download };
}

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

  describe('downloadDelta — append to the same PT1H.json blob', () => {
    afterEach(() => jest.clearAllMocks());

    it('commits the last DATA block as the cursor, not the trailing closer', async () => {
      const d1 = dataBlock('1111', 100);
      const { download } = mockBlob({ blocks: [OPENER, d1, CLOSER] });

      const result = await delta.downloadDelta('c', 'b', null);

      // First run downloads the whole blob (offset 0, all 114 bytes)...
      expect(download).toHaveBeenCalledWith(0, 12 + 100 + 2);
      // ...but the cursor is the data block, never the closer.
      expect(result.lastBlockId).toBe(d1.name);
    });

    it('detects new data appended before the closer (the bug under test)', async () => {
      const d1 = dataBlock('1111', 100);
      const d2 = dataBlock('2222', 80);
      // Cursor is parked on d1 (committed on the previous run); a new data block
      // d2 was inserted before the constant closer.
      const { download } = mockBlob({ blocks: [OPENER, d1, d2, CLOSER] });

      const result = await delta.downloadDelta('c', 'b', d1.name);

      // Must NOT be treated as "no new data": download starts after d1.
      expect(result).not.toBeNull();
      expect(download).toHaveBeenCalledWith(12 + 100, 80 + 2); // offset past d1, new d2 + closer
      expect(result.lastBlockId).toBe(d2.name);
    });

    it('returns null only when no new data block exists beyond the cursor', async () => {
      const d1 = dataBlock('1111', 100);
      const { download } = mockBlob({ blocks: [OPENER, d1, CLOSER] });

      const result = await delta.downloadDelta('c', 'b', d1.name);

      expect(result).toBeNull();
      expect(download).not.toHaveBeenCalled();
    });

    it('reprocesses from the start when the cursor block is gone (blob recreated)', async () => {
      const d1 = dataBlock('9999', 50);
      const { download } = mockBlob({ blocks: [OPENER, d1, CLOSER] });

      const result = await delta.downloadDelta('c', 'b', b64('D' + 'stale'));

      expect(download).toHaveBeenCalledWith(0, 12 + 50 + 2);
      expect(result.lastBlockId).toBe(d1.name);
    });

    it('returns null (never commits a closer) when the blob holds only the closer', async () => {
      // Freshly-initialized blob: the terminator exists but no data has landed.
      // The fallback must not treat the closer as a data block and commit it as
      // the cursor — that is the very bug this change guards against.
      const { download } = mockBlob({ blocks: [CLOSER] });

      const result = await delta.downloadDelta('c', 'b', null);

      expect(result).toBeNull();
      expect(download).not.toHaveBeenCalled();
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
