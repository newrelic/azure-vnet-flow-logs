'use strict';

require('../testSetup');

const { Readable } = require('stream');
const { BlobServiceClient } = require('@azure/storage-blob');

const delta = require('../VNetFlowForwarder/delta');

// Azure's "Z" + 32 zeros block name, base64-encoded — used as the trailing
// block in PT1H.json blobs. Must match the constant in delta.js.
const TERMINATOR_NAME = Buffer.from(
  'Z00000000000000000000000000000000'
).toString('base64');

function makeBlockBlobClient({ blocks, body = '' }) {
  return {
    getBlockList: jest.fn().mockResolvedValue({ committedBlocks: blocks }),
  };
}

function makeBlobClient(body) {
  return {
    download: jest.fn().mockResolvedValue({
      readableStreamBody: Readable.from([Buffer.from(body, 'utf8')]),
    }),
  };
}

function primeClient({ blocks, body }) {
  delta.resetClient();
  BlobServiceClient.fromConnectionString.mockReset();
  BlobServiceClient.fromConnectionString.mockImplementation(() => ({
    getContainerClient: jest.fn().mockReturnValue({
      getBlockBlobClient: jest
        .fn()
        .mockReturnValue(makeBlockBlobClient({ blocks })),
      getBlobClient: jest.fn().mockReturnValue(makeBlobClient(body)),
    }),
  }));
}

describe('Delta', () => {
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

  describe('downloadDelta — cursor advancement past terminator', () => {
    afterEach(() => {
      delta.resetClient();
    });

    it('first run: stores cursor at last DATA block, not the terminator', async () => {
      // Realistic block list: [header, data1, terminator]
      primeClient({
        blocks: [
          { name: 'aGVhZGVy', size: 10 }, // "header"
          { name: 'ZGF0YTE=', size: 20 }, // "data1"
          { name: TERMINATOR_NAME, size: 3 },
        ],
        body: 'BODY',
      });

      const result = await delta.downloadDelta('c', 'b', null);

      expect(result).not.toBeNull();
      expect(result.lastBlockId).toBe('ZGF0YTE='); // last data block, NOT terminator
      expect(result.lastBlockId).not.toBe(TERMINATOR_NAME);
    });

    it('second run with no new blocks: returns null (caught up)', async () => {
      primeClient({
        blocks: [
          { name: 'aGVhZGVy', size: 10 },
          { name: 'ZGF0YTE=', size: 20 },
          { name: TERMINATOR_NAME, size: 3 },
        ],
        body: 'BODY',
      });

      // Cursor already at last data block
      const result = await delta.downloadDelta('c', 'b', 'ZGF0YTE=');

      expect(result).toBeNull();
    });

    it('second run with new data block appended before terminator: returns the new data', async () => {
      // Blob grew: a new data block was inserted between data1 and terminator
      primeClient({
        blocks: [
          { name: 'aGVhZGVy', size: 10 },
          { name: 'ZGF0YTE=', size: 20 }, // already processed
          { name: 'ZGF0YTI=', size: 25 }, // NEW data
          { name: TERMINATOR_NAME, size: 3 },
        ],
        body: 'NEW_DATA',
      });

      const result = await delta.downloadDelta('c', 'b', 'ZGF0YTE=');

      expect(result).not.toBeNull();
      expect(result.data).toBe('NEW_DATA');
      expect(result.lastBlockId).toBe('ZGF0YTI='); // advances past new data block
    });

    it('handles blob with only the terminator (no data yet)', async () => {
      primeClient({
        blocks: [{ name: TERMINATOR_NAME, size: 3 }],
        body: '',
      });

      const result = await delta.downloadDelta('c', 'b', null);

      expect(result).toBeNull();
    });

    it('handles blob with no terminator (treats every block as data)', async () => {
      // Some early or partial blob states may not have the terminator yet.
      primeClient({
        blocks: [
          { name: 'aGVhZGVy', size: 10 },
          { name: 'ZGF0YTE=', size: 20 },
        ],
        body: 'BODY',
      });

      const result = await delta.downloadDelta('c', 'b', null);

      expect(result).not.toBeNull();
      expect(result.lastBlockId).toBe('ZGF0YTE=');
    });

    it('blob recreated (cursor block ID not in block list) reprocesses from start', async () => {
      primeClient({
        blocks: [
          { name: 'bmV3MQ==', size: 10 },
          { name: 'bmV3Mg==', size: 20 },
          { name: TERMINATOR_NAME, size: 3 },
        ],
        body: 'FRESH',
      });

      const result = await delta.downloadDelta('c', 'b', 'b2xkQ3Vyc29y'); // not in list

      expect(result).not.toBeNull();
      expect(result.data).toBe('FRESH');
      expect(result.lastBlockId).toBe('bmV3Mg==');
    });
  });
});
