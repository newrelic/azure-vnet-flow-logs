#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/e2e-tests/common-scripts/test-configs.cfg"
source "${ROOT_DIR}/e2e-tests/common-scripts/resource-scripts.sh"
source "${ROOT_DIR}/e2e-tests/common-scripts/stack-scripts.sh"
source "${ROOT_DIR}/e2e-tests/common-scripts/logs-scripts.sh"

cleanup() {
  echo "[main] Cleanup start"
  teardown_with_backoff || true
}
trap cleanup EXIT

main() {
  require_cmds

  echo "[main] Starting e2e run: ${RUN_ID}"
  az account set --subscription "${AZURE_SUBSCRIPTION_ID}"

  create_resource_group
  deploy_forwarder_template
  resolve_network_watcher
  deploy_traffic_template
  deploy_flowlog_template
  build_and_deploy_package
  verify_eventgrid_subscription

  local marker vm_ip vm_private_ip blob_name
  marker=$(generate_traffic)
  vm_ip=$(get_vm_ip)
  vm_private_ip=$(get_vm_private_ip)
  echo "[main] Traffic marker: ${marker}; VM public IP: ${vm_ip}; VM private IP: ${vm_private_ip}"

  blob_name=$(wait_for_blob)
  echo "[main] First flow log blob: ${blob_name}"

  download_blob "${blob_name}"

  # Identity filter matches the attributes the forwarder actually emits
  # (VNetFlowForwarder/nr-client.js), scoped to this run's uniquely-named VNet
  # (emitted per-record as virtualNetworkName by VNetFlowForwarder/parser.js) so
  # counts cannot be polluted by unrelated flow-log data in the same account.
  local nr_scope
  nr_scope="instrumentation.provider = 'azure' AND instrumentation.name = 'vnet-app' AND virtualNetworkName = '${VNET_NAME}'"
  local nr_vm_scope
  nr_vm_scope="${nr_scope} AND (srcAddr = '${vm_private_ip}' OR destAddr = '${vm_private_ip}')"

  # Some NR accounts route this log type into a custom event type via a data
  # partition rule (confirmed on a real run: records landed in
  # Log_VNET_Flows_Azure, not Log), so query both - harmless if one has no data.
  local nrql_records
  nrql_records="SELECT * FROM Log, Log_VNET_Flows_Azure WHERE ${nr_scope} SINCE 30 minutes ago LIMIT 50"
  wait_for_nr_logs "${nrql_records}"
  assert_required_attributes "${NR_RESULTS_FILE}"

  local nrql_count
  nrql_count="SELECT count(*) as count FROM Log, Log_VNET_Flows_Azure WHERE ${nr_scope} SINCE 30 minutes ago"
  compare_blob_and_nr_counts "${nrql_count}" || {
    echo "[main] Completeness check failed"
    exit 1
  }

  # Give the first round a drain window before starting the second-round
  # verification window, so the new baseline is less likely to miss late-arriving
  # records from the first round and then misattribute them to the second. A
  # flat 5s isn't enough - measured real delivery latency for this pipeline is
  # on the order of minutes, so reuse NR_INGESTION_WARMUP as the drain length.
  echo "[main] Waiting ${NR_INGESTION_WARMUP}s before taking the second-round baseline"
  sleep "${NR_INGESTION_WARMUP}"

  local second_round_start
  second_round_start=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local nrql_second_round_count
  nrql_second_round_count="SELECT count(*) as count FROM Log, Log_VNET_Flows_Azure WHERE ${nr_vm_scope} SINCE '${second_round_start}'"
  local second_round_baseline
  second_round_baseline=$(nr_count_for "${nrql_second_round_count}")
  echo "[main] Baseline NR count for VM-scoped logs since ${second_round_start}: ${second_round_baseline}"

  echo "[main] Generating second round of traffic to verify incremental delivery"
  local marker2
  marker2=$(generate_traffic)
  echo "[main] Second traffic marker: ${marker2}"

  wait_for_nr_count_increase "${nrql_second_round_count}" "${second_round_baseline}" || {
    echo "[main] NR count did not increase after second traffic round - incremental delivery check failed"
    exit 1
  }

  echo "[main] E2E test passed (including incremental delivery check)"
}

main "$@"
