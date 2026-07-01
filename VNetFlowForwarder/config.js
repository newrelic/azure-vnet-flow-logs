'use strict';

/**
 * VNet Flow Logs Forwarder — Configuration
 *
 * Centralized environment variable access and defaults.
 */

const _parseInt = (val, def) => {
  const n = parseInt(val, 10);
  return Number.isNaN(n) ? def : n;
};

const config = {
  // New Relic
  nrLicenseKey: process.env.NR_LICENSE_KEY || '',
  nrInsertKey: process.env.NR_INSERT_KEY || '',
  nrEndpoint: process.env.NR_ENDPOINT || 'https://log-api.newrelic.com/log/v1',
  nrTags: process.env.NR_TAGS || '',
  nrMaxRetries: _parseInt(process.env.NR_MAX_RETRIES, 3),
  nrRetryInterval: _parseInt(process.env.NR_RETRY_INTERVAL, 2000),

  // Authentication
  // 'Local Authentication' uses shared-key connection strings (default).
  // 'Managed Identity' authenticates via the function's system-assigned
  // identity, leaving no secrets in app settings.
  authenticationMode: process.env.AUTHENTICATION_MODE || 'Local Authentication',

  // Azure Storage — Local Authentication (connection strings)
  sourceStorageConnection: process.env.SOURCE_STORAGE_CONNECTION || '',
  cursorStorageConnection: process.env.CURSOR_STORAGE_CONNECTION || '',
  cursorTableName: 'nrvnetflowlogscursors',

  // Azure Storage — Managed Identity (service endpoints)
  sourceStorageBlobServiceUri:
    process.env.SOURCE_STORAGE_BLOB_SERVICE_URI || '',
  cursorStorageTableServiceUri:
    process.env.CURSOR_STORAGE_TABLE_SERVICE_URI || '',

  // Event Hub
  eventhubConnection: process.env.EVENTHUB_CONSUMER_CONNECTION || '',
  eventhubFullyQualifiedNamespace:
    process.env.EVENTHUB_CONSUMER_CONNECTION__fullyQualifiedNamespace || '',
  eventhubName: process.env.EVENTHUB_NAME || '',
  eventhubConsumerGroup: process.env.EVENTHUB_CONSUMER_GROUP || '$Default',

  // Cursor cleanup (always enabled)
  cursorCleanupEnabled: true,
  cursorRetentionHours: _parseInt(process.env.CURSOR_RETENTION_HOURS, 48),
  cursorCleanupSchedule: process.env.CURSOR_CLEANUP_SCHEDULE || '0 0 3 * * *',

  // Poison event protection
  maxConsecutiveFailures: _parseInt(process.env.MAX_CONSECUTIVE_FAILURES, 5),

  // Limits
  maxPayloadSize: 1000 * 1024, // ~1 MB compressed
  maxMessagesPerPayload: 900,

  // Version (from package.json)
  version: require('../package.json').version,
};

/**
 * Returns true when the forwarder should authenticate to Azure data planes
 * (Event Hub, source blobs, cursor table) using the function's managed
 * identity rather than shared-key connection strings.
 */
config.useManagedIdentity = function () {
  return this.authenticationMode === 'Managed Identity';
};

/**
 * Returns the API key to use for New Relic authentication.
 */
config.getApiKey = function () {
  return this.nrLicenseKey || this.nrInsertKey;
};

/**
 * Returns the header name for the configured key type.
 */
config.getApiKeyHeader = function () {
  return this.nrLicenseKey ? 'X-License-Key' : 'X-Insert-Key';
};

/**
 * Validates that all required configuration is present.
 * Throws if required runtime app settings are missing.
 */
config.validate = function () {
  if (!this.nrLicenseKey && !this.nrInsertKey) {
    throw new Error(
      'Missing NR_LICENSE_KEY or NR_INSERT_KEY app setting. Configure at least one runtime key.'
    );
  }
  if (this.useManagedIdentity()) {
    // Managed Identity mode: service endpoints replace connection strings.
    if (!this.sourceStorageBlobServiceUri) {
      throw new Error(
        'Missing SOURCE_STORAGE_BLOB_SERVICE_URI app setting. Required when AUTHENTICATION_MODE is "Managed Identity". This value is deployment-managed and must be present at runtime.'
      );
    }
    if (!this.cursorStorageTableServiceUri) {
      throw new Error(
        'Missing CURSOR_STORAGE_TABLE_SERVICE_URI app setting. Required when AUTHENTICATION_MODE is "Managed Identity". This value is deployment-managed and must be present at runtime.'
      );
    }
    if (!this.eventhubFullyQualifiedNamespace) {
      throw new Error(
        'Missing EVENTHUB_CONSUMER_CONNECTION__fullyQualifiedNamespace app setting. Required when AUTHENTICATION_MODE is "Managed Identity". This value is deployment-managed and must be present at runtime.'
      );
    }
  } else {
    // Local Authentication mode: shared-key connection strings.
    if (!this.sourceStorageConnection) {
      throw new Error(
        'Missing SOURCE_STORAGE_CONNECTION app setting. This value is deployment-managed and must be present at runtime.'
      );
    }
    if (!this.cursorStorageConnection) {
      throw new Error(
        'Missing CURSOR_STORAGE_CONNECTION app setting. This value is deployment-managed and must be present at runtime.'
      );
    }
    if (!this.eventhubConnection) {
      throw new Error(
        'Missing EVENTHUB_CONSUMER_CONNECTION app setting. This value is deployment-managed and must be present at runtime.'
      );
    }
  }
  if (!this.eventhubName) {
    throw new Error(
      'Missing EVENTHUB_NAME app setting. This value is deployment-managed and must be present at runtime.'
    );
  }
  try {
    new URL(this.nrEndpoint);
  } catch {
    throw new Error(`NR_ENDPOINT is not a valid URL: ${this.nrEndpoint}`);
  }
};

module.exports = config;
