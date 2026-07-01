'use strict';

require('../testSetup');

const parser = require('../VNetFlowForwarder/parser');

describe('Parser', () => {
  describe('parseFlowTuple', () => {
    it('should parse a complete flow tuple CSV', () => {
      // Real VNet Flow Logs v4 tuple: field 7 = flow state, field 8 = encryption.
      const tuple =
        '1699990055,10.0.0.4,10.0.0.5,12345,443,6,O,C,NX,10,1500,8,1200';
      const result = parser.parseFlowTuple(tuple);

      expect(result.timestamp).toBe(1699990055000);
      expect(result.srcAddr).toBe('10.0.0.4');
      expect(result.destAddr).toBe('10.0.0.5');
      expect(result.srcPort).toBe(12345);
      expect(result.destPort).toBe(443);
      expect(result.protocol).toBe('TCP');
      expect(result.direction).toBe('Outbound');
      expect(result.flowState).toBe('Continuing');
      expect(result.encryption).toBe('Not Encrypted');
      expect(result.packetsSrcToDest).toBe(10);
      expect(result.bytesSrcToDest).toBe(1500);
      expect(result.packetsDestToSrc).toBe(8);
      expect(result.bytesDestToSrc).toBe(1200);
    });

    it('should map a denied flow state and encrypted flow', () => {
      // VNet flow logs express a blocked flow as flow state "D" (Deny).
      const tuple = '1699990100,192.168.1.1,10.0.0.1,8080,53,17,I,D,X,1,64,0,0';
      const result = parser.parseFlowTuple(tuple);

      expect(result.protocol).toBe('UDP');
      expect(result.direction).toBe('Inbound');
      expect(result.flowState).toBe('Deny');
      expect(result.encryption).toBe('Encrypted');
    });

    it('should pass through an unmapped NX_* encryption reason code', () => {
      const tuple =
        '1699990055,10.0.0.4,10.0.0.5,12345,443,6,O,B,NX_HW_NOT_SUPPORTED,1,64,0,0';
      const result = parser.parseFlowTuple(tuple);

      expect(result.flowState).toBe('Begin');
      expect(result.encryption).toBe('NX_HW_NOT_SUPPORTED');
    });

    it('should handle tuple with missing optional fields', () => {
      const tuple = '1699990055,10.0.0.4,10.0.0.5,12345,443,6,O,E,NX';
      const result = parser.parseFlowTuple(tuple);

      expect(result.timestamp).toBe(1699990055000);
      expect(result.flowState).toBe('End');
      expect(result.encryption).toBe('Not Encrypted');
      expect(result.packetsSrcToDest).toBeUndefined();
    });

    it('should fall back to ingest time when the tuple timestamp is invalid', () => {
      const nowSpy = jest.spyOn(Date, 'now').mockReturnValue(1700000000000);
      const tuple = 'not-a-timestamp,10.0.0.4,10.0.0.5,12345,443,6,O,E,NX';
      const result = parser.parseFlowTuple(tuple);

      expect(result.timestamp).toBe(1700000000000);

      nowSpy.mockRestore();
    });

    it('should keep a VNet v4 millisecond timestamp (13-digit) as-is', () => {
      // Real VNet Flow Logs v4 tuples carry epoch milliseconds.
      const tuple =
        '1782658803422,10.0.0.4,10.0.0.5,12345,443,6,O,C,NX,1,64,1,64';
      const result = parser.parseFlowTuple(tuple);

      expect(result.timestamp).toBe(1782658803422);
    });

    it('should promote a legacy NSG second timestamp (10-digit) to ms', () => {
      // Legacy NSG flow logs carry epoch seconds; must be promoted to ms.
      const tuple = '1699990055,10.0.0.4,10.0.0.5,12345,443,6,O,C,NX';
      const result = parser.parseFlowTuple(tuple);

      expect(result.timestamp).toBe(1699990055000);
    });
  });

  describe('parseRawDelta', () => {
    it('should parse complete PT1H.json', () => {
      const json = JSON.stringify({
        records: [
          {
            time: '2024-01-01T00:00:00Z',
            macAddress: 'AABBCCDDEEFF',
            category: 'FlowLogFlowEvent',
            flowLogVersion: 4,
            flowLogGUID: 'guid-123',
            flowLogResourceID: '/sub/rg/provider/res',
            targetResourceID: '/sub/rg/provider/target',
            operationName: 'FlowLogFlowEvent',
            flowRecords: {
              flows: [
                {
                  aclID: 'acl-1',
                  flowGroups: [
                    {
                      rule: 'DefaultRule_AllowAll',
                      flowTuples: [
                        '1699990055,10.0.0.4,10.0.0.5,12345,443,6,O,C,NX,10,1500,8,1200',
                      ],
                    },
                  ],
                },
              ],
            },
          },
        ],
      });
      const result = parser.parseRawDelta(json);
      expect(result).toHaveLength(1);
      expect(result[0].macAddress).toBe('AABBCCDDEEFF');
      expect(result[0].category).toBe('FlowLogFlowEvent');
      expect(result[0].flowLogVersion).toBe(4);
      expect(result[0].flowRecords.flows).toHaveLength(1);
      expect(
        result[0].flowRecords.flows[0].flowGroups[0].flowTuples
      ).toHaveLength(1);
    });

    it('should parse a JSON fragment (appended blocks)', () => {
      const fragment =
        ',{"time":"2024-01-01T01:00:00Z","macAddress":"112233445566","flowRecords":{"flows":[]}}]}';
      const result = parser.parseRawDelta(fragment);
      expect(result).toHaveLength(1);
      expect(result[0].macAddress).toBe('112233445566');
    });

    it('should parse multiple records in a fragment', () => {
      const fragment =
        ',{"time":"T1","macAddress":"AA"},{"time":"T2","macAddress":"BB"}]}';
      const result = parser.parseRawDelta(fragment);
      expect(result).toHaveLength(2);
      expect(result[0].macAddress).toBe('AA');
      expect(result[1].macAddress).toBe('BB');
    });

    it('should return empty array for empty input', () => {
      expect(parser.parseRawDelta('')).toEqual([]);
      expect(parser.parseRawDelta(null)).toEqual([]);
      expect(parser.parseRawDelta('   ')).toEqual([]);
    });

    it('should handle array input', () => {
      const json = JSON.stringify([{ time: 'T1' }, { time: 'T2' }]);
      const result = parser.parseRawDelta(json);
      expect(result).toHaveLength(2);
    });
  });

  describe('extractMetadataFromPath', () => {
    it('should extract all metadata from a VNet flow log path', () => {
      const path =
        'resourceId=/SUBSCRIPTIONS/sub-123/RESOURCEGROUPS/rg-prod/PROVIDERS/MICROSOFT.NETWORK/VIRTUALNETWORKS/myVnet/y=2024/m=03/d=15/h=10/m=00/macAddress=AABBCCDDEEFF/PT1H.json';
      const meta = parser.extractMetadataFromPath(path);

      expect(meta.subscriptionId).toBe('sub-123');
      expect(meta.resourceGroup).toBe('rg-prod');
      expect(meta.resourceType).toBe('VIRTUALNETWORKS');
      expect(meta.resourceName).toBe('myVnet');
      expect(meta.macAddress).toBe('AABBCCDDEEFF');
      expect(meta.year).toBe('2024');
      expect(meta.month).toBe('03');
      expect(meta.day).toBe('15');
      expect(meta.hour).toBe('10');
    });

    it('should handle NSG flow log path', () => {
      const path =
        'resourceId=/SUBSCRIPTIONS/abc/RESOURCEGROUPS/rg1/PROVIDERS/MICROSOFT.NETWORK/NETWORKSECURITYGROUPS/myNsg/y=2024/m=01/d=01/h=00/m=00/macAddress=001122334455/PT1H.json';
      const meta = parser.extractMetadataFromPath(path);

      expect(meta.resourceType).toBe('NETWORKSECURITYGROUPS');
      expect(meta.resourceName).toBe('myNsg');
    });

    it('should extract subscription and resource group from VNet flowLogResourceID format', () => {
      const path =
        'flowLogResourceID=/9C99D7C5-7653-4B53-AE61-DAEFF13D8569_BPAVAN-E2E-VNETFLOW-STAGING-BATCH1/NETWORKWATCHER_CENTRALINDIA_FLOWLOG/y=2024/m=01/d=01/h=00/m=00/macAddress=001122334455/PT1H.json';
      const meta = parser.extractMetadataFromPath(path);

      expect(meta.subscriptionId).toBe('9c99d7c5-7653-4b53-ae61-daeff13d8569');
      expect(meta.resourceGroup).toBe('bpavan-e2e-vnetflow-staging-batch1');
      expect(meta.macAddress).toBe('001122334455');
    });

    it('should handle partial paths gracefully', () => {
      const meta = parser.extractMetadataFromPath('some/random/path.json');
      expect(meta.subscriptionId).toBeUndefined();
      expect(meta.macAddress).toBeUndefined();
    });
  });

  describe('parseTargetResourceContext', () => {
    it('should parse VNet target resource context', () => {
      const context = parser.parseTargetResourceContext(
        '/subscriptions/sub-123/resourceGroups/rg-prod/providers/Microsoft.Network/virtualNetworks/my-vnet'
      );

      expect(context.targetResourceType).toBe('virtualnetworks');
      expect(context.virtualNetworkName).toBe('my-vnet');
      expect(context.subnetName).toBeUndefined();
    });

    it('should parse subnet target resource context', () => {
      const context = parser.parseTargetResourceContext(
        '/subscriptions/sub-123/resourceGroups/rg-prod/providers/Microsoft.Network/virtualNetworks/my-vnet/subnets/my-subnet'
      );

      expect(context.targetResourceType).toBe('virtualnetworks/subnets');
      expect(context.virtualNetworkName).toBe('my-vnet');
      expect(context.subnetName).toBe('my-subnet');
    });
  });

  describe('transformRecords', () => {
    it('should transform records with flow tuples into log entries', () => {
      const records = [
        {
          time: '2024-01-01T00:00:00Z',
          macAddress: 'AABBCCDDEEFF',
          category: 'FlowLogFlowEvent',
          flowLogVersion: 4,
          flowLogGUID: 'guid-123',
          flowLogResourceID: '/sub/rg/provider/res',
          targetResourceID: '/sub/rg/provider/target',
          operationName: 'FlowLogFlowEvent',
          flowRecords: {
            flows: [
              {
                aclID: 'acl-1',
                flowGroups: [
                  {
                    rule: 'AllowAll',
                    flowTuples: [
                      '1699990055,10.0.0.4,10.0.0.5,12345,443,6,O,C,NX,10,1500,8,1200',
                      '1699990060,10.0.0.4,10.0.0.6,12346,80,6,O,B,X,1,100,0,0',
                    ],
                  },
                ],
              },
            ],
          },
        },
      ];
      const meta = { subscriptionId: 'sub-1', resourceGroup: 'rg-1' };
      const entries = parser.transformRecords(records, meta);

      expect(entries).toHaveLength(2);
      expect(entries[0].timestamp).toBe(1699990055000);
      expect(entries[0].attributes.srcAddr).toBe('10.0.0.4');
      expect(entries[0].attributes.destAddr).toBe('10.0.0.5');
      expect(entries[0].attributes.srcPort).toBe(12345);
      expect(entries[0].attributes.destPort).toBe(443);
      expect(entries[0].attributes.protocol).toBe('TCP');
      expect(entries[0].attributes.direction).toBe('Outbound');
      expect(entries[0].attributes.flowState).toBe('Continuing');
      expect(entries[0].attributes.encryption).toBe('Not Encrypted');
      expect(entries[0].attributes.packetsSrcToDest).toBe(10);
      expect(entries[0].attributes.bytesSrcToDest).toBe(1500);
      expect(entries[0].attributes.packetsDestToSrc).toBe(8);
      expect(entries[0].attributes.bytesDestToSrc).toBe(1200);
      expect(entries[0].attributes.subscriptionId).toBe('sub-1');

      expect(entries[1].timestamp).toBe(1699990060000);
      expect(entries[1].attributes.srcAddr).toBe('10.0.0.4');
      expect(entries[1].attributes.destAddr).toBe('10.0.0.6');
      expect(entries[1].attributes.srcPort).toBe(12346);
      expect(entries[1].attributes.destPort).toBe(80);
      expect(entries[1].attributes.protocol).toBe('TCP');
      expect(entries[1].attributes.direction).toBe('Outbound');
      expect(entries[1].attributes.flowState).toBe('Begin');
      expect(entries[1].attributes.encryption).toBe('Encrypted');
      expect(entries[1].attributes.packetsSrcToDest).toBe(1);
      expect(entries[1].attributes.bytesSrcToDest).toBe(100);
      expect(entries[1].attributes.packetsDestToSrc).toBe(0);
      expect(entries[1].attributes.bytesDestToSrc).toBe(0);
    });

    it('should handle records with no flow tuples', () => {
      const records = [
        {
          time: '2024-01-01T00:00:00Z',
          macAddress: 'AABB',
          flowRecords: { flows: [] },
        },
      ];
      const entries = parser.transformRecords(records, {});
      expect(entries).toHaveLength(1);
      expect(entries[0].timestamp).toBe(Date.parse('2024-01-01T00:00:00Z'));
    });

    it('should enrich entries with VNet and subnet names from targetResourceID', () => {
      const records = [
        {
          time: '2024-01-01T00:00:00Z',
          category: 'FlowLogFlowEvent',
          operationName: 'FlowLogFlowEvent',
          targetResourceID:
            '/subscriptions/sub-123/resourceGroups/rg-prod/providers/Microsoft.Network/virtualNetworks/my-vnet/subnets/my-subnet',
          flowRecords: {
            flows: [
              {
                aclID: 'acl-1',
                flowGroups: [
                  {
                    rule: 'AllowAll',
                    flowTuples: [
                      '1699990055,10.0.0.4,10.0.0.5,12345,443,6,O,C,NX,10,1500,8,1200',
                    ],
                  },
                ],
              },
            ],
          },
        },
      ];

      const entries = parser.transformRecords(records, {});

      expect(entries).toHaveLength(1);
      expect(entries[0].attributes.targetResourceType).toBe(
        'virtualnetworks/subnets'
      );
      expect(entries[0].attributes.virtualNetworkName).toBe('my-vnet');
      expect(entries[0].attributes.subnetName).toBe('my-subnet');
      expect(entries[0].attributes.resourceType).toBe('virtualNetworks');
      expect(entries[0].attributes.resourceName).toBe('my-vnet');
    });
  });
});
