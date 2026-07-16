#!/usr/bin/env bash
set -euo pipefail

stack_log() {
  echo "[stack] $*" >&2
}

deploy_forwarder_template() {
  stack_log "Deploying forwarder resources via ARM template"
  # Parameter names must match arm/azuredeploy-vnetflowlogsforwarder.json exactly.
  # The template derives location from the resource group, so no location param is passed.
  # The Event Grid -> Event Hub subscription's dependsOn on the delivery identity's
  # role assignment only guarantees ARM created that resource, not that Azure RBAC
  # has finished propagating the permission - so a fresh deployment can intermittently
  # fail with "Managed Identity Authorization Error" on the subscription. Retry the
  # whole deployment rather than fail outright: it's idempotent, ARM reconciles
  # already-succeeded resources instead of recreating them.
  local attempt=1 max_attempts=4 sleep_s=30 out
  while true; do
    if out=$(az deployment group create \
      --resource-group "${RESOURCE_GROUP}" \
      --name "${FORWARDER_DEPLOYMENT_NAME}" \
      --template-file "${ARM_FORWARDER_TEMPLATE}" \
      --parameters \
        newRelicIngestLicenseKey="${NR_LICENSE_KEY}" \
        newRelicEndpoint="${NR_LOG_ENDPOINT}" \
        eventHubScalingMode="${SCALING_MODE}" \
        disablePublicAccessToStorageAccount="${DISABLE_PUBLIC_ACCESS_TO_STORAGE}" \
        maxRetries="${MAX_RETRIES}" \
        retryInterval="${RETRY_INTERVAL}" \
        maxEventBatchSize="${EVENT_HUB_BATCH_SIZE}" \
        functionLogLevel="${FUNCTION_LOG_LEVEL}" \
        flowLogsStorageAccountName="${SOURCE_STORAGE_ACCOUNT_NAME}" \
      --query properties.outputs -o json); then
      echo "${out}" > "${FORWARDER_OUTPUTS_FILE}"
      break
    fi
    if [[ ${attempt} -ge ${max_attempts} ]]; then
      echo "Forwarder deployment failed after ${max_attempts} attempts"
      return 1
    fi
    stack_log "Forwarder deployment attempt ${attempt} failed (possible RBAC propagation race on Event Grid delivery identity); retrying in ${sleep_s}s"
    sleep "${sleep_s}"
    attempt=$((attempt + 1))
    sleep_s=$((sleep_s * 2))
  done

  resolve_forwarder_resources
  export SOURCE_STORAGE FUNCTION_APP_NAME EVENTHUB_NAMESPACE EVENTHUB_NAME CURSOR_STORAGE
}

# The forwarder template does not expose deployment outputs, so discover the
# resource names it created by listing them in the resource group. Names follow
# the fixed prefixes defined in arm/azuredeploy-vnetflowlogsforwarder.json:
#   flow-logs source storage : nrvnetflsrc<suffix>   (skipped if caller supplied one)
#   function/cursor storage  : nrvnetflfn<suffix>
#   function app             : the only Microsoft.Web/sites in the group
#   event hub namespace      : the only Microsoft.EventHub/namespaces in the group
#   event hub                : the fixed name 'nrvnetflowlogs-eventhub'
resolve_forwarder_resources() {
  stack_log "Resolving deployed forwarder resource names"

  if [[ -n "${SOURCE_STORAGE_ACCOUNT_NAME}" ]]; then
    SOURCE_STORAGE="${SOURCE_STORAGE_ACCOUNT_NAME}"
  else
    SOURCE_STORAGE=$(az storage account list --resource-group "${RESOURCE_GROUP}" \
      --query "[?starts_with(name, 'nrvnetflsrc')].name | [0]" -o tsv)
  fi

  CURSOR_STORAGE=$(az storage account list --resource-group "${RESOURCE_GROUP}" \
    --query "[?starts_with(name, 'nrvnetflfn')].name | [0]" -o tsv)

  FUNCTION_APP_NAME=$(az functionapp list --resource-group "${RESOURCE_GROUP}" \
    --query "[0].name" -o tsv)

  EVENTHUB_NAMESPACE=$(az eventhubs namespace list --resource-group "${RESOURCE_GROUP}" \
    --query "[0].name" -o tsv)

  EVENTHUB_NAME="nrvnetflowlogs-eventhub"

  if [[ -z "${SOURCE_STORAGE}" || "${SOURCE_STORAGE}" == "None" \
     || -z "${FUNCTION_APP_NAME}" || "${FUNCTION_APP_NAME}" == "None" \
     || -z "${EVENTHUB_NAMESPACE}" || "${EVENTHUB_NAMESPACE}" == "None" ]]; then
    echo "Failed to resolve forwarder resources (source=${SOURCE_STORAGE}, functionApp=${FUNCTION_APP_NAME}, eventHubNs=${EVENTHUB_NAMESPACE})"
    return 1
  fi

  stack_log "Resolved: source=${SOURCE_STORAGE}, cursor=${CURSOR_STORAGE}, functionApp=${FUNCTION_APP_NAME}, eventHubNs=${EVENTHUB_NAMESPACE}, eventHub=${EVENTHUB_NAME}"
}

