'use strict';

require('../testSetup');

describe('Index - Function Registration', () => {
  it('should export consumer handler', () => {
    const index = require('../VNetFlowForwarder/index');

    expect(index.consumerHandler).toBeDefined();
    expect(typeof index.consumerHandler).toBe('function');
  });
});

describe('Index - Cold-start config validation', () => {
  afterEach(() => {
    jest.restoreAllMocks();
    jest.resetModules();
  });

  it('registers an appStart hook that fails loudly on missing config', () => {
    jest.resetModules();
    const { app } = require('@azure/functions');

    // Capture the appStart handler registered at module load.
    let startHandler;
    jest.spyOn(app.hook, 'appStart').mockImplementation((fn) => {
      startHandler = fn;
    });

    const config = require('../VNetFlowForwarder/config');
    jest.spyOn(config, 'validate').mockImplementation(() => {
      throw new Error('Missing NR_LICENSE_KEY app setting.');
    });
    const errorSpy = jest.spyOn(console, 'error').mockImplementation(() => {});

    require('../VNetFlowForwarder/index');

    expect(typeof startHandler).toBe('function');
    // Cold start must throw (host reports startup failure), not swallow it.
    expect(() => startHandler()).toThrow('Missing NR_LICENSE_KEY');
    // ...and emit a clear, App Insights-visible error.
    expect(errorSpy).toHaveBeenCalledWith(
      expect.stringContaining('cold-start configuration error')
    );
  });

  it('appStart hook is a no-op when config is valid', () => {
    jest.resetModules();
    const { app } = require('@azure/functions');

    let startHandler;
    jest.spyOn(app.hook, 'appStart').mockImplementation((fn) => {
      startHandler = fn;
    });

    const config = require('../VNetFlowForwarder/config');
    jest.spyOn(config, 'validate').mockImplementation(() => {});

    require('../VNetFlowForwarder/index');

    expect(() => startHandler()).not.toThrow();
  });
});
