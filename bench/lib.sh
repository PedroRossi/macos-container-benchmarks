#!/usr/bin/env bash
# lib.sh — engine abstraction + helpers for the Apple container vs Lima benchmark.
# Engines:
#   apple-native   -> `container run ...`            (one micro-VM per container)
#   apple-dockerd  -> dockerd inside an Apple container, published socket  (config #2)
#   lima-docker    -> dockerd inside a Lima vz VM
#   colima         -> dockerd inside a Colima (Lima) vz VM
set -uo pipefail

BENCH_IMAGE="${BENCH_IMAGE:-bench:latest}"
APPLE_SOCK="${APPLE_SOCK:-$HOME/apple-docker.sock}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${RESULTS_DIR:-$REPO_DIR/results}"

ALL_ENGINES=(apple-native apple-dockerd lima-docker colima orbstack)

_docker_ctx() {  # docker context name for a docker-based engine
  case "$1" in
    apple-dockerd) echo apple-dockerd ;;
    lima-docker)   echo lima-docker ;;
    colima)        echo colima ;;
    orbstack)      echo orbstack ;;
  esac
}

engine_available() {
  case "$1" in
    apple-native)  command -v container >/dev/null 2>&1 && container ls >/dev/null 2>&1 ;;
    apple-dockerd|lima-docker|colima|orbstack)
      docker --context "$(_docker_ctx "$1")" version >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

available_engines() {
  local e; for e in "${ALL_ENGINES[@]}"; do engine_available "$e" && echo "$e"; done
}

# Run a one-shot container (auto-removed), exec CMD, echo its stdout.
engine_oneshot() {
  local eng="$1" cpus="$2" memg="$3" image="$4"; shift 4
  if [ "$eng" = apple-native ]; then
    container run --rm --cpus "$cpus" --memory "${memg}G" "$image" "$@"
  else
    docker --context "$(_docker_ctx "$eng")" run --rm --cpus "$cpus" --memory "${memg}g" "$image" "$@"
  fi
}

# Same invocation rendered as one shell-string (for hyperfine).
engine_oneshot_cmd() {
  local eng="$1" cpus="$2" memg="$3" image="$4"; shift 4
  if [ "$eng" = apple-native ]; then
    echo "container run --rm --cpus $cpus --memory ${memg}G $image $*"
  else
    echo "docker --context $(_docker_ctx "$eng") run --rm --cpus $cpus --memory ${memg}g $image $*"
  fi
}

engine_run_detached() {  # name cpus memg image -> starts `sleep infinity`, echoes name
  local eng="$1" name="$2" cpus="$3" memg="$4" image="$5"
  if [ "$eng" = apple-native ]; then
    container run -d --name "$name" --cpus "$cpus" --memory "${memg}G" "$image" sleep infinity >/dev/null
  else
    docker --context "$(_docker_ctx "$eng")" run -d --name "$name" --cpus "$cpus" --memory "${memg}g" "$image" sleep infinity >/dev/null
  fi
  echo "$name"
}

engine_exec() {  # eng name cmd...
  local eng="$1" name="$2"; shift 2
  if [ "$eng" = apple-native ]; then container exec "$name" "$@"
  else docker --context "$(_docker_ctx "$eng")" exec "$name" "$@"; fi
}

engine_rm() {  # eng name  (stop+remove, ignore errors)
  local eng="$1" name="$2"
  if [ "$eng" = apple-native ]; then container rm -f "$name" >/dev/null 2>&1
  else docker --context "$(_docker_ctx "$eng")" rm -f "$name" >/dev/null 2>&1; fi
}

# Host-side RSS (MB) attributable to an engine's VM/helper processes.
# Patterns are refined empirically; engine_host_ps prints what matched for transparency.
_engine_pat() {
  case "$1" in
    apple-native|apple-dockerd) echo 'container-|com.apple.Virtual|vminitd|helper.*container' ;;
    lima-docker)   echo 'bench-docker' ;;
    colima)        echo '/colima|_lima/colima|colima/' ;;
  esac
}
engine_host_ps() { ps -axo pid,rss,command | grep -iE "$(_engine_pat "$1")" | grep -v grep; }
engine_host_rss_mb() {
  engine_host_ps "$1" | awk '{s+=$2} END{printf "%.0f", (s/1024)}'
}

# Whole-system physical memory in use (active+wired+compressed), MB.
# More reliable than per-process attribution for the scaling delta, since
# apple-native and apple-dockerd share the same host helper processes.
host_used_mb() {
  vm_stat | awk '
    /page size of/ {ps=$8}
    /Pages active/ {gsub(/\./,"",$3); a=$3}
    /Pages wired down/ {gsub(/\./,"",$4); w=$4}
    /Pages occupied by compressor/ {gsub(/\./,"",$5); c=$5}
    END { if(ps=="")ps=16384; printf "%.0f", (a+w+c)*ps/1048576 }'
}

# CSV
csv_init() { mkdir -p "$(dirname "$1")"; echo "timestamp,engine,metric,unit,value,cpus,mem_g,arch,notes" > "$1"; }
csv_row()  { # file engine metric unit value cpus memg arch notes
  echo "$(date +%Y-%m-%dT%H:%M:%S),$2,$3,$4,$5,$6,$7,$8,${9:-}" >> "$1"; }
