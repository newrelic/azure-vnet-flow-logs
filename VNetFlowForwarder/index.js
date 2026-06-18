'use strict';

/**
 * VNet Flow Logs Forwarder — Function Registration
 *
 * Registers Azure Functions:
 *   1. VNetFlowRelay: Event Grid trigger -> Event Hub (with partition key)
 *   2. VNetFlowConsumer: Event Hub trigger -> cursor -> delta -> NR
 *   3. VNetFlowCleanup: Timer trigger -> cleanup stale cursors
 */

const { app } = require('@azure/functions');
const config = require('./config');
const { relayHandler } = require('./relay');
const { consumerHandler } = require('./consumer');
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

// Register the Event Grid -> Event Hub relay function
app.eventGrid('VNetFlowLogsRelay', {
  handler: async (event, context) => {
    ensureConfigValidated();
    await relayHandler(event, context);
  },
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

module.exports = { relayHandler, consumerHandler };
