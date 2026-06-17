#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[stack] $*"
}

deploy_forwarder_template() {
  log "Deploying forwarder resources via ARM template"
  az deployment group create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${FORWARDER_DEPLOYMENT_NAME}" \
    --template-file "${ARM_FORWARDER_TEMPLATE}" \
    --parameters \
      newRelicLicenseKey="${NR_LICENSE_KEY}" \
      location="${AZURE_REGION}" \
      newRelicEndpoint="${NR_LOG_ENDPOINT}" \
      scalingMode="${SCALING_MODE}" \
      disablePublicAccessToStorageAccount="${DISABLE_PUBLIC_ACCESS_TO_STORAGE}" \
      newRelicTags="${NEW_RELIC_TAGS}" \
      maxRetries="${MAX_RETRIES}" \
      retryInterval="${RETRY_INTERVAL}" \
      eventHubBatchSize="${EVENT_HUB_BATCH_SIZE}" \
      debugEnabled="${DEBUG_ENABLED}" \
      sourceStorageAccountName="${SOURCE_STORAGE_ACCOUNT_NAME}" \
      eventHubNamespace="${EVENT_HUB_NAMESPACE_OVERRIDE}" \
      eventHubName="${EVENT_HUB_NAME_OVERRIDE}" \
      eventGridSystemTopicName="${EVENT_GRID_SYSTEM_TOPIC_NAME_OVERRIDE}" \
      eventGridSubscriptionName="${EVENT_GRID_SUBSCRIPTION_NAME_OVERRIDE}" \
    --query properties.outputs -o json > "${FORWARDER_OUTPUTS_FILE}"

  SOURCE_STORAGE=$(jq -r '.sourceStorageAccountName.value' "${FORWARDER_OUTPUTS_FILE}")
  FUNCTION_APP_NAME=$(jq -r '.functionAppName.value' "${FORWARDER_OUTPUTS_FILE}")
  EVENTHUB_NAMESPACE=$(jq -r '.eventHubNamespace.value' "${FORWARDER_OUTPUTS_FILE}")
  EVENTHUB_NAME=$(jq -r '.eventHubName.value' "${FORWARDER_OUTPUTS_FILE}")
  CURSOR_STORAGE=$(jq -r '.cursorStorageAccountName.value' "${FORWARDER_OUTPUTS_FILE}")

  export SOURCE_STORAGE FUNCTION_APP_NAME EVENTHUB_NAMESPACE EVENTHUB_NAME CURSOR_STORAGE
}

deploy_traffic_template() {
  if [[ ! -f "${VM_ADMIN_PUBLIC_KEY_PATH}" ]]; then
    echo "VM public key file not found: ${VM_ADMIN_PUBLIC_KEY_PATH}"
    exit 1
  fi

  local vm_key
  vm_key=$(cat "${VM_ADMIN_PUBLIC_KEY_PATH}")

  log "Deploying traffic resources via ARM template"
  az deployment group create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${TRAFFIC_DEPLOYMENT_NAME}" \
    --template-file "${ARM_TRAFFIC_TEMPLATE}" \
    --parameters \
      location="${AZURE_REGION}" \
      vnetName="${VNET_NAME}" \
      subnetName="${SUBNET_NAME}" \
      nsgName="${NSG_NAME}" \
      vmName="${VM_NAME}" \
      vmSize="${VM_SIZE}" \
      vmAdminUsername="${VM_ADMIN_USERNAME}" \
      vmAdminPublicKey="${vm_key}" \
      vmPublicIpName="${VM_PUBLIC_IP_NAME}" \
      vmNicName="${VM_NIC_NAME}" \
      vnetAddressPrefix="${VNET_CIDR}" \
      subnetAddressPrefix="${SUBNET_CIDR}" \
    --query properties.outputs -o json > "${TRAFFIC_OUTPUTS_FILE}"
}

deploy_flowlog_template() {
  log "Deploying flow-log resource via ARM template"
  local source_storage_id vnet_id
  source_storage_id=$(az storage account show --name "${SOURCE_STORAGE}" --resource-group "${RESOURCE_GROUP}" --query id -o tsv)
  vnet_id=$(az network vnet show --name "${VNET_NAME}" --resource-group "${RESOURCE_GROUP}" --query id -o tsv)

  az deployment group create \
    --resource-group "${NETWORK_WATCHER_RG}" \
    --name "${RUN_ID}-flowlog" \
    --template-file "${E2E_DIR}/arm/azuredeploy-e2e-flowlog.json" \
    --parameters \
      location="${AZURE_REGION}" \
      networkWatcherName="${NETWORK_WATCHER_NAME}" \
      flowLogName="${RUN_ID}-flowlog" \
      targetResourceId="${vnet_id}" \
      storageId="${source_storage_id}" >/dev/null
}

build_and_deploy_package() {
  log "Building function package"
  npm run package >/dev/null

  log "Deploying package"
  az functionapp deployment source config-zip \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${FUNCTION_APP_NAME}" \
    --src "${DEPLOY_PACKAGE}" >/dev/null
}

verify_eventgrid_subscription() {
  log "Verifying Event Grid -> Event Hub subscription wiring"
  local storage_id
  storage_id=$(az storage account show --name "${SOURCE_STORAGE}" --resource-group "${RESOURCE_GROUP}" --query id -o tsv)
  local eh_id
  eh_id=$(az eventhubs eventhub show --name "${EVENTHUB_NAME}" --namespace-name "${EVENTHUB_NAMESPACE}" --resource-group "${RESOURCE_GROUP}" --query id -o tsv)

  local sub_count
  sub_count=$(az eventgrid event-subscription list \
    --source-resource-id "${storage_id}" \
    --query "[?contains(destination.properties.resourceId, '${eh_id}')].name | length(@)" \
    -o tsv)

  if [[ "${sub_count}" == "0" || -z "${sub_count}" ]]; then
    echo "No Event Grid subscription found from source storage to Event Hub"
    return 1
  fi
}

show_deployment_failures() {
  log "Fetching deployment errors (if any)"
  az deployment operation group list \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${FORWARDER_DEPLOYMENT_NAME}" \
    --query "[?properties.provisioningState=='Failed'].{target:properties.targetResource.resourceName, status:properties.statusMessage}" \
    -o table || true

  az deployment operation group list \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${TRAFFIC_DEPLOYMENT_NAME}" \
    --query "[?properties.provisioningState=='Failed'].{target:properties.targetResource.resourceName, status:properties.statusMessage}" \
    -o table || true
}

teardown_with_backoff() {
  log "Deleting resource group"
  az group delete --name "${RESOURCE_GROUP}" --yes --no-wait >/dev/null || true

  local sleep_s=10
  local max_sleep=120
  for _ in {1..10}; do
    if ! az group show --name "${RESOURCE_GROUP}" >/dev/null 2>&1; then
      log "Resource group deleted"
      return 0
    fi
    sleep "${sleep_s}"
    if [[ ${sleep_s} -lt ${max_sleep} ]]; then
      sleep_s=$((sleep_s * 2))
      if [[ ${sleep_s} -gt ${max_sleep} ]]; then
        sleep_s=${max_sleep}
      fi
    fi
  done

  log "Resource group delete still in progress"
}
