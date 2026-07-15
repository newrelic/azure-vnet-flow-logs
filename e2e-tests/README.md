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

- The script always attempts teardown via trap on exit, including the flow log created on the Network Watcher (which lives outside the run resource group).
- Resource provisioning is ARM-template based: the forwarder uses the product template `arm/azuredeploy-vnetflowlogsforwarder.json`; the traffic VM and flow log use `e2e-tests/arm/azuredeploy-e2e-traffic.json` and `e2e-tests/arm/azuredeploy-e2e-flowlog.json`.
- The forwarder template exposes no deployment outputs, so the scripts discover the deployed resource names (function app, storage accounts, Event Hub namespace) by listing them in the resource group.
- New Relic validation is scoped to this run's uniquely-named VNet (`virtualNetworkName`), so counts are deterministic and not polluted by unrelated flow-log data.
- If no SSH public key exists at `VM_ADMIN_PUBLIC_KEY_PATH`, an ephemeral throwaway keypair is generated for the traffic VM.

## CI

`.github/workflows/run-e2e-tests.yaml` runs this suite automatically when a pull request is **approved** (`pull_request_review` → `submitted` with `state == approved`), on a monthly schedule, and via manual `workflow_dispatch`. It authenticates to Azure with OIDC (keyless), mirroring how `newrelic/aws-unified-lambda` authenticates to AWS.

Required repository secrets:

- `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` — for OIDC login via `azure/login@v2`
- `NR_LICENSE_KEY`, `NR_QUERY_API_KEY`, `NR_ACCOUNT_ID` — New Relic ingest + query
- `SLACK_WEBHOOK_URL` — failure notifications

One-time Azure setup: create an App Registration (or user-assigned managed identity) with a **federated credential** trusting this repository, and grant it Contributor on the test subscription. No client secret is stored.
