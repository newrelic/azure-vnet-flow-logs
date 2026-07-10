'use strict';

/**
 * VNet Flow Logs Forwarder — Event Hub Consumer Function
 *
 * Triggered by Event Hub messages (routed from Event Grid via partition key).
 * For each message (representing a BlobCreated event):
 *   1. Reads the cursor from Table Storage
 *   2. Downloads only new blocks from the blob (delta)
 *   3. Parses VNet flow log records
 *   4. Sends to New Relic
 *   5. Commits the new cursor on success
 */

const config = require('./config');
const cursor = require('./cursor');
const delta = require('./delta');
const parser = require('./parser');
const nrClient = require('./nr-client');

/**
 * Normalize a blob path from an Event Hub/Event Grid message.
 * Handles both subject format and full data.url (HTTPS) format.
 */
function normalizeBlobPath(event) {
  if (event?.subject) return event.subject;
  if (event?.data?.url) {
    try {
      const u = new URL(event.data.url);
      return u.pathname.slice(1); // /container/blob -> container/blob
    } catch {
      return '';
    }
  }
  return '';
}

/**
 * Emit a debug log using Azure Functions logger levels.
 * Visibility is controlled by host.json/app settings log level configuration.
 */
function logDebug(context, message) {
  if (typeof context?.debug === 'function') {
    context.debug(message);
  }
}

/**
 * Handle a per-event processing error and update poison-event failure tracking.
 *
 * @param {Object} context - Azure Function context
 * @param {string} blobPath - Normalized blob path
 * @param {Error} err - Processing error
 * @param {Object|null} cursorData - Pre-fetched cursor data {lastBlockId, failureCount}
 * @returns {Promise<void>}
 */
async function handleProcessingError(context, blobPath, err, cursorData) {
  context.error(
    `Error processing event for blob "${blobPath}": ${err.message}`
  );

  // Increment failure counter for poison event protection.
  // This path is reached only after nr-client retries are exhausted or on other hard failures.
  // Reuse pre-fetched cursor data to avoid an extra Table Storage call.
  try {
    const lastBlockId = cursorData?.lastBlockId || null;
    const failureCount = cursorData?.failureCount || 0;
    await cursor.incrementFailure(blobPath, lastBlockId, failureCount);
  } catch (cursorErr) {
    context.warn(`Failed to increment failure counter: ${cursorErr.message}`);
  }
}

/**
 * Consumer handler: processes a batch of Event Hub messages.
 * Each message contains a blob path that needs delta processing.
 *
 * @param {Array<Object>} messages - Array of Event Hub message bodies
 * @param {Object} context - Azure Function context
 */
async function consumerHandler(messages, context) {
  const msgArray = Array.isArray(messages) ? messages : [messages];
  let totalRecords = 0;
  let totalBytes = 0;
  let processedEvents = 0;
  let skippedEvents = 0;
  let erroredEvents = 0;

  for (const message of msgArray) {
    const eventArray = Array.isArray(message) ? message : [message];

    for (const rawMsg of eventArray) {
      // Pre-fetch cursor to avoid redundant calls on error
      let cursorData = null;
      const blobPath = normalizeBlobPath(rawMsg) || 'unknown';

      try {
        cursorData = await cursor.getCursor(blobPath);
        const result = await processEvent(rawMsg, context, cursorData);
        if (result) {
          totalRecords += result.records;
          totalBytes += result.bytes;
          processedEvents++;
        } else {
          skippedEvents++;
        }
      } catch (err) {
        erroredEvents++;
        await handleProcessingError(context, blobPath, err, cursorData);
      }
    }
  }

  context.log(
    `VNetFlowLogs batch complete: ${processedEvents} processed, ${skippedEvents} skipped, ${erroredEvents} errors. ` +
      `Total records: ${totalRecords}, bytes downloaded: ${totalBytes}`
  );
}

