'use strict';

require('../testSetup');

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
});
