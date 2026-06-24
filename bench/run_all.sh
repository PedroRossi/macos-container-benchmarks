#!/usr/bin/env bash
# run_all.sh — orchestrator for the Apple `container` vs Lima benchmark.
# Usage: run_all.sh <setup|startup|cpumem|hostmem|all> [cpus] [mem_g]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

PHASE="${1:-all}"; CPUS="${2:-4}"; MEMG="${3:-4}"
STAMP="${STAMP:-$(date +%Y%m%d-%H%M%S)}"
OUT="$RESULTS_DIR/$STAMP"; CSV="$OUT/results.csv"
mkdir -p "$OUT"; [ -f "$CSV" ] || csv_init "$CSV"
REPS="${REPS:-5}"

log(){ echo "[$(date +%H:%M:%S)] $*"; }

# ---- setup: docker contexts + bench image per engine ----------------------
setup() {
  log "Creating docker contexts..."
  docker context create apple-dockerd --docker "host=unix://$APPLE_SOCK" 2>/dev/null \
    || docker context update apple-dockerd --docker "host=unix://$APPLE_SOCK" 2>/dev/null || true
  if [ -S "$HOME/.lima/bench-docker/sock/docker.sock" ]; then
    docker context create lima-docker --docker "host=unix://$HOME/.lima/bench-docker/sock/docker.sock" 2>/dev/null \
      || docker context update lima-docker --docker "host=unix://$HOME/.lima/bench-docker/sock/docker.sock" 2>/dev/null || true
  fi
  log "Available engines: $(available_engines | tr '\n' ' ')"
  log "Building bench image on each engine (parallel)..."
  for e in $(available_engines); do build_image "$e" & done; wait
  log "Image build done."
}

build_image() {
  local eng="$1" ctx
  if [ "$eng" = apple-native ]; then
    container build -t "$BENCH_IMAGE" -f "$REPO_DIR/images/bench/Dockerfile" "$REPO_DIR/images/bench" \
      >"$OUT/build-$eng.log" 2>&1
  else
    ctx="$(_docker_ctx "$eng")"
    docker --context "$ctx" build -t "$BENCH_IMAGE" -f "$REPO_DIR/images/bench/Dockerfile" "$REPO_DIR/images/bench" \
      >"$OUT/build-$eng.log" 2>&1
  fi
  echo "  built on $eng (exit $?)"
}

# ---- warm startup latency (hyperfine) -------------------------------------
startup() {
  command -v hyperfine >/dev/null || { log "no hyperfine"; return; }
  for e in $(available_engines); do
    log "startup: $e"
    local cmd; cmd="$(engine_oneshot_cmd "$e" "$CPUS" "$MEMG" "$BENCH_IMAGE" true)"
    local j="$OUT/startup-$e.json"
    hyperfine --warmup 3 --runs 20 --export-json "$j" "$cmd" >/dev/null 2>&1 || { log "  failed"; continue; }
    local mean p95 sd
    mean=$(awk -F'[:,]' '/"mean"/{print $2; exit}' "$j")
    sd=$(awk -F'[:,]' '/"stddev"/{print $2; exit}' "$j")
    csv_row "$CSV" "$e" startup_warm s "$mean" "$CPUS" "$MEMG" arm64 "stddev=$sd"
    log "  mean=${mean}s"
  done
}

# ---- CPU + memory (sysbench inside the container) -------------------------
cpumem() {
  for e in $(available_engines); do
    log "cpumem: $e"
    for th in 1 "$CPUS"; do
      local out evs
      out=$(engine_oneshot "$e" "$CPUS" "$MEMG" "$BENCH_IMAGE" \
            sysbench cpu --cpu-max-prime=20000 --threads="$th" --time=15 run 2>/dev/null)
      evs=$(echo "$out" | awk '/events per second/{print $4}')
      [ -n "$evs" ] && csv_row "$CSV" "$e" "cpu_eps_t${th}" eps "$evs" "$CPUS" "$MEMG" arm64
      log "  cpu t=$th -> ${evs:-NA} eps"
    done
    local out mibs
    out=$(engine_oneshot "$e" "$CPUS" "$MEMG" "$BENCH_IMAGE" \
          sysbench memory --memory-block-size=1M --memory-total-size=8G --memory-oper=write --threads="$CPUS" run 2>/dev/null)
    mibs=$(echo "$out" | awk -F'[()]' '/MiB\/sec/{print $2}' | awk '{print $1}')
    [ -n "$mibs" ] && csv_row "$CSV" "$e" mem_write MiB/s "$mibs" "$CPUS" "$MEMG" arm64
    log "  mem write -> ${mibs:-NA} MiB/s"
  done
}

# ---- host memory: idle (0 containers) + per running container -------------
# Marginal host-memory cost of running N containers, per engine (whole-system delta).
# Headline: apple-native grows ~linearly (N micro-VMs); docker engines stay ~flat (1 VM).
# Scaling containers use SCALE_MEMG GiB each (default 1) to stay within the 24 GB host.
hostmem() {
  local SCALE_MEMG="${SCALE_MEMG:-1}"
  for e in $(available_engines); do
    log "hostmem: $e (scaling containers @ ${SCALE_MEMG}G each)"
    local base; base=$(host_used_mb)
    csv_row "$CSV" "$e" host_used_base MB "$base" "$CPUS" "$SCALE_MEMG" arm64 "system total used, 0 bench containers"
    local names=() i n rss delta
    for i in 1 2 3; do
      while [ "${#names[@]}" -lt "$i" ]; do
        n="bench_${e}_$((${#names[@]}+1))"
        engine_run_detached "$e" "$n" "$CPUS" "$SCALE_MEMG" "$BENCH_IMAGE" >/dev/null 2>&1
        names+=("$n")
      done
      sleep 3
      rss=$(host_used_mb); delta=$((rss - base))
      csv_row "$CSV" "$e" "host_used_delta_n${i}" MB "$delta" "$CPUS" "$SCALE_MEMG" arm64 "$i containers; total=${rss}MB"
      log "  N=$i used=${rss}MB delta=+${delta}MB"
    done
    for n in "${names[@]}"; do engine_rm "$e" "$n"; done
    sleep 2
  done
}

