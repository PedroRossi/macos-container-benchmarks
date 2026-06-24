#!/usr/bin/env bash
# idle_compare.sh — isolated idle host-RAM cost of OrbStack vs Colima, one engine at a time.
# Metric: whole-system physical RAM in use (active+wired+compressed) vs a both-stopped baseline.
# Per-process attribution is unreliable for vz VMs, so we isolate by running ONE engine at a time.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"; source ./lib.sh
OUT="${1:-$RESULTS_DIR/orbstack-vs-colima}"; mkdir -p "$OUT"; CSV="$OUT/idle.csv"; csv_init "$CSV"
IMG=alpine:3.20
log(){ echo "[$(date +%H:%M:%S)] $*"; }
avg_used(){ local s=0 i u; for i in 1 2 3; do u=$(host_used_mb); s=$((s+u)); sleep 2; done; echo $((s/3)); }

orb stop >/dev/null 2>&1; colima stop >/dev/null 2>&1; sleep 8
BASE=$(avg_used); log "baseline (both stopped) = ${BASE}MB"

measure(){ # name ctx start_cmd stop_cmd
  local name="$1" ctx="$2" startcmd="$3" stopcmd="$4" idle one
  log "$name: starting"; eval "$startcmd" >/dev/null 2>&1
  local i; for i in $(seq 1 90); do docker --context "$ctx" version >/dev/null 2>&1 && break; sleep 1; done
  sleep 25
  idle=$(avg_used); log "  $name idle used=${idle}MB  delta=+$((idle-BASE))MB"
  docker --context "$ctx" run -d --name idletest "$IMG" sleep infinity >/dev/null 2>&1; sleep 15
  one=$(avg_used);  log "  $name +1ctr used=${one}MB  delta=+$((one-BASE))MB"
  docker --context "$ctx" rm -f idletest >/dev/null 2>&1
  csv_row "$CSV" "$name" host_idle_delta MB "$((idle-BASE))" 4 4 arm64 "baseline=${BASE}MB"
  csv_row "$CSV" "$name" host_1ctr_delta MB "$((one-BASE))" 4 4 arm64 "1 alpine idle"
  eval "$stopcmd" >/dev/null 2>&1; sleep 8
}

measure colima  colima   "colima start --cpu 4 --memory 4 --vm-type vz"  "colima stop"
measure orbstack orbstack "orb start"                                    "orb stop"
log "DONE -> $CSV"
