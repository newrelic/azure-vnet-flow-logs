#!/usr/bin/env bash
set -euo pipefail

require_cmds() {
  local missing=0
  for c in az jq curl uuidgen zip ssh-keygen getent; do
    if ! command -v "$c" >/dev/null 2>&1; then
      echo "Missing required command: $c"
      missing=1
    fi
  done
  if [[ $missing -ne 0 ]]; then
    exit 1
  fi
}

resource_log() {
  echo "[resource] $*" >&2
}

# Ensure an SSH public key exists at VM_ADMIN_PUBLIC_KEY_PATH for the traffic VM.
# On a fresh CI runner no key exists, so generate an ephemeral keypair rather than
# failing. The VM is provisioned and torn down within the run, so the key is
# throwaway.
ensure_ssh_key() {
  if [[ -f "${VM_ADMIN_PUBLIC_KEY_PATH}" ]]; then
    return 0
  fi

  local private_key_path
  private_key_path="${VM_ADMIN_PUBLIC_KEY_PATH%.pub}"
  if [[ "${private_key_path}" == "${VM_ADMIN_PUBLIC_KEY_PATH}" ]]; then
    private_key_path="${VM_ADMIN_PUBLIC_KEY_PATH}.key"
  fi

  resource_log "SSH public key not found at ${VM_ADMIN_PUBLIC_KEY_PATH}; generating an ephemeral keypair"
  mkdir -p "$(dirname "${private_key_path}")"
  ssh-keygen -t rsa -b 4096 -f "${private_key_path}" -N "" -q
  if [[ ! -f "${VM_ADMIN_PUBLIC_KEY_PATH}" ]]; then
    # ssh-keygen writes <path>.pub next to the private key; align if names differ.
    cp "${private_key_path}.pub" "${VM_ADMIN_PUBLIC_KEY_PATH}"
  fi
}

create_resource_group() {
  resource_log "Creating resource group: ${RESOURCE_GROUP}"
  az group create \
    --name "${RESOURCE_GROUP}" \
    --location "${AZURE_REGION}" \
    --tags "${TAG_PURPOSE}" "${TAG_CREATED_BY}" >/dev/null
}

resolve_network_watcher() {
  if [[ -n "${NETWORK_WATCHER_NAME}" ]]; then
    if [[ -z "${NETWORK_WATCHER_RG}" ]]; then
      NETWORK_WATCHER_RG="NetworkWatcherRG"
    fi
    return 0
  fi

  NETWORK_WATCHER_NAME=$(az network watcher list --query "[?location=='${AZURE_REGION}'].name | [0]" -o tsv)
  NETWORK_WATCHER_RG=$(az network watcher list --query "[?location=='${AZURE_REGION}'].resourceGroup | [0]" -o tsv)
  if [[ -z "${NETWORK_WATCHER_NAME}" || "${NETWORK_WATCHER_NAME}" == "None" ]]; then
    echo "No Network Watcher found in ${AZURE_REGION}. Set NETWORK_WATCHER_NAME explicitly."
    exit 1
  fi
  if [[ -z "${NETWORK_WATCHER_RG}" || "${NETWORK_WATCHER_RG}" == "None" ]]; then
    NETWORK_WATCHER_RG="NetworkWatcherRG"
  fi
  export NETWORK_WATCHER_NAME
  export NETWORK_WATCHER_RG
}

wait_for_blob() {
  resource_log "Waiting for first flow-log blob (timeout ${TEST_TIMEOUT_FLOW_LOGS}s)"
  local deadline=$(( $(date +%s) + TEST_TIMEOUT_FLOW_LOGS ))
  local account_key
  account_key=$(az storage account keys list --resource-group "${RESOURCE_GROUP}" --account-name "${SOURCE_STORAGE}" --query "[0].value" -o tsv)

  while [[ $(date +%s) -lt $deadline ]]; do
    local blob
    blob=$(az storage blob list \
      --account-name "${SOURCE_STORAGE}" \
      --account-key "${account_key}" \
      --container-name insights-logs-flowlogflowevent \
      --num-results 1 \
      --query "[0].name" -o tsv 2>/dev/null || true)

    if [[ -n "${blob}" && "${blob}" != "None" ]]; then
      echo "${blob}"
      return 0
    fi
    sleep "${FLOW_LOG_POLL_INTERVAL}"
  done

  echo "Timed out waiting for flow log blob"
  return 1
}

generate_traffic() {
  local url="${1:-https://www.microsoft.com}"
  local host_header="${2:-}"
  resource_log "Generating traffic from VM"
  local marker
  marker=$(uuidgen)
  echo "${marker}" > "${MARKER_FILE}"

  local curl_cmd
  curl_cmd="curl -sS -m 10"
  if [[ -n "${host_header}" ]]; then
    curl_cmd="${curl_cmd} -H 'Host: ${host_header}'"
  fi
  curl_cmd="${curl_cmd} '${url}' >/dev/null"

  az vm run-command invoke \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${VM_NAME}" \
    --command-id RunShellScript \
    --scripts "set -e; success=0; for i in 1 2 3 4 5; do if ${curl_cmd}; then success=1; fi; done; if [[ \$success -ne 1 ]]; then echo 'Traffic generation failed: all outbound requests failed' >&2; exit 1; fi; echo ${marker}" >/dev/null

  echo "${marker}"
}

get_vm_ip() {
  az vm show -d --resource-group "${RESOURCE_GROUP}" --name "${VM_NAME}" --query publicIps -o tsv
}

get_vm_private_ip() {
  az vm show -d --resource-group "${RESOURCE_GROUP}" --name "${VM_NAME}" --query privateIps -o tsv
}

download_blob() {
  local blob_name="$1"
  local account_key
  account_key=$(az storage account keys list --resource-group "${RESOURCE_GROUP}" --account-name "${SOURCE_STORAGE}" --query "[0].value" -o tsv)

  az storage blob download \
    --account-name "${SOURCE_STORAGE}" \
    --account-key "${account_key}" \
    --container-name insights-logs-flowlogflowevent \
    --name "${blob_name}" \
    --file "${RAW_BLOB_FILE}" \
    --overwrite >/dev/null
}
