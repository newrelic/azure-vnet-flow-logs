'use strict';

require('../testSetup');

const axios = require('axios');
const config = require('../VNetFlowForwarder/config');
const nrClient = require('../VNetFlowForwarder/nr-client');

describe('NR Client', () => {
  it('should export only runtime API', () => {
    expect(Object.keys(nrClient)).toEqual(['sendToNewRelic']);
  });

  it('should no-op on empty log entry list', async () => {
    const context = {
      invocationId: 'inv-123',
      warn: jest.fn(),
      error: jest.fn(),
    };

    await expect(nrClient.sendToNewRelic([], context)).resolves.toBeUndefined();
    await expect(
      nrClient.sendToNewRelic(null, context)
    ).resolves.toBeUndefined();
  });

  it('should retry once on retryable 5xx and then succeed', async () => {
    const context = {
      invocationId: 'inv-123',
      warn: jest.fn(),
      error: jest.fn(),
    };
    const origRetries = config.nrMaxRetries;
    const origInterval = config.nrRetryInterval;
    const origAdapter = axios.defaults.adapter;
    let callCount = 0;

    config.nrMaxRetries = 1;
    config.nrRetryInterval = 0;

    axios.defaults.adapter = jest.fn(async (requestConfig) => {
      callCount += 1;
      if (callCount === 1) {
        return {
          data: 'temporary failure',
          status: 500,
          statusText: 'Internal Server Error',
          headers: {},
          config: requestConfig,
          request: {},
        };
      }

      return {
        data: '',
        status: 202,
        statusText: 'Accepted',
        headers: {},
        config: requestConfig,
        request: {},
      };
    });

    try {
      await expect(
        nrClient.sendToNewRelic(
          [
            {
              timestamp: Date.now(),
              message: 'test-message',
              attributes: {},
            },
          ],
          context
        )
      ).resolves.toBeUndefined();

      expect(callCount).toBe(2);
      expect(context.warn).toHaveBeenCalledWith(
        expect.stringContaining('Retrying in 0ms')
      );
    } finally {
      axios.defaults.adapter = origAdapter;
      config.nrMaxRetries = origRetries;
      config.nrRetryInterval = origInterval;
    }
  });

  it('should honor Retry-After delay on 429 responses', async () => {
    const context = {
      invocationId: 'inv-123',
      warn: jest.fn(),
      error: jest.fn(),
    };
    const origRetries = config.nrMaxRetries;
    const origInterval = config.nrRetryInterval;
    const origAdapter = axios.defaults.adapter;
    let callCount = 0;

    config.nrMaxRetries = 1;
    config.nrRetryInterval = 777;

    axios.defaults.adapter = jest.fn(async (requestConfig) => {
      callCount += 1;
      if (callCount === 1) {
        return {
          data: 'rate limited',
          status: 429,
          statusText: 'Too Many Requests',
          headers: {
            'retry-after': '0',
          },
          config: requestConfig,
          request: {},
        };
      }

      return {
        data: '',
        status: 202,
        statusText: 'Accepted',
        headers: {},
        config: requestConfig,
        request: {},
      };
    });

    try {
      await expect(
        nrClient.sendToNewRelic(
          [
            {
              timestamp: Date.now(),
              message: 'test-message',
              attributes: {},
            },
          ],
          context
        )
      ).resolves.toBeUndefined();

      expect(callCount).toBe(2);
      expect(context.warn).toHaveBeenCalledWith(
        expect.stringContaining('Retrying in 0ms')
      );
    } finally {
      axios.defaults.adapter = origAdapter;
      config.nrMaxRetries = origRetries;
      config.nrRetryInterval = origInterval;
    }
  });
});
