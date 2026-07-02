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

const _parseDate = (val) => {
  if (!val) return null;
  const d = new Date(val);
  return Number.isNaN(d.getTime()) ? null : d;
};

const config = {
  // New Relic
  nrLicenseKey: process.env.NR_LICENSE_KEY || '',
  nrEndpoint: process.env.NR_ENDPOINT || 'https://log-api.newrelic.com/log/v1',
  nrTags: process.env.NR_TAGS || '',
  nrMaxRetries: _parseInt(process.env.NR_MAX_RETRIES, 3),
  nrRetryInterval: _parseInt(process.env.NR_RETRY_INTERVAL, 2000),

  // Azure Storage
  sourceStorageConnection: process.env.SOURCE_STORAGE_CONNECTION || '',
  cursorStorageConnection: process.env.CURSOR_STORAGE_CONNECTION || '',
  cursorTableName: 'nrvnetflowlogscursors',

  // Deployment watermark: the time the integration was deployed (set by the
  // deployment template via utcNow()). Flow-log blobs created before this
  // instant hold pre-existing/historical data that must NOT be backfilled —
  // the Event Hub consumer starts fromEnd, so we mirror that for blob content.
  // Null when unset (older deployments): backfill behavior is preserved.
  integrationStartTime: _parseDate(process.env.INTEGRATION_START_TIME),

  // Event Hub
  eventhubConnection: process.env.EVENTHUB_CONSUMER_CONNECTION || '',
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
 * Returns the API key to use for New Relic authentication.
 */
config.getApiKey = function () {
  return this.nrLicenseKey;
};

/**
 * Returns the header name for the configured key type.
 */
config.getApiKeyHeader = function () {
  return 'X-License-Key';
};

/**
 * Validates that all required configuration is present.
 * Throws if required runtime app settings are missing.
 */
config.validate = function () {
  if (!this.nrLicenseKey) {
    throw new Error(
      'Missing NR_LICENSE_KEY app setting. This value is deployment-managed and must be present at runtime.'
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
