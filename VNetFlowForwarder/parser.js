'use strict';

/**
 * VNet Flow Logs Forwarder — Flow Log Parser
 *
 * Parses PT1H.json delta fragments into structured log records
 * suitable for New Relic ingestion.
 *
 * PT1H.json structure (VNet Flow Logs v2):
 * {
 *   "records": [
 *     {
 *       "time": "2024-01-01T00:00:00.0000000Z",
 *       "flowLogVersion": 4,
 *       "flowLogGUID": "...",
 *       "macAddress": "...",
 *       "category": "FlowLogFlowEvent",
 *       "flowLogResourceID": "/subscriptions/.../...",
 *       "targetResourceID": "/subscriptions/.../...",
 *       "operationName": "FlowLogFlowEvent",
 *       "flowRecords": {
 *         "flows": [
 *           {
 *             "aclID": "...",
 *             "flowGroups": [
 *               {
 *                 "rule": "...",
 *                 "flowTuples": [
 *                   "1699990055,10.0.0.4,10.0.0.5,12345,443,6,O,A,C,1,100,1,80"
 *                 ]
 *               }
 *             ]
 *           }
 *         ]
 *       }
 *     }
 *   ]
 * }
 *
 * Flow Tuple CSV format (VNet Flow Logs):
 *   0: Timestamp. VNet Flow Logs (v4) emit Unix epoch MILLISECONDS (13-digit);
 *      legacy NSG flow logs emit Unix epoch SECONDS (10-digit). See parseFlowTuple.
 *   1: Source IP
 *   2: Destination IP
 *   3: Source Port
 *   4: Destination Port
 *   5: Protocol (6=TCP, 17=UDP, 1=ICMP)
 *   6: Direction (I=Inbound, O=Outbound)
 *   7: Action (A=Allowed, D=Denied)
 *   8: State (B=Begin, C=Continuing, E=End)
 *   9: Packets (source to destination)
 *   10: Bytes (source to destination)
 *   11: Packets (destination to source)
 *   12: Bytes (destination to source)
 */

const config = require('./config');

const PROTOCOL_MAP = {
  6: 'TCP',
  17: 'UDP',
  1: 'ICMP',
};

const DIRECTION_MAP = {
  I: 'Inbound',
  O: 'Outbound',
};

const ACTION_MAP = {
  A: 'Allowed',
  D: 'Denied',
};

const STATE_MAP = {
  B: 'Begin',
  C: 'Continuing',
  E: 'End',
};

// Boundary used to tell epoch-seconds timestamps from epoch-milliseconds ones.
// 1e11 (~year 5138 in seconds, ~Mar 1973 in ms) sits safely between any
// realistic 10-digit seconds value and 13-digit milliseconds value: anything
// below it is treated as seconds and promoted to ms; anything above is ms.
const EPOCH_MS_THRESHOLD = 1e11;

/**
 * Parse a raw delta string from the PT1H.json blob into an array of records.
 *
 * The delta is a JSON fragment — it may start/end mid-array. We handle:
 * - Complete JSON (first block set)
 * - Fragment starting with comma + records (appended blocks)
 * - Fragment with trailing comma or incomplete trailing record
 *
 * @param {string} rawDelta - Raw text downloaded from delta blocks
 * @returns {Array<Object>} Parsed record objects from the "records" array
 */
function parseRawDelta(rawDelta) {
  if (!rawDelta || rawDelta.trim().length === 0) {
    return [];
  }

  let text = rawDelta.trim();

  // Strategy 1: Try parsing as complete JSON
  try {
    const parsed = JSON.parse(text);
    if (parsed.records && Array.isArray(parsed.records)) {
      return parsed.records;
    }
    if (Array.isArray(parsed)) {
      return parsed;
    }
    return [parsed];
  } catch {
    // Not complete JSON — handle as fragment
  }

  // Strategy 2: Fragment from appended blocks
  // The delta often looks like: ,{"time":"...","flowRecords":{...}}\n]}\n
  // or: ,{"time":"..."},{"time":"..."}
  // Strip leading/trailing structural chars and wrap as array

  // Remove leading comma if present
  if (text.startsWith(',')) {
    text = text.slice(1);
  }

  // Remove trailing incomplete structures
  // If ends with "]}" it's the file close — strip it
  if (text.endsWith(']}')) {
    text = text.slice(0, -2);
  } else if (text.endsWith(']\n}')) {
    text = text.slice(0, -3);
  } else if (text.endsWith(']\r\n}')) {
    text = text.slice(0, -4);
  }

  // Trim trailing commas
  text = text.replace(/,\s*$/, '');

  // Wrap in array and parse
  try {
    const records = JSON.parse(`[${text}]`);
    return records;
  } catch {
    // Strategy 3: Try to salvage line by line
    return parseLineByLine(text);
  }
}

