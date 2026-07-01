'use strict';

require('../testSetup');

const parser = require('../VNetFlowForwarder/parser');
const cursor = require('../VNetFlowForwarder/cursor');
const delta = require('../VNetFlowForwarder/delta');
const nrClient = require('../VNetFlowForwarder/nr-client');
const config = require('../VNetFlowForwarder/config');
const logForwarder = require('../VNetFlowForwarder/log-forwarder');

describe('Log Forwarder', () => {
  const mockContext = {
    log: jest.fn(),
    warn: jest.fn(),
    error: jest.fn(),
  };

  beforeEach(() => {
    jest.clearAllMocks();
  });

  describe('consumerHandler', () => {
    it('should process single event successfully', async () => {
      const mockMessage = {
        subject:
          '/blobServices/default/containers/test/blobs/resource/PT1H.json',
      };

      jest
        .spyOn(cursor, 'getCursor')
        .mockResolvedValue({ lastBlockId: '', failureCount: 0 });
      jest
        .spyOn(delta, 'parseBlobPath')
        .mockReturnValue({ containerName: 'test', blobName: 'blob.json' });
      jest
        .spyOn(delta, 'downloadDelta')
        .mockResolvedValue({ data: '{"records":[]}', lastBlockId: 'block-1' });
      jest.spyOn(parser, 'parseRawDelta').mockReturnValue([{ record: 'data' }]);
      jest.spyOn(parser, 'extractMetadataFromPath').mockReturnValue({});
      jest.spyOn(parser, 'transformRecords').mockReturnValue({
        logEntries: [{ message: 'log' }],
        fallbackCount: 0,
      });
      jest.spyOn(nrClient, 'sendToNewRelic').mockResolvedValue();
      jest.spyOn(cursor, 'setCursor').mockResolvedValue();

      await logForwarder.consumerHandler(mockMessage, mockContext);

      expect(mockContext.log).toHaveBeenCalledWith(
        expect.stringContaining('1 processed')
      );
    });

    it('warns when tuples used a timestamp fallback', async () => {
      const mockMessage = {
        subject:
          '/blobServices/default/containers/test/blobs/resource/PT1H.json',
      };

      jest
        .spyOn(cursor, 'getCursor')
        .mockResolvedValue({ lastBlockId: '', failureCount: 0 });
      jest
        .spyOn(delta, 'parseBlobPath')
        .mockReturnValue({ containerName: 'test', blobName: 'blob.json' });
      jest
        .spyOn(delta, 'downloadDelta')
        .mockResolvedValue({ data: '{"records":[]}', lastBlockId: 'block-1' });
      jest.spyOn(parser, 'parseRawDelta').mockReturnValue([{ record: 'data' }]);
      jest.spyOn(parser, 'extractMetadataFromPath').mockReturnValue({});
      jest.spyOn(parser, 'transformRecords').mockReturnValue({
        logEntries: [{ message: 'log' }],
        fallbackCount: 3,
      });
      jest.spyOn(nrClient, 'sendToNewRelic').mockResolvedValue();
      jest.spyOn(cursor, 'setCursor').mockResolvedValue();

      await logForwarder.consumerHandler(mockMessage, mockContext);

      expect(mockContext.warn).toHaveBeenCalledWith(
        expect.stringContaining('3 flow tuples had invalid timestamps')
      );
    });

    it('does not warn when there are no timestamp fallbacks', async () => {
      const mockMessage = {
        subject:
          '/blobServices/default/containers/test/blobs/resource/PT1H.json',
      };

      jest
        .spyOn(cursor, 'getCursor')
        .mockResolvedValue({ lastBlockId: '', failureCount: 0 });
      jest
        .spyOn(delta, 'parseBlobPath')
        .mockReturnValue({ containerName: 'test', blobName: 'blob.json' });
      jest
        .spyOn(delta, 'downloadDelta')
        .mockResolvedValue({ data: '{"records":[]}', lastBlockId: 'block-1' });
      jest.spyOn(parser, 'parseRawDelta').mockReturnValue([{ record: 'data' }]);
      jest.spyOn(parser, 'extractMetadataFromPath').mockReturnValue({});
      jest.spyOn(parser, 'transformRecords').mockReturnValue({
        logEntries: [{ message: 'log' }],
        fallbackCount: 0,
      });
      jest.spyOn(nrClient, 'sendToNewRelic').mockResolvedValue();
      jest.spyOn(cursor, 'setCursor').mockResolvedValue();

      await logForwarder.consumerHandler(mockMessage, mockContext);

      expect(mockContext.warn).not.toHaveBeenCalledWith(
        expect.stringContaining('invalid timestamps')
      );
    });

    it('should process batch of events', async () => {
      const mockMessages = [
        { subject: '/blob1.json' },
        { subject: '/blob2.json' },
        { subject: '/blob3.json' },
      ];

      jest
        .spyOn(cursor, 'getCursor')
        .mockResolvedValue({ lastBlockId: '', failureCount: 0 });
      jest
        .spyOn(delta, 'parseBlobPath')
        .mockReturnValue({ containerName: 'test', blobName: 'blob.json' });
      jest
        .spyOn(delta, 'downloadDelta')
        .mockResolvedValue({ data: '{"records":[]}', lastBlockId: 'block-1' });
      jest.spyOn(parser, 'parseRawDelta').mockReturnValue([{ record: 'data' }]);
      jest.spyOn(parser, 'extractMetadataFromPath').mockReturnValue({});
      jest.spyOn(parser, 'transformRecords').mockReturnValue({
        logEntries: [{ message: 'log' }],
        fallbackCount: 0,
      });
      jest.spyOn(nrClient, 'sendToNewRelic').mockResolvedValue();
      jest.spyOn(cursor, 'setCursor').mockResolvedValue();

      await logForwarder.consumerHandler(mockMessages, mockContext);

      expect(mockContext.log).toHaveBeenCalledWith(
        expect.stringContaining('3 processed')
      );
    });

    it('should process all events in an array-wrapped Event Grid message', async () => {
      const wrappedMessage = [
        { subject: '/blob1.json' },
        { subject: '/blob2.json' },
      ];

      jest.spyOn(cursor, 'getCursor').mockResolvedValue({
        lastBlockId: '',
        failureCount: 0,
      });
      jest.spyOn(delta, 'parseBlobPath').mockReturnValue({
        containerName: 'test',
        blobName: 'blob.json',
      });
      jest.spyOn(delta, 'downloadDelta').mockResolvedValue({
        data: '{"records":[]}',
        lastBlockId: 'block-1',
      });
      jest.spyOn(parser, 'parseRawDelta').mockReturnValue([{ record: 'data' }]);
      jest.spyOn(parser, 'extractMetadataFromPath').mockReturnValue({});
      jest.spyOn(parser, 'transformRecords').mockReturnValue({
        logEntries: [{ message: 'log' }],
        fallbackCount: 0,
      });
      jest.spyOn(nrClient, 'sendToNewRelic').mockResolvedValue();
      jest.spyOn(cursor, 'setCursor').mockResolvedValue();

      await logForwarder.consumerHandler([wrappedMessage], mockContext);

      expect(mockContext.log).toHaveBeenCalledWith(
        expect.stringContaining('2 processed')
      );
    });

    it('should handle errors and increment failure counter', async () => {
      const mockMessage = {
        subject: '/blob-error.json',
      };

      jest.spyOn(delta, 'parseBlobPath').mockImplementation(() => {
        throw new Error('Processing failed');
      });
      jest.spyOn(cursor, 'getCursor').mockResolvedValue({
        lastBlockId: 'block-1',
        failureCount: 1,
      });
      jest.spyOn(cursor, 'incrementFailure').mockResolvedValue();

      await logForwarder.consumerHandler(mockMessage, mockContext);

      expect(mockContext.error).toHaveBeenCalledWith(
        expect.stringContaining('Processing failed')
      );
      expect(cursor.incrementFailure).toHaveBeenCalled();
    });

    it('should count skipped events', async () => {
      jest.spyOn(cursor, 'getCursor').mockResolvedValue({
        lastBlockId: '',
        failureCount: config.maxConsecutiveFailures,
      });
      jest
        .spyOn(delta, 'parseBlobPath')
        .mockReturnValue({ containerName: 'test', blobName: 'blob.json' });

      await logForwarder.consumerHandler(
        { subject: '/blob.json' },
        mockContext
      );

      expect(mockContext.log).toHaveBeenCalledWith(
        expect.stringContaining('1 skipped')
      );
    });
  });

  it('should not export internal processing helpers', () => {
    expect(logForwarder.processEvent).toBeUndefined();
  });
});
