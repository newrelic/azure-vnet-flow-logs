'use strict';

require('../testSetup');

const delta = require('../VNetFlowForwarder/delta');

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
});
