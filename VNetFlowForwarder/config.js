'use strict';

/**
 * VNet Flow Logs Forwarder — Configuration
 *
 * Centralized environment variable access and defaults.
 */

const config = {
  // New Relic
  nrLicenseKey: process.env.NR_LICENSE_KEY || '',
  nrInsertKey: process.env.NR_INSERT_KEY || '',
  nrEndpoint: process.env.NR_ENDPOINT || 'https://log-api.newrelic.com/log/v1',
  nrTags: process.env.NR_TAGS || '',
  nrMaxRetries: parseInt(process.env.NR_MAX_RETRIES, 10) || 3,
  nrRetryInterval: parseInt(process.env.NR_RETRY_INTERVAL, 10) || 2000,

  // Azure Storage
  sourceStorageConnection: process.env.SOURCE_STORAGE_CONNECTION || '',
  cursorStorageConnection: process.env.CURSOR_STORAGE_CONNECTION || '',
  cursorTableName: 'nrvnetflowlogscursors',

  // Event Hub
  eventhubConnection: process.env.EVENTHUB_CONSUMER_CONNECTION || '',
  eventhubName: process.env.EVENTHUB_NAME || '',
  eventhubConsumerGroup: process.env.EVENTHUB_CONSUMER_GROUP || '$Default',

  // Cursor cleanup
  cursorCleanupEnabled: process.env.CURSOR_CLEANUP_ENABLED !== 'false',
  cursorRetentionHours: parseInt(process.env.CURSOR_RETENTION_HOURS, 10) || 48,
  cursorCleanupSchedule: process.env.CURSOR_CLEANUP_SCHEDULE || '0 0 3 * * *',

  // Poison event protection
  maxConsecutiveFailures: parseInt(process.env.MAX_CONSECUTIVE_FAILURES, 10) || 3,

  // Logging
  debugEnabled: process.env.DEBUG_ENABLED === 'true',

  // Limits
  maxPayloadSize: 1000 * 1024, // ~1 MB compressed
  maxMessagesPerPayload: 900,

  // Version (from package.json)
  version: require('../package.json').version,
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
 * Throws if critical settings are missing.
 */
config.validate = function () {
  if (!this.nrLicenseKey && !this.nrInsertKey) {
    throw new Error(
      'Missing NR_LICENSE_KEY or NR_INSERT_KEY. Configure at least one.'
    );
  }
  if (!this.sourceStorageConnection) {
    throw new Error(
      'Missing SOURCE_STORAGE_CONNECTION. Set the source storage account connection string.'
    );
  }
  if (!this.cursorStorageConnection) {
    throw new Error(
      'Missing CURSOR_STORAGE_CONNECTION. Set the cursor storage account connection string.'
    );
  }
  if (!this.eventhubConnection) {
    throw new Error(
      'Missing EVENTHUB_CONSUMER_CONNECTION. Set the Event Hub connection string.'
    );
  }
  if (!this.eventhubName) {
    throw new Error('Missing EVENTHUB_NAME. Set the Event Hub name.');
  }
};

module.exports = config;
