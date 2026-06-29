'use strict';

/**
 * VNet Flow Logs Forwarder — New Relic Delivery
 *
 * Handles batching, compression, and HTTP delivery of log payloads
 * to the New Relic Logs API with retry logic.
 */

const axios = require('axios');
const axiosRetryImport = require('axios-retry');
const https = require('https');
const zlib = require('zlib');
const config = require('./config');

const axiosRetry = axiosRetryImport.default || axiosRetryImport;

const INSTRUMENTATION_PROVIDER = 'azure';
const INSTRUMENTATION_NAME = 'vnet-app';
const RETRYABLE_NETWORK_ERROR_CODES = new Set([
  'ETIMEDOUT',
  'ECONNRESET',
  'ECONNABORTED',
  'ENOTFOUND',
  'EAI_AGAIN',
]);

// Reuse TCP connections across requests within the same function invocation
const httpsAgent = new https.Agent({ keepAlive: true });

// Dedicated axios instance so our interceptor and retry policy don't leak onto
// the global axios singleton shared by the rest of the process.
const nrClient = axios.create();

// Resolve the transport adapter from global axios at call time instead of
// snapshotting it at create(). Only our interceptor and retry policy need to be
// scoped to this instance; the transport stays shared (and stubbable in tests).
nrClient.defaults.adapter = (requestConfig) =>
  axios.getAdapter(axios.defaults.adapter)(requestConfig);

// Cap response-body text included in error messages to avoid unbounded growth.
function truncateBody(body) {
  if (body === null || body === undefined) return '';
  const bodyStr = typeof body === 'string' ? body : JSON.stringify(body);
  return bodyStr.slice(0, 4096);
}

// Convert non-202 responses into errors before axios-retry evaluates retry rules.
nrClient.interceptors.response.use((response) => {
  const requiresAcceptedStatus =
    response?.config?.metadata?.requiresAcceptedStatus === true;
  if (requiresAcceptedStatus && response.status !== 202) {
    const err = new Error(
      `NR API returned ${response.status}: ${truncateBody(response.data)}`
    );
    err.response = response;
    err.config = response.config;
    throw err;
  }
  return response;
});

// Install retry interceptor once; per-request retry policy is configured in request options.
axiosRetry(nrClient);

/**
 * Build the New Relic payload envelope.
 *
 * @param {Array<Object>} logEntries - Array of log entry objects
 * @param {Object} context - Azure Function context
 * @returns {Array<Object>} NR Logs API payload
 */
function buildPayload(logEntries, context) {
  const tags = parseTags(config.nrTags);
  return [
    {
      common: {
        attributes: {
          'instrumentation.provider': INSTRUMENTATION_PROVIDER,
          'instrumentation.name': INSTRUMENTATION_NAME,
          'instrumentation.version': config.version,
          tags,
        },
      },
      logs: logEntries,
    },
  ];
}

/**
 * Parse semicolon-separated tags string into an object.
 * Format: "key1:value1;key2:value2"
 */
function parseTags(tagsStr) {
  const tagsObj = {};
  if (!tagsStr) return tagsObj;
  const tags = tagsStr.split(';');
  for (const tag of tags) {
    const [key, ...valueParts] = tag.split(':');
    if (key && valueParts.length > 0) {
      tagsObj[key.trim()] = valueParts.join(':').trim();
    }
  }
  return tagsObj;
}

/**
 * Compress data with gzip.
 * @param {string} data - JSON string to compress
 * @returns {Promise<Buffer>} Compressed buffer
 */
function compress(data) {
  return new Promise((resolve, reject) => {
    zlib.gzip(data, (err, result) => {
      if (err) reject(err);
      else resolve(result);
    });
  });
}

/**
 * Send log entries to New Relic with batching, compression, and retry.
 * Recursively splits payloads that exceed the size limit.
 *
 * @param {Array<Object>} logEntries - Log entries to send
 * @param {Object} context - Azure Function context
 * @returns {Promise<void>}
 */
async function sendToNewRelic(logEntries, context) {
  if (!logEntries || logEntries.length === 0) {
    return;
  }

  // Split into message-count batches
  const batches = [];
  for (let i = 0; i < logEntries.length; i += config.maxMessagesPerPayload) {
    batches.push(logEntries.slice(i, i + config.maxMessagesPerPayload));
  }

  for (const batch of batches) {
    await compressAndSend(batch, context);
  }
}

