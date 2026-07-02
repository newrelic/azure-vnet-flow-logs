'use strict';

/**
 * VNet Flow Logs Forwarder — Function Registration
 *
 * Registers Azure Functions:
 *   1. VNetFlowConsumer: Event Hub trigger -> cursor -> delta -> NR
 *   2. VNetFlowCleanup: Timer trigger -> cleanup stale cursors
 */

const { app } = require('@azure/functions');
const config = require('./config');
const { consumerHandler } = require('./log-forwarder');
const cursor = require('./cursor');

let configValidated = false;

/**
 * Validate configuration once per cold start (deferred for testability).
 * Intentionally one-shot: warm invocations reuse the same module instance.
 */
function ensureConfigValidated() {
  if (!configValidated) {
    config.validate();
    configValidated = true;
  }
}

// Fail loudly at cold start if deployment-managed settings (e.g. NR_LICENSE_KEY,
// SOURCE_STORAGE_CONNECTION) are blank or missing. Running this in appStart
// surfaces the error in App Insights the moment the worker starts — even with
// zero incoming events — instead of a function that deploys "green" but drops
// or stalls work on the first trigger. The error is logged and rethrown so the
// host reports startup as failed.
app.hook.appStart(() => {
  try {
    ensureConfigValidated();
  } catch (err) {
    // console.error is captured by the Functions host and surfaces in App
    // Insights at error level.
    console.error(
      `VNetFlowLogs cold-start configuration error: ${err.message} ` +
        'The function cannot process events until this app setting is present.'
    );
    throw err;
  }
});

// Register the Event Hub consumer function
app.eventHub('VNetFlowLogsConsumer', {
  eventHubName: config.eventhubName,
  connection: 'EVENTHUB_CONSUMER_CONNECTION',
  cardinality: 'many',
  consumerGroup: config.eventhubConsumerGroup,
  handler: async (messages, context) => {
    ensureConfigValidated();
    await consumerHandler(messages, context);
  },
});

// Register the cursor cleanup timer function
if (config.cursorCleanupEnabled) {
  app.timer('VNetFlowLogsCleanup', {
    schedule: config.cursorCleanupSchedule,
    handler: async (timer, context) => {
      ensureConfigValidated();
      context.log('VNetFlowLogsCleanup: starting cursor cleanup...');
      const { deleted, errors } = await cursor.cleanupStaleCursors(
        config.cursorRetentionHours
      );
      context.log(
        `VNetFlowLogsCleanup: deleted ${deleted} stale cursors, ${errors} errors`
      );
    },
  });
}

module.exports = { consumerHandler };
