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
});