deploy_traffic_template() {
  ensure_ssh_key

  local vm_key
  vm_key=$(cat "${VM_ADMIN_PUBLIC_KEY_PATH}")

  stack_log "Deploying traffic resources via ARM template"
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
  stack_log "Deploying flow-log resource via ARM template"
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
  stack_log "Building function package"
  npm run package >/dev/null

  stack_log "Deploying package"
  # A freshly created Function App's *.scm.azurewebsites.net TLS binding can briefly
  # present a placeholder certificate before Azure's real cert propagates, so retry
  # with backoff instead of failing on the first attempt.
  local attempt=1 max_attempts=5 sleep_s=15 out
  while true; do
    if out=$(az functionapp deployment source config-zip \
      --resource-group "${RESOURCE_GROUP}" \
      --name "${FUNCTION_APP_NAME}" \
      --src "${DEPLOY_PACKAGE}" 2>&1); then
      return 0
    fi
    if [[ ${attempt} -ge ${max_attempts} ]]; then
      echo "Package deployment failed after ${max_attempts} attempts:"
      echo "${out}"
      return 1
    fi
    stack_log "Package deployment attempt ${attempt} failed (likely SCM TLS still propagating); retrying in ${sleep_s}s"
    sleep "${sleep_s}"
    attempt=$((attempt + 1))
    sleep_s=$((sleep_s * 2))
  done
}

verify_eventgrid_subscription() {
  stack_log "Verifying Event Grid -> Event Hub subscription wiring"
  local storage_id
  storage_id=$(az storage account show --name "${SOURCE_STORAGE}" --resource-group "${RESOURCE_GROUP}" --query id -o tsv)
  local eh_id
  eh_id=$(az eventhubs eventhub show --name "${EVENTHUB_NAME}" --namespace-name "${EVENTHUB_NAMESPACE}" --resource-group "${RESOURCE_GROUP}" --query id -o tsv)

  # The forwarder template delivers via a user-assigned managed identity
  # (deliveryWithResourceIdentity), not plain `destination` - that field is null
  # for identity-based subscriptions. Also: the returned/list representation has no
  # extra `.properties.` nesting around resourceId (that nesting only exists in the
  # ARM PUT/deployment body schema) - confirmed empirically against a live
  # subscription, so query destination.resourceId directly, not destination.properties.resourceId.
  local sub_count
  sub_count=$(az eventgrid event-subscription list \
    --source-resource-id "${storage_id}" \
    --query "[?contains((destination.resourceId || deliveryWithResourceIdentity.destination.resourceId || ''), '${eh_id}')].name | length(@)" \
    -o tsv)

  if [[ "${sub_count}" == "0" || -z "${sub_count}" ]]; then
    echo "No Event Grid subscription found from source storage to Event Hub"
    return 1
  fi
}

show_deployment_failures() {
  stack_log "Fetching deployment errors (if any)"
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
  # The flow log lives on the Network Watcher (in NETWORK_WATCHER_RG), not in the
  # run resource group, so deleting the run RG never removes it. Delete it first,
  # best-effort, to avoid leaving a flow log pointing at deleted resources.
  if [[ -n "${NETWORK_WATCHER_NAME:-}" ]]; then
    stack_log "Deleting flow log ${RUN_ID}-flowlog from network watcher ${NETWORK_WATCHER_NAME}"
    az network watcher flow-log delete \
      --location "${AZURE_REGION}" \
      --name "${RUN_ID}-flowlog" >/dev/null 2>&1 || true
  fi

  stack_log "Deleting resource group"
  az group delete --name "${RESOURCE_GROUP}" --yes --no-wait >/dev/null || true

  local sleep_s=10
  local max_sleep=120
  for _ in {1..10}; do
    # `az group exists` prints a clean true/false and is the authoritative check.
    # A network/auth error also makes it fail non-zero, so on failure we don't know
    # the group is gone - only an explicit "false" counts as deleted, otherwise we
    # keep polling instead of risking a false "deleted" report.
    local exists
    exists=$(az group exists --name "${RESOURCE_GROUP}" 2>/dev/null) || exists="unknown"
    if [[ "${exists}" == "false" ]]; then
      stack_log "Resource group deleted"
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

  stack_log "Resource group delete not confirmed after retry budget - check ${RESOURCE_GROUP} manually"
  return 1
}
