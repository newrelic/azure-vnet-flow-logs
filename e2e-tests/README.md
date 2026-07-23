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

`.github/workflows/run-e2e-tests.yaml` runs this suite automatically when a pull request is **approved** (`pull_request_review` → `submitted` with `state == approved`), on a monthly schedule, and via manual `workflow_dispatch`. It authenticates to Azure with the client secret issued for the `azure-vnet-test` service principal (provisioned via `csi-shared/service-account-permissions` PR #842, credential rotated in Vault at `containers/teams/logging/production/azure-vnet/`). OIDC/federated-credential login was considered (mirroring how `newrelic/aws-unified-lambda` authenticates to AWS) but isn't supported by that provisioning platform for Azure apps, so this uses the secret it actually issues instead.

Required repository secrets:

- `AZURE_CREDENTIALS` — JSON blob (`clientId`, `clientSecret`, `subscriptionId`, `tenantId`) for `azure/login@v2`; that action has no separate `client-secret` input, only a combined `creds` blob
- `AZURE_SUBSCRIPTION_ID` — used by the test script itself, separate from the login step
- `NR_LICENSE_KEY`, `NR_QUERY_API_KEY`, `NR_ACCOUNT_ID` — New Relic ingest + query
- `SLACK_WEBHOOK_URL` — failure notifications
