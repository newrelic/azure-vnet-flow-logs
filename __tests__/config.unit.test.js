'use strict';

require('../testSetup');

const config = require('../VNetFlowForwarder/config');

describe('Config', () => {
  it('should return license key as API key', () => {
    expect(config.getApiKey()).toBe('test-license-key');
    expect(config.getApiKeyHeader()).toBe('X-License-Key');
  });

  it('should validate successfully with required vars set', () => {
    expect(() => config.validate()).not.toThrow();
  });

  it('should throw if no license key configured', () => {
    const origLicense = config.nrLicenseKey;
    config.nrLicenseKey = '';

    expect(() => config.validate()).toThrow('Missing NR_LICENSE_KEY');

    config.nrLicenseKey = origLicense;
  });

  it('should throw if no storage connection', () => {
    const orig = config.sourceStorageConnection;
    config.sourceStorageConnection = '';

    expect(() => config.validate()).toThrow(
      'Missing SOURCE_STORAGE_CONNECTION'
    );

    config.sourceStorageConnection = orig;
  });

  describe('Managed Identity mode', () => {
    let saved;

    beforeEach(() => {
      saved = {
        authenticationMode: config.authenticationMode,
        sourceStorageBlobServiceUri: config.sourceStorageBlobServiceUri,
        cursorStorageTableServiceUri: config.cursorStorageTableServiceUri,
        eventhubFullyQualifiedNamespace: config.eventhubFullyQualifiedNamespace,
      };
      config.authenticationMode = 'Managed Identity';
      config.sourceStorageBlobServiceUri = 'https://src.blob.core.windows.net';
      config.cursorStorageTableServiceUri = 'https://fn.table.core.windows.net';
      config.eventhubFullyQualifiedNamespace = 'ns.servicebus.windows.net';
    });

    afterEach(() => {
      Object.assign(config, saved);
    });

    it('useManagedIdentity reflects the configured mode', () => {
      expect(config.useManagedIdentity()).toBe(true);
      config.authenticationMode = 'Local Authentication';
      expect(config.useManagedIdentity()).toBe(false);
    });

    it('validates with the MI service endpoints and ignores absent connection strings', () => {
      const saved = {
        sourceStorageConnection: config.sourceStorageConnection,
        cursorStorageConnection: config.cursorStorageConnection,
        eventhubConnection: config.eventhubConnection,
      };
      config.sourceStorageConnection = '';
      config.cursorStorageConnection = '';
      config.eventhubConnection = '';

      expect(() => config.validate()).not.toThrow();

      Object.assign(config, saved);
    });

    it('throws if the source blob service URI is missing', () => {
      config.sourceStorageBlobServiceUri = '';
      expect(() => config.validate()).toThrow(
        'Missing SOURCE_STORAGE_BLOB_SERVICE_URI'
      );
    });

    it('throws if the cursor table service URI is missing', () => {
      config.cursorStorageTableServiceUri = '';
      expect(() => config.validate()).toThrow(
        'Missing CURSOR_STORAGE_TABLE_SERVICE_URI'
      );
    });

    it('throws if the Event Hub fully qualified namespace is missing', () => {
      config.eventhubFullyQualifiedNamespace = '';
      expect(() => config.validate()).toThrow(
        'Missing EVENTHUB_CONSUMER_CONNECTION__fullyQualifiedNamespace'
      );
    });
  });
});