/**
 * Compress a batch and send it. If too large, split recursively.
 */
async function compressAndSend(logEntries, context) {
  const payload = buildPayload(logEntries, context);
  const jsonStr = JSON.stringify(payload);
  const compressed = await compress(jsonStr);

  if (compressed.length > config.maxPayloadSize) {
    if (logEntries.length === 1) {
      context.error(
        `Single log entry exceeds max payload size (${compressed.length} bytes compressed). Skipping.`
      );
      return;
    }
    // Split in half and retry both
    const mid = Math.floor(logEntries.length / 2);
    await compressAndSend(logEntries.slice(0, mid), context);
    await compressAndSend(logEntries.slice(mid), context);
    return;
  }

  await httpSend(compressed, context);
}

/**
 * Send compressed payload via HTTPS to New Relic.
 *
 * @param {Buffer} compressedData
 * @param {Object} context
 * @returns {Promise<void>}
 */
async function httpSend(compressedData, context) {
  try {
    await nrClient.post(config.nrEndpoint, compressedData, {
      httpsAgent,
      responseType: 'text',
      validateStatus: () => true,
      metadata: {
        requiresAcceptedStatus: true,
      },
      headers: {
        'Content-Type': 'application/json',
        'Content-Encoding': 'gzip',
        [config.getApiKeyHeader()]: config.getApiKey(),
      },
      'axios-retry': {
        retries: config.nrMaxRetries,
        retryCondition: (error) => isRetryableError(normalizeAxiosError(error)),
        retryDelay: (_retryCount, error) =>
          getRetryDelay(normalizeAxiosError(error), config.nrRetryInterval),
        onRetry: (retryCount, error) => {
          const normalized = normalizeAxiosError(error);
          const retryDelay = getRetryDelay(normalized, config.nrRetryInterval);
          context.warn(
            `NR delivery attempt ${retryCount} failed: ${normalized.message}. Retrying in ${retryDelay}ms...`
          );
        },
      },
    });
  } catch (error) {
    const normalized = normalizeAxiosError(error);
    if (!isRetryableError(normalized)) {
      context.warn(
        `NR delivery failed with non-retryable error: ${normalized.message}`
      );
    }
    throw normalized;
  }
}

function normalizeAxiosError(error) {
  // axios-retry hands the same error to retryCondition, retryDelay, and onRetry.
  // Normalize once and cache on the error so each callback reuses the result.
  if (error && error.__nrNormalized) {
    return error.__nrNormalized;
  }

  const statusCode = error?.response?.status;
  const responseHeaders = error?.response?.headers || {};
  const responseBody = truncateBody(error?.response?.data);

  let normalized;
  if (typeof statusCode === 'number') {
    normalized = new Error(`NR API returned ${statusCode}: ${responseBody}`);
    normalized.statusCode = statusCode;
    normalized.responseBody = responseBody;
    normalized.retryAfter =
      responseHeaders['retry-after'] || responseHeaders['Retry-After'];
  } else {
    normalized = new Error(error?.message || 'NR API request failed');
    normalized.code = error?.code;
  }

  if (error && typeof error === 'object') {
    Object.defineProperty(error, '__nrNormalized', {
      value: normalized,
      enumerable: false,
    });
  }
  return normalized;
}

function isRetryableError(err) {
  if (!err) return false;
  if (typeof err.statusCode === 'number') {
    return err.statusCode === 429 || err.statusCode >= 500;
  }
  return RETRYABLE_NETWORK_ERROR_CODES.has(err.code);
}

function getRetryDelay(err, fallbackDelayMs) {
  if (err?.statusCode === 429) {
    const retryAfterDelay = parseRetryAfterMs(err.retryAfter);
    if (retryAfterDelay !== null) {
      return retryAfterDelay;
    }
  }
  return fallbackDelayMs;
}

function parseRetryAfterMs(retryAfterHeader) {
  if (!retryAfterHeader) return null;

  const headerValue = Array.isArray(retryAfterHeader)
    ? retryAfterHeader[0]
    : retryAfterHeader;

  const seconds = Number(headerValue);
  if (Number.isFinite(seconds) && seconds >= 0) {
    return seconds * 1000;
  }

  const dateMs = Date.parse(headerValue);
  if (!Number.isNaN(dateMs)) {
    return Math.max(0, dateMs - Date.now());
  }

  return null;
}

module.exports = {
  sendToNewRelic,
};
