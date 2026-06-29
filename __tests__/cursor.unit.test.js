'use strict';

require('../testSetup');

const { TableClient } = require('@azure/data-tables');
const cursor = require('../VNetFlowForwarder/cursor');

describe('Cursor', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    cursor.resetClient();
  });

  describe('encodeKeys', () => {
    it('should encode slashes in blob paths', () => {
      const path =
        '/blobServices/default/containers/insights/blobs/resource/PT1H.json';
      const keys = cursor.encodeKeys(path);

      expect(keys.partitionKey).toBe('vnetflowlogs');
      expect(keys.rowKey).not.toContain('/');
      expect(keys.rowKey).not.toContain('\\');
      expect(keys.rowKey).not.toContain('#');
      expect(keys.rowKey).not.toContain('?');
      expect(keys.rowKey).toBe(
        '|2f|blobServices|2f|default|2f|containers|2f|insights|2f|blobs|2f|resource|2f|PT1H.json'
      );
    });

    it('should produce consistent keys for same input', () => {
      const path = 'container/path/to/blob.json';
      const keys1 = cursor.encodeKeys(path);
      const keys2 = cursor.encodeKeys(path);
      expect(keys1.rowKey).toBe(keys2.rowKey);
    });

    it('should produce different keys for different inputs', () => {
      const keys1 = cursor.encodeKeys('container/path1/blob.json');
      const keys2 = cursor.encodeKeys('container/path2/blob.json');
      expect(keys1.rowKey).not.toBe(keys2.rowKey);
    });
  });

  describe('cleanupStaleCursors', () => {
    it('should delete stale cursors and return deletion stats', async () => {
      const staleEntities = [
        { partitionKey: 'vnetflowlogs', rowKey: 'rk1' },
        { partitionKey: 'vnetflowlogs', rowKey: 'rk2' },
      ];
      const mockClient = {
        listEntities: jest.fn().mockReturnValue(staleEntities),
        deleteEntity: jest.fn().mockResolvedValue(undefined),
      };

      TableClient.fromConnectionString.mockReturnValue(mockClient);

      const result = await cursor.cleanupStaleCursors(48);

      expect(result).toEqual({ deleted: 2, errors: 0 });
      expect(mockClient.listEntities).toHaveBeenCalledWith(
        expect.objectContaining({
          queryOptions: expect.objectContaining({
            filter: expect.stringContaining("PartitionKey eq 'vnetflowlogs'"),
          }),
        })
      );
      expect(mockClient.deleteEntity).toHaveBeenCalledTimes(2);
      expect(mockClient.deleteEntity).toHaveBeenCalledWith(
        'vnetflowlogs',
        'rk1'
      );
      expect(mockClient.deleteEntity).toHaveBeenCalledWith(
        'vnetflowlogs',
        'rk2'
      );
    });

    it('should count delete errors without failing the cleanup run', async () => {
      const staleEntities = [
        { partitionKey: 'vnetflowlogs', rowKey: 'rk1' },
        { partitionKey: 'vnetflowlogs', rowKey: 'rk2' },
      ];
      const mockClient = {
        listEntities: jest.fn().mockReturnValue(staleEntities),
        deleteEntity: jest
          .fn()
          .mockRejectedValueOnce(new Error('delete failed'))
          .mockResolvedValueOnce(undefined),
      };

      TableClient.fromConnectionString.mockReturnValue(mockClient);

      const result = await cursor.cleanupStaleCursors(48);

      expect(result).toEqual({ deleted: 1, errors: 1 });
      expect(mockClient.deleteEntity).toHaveBeenCalledTimes(2);
    });
  });
});