/**
 * Fallback: parse individual JSON objects separated by commas/newlines.
 */
function parseLineByLine(text) {
  const records = [];
  // Split on },{ boundaries
  const parts = text.split(/\}\s*,\s*\{/);
  for (let i = 0; i < parts.length; i++) {
    let part = parts[i];
    if (i > 0) part = '{' + part;
    if (i < parts.length - 1) part = part + '}';
    try {
      records.push(JSON.parse(part));
    } catch {
      // Skip unparseable fragments
    }
  }
  return records;
}

/**
 * Extract metadata from a blob path.
 *
 * Supports two path formats:
 *
 * 1. NSG flow logs:
 *    resourceId=/SUBSCRIPTIONS/{sub}/RESOURCEGROUPS/{rg}/PROVIDERS/
 *    MICROSOFT.NETWORK/NETWORKSECURITYGROUPS/{name}/y=2024/m=01/d=15/h=10/
 *    m=00/macAddress={mac}/PT1H.json
 *
 * 2. VNet flow logs:
 *    flowLogResourceID=/{SUB}_{RG}/{NETWORKWATCHER_REGION_FLOWLOGNAME}/
 *    y=2026/m=06/d=09/h=07/m=00/macAddress={mac}/PT1H.json
 *
 * @param {string} blobPath - The blob name within the container
 * @returns {Object} Extracted metadata
 */
function extractMetadataFromPath(blobPath) {
  const metadata = {};
  const lower = blobPath.toLowerCase();

  // Extract subscription ID
  const subMatch = lower.match(/subscriptions\/([^/]+)/);
  if (subMatch) metadata.subscriptionId = subMatch[1];

  // Extract resource group
  const rgMatch = lower.match(/resourcegroups\/([^/]+)/);
  if (rgMatch) metadata.resourceGroup = rgMatch[1];

  // Extract resource type and name (e.g., virtualNetworks/myVnet or networkSecurityGroups/myNsg)
  const providerMatch = blobPath.match(
    /PROVIDERS\/MICROSOFT\.NETWORK\/([^/]+)\/([^/]+)/i
  );
  if (providerMatch) {
    metadata.resourceType = providerMatch[1];
    metadata.resourceName = providerMatch[2];
  }

  // VNet flow log path format: flowLogResourceID=/{SUB}_{RG}/{NETWORKWATCHER_REGION_NAME}/...
  // Guard against ReDoS by only processing reasonably-sized paths and bounding repetitions
  if (!metadata.subscriptionId || !metadata.resourceGroup) {
    if (blobPath.length < 2048) {
      const vnetFlowMatch = blobPath.match(
        /flowLogResourceID=\/([^_/]{1,64})_([^/]{1,128})\/([^/]{1,256})/i
      );
      if (vnetFlowMatch) {
        if (!metadata.subscriptionId) {
          metadata.subscriptionId = vnetFlowMatch[1].toLowerCase();
        }
        if (!metadata.resourceGroup) {
          metadata.resourceGroup = vnetFlowMatch[2].toLowerCase();
        }
      }
    }
  }

  // Extract MAC address
  const macMatch = blobPath.match(/macAddress=([^/]+)/i);
  if (macMatch) metadata.macAddress = macMatch[1];

  // Extract date-hour
  const dateMatch = blobPath.match(
    /y=(\d{4})\/m=(\d{2})\/d=(\d{2})\/h=(\d{2})/
  );
  if (dateMatch) {
    metadata.year = dateMatch[1];
    metadata.month = dateMatch[2];
    metadata.day = dateMatch[3];
    metadata.hour = dateMatch[4];
  }

  return metadata;
}