# run the bench image with an optional host bind-mount at /data
_run_with_mount() { # eng hostdir(or empty) cmd...
  local eng="$1" hm="$2"; shift 2
  local v=(); [ -n "$hm" ] && v=(-v "$hm:/data")
  if [ "$eng" = apple-native ]; then container run --rm "${v[@]}" "$BENCH_IMAGE" "$@"
  else docker --context "$(_docker_ctx "$eng")" run --rm "${v[@]}" "$BENCH_IMAGE" "$@"; fi
}

# ---- disk I/O (fio): rootfs (overlay, buffered) all engines; bind-mount (virtiofs, O_DIRECT) where RW works ----
fio_one() { # eng label dir direct hostdir rw
  local eng="$1" label="$2" dir="$3" direct="$4" hm="$5" rw="$6" out iops bw ioeng=libaio iod=64
  [ "$direct" = 0 ] && { ioeng=psync; iod=1; }   # libaio needs O_DIRECT; psync for buffered
  out=$(_run_with_mount "$eng" "$hm" fio --name=j --directory="$dir" --size=512M --runtime=20 --time_based \
        --ioengine="$ioeng" --direct="$direct" --bs=4k --iodepth="$iod" --rw="$rw" --group_reporting 2>&1)
  iops=$(echo "$out" | awk -F'[=,]' '/IOPS=/{print $2; exit}')
  bw=$(echo "$out" | awk -F'[()]' '/IOPS=/{print $2; exit}')
  csv_row "$CSV" "$eng" "fio_${label}_${rw}" IOPS "${iops:-NA}" "$CPUS" "$MEMG" arm64 "4k qd64 direct=$direct bw=${bw:-NA}"
  log "  $label $rw -> ${iops:-NA} IOPS ${bw:+($bw)}"
}
disk() {
  local VT="$HOME/bench-fio"; rm -rf "$VT"; mkdir -p "$VT"
  for e in $(available_engines); do
    log "disk(rootfs): $e"
    fio_one "$e" rootfs /tmp 0 "" randwrite
    fio_one "$e" rootfs /tmp 0 "" randread
    case "$e" in
      apple-native|colima)
        log "disk(bindmount/virtiofs): $e"
        fio_one "$e" bindmount /data 1 "$VT" randwrite
        fio_one "$e" bindmount /data 1 "$VT" randread ;;
    esac
  done
  rm -rf "$VT"
}

# ---- network: container -> macOS host iperf3 ----
net() {
  command -v iperf3 >/dev/null || { log "no host iperf3"; return; }
  pkill -f 'iperf3 -s' 2>/dev/null; ( iperf3 -s >/dev/null 2>&1 & ) ; sleep 1
  local hostip out g
  for e in $(available_engines); do
    case "$e" in apple-native) hostip="192.168.64.1" ;; *) hostip="host.docker.internal" ;; esac
    out=$(_run_with_mount "$e" "" iperf3 -c "$hostip" -t 8 -P 4 2>&1)
    g=$(echo "$out" | awk '/receiver/{v=$(NF-2)" "$(NF-1)} END{print v}')
    csv_row "$CSV" "$e" net_c2host Gbps "${g:-NA}" "$CPUS" "$MEMG" arm64 "iperf3 -P4 -> $hostip"
    log "  net $e -> $hostip : ${g:-NA}"
  done
  pkill -f 'iperf3 -s' 2>/dev/null
}

# ---- build time: --no-cache build of the bench Dockerfile ----
build_time() {
  local D="$REPO_DIR/images/bench/Dockerfile" C="$REPO_DIR/images/bench"
  for e in $(available_engines); do
    local t cmd
    if [ "$e" = apple-native ]; then
      cmd="container build --no-cache -t bench:timing -f $D $C"
    else
      cmd="docker --context $(_docker_ctx "$e") build --no-cache -t bench:timing -f $D $C"
    fi
    # run build via sh -c (its output -> /dev/null); /usr/bin/time's "real" line stays on stderr.
    # gsub comma->dot: this host's locale prints decimals with a comma, which would corrupt the CSV.
    t=$( { /usr/bin/time -p sh -c "$cmd >/dev/null 2>&1"; } 2>&1 | awk '/^real/{gsub(/,/,".",$2); print $2}' )
    csv_row "$CSV" "$e" build_nocache s "${t:-NA}" "$CPUS" "$MEMG" arm64 "bench Dockerfile no-cache"
    log "  build $e -> ${t:-NA}s"
  done
}

case "$PHASE" in
  setup)   setup ;;
  startup) startup ;;
  cpumem)  cpumem ;;
  hostmem) hostmem ;;
  disk)    disk ;;
  net)     net ;;
  build)   build_time ;;
  all)     setup; startup; cpumem; disk; net; build_time; hostmem; log "CSV -> $CSV" ;;
  *) echo "unknown phase: $PHASE"; exit 1 ;;
esac
