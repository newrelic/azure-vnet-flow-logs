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
 * Validate configuration on first invocation (deferred for testability).
 */
function ensureConfigValidated() {
  if (!configValidated) {
    config.validate();
    configValidated = true;
  }
}

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
