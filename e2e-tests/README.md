# E2E Tests (Local)

This folder contains end-to-end validation scripts for `azure-vnet-flow-logs`.

## What it does

The main script provisions temporary Azure resources using ARM templates, deploys the function package, generates network traffic, waits for flow-log blobs, validates New Relic ingestion, runs a basic completeness check, and tears down resources.

## Requirements

- `az`, `jq`, `curl`, `uuidgen`, `zip`
- Azure permissions to create and delete resources in the target subscription
- New Relic ingest key and query key

## Required environment variables

- `AZURE_SUBSCRIPTION_ID`
- `NR_LICENSE_KEY`
- `NR_QUERY_API_KEY`
- `NR_ACCOUNT_ID`

Optional variables are defined in `common-scripts/test-configs.cfg`.

## Run

```bash
cd azure-vnet-flow-logs
npm run test:e2e
```

or directly:

```bash
./e2e-tests/vnet-flow-log-test.sh
```

## Notes

- The script always attempts teardown via trap on exit.
- Resource provisioning is ARM-template based (`armTemplates/azuredeploy-vnetflowlogsforwarder.json`, `e2e-tests/arm/azuredeploy-e2e-traffic.json`, and `e2e-tests/arm/azuredeploy-e2e-flowlog.json`).
- This is local e2e code only (no CI workflow files added).
