'use strict';

require('../testSetup');

const { EventEmitter } = require('events');
const https = require('https');
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
    await expect(nrClient.sendToNewRelic(null, context)).resolves.toBeUndefined();
  });

  it('should retry once on retryable 5xx and then succeed', async () => {
    const context = {
      invocationId: 'inv-123',
      warn: jest.fn(),
      error: jest.fn(),
    };
    const origRetries = config.nrMaxRetries;
    const origInterval = config.nrRetryInterval;
    let callCount = 0;

    config.nrMaxRetries = 1;
    config.nrRetryInterval = 0;

    const requestSpy = jest
      .spyOn(https, 'request')
      .mockImplementation((options, callback) => {
        callCount += 1;
        const req = new EventEmitter();
        req.write = jest.fn();
        req.end = jest.fn(() => {
          const res = new EventEmitter();
          res.statusCode = callCount === 1 ? 500 : 202;
          res.headers = {};
          res.setEncoding = jest.fn();
          callback(res);
          if (callCount === 1) {
            res.emit('data', 'temporary failure');
          }
          res.emit('end');
        });
        return req;
      });

    await expect(
      nrClient.sendToNewRelic([
        {
          timestamp: Date.now(),
          message: 'test-message',
          attributes: {},
        },
      ], context)
    ).resolves.toBeUndefined();

    expect(callCount).toBe(2);
    expect(context.warn).toHaveBeenCalledWith(
      expect.stringContaining('Retrying in 0ms')
    );

    requestSpy.mockRestore();
    config.nrMaxRetries = origRetries;
    config.nrRetryInterval = origInterval;
  });
});
