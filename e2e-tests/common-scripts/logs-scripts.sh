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
  # Flat attribute keys as emitted by VNetFlowForwarder/parser.js (note flowState, not state).
  local attrs=(
    "srcAddr"
    "destAddr"
    "srcPort"
    "destPort"
    "protocol"
    "direction"
    "flowState"
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

nr_count_for() {
  local nrql="$1"
  local nr_json
  nr_json=$(nr_query "${nrql}")
  echo "${nr_json}" | jq -r '.["data"].actor.account.nrql.results[0].count // 0'
}

wait_for_nr_count_increase() {
  local nrql="$1" baseline="$2"
  local sleep_s="${NR_POLL_INITIAL}"
  local attempt=0

  while [[ ${attempt} -lt ${NR_POLL_RETRIES} ]]; do
    log "NR count-increase check attempt $((attempt + 1))"
    local count
    count=$(nr_count_for "${nrql}")
    log "Current NR count: ${count} (baseline ${baseline})"
    if [[ "${count}" -gt "${baseline}" ]]; then
      log "NR count increased: ${baseline} -> ${count}"
      return 0
    fi

    sleep "${sleep_s}"
    sleep_s=$((sleep_s * 2))
    if [[ ${sleep_s} -gt ${NR_POLL_MAX} ]]; then
      sleep_s=${NR_POLL_MAX}
    fi
    attempt=$((attempt + 1))
  done

  log "NR count did not increase within retry budget (baseline=${baseline})"
  return 1
}

compare_blob_and_nr_counts() {
  local nrql="$1"
  local tuple_count nr_count

  tuple_count=$(jq '[.records[].flowRecords.flows[].flowGroups[].flowTuples[]] | length' "${RAW_BLOB_FILE}" 2>/dev/null || echo 0)
  nr_count=$(nr_count_for "${nrql}")

  echo "Tuple count in sampled blob: ${tuple_count}"
  echo "NR record count (run-scoped): ${nr_count}"

  # The NRQL is scoped to this run's VNet, so nr_count reflects only this run's
  # flow data. The sampled blob is a single hourly blob that Azure keeps appending
  # to, so New Relic may legitimately hold at least as many records as the snapshot
  # we counted. Assert the pipeline delivered data without loss: NR >= blob > 0.
  if [[ "${tuple_count}" -le 0 ]]; then
    echo "No flow tuples found in sampled blob; cannot validate completeness"
    return 1
  fi

  [[ "${nr_count}" -ge "${tuple_count}" ]]
}
