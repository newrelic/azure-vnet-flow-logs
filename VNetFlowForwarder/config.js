'use strict';

/**
 * VNet Flow Logs Forwarder — Configuration
 *
 * Centralized environment variable access and defaults.
 */

const _parseInt = (val, def) => { const n = parseInt(val, 10); return Number.isNaN(n) ? def : n; };

const config = {
  // New Relic
  nrLicenseKey: process.env.NR_LICENSE_KEY || '',
  nrInsertKey: process.env.NR_INSERT_KEY || '',
  nrEndpoint: process.env.NR_ENDPOINT || 'https://log-api.newrelic.com/log/v1',
  nrTags: process.env.NR_TAGS || '',
  nrMaxRetries: _parseInt(process.env.NR_MAX_RETRIES, 3),
  nrRetryInterval: _parseInt(process.env.NR_RETRY_INTERVAL, 2000),

  // Azure Storage
  sourceStorageConnection: process.env.SOURCE_STORAGE_CONNECTION || '',
  cursorStorageConnection: process.env.CURSOR_STORAGE_CONNECTION || '',
  cursorTableName: 'nrvnetflowlogscursors',

  // Event Hub
  eventhubConnection: process.env.EVENTHUB_CONSUMER_CONNECTION || '',
  eventhubName: process.env.EVENTHUB_NAME || '',
  eventhubConsumerGroup: process.env.EVENTHUB_CONSUMER_GROUP || '$Default',

  // Cursor cleanup (always enabled)
  cursorCleanupEnabled: true,
  cursorRetentionHours: _parseInt(process.env.CURSOR_RETENTION_HOURS, 48),
  cursorCleanupSchedule: process.env.CURSOR_CLEANUP_SCHEDULE || '0 0 3 * * *',

  // Poison event protection
  maxConsecutiveFailures: _parseInt(process.env.MAX_CONSECUTIVE_FAILURES, 3),

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
 * Throws if required runtime app settings are missing.
 */
config.validate = function () {
  if (!this.nrLicenseKey && !this.nrInsertKey) {
    throw new Error(
      'Missing NR_LICENSE_KEY or NR_INSERT_KEY app setting. Configure at least one runtime key.'
    );
  }
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
  if (!this.eventhubName) {
    throw new Error('Missing EVENTHUB_NAME app setting. This value is deployment-managed and must be present at runtime.');
  }
  try {
    new URL(this.nrEndpoint);
  } catch {
    throw new Error(`NR_ENDPOINT is not a valid URL: ${this.nrEndpoint}`);
  }
};

module.exports = config;
