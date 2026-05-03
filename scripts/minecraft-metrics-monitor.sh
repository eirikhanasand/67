#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-67}"
THRESHOLD_PERCENT="${THRESHOLD_PERCENT:-90}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-30}"
ALERT_COOLDOWN_SECONDS="${ALERT_COOLDOWN_SECONDS:-300}"
RCON_COMMAND="${RCON_COMMAND:-docker exec ${CONTAINER_NAME} rcon-cli}"

last_alert_at=0
sent_initial=0

say() {
  local message="$1"
  ${RCON_COMMAND} "say ${message}" >/dev/null 2>&1 || true
}

container_state() {
  docker inspect -f '{{.State.Running}} {{.HostConfig.NanoCpus}} {{.HostConfig.Memory}}' "${CONTAINER_NAME}" 2>/dev/null || true
}

container_stats() {
  docker stats "${CONTAINER_NAME}" --no-stream --format '{{.CPUPerc}} {{.MemPerc}} {{.MemUsage}}' 2>/dev/null || true
}

host_cpu_count() {
  nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || printf '1\n'
}

format_metrics() {
  local raw_cpu="$1"
  local mem_percent="$2"
  local mem_usage="$3"
  local cpu_limit="$4"

  awk -v raw_cpu="${raw_cpu%%%}" \
      -v mem_percent="${mem_percent%%%}" \
      -v mem_usage="${mem_usage}" \
      -v cpu_limit="${cpu_limit}" \
      -v threshold="${THRESHOLD_PERCENT}" '
    BEGIN {
      normalized_cpu = raw_cpu / cpu_limit;
      printf "67 metrics: CPU %.1f%% of %.1f-core limit (docker %.1f%%), memory %.1f%% (%s), threshold %.0f%%",
        normalized_cpu, cpu_limit, raw_cpu, mem_percent, mem_usage, threshold
    }
  '
}

over_threshold() {
  local raw_cpu="$1"
  local mem_percent="$2"
  local cpu_limit="$3"

  awk -v raw_cpu="${raw_cpu%%%}" \
      -v mem_percent="${mem_percent%%%}" \
      -v cpu_limit="${cpu_limit}" \
      -v threshold="${THRESHOLD_PERCENT}" '
    BEGIN {
      normalized_cpu = raw_cpu / cpu_limit;
      if (normalized_cpu >= threshold || mem_percent >= threshold) {
        exit 0
      }
      exit 1
    }
  '
}

while true; do
  state="$(container_state)"
  if [[ -z "${state}" ]]; then
    sleep "${INTERVAL_SECONDS}"
    continue
  fi

  read -r running nano_cpus memory_limit <<<"${state}"
  if [[ "${running}" != "true" ]]; then
    sleep "${INTERVAL_SECONDS}"
    continue
  fi

  if [[ "${nano_cpus}" =~ ^[0-9]+$ && "${nano_cpus}" -gt 0 ]]; then
    cpu_limit="$(awk -v nano="${nano_cpus}" 'BEGIN { printf "%.3f", nano / 1000000000 }')"
  else
    cpu_limit="$(host_cpu_count)"
  fi

  stats="$(container_stats)"
  if [[ -z "${stats}" ]]; then
    sleep "${INTERVAL_SECONDS}"
    continue
  fi

  read -r raw_cpu mem_percent mem_used _mem_slash mem_limit _rest <<<"${stats}"
  mem_usage="${mem_used} / ${mem_limit}"
  message="$(format_metrics "${raw_cpu}" "${mem_percent}" "${mem_usage}" "${cpu_limit}")"

  now="$(date +%s)"
  if [[ "${sent_initial}" -eq 0 ]]; then
    say "${message} (initial report)"
    sent_initial=1
    last_alert_at="${now}"
  elif over_threshold "${raw_cpu}" "${mem_percent}" "${cpu_limit}" && (( now - last_alert_at >= ALERT_COOLDOWN_SECONDS )); then
    say "${message}"
    last_alert_at="${now}"
  fi

  sleep "${INTERVAL_SECONDS}"
done