/**
 * Process a single blob event: cursor -> delta -> parse -> send -> commit.
 *
 * @param {Object} message - Event Hub message body (contains subject/blobPath)
 * @param {Object} context - Azure Function context
 * @param {Object} cursorData - Pre-fetched cursor data {lastBlockId, failureCount}
 * @returns {Promise<{records: number, bytes: number} | null>} Processing stats or null if skipped
 */
async function processEvent(event, context, cursorData) {
  if (!event) {
    context.warn('Consumer: empty message. Skipping.');
    return null;
  }

  const blobPath = normalizeBlobPath(event);
  if (!blobPath) {
    context.warn('Consumer: message has no blob path. Skipping.');
    return null;
  }

  logDebug(context, `Consumer: processing ${blobPath}`);

  // Step 1: Parse the blob path
  const { containerName, blobName } = delta.parseBlobPath(blobPath);

  // Step 2: Use provided cursor data and check for poison event
  const { lastBlockId, failureCount = 0 } = cursorData || {};
  if (failureCount >= config.maxConsecutiveFailures) {
    context.error(
      `Consumer: blob "${blobPath}" has failed ${failureCount} consecutive times (threshold: ${config.maxConsecutiveFailures}). Skipping (poison event).`
    );
    return null;
  }
  logDebug(context, `Consumer: cursor for ${blobPath} = ${lastBlockId}`);

  // Step 3: Download delta
  let deltaResult;
  try {
    deltaResult = await delta.downloadDelta(
      containerName,
      blobName,
      lastBlockId
    );
  } catch (err) {
    if (err.statusCode === 404) {
      context.warn(`Consumer: blob not found (deleted?): ${blobPath}`);
      return null;
    }
    throw err;
  }

  if (!deltaResult) {
    logDebug(context, `Consumer: no new blocks for ${blobPath}. Skipping.`);
    return null;
  }

  const { data, lastBlockId: newLastBlockId } = deltaResult;

  // Step 4: Parse the delta into flow log records
  const records = parser.parseRawDelta(data);
  if (records.length === 0) {
    context.warn(`Consumer: parsed 0 records from delta of ${blobPath}`);
    // Still advance cursor to avoid re-processing empty deltas
    try {
      await cursor.setCursor(blobPath, newLastBlockId);
    } catch (cursorErr) {
      context.error(
        `Consumer: cursor commit failed for empty delta ${blobPath}: ${cursorErr.message}`
      );
      throw cursorErr;
    }
    return { records: 0, bytes: data.length };
  }

  // Step 5: Transform records into NR log entries
  const pathMetadata = parser.extractMetadataFromPath(blobName);
  const { logEntries, fallbackCount } = parser.transformRecords(
    records,
    pathMetadata
  );

  // Surface invalid-timestamp fallbacks to the Function's own logs for
  // troubleshooting. This stays server-side (Azure Monitor / App Insights) and
  // is intentionally not attached to any log entry, so nothing extra is sent to
  // New Relic.
  if (fallbackCount > 0) {
    context.warn(
      `Consumer: ${fallbackCount} flow tuples had invalid timestamps for ${blobPath}; fallback ingest-time timestamps were used.`
    );
  }

  logDebug(
    context,
    `Consumer: ${records.length} records -> ${logEntries.length} log entries from ${blobPath}`
  );

  // Step 6: Send to New Relic
  await nrClient.sendToNewRelic(logEntries, context);

  // Step 7: Commit cursor (only after successful delivery)
  try {
    await cursor.setCursor(blobPath, newLastBlockId);
  } catch (cursorErr) {
    context.error(
      `Consumer: cursor commit failed for ${blobPath}: ${cursorErr.message}. Records sent but cursor not advanced — possible duplicate delivery on retry.`
    );
    throw cursorErr;
  }

  logDebug(
    context,
    `Consumer: cursor advanced to block ${newLastBlockId} for ${blobPath}`
  );

  return { records: logEntries.length, bytes: data.length };
}

module.exports = {
  consumerHandler,
};
