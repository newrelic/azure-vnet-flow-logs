'use strict';

require('../testSetup');

const cursor = require('../VNetFlowForwarder/cursor');

describe('Cursor', () => {
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
});
