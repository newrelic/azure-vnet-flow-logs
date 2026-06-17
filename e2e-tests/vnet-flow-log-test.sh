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

  local marker vm_ip blob_name
  marker=$(generate_traffic)
  vm_ip=$(get_vm_ip)
  echo "[main] Traffic marker: ${marker}; VM public IP: ${vm_ip}"

  blob_name=$(wait_for_blob)
  echo "[main] First flow log blob: ${blob_name}"

  download_blob "${blob_name}"

  local nrql_records
  nrql_records="SELECT * FROM Log WHERE plugin.type = 'azure' AND azure.forwardername = 'VNetFlowLogsForwarder' SINCE 30 minutes ago LIMIT 50"
  wait_for_nr_logs "${nrql_records}"
  assert_required_attributes "${NR_RESULTS_FILE}"

  local nrql_count
  nrql_count="SELECT count(*) as count FROM Log WHERE plugin.type = 'azure' AND azure.forwardername = 'VNetFlowLogsForwarder' SINCE 30 minutes ago"
  compare_blob_and_nr_counts "${nrql_count}" || {
    echo "[main] Completeness check failed"
    exit 1
  }

  echo "[main] E2E test passed"
}

main "$@"
