#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[logs] $*"
}

nr_query() {
  local nrql="$1"
  local payload
  payload=$(jq -n --arg accountId "${NR_ACCOUNT_ID}" --arg nrql "${nrql}" '{query: "{ actor { account(id: " + $accountId + ") { nrql(query: \\\"" + $nrql + "\\\") { results } } } }"}')

  curl -sS -X POST "${NR_GRAPHQL_ENDPOINT}" \
    -H "Content-Type: application/json" \
    -H "API-Key: ${NR_QUERY_API_KEY}" \
    -d "${payload}"
}

wait_for_nr_logs() {
  local nrql="$1"
  local sleep_s="${NR_POLL_INITIAL}"
  local attempt=0

  while [[ ${attempt} -lt ${NR_POLL_RETRIES} ]]; do
    log "NR query attempt $((attempt + 1))"
    local out
    out=$(nr_query "${nrql}")
    echo "${out}" > "${NR_RESULTS_FILE}"

    local count
    count=$(echo "${out}" | jq '[.data.actor.account.nrql.results[]] | length' 2>/dev/null || echo 0)
    if [[ "${count}" -gt 0 ]]; then
      log "NR results found: ${count}"
      return 0
    fi

    sleep "${sleep_s}"
    sleep_s=$((sleep_s * 2))
    if [[ ${sleep_s} -gt ${NR_POLL_MAX} ]]; then
      sleep_s=${NR_POLL_MAX}
    fi
    attempt=$((attempt + 1))
  done

  log "No NR results found within retry budget"
  return 1
}

assert_required_attributes() {
  local json_file="$1"
  local missing=0
  local attrs=(
    "flow.srcAddr"
    "flow.destAddr"
    "flow.srcPort"
    "flow.destPort"
    "flow.protocol"
    "flow.direction"
    "flow.state"
  )

  for attr in "${attrs[@]}"; do
    if ! jq -e --arg a "${attr}" '.data.actor.account.nrql.results[] | has($a)' "${json_file}" >/dev/null 2>&1; then
      echo "Missing expected attribute in NR results: ${attr}"
      missing=1
    fi
  done

  if [[ ${missing} -ne 0 ]]; then
    return 1
  fi
}

compare_blob_and_nr_counts() {
  local nrql="$1"
  local tuple_count nr_count nr_json

  tuple_count=$(jq '[.records[].flowRecords.flows[].flowGroups[].flowTuples[]] | length' "${RAW_BLOB_FILE}" 2>/dev/null || echo 0)
  nr_json=$(nr_query "${nrql}")
  nr_count=$(echo "${nr_json}" | jq -r '.["data"].actor.account.nrql.results[0].count // 0')

  echo "Tuple count in blob: ${tuple_count}"
  echo "NR record count: ${nr_count}"

  [[ "${tuple_count}" -eq "${nr_count}" ]]
}