/**
 * Parse a single flow tuple CSV string into a structured object.
 *
 * @param {string} tuple - CSV string
 * @returns {Object} Structured flow record
 */
function parseFlowTuple(tuple) {
  const fields = tuple.split(',');
  const ts = parseInt(fields[0], 10);
  const timestampParseFallback = Number.isNaN(ts);
  // New Relic expects `timestamp` in epoch milliseconds. VNet Flow Logs (v4)
  // already emit epoch ms (13-digit, e.g. 1782658803422); legacy NSG flow logs
  // emit epoch seconds (10-digit). Promote seconds->ms; leave ms untouched.
  const record = {
    timestamp: timestampParseFallback
      ? Date.now()
      : ts < EPOCH_MS_THRESHOLD
      ? ts * 1000
      : ts,
    srcAddr: fields[1] || '',
    destAddr: fields[2] || '',
    srcPort: parseInt(fields[3], 10) || 0,
    destPort: parseInt(fields[4], 10) || 0,
    protocol: PROTOCOL_MAP[fields[5]] || fields[5] || '',
    direction: DIRECTION_MAP[fields[6]] || fields[6] || '',
    action: ACTION_MAP[fields[7]] || fields[7] || '',
    state: STATE_MAP[fields[8]] || fields[8] || '',
  };

  // Packet/byte counts (may not be present in all versions)
  if (fields[9]) record.packetsSrcToDest = parseInt(fields[9], 10) || 0;
  if (fields[10]) record.bytesSrcToDest = parseInt(fields[10], 10) || 0;
  if (fields[11]) record.packetsDestToSrc = parseInt(fields[11], 10) || 0;
  if (fields[12]) record.bytesDestToSrc = parseInt(fields[12], 10) || 0;

  return record;
}

/**
 * Parse Azure network target resource context from targetResourceID.
 *
 * Example IDs:
 * - /subscriptions/.../providers/Microsoft.Network/virtualNetworks/{vnet}
 * - /subscriptions/.../providers/Microsoft.Network/virtualNetworks/{vnet}/subnets/{subnet}
 * - /subscriptions/.../providers/Microsoft.Network/networkInterfaces/{nic}
 *
 * @param {string} targetResourceID - Azure target resource ID
 * @returns {Object} Parsed resource context
 */
function parseTargetResourceContext(targetResourceID) {
  if (!targetResourceID || typeof targetResourceID !== 'string') {
    return {};
  }

  const match = targetResourceID.match(/providers\/Microsoft\.Network\/(.+)$/i);
  if (!match || !match[1]) {
    return {};
  }

  const segments = match[1].split('/').filter(Boolean);
  if (segments.length < 2) {
    return {};
  }

  const typeParts = [];
  const nameByType = {};

  for (let i = 0; i + 1 < segments.length; i += 2) {
    const typePart = segments[i];
    const namePart = segments[i + 1];

    typeParts.push(typePart.toLowerCase());
    nameByType[typePart.toLowerCase()] = namePart;
  }

  const context = {
    targetResourceType: typeParts.join('/'),
  };

  if (nameByType.virtualnetworks) {
    context.virtualNetworkName = nameByType.virtualnetworks;
  }
  if (nameByType.subnets) {
    context.subnetName = nameByType.subnets;
  }
  if (nameByType.networkinterfaces) {
    context.networkInterfaceName = nameByType.networkinterfaces;
  }

  return context;
}

/**
 * Transform parsed PT1H.json records into New Relic log entries.
 *
 * @param {Array<Object>} records - Parsed JSON records from PT1H.json
 * @param {Object} pathMetadata - Metadata extracted from blob path
 * @returns {Array<Object>} Array of NR log entry objects
 */
