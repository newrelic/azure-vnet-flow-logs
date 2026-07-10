'use strict';

require('../testSetup');

describe('Index - Function Registration', () => {
  it('should export consumer handler', () => {
    const index = require('../VNetFlowForwarder/index');

    expect(index.consumerHandler).toBeDefined();
    expect(typeof index.consumerHandler).toBe('function');
  });
});
