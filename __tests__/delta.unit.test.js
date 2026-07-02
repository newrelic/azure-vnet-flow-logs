'use strict';

require('../testSetup');

const { Readable } = require('stream');
const { BlobServiceClient } = require('@azure/storage-blob');
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
function mockBlob({ blocks, data = '{}', createdOn = null }) {
  const getBlockList = jest.fn().mockResolvedValue({ committedBlocks: blocks });
  const download = jest.fn().mockResolvedValue({
    readableStreamBody: Readable.from([Buffer.from(data)]),
  });
  const getProperties = jest.fn().mockResolvedValue({ createdOn });

  BlobServiceClient.fromConnectionString.mockReturnValue({
    getContainerClient: () => ({
      getBlockBlobClient: () => ({ getBlockList }),
      getBlobClient: () => ({ download, getProperties }),
    }),
  });
  delta.resetClient();
  return { getBlockList, download, getProperties };
}

describe('Delta', () => {
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

  describe('downloadDelta — historical backfill guard (INTEGRATION_START_TIME)', () => {
    const DEPLOY_TIME = new Date('2026-07-02T08:00:00Z');

    afterEach(() => {
      jest.clearAllMocks();
      config.integrationStartTime = null;
    });

    it('skips backfill for a first-seen blob created before deployment', async () => {
      config.integrationStartTime = DEPLOY_TIME;
      const d1 = dataBlock('1111', 100);
      const d2 = dataBlock('2222', 80);
      // Current-hour blob that existed before deploy (created 07:00) and was
      // appended to afterwards — the classic historical-backfill case.
      const { download } = mockBlob({
        blocks: [OPENER, d1, d2, CLOSER],
        createdOn: new Date('2026-07-02T07:00:00Z'),
      });

      const result = await delta.downloadDelta('c', 'b', null);

      // No historical content downloaded; cursor parked at the current frontier.
      expect(download).not.toHaveBeenCalled();
      expect(result).toEqual({
        data: '',
        lastBlockId: d2.name,
        skippedBackfill: true,
      });
    });

    it('ingests in full a first-seen blob created at/after deployment', async () => {
      config.integrationStartTime = DEPLOY_TIME;
      const d1 = dataBlock('1111', 100);
      // A brand-new hour blob created after deploy (09:00) — all content is new.
      const { download } = mockBlob({
        blocks: [OPENER, d1, CLOSER],
        createdOn: new Date('2026-07-02T09:00:00Z'),
      });

      const result = await delta.downloadDelta('c', 'b', null);

      expect(download).toHaveBeenCalledWith(0, 12 + 100 + 2);
      expect(result.lastBlockId).toBe(d1.name);
      expect(result.skippedBackfill).toBeUndefined();
    });

    it('preserves full-read behavior when no watermark is configured', async () => {
      config.integrationStartTime = null;
      const d1 = dataBlock('1111', 100);
      const { download, getProperties } = mockBlob({
        blocks: [OPENER, d1, CLOSER],
        createdOn: new Date('2020-01-01T00:00:00Z'),
      });

      const result = await delta.downloadDelta('c', 'b', null);

      // Watermark unset -> creation time is never consulted, whole blob is read.
      expect(getProperties).not.toHaveBeenCalled();
      expect(download).toHaveBeenCalledWith(0, 12 + 100 + 2);
      expect(result.lastBlockId).toBe(d1.name);
    });

    it('reads in full when creation time is missing or invalid', async () => {
      config.integrationStartTime = DEPLOY_TIME;
      const d1 = dataBlock('1111', 100);
      // Azure returned no/invalid creation time: we must not skip backfill on a
      // NaN comparison — default to the safe full read instead.
      const { download } = mockBlob({
        blocks: [OPENER, d1, CLOSER],
        createdOn: new Date('not-a-date'),
      });

      const result = await delta.downloadDelta('c', 'b', null);

      expect(download).toHaveBeenCalledWith(0, 12 + 100 + 2);
      expect(result.skippedBackfill).toBeUndefined();
    });

    it('does not consult creation time once a cursor exists', async () => {
      config.integrationStartTime = DEPLOY_TIME;
      const d1 = dataBlock('1111', 100);
      const d2 = dataBlock('2222', 80);
      const { getProperties } = mockBlob({
        blocks: [OPENER, d1, d2, CLOSER],
        createdOn: new Date('2026-07-02T07:00:00Z'),
      });

      const result = await delta.downloadDelta('c', 'b', d1.name);

      // A committed cursor means we already own this blob — the watermark only
      // gates the very first sight, so creation time must not be fetched.
      expect(getProperties).not.toHaveBeenCalled();
      expect(result.lastBlockId).toBe(d2.name);
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