function transformRecords(records, pathMetadata) {
  const logEntries = [];

  for (const record of records) {
    // Use targetResourceID from record to fill missing path metadata
    // targetResourceID represents the actual VNet resource, so prefer it over
    // blob path metadata (which may point to NetworkWatcherRG instead of the VNet's RG)
    const enriched = { ...pathMetadata };
    if (record.targetResourceID) {
      const targetContext = parseTargetResourceContext(record.targetResourceID);

      const targetMatch = record.targetResourceID.match(
        /providers\/Microsoft\.Network\/([^/]+)\/([^/]+)/i
      );
      if (targetMatch) {
        if (!enriched.resourceType) enriched.resourceType = targetMatch[1];
        if (!enriched.resourceName) enriched.resourceName = targetMatch[2];
      }
      // Always prefer targetResourceID for subscriptionId and resourceGroup
      // since the blob path may reference the NetworkWatcher RG, not the VNet's RG
      const subMatch = record.targetResourceID.match(/subscriptions\/([^/]+)/i);
      if (subMatch) enriched.subscriptionId = subMatch[1].toLowerCase();
      const rgMatch = record.targetResourceID.match(/resourceGroups\/([^/]+)/i);
      if (rgMatch) enriched.resourceGroup = rgMatch[1];

      if (targetContext.virtualNetworkName) {
        enriched.virtualNetworkName = targetContext.virtualNetworkName;
      }
      if (targetContext.subnetName) {
        enriched.subnetName = targetContext.subnetName;
      }
      if (targetContext.networkInterfaceName) {
        enriched.networkInterfaceName = targetContext.networkInterfaceName;
      }
      if (targetContext.targetResourceType) {
        enriched.targetResourceType = targetContext.targetResourceType;
      }
    }

    const baseAttrs = {
      subscriptionId: enriched.subscriptionId || '',
      resourceGroup: enriched.resourceGroup || '',
      resourceType: enriched.resourceType || '',
      resourceName: enriched.resourceName || '',
      macAddress: pathMetadata.macAddress || record.macAddress || '',
      category: record.category || 'FlowLogFlowEvent',
      operationName: record.operationName || '',
      flowLogVersion: record.flowLogVersion || '',
      flowLogGUID: record.flowLogGUID || '',
      flowLogResourceID: record.flowLogResourceID || '',
      targetResourceID: record.targetResourceID || '',
      targetResourceType: enriched.targetResourceType || '',
      virtualNetworkName: enriched.virtualNetworkName || '',
      subnetName: enriched.subnetName || '',
      networkInterfaceName: enriched.networkInterfaceName || '',
    };

    // Extract flow tuples from nested structure
    const flowRecords = record.flowRecords || {};
    const flows = flowRecords.flows || [];
    let recordHasTuples = false;

    for (const flow of flows) {
      const aclID = flow.aclID || '';
      const flowGroups = flow.flowGroups || [];

      for (const group of flowGroups) {
        const rule = group.rule || '';
        const tuples = group.flowTuples || [];

        for (const tuple of tuples) {
          recordHasTuples = true;
          const parsed = parseFlowTuple(tuple);
          logEntries.push({
            timestamp: parsed.timestamp,
            message: tuple,
            attributes: {
              ...baseAttrs,
              aclID,
              rule,
              srcAddr: parsed.srcAddr,
              destAddr: parsed.destAddr,
              srcPort: parsed.srcPort,
              destPort: parsed.destPort,
              protocol: parsed.protocol,
              direction: parsed.direction,
              action: parsed.action,
              state: parsed.state,
              packetsSrcToDest: parsed.packetsSrcToDest,
              bytesSrcToDest: parsed.bytesSrcToDest,
              packetsDestToSrc: parsed.packetsDestToSrc,
              bytesDestToSrc: parsed.bytesDestToSrc,
            },
          });
        }
      }
    }

    // If no flow tuples found for this record, still emit it as a log entry
    if (!recordHasTuples && record.time) {
      logEntries.push({
        timestamp: Date.parse(record.time),
        message: JSON.stringify(record),
        attributes: baseAttrs,
      });
    }
  }

  return logEntries;
}

module.exports = {
  parseRawDelta,
  extractMetadataFromPath,
  parseFlowTuple,
  transformRecords,
  PROTOCOL_MAP,
  DIRECTION_MAP,
  ACTION_MAP,
  STATE_MAP,
  parseTargetResourceContext,
};
