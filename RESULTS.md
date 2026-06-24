# Results — Apple `container` vs Lima (first run)

**Run:** `results/run-4gb/` · 2026-06-23 · macOS 26.2 (25C56) · Apple M4 Pro, 12 cores, 24 GiB.
**Config:** 4 vCPU, 4 GiB per engine, arm64, single Ubuntu 24.04 bench image (same Dockerfile per engine).
**Engines:** `apple-native` (container 1.0.0) · `apple-dockerd` (dockerd in an Apple container, config #2) ·
`lima-docker` (Lima 2.1.1, vz) · `colima` (0.10.1, vz). Docker CLI 29.2.1.

> Status: Startup, CPU, volumes, Rosetta, disk, network, build, and the **2 GB sweep** are done. Memory
> bandwidth + host-scaling are **directional** (see caveats). Remaining: real-world (pgbench/redis/wrk), a
> hardened host-scaling pass, the OrbStack bracket. Covers most of [PLAN.md](./PLAN.md).

## Comparison table

| metric | apple-native | apple-dockerd | lima-docker | colima |
|---|--:|--:|--:|--:|
| **startup warm** (s) | **0.709** | 0.148 | 0.161 | 0.127 |
| cpu 1-thread (eps) | 5172 | 5217 | 5112 | 5048 |
| cpu 4-thread (eps) | 18303 | 18535 | 18520 | 18661 |
| disk bind-mount randwrite (IOPS) | 16.1k | — | — | 13.5k |
| disk bind-mount randread (IOPS) | 34.1k | — | — | 31.5k |
| network c→host (Gbit/s) | 66.5* | NA | 2.94 | 2.85 |
| build no-cache (s) | ~17–25 | ~17 | ~17 | ~16 |
| mem write (MiB/s) *(noisy)* | 185191 | 128394 | 113675 | 99413 |
| host mem Δ, N=1 container (MB) | +254 | +258 | −5 | +86 |
| host mem Δ, N=2 containers (MB) | **+877** | +133 | −4 | +61 |
| host mem Δ, N=3 containers (MB) | **+564** | +106 | −24 | +28 |

(host-mem scaling used 1 GiB idle containers to stay within 24 GB.)

## Findings

### 1. Startup — the clearest architectural result *(solid: 20 runs each)*
`apple-native` warm-starts in **0.71 s ± 0.05**, vs **0.13–0.16 s** for every shared-VM engine —
**~4.4–5.6× slower**. Cause: each `container run` boots a fresh micro-VM, while the others start a process
in an already-running VM. **Crucially, `apple-dockerd` (≈0.15 s) matches Lima/Colima** — i.e. running
`dockerd` *inside* an Apple container erases the gap. So the cost is the **per-container-VM model**, not
Apple's stack. This is the central trade-off: isolation-per-container vs fast start.

### 2. CPU — no meaningful difference *(solid)*
All four are within ~3% (1-thread ~5.0–5.2k eps; 4-thread ~18.3–18.7k eps). Once a container is running,
CPU passes through the shared `vz` hypervisor identically. CPU is **not** a differentiator here.

### 3. Host memory scaling — the headline *(directional; needs hardening)*
`apple-native` is the **only** engine whose host memory grows with container count: roughly **+250–440 MB
per added container** (each is a separate micro-VM carrying its own kernel+init, even when idle). The
shared-VM engines — `lima-docker`, `colima`, **and `apple-dockerd`** — stay essentially **flat** (a new
container is just a process in the existing VM).

This confirms the architectural prediction, but the numbers are noisy: it's a whole-system memory delta
(so macOS background activity adds ±~100 MB), the containers were idle (`sleep infinity`, so they barely
touch their 1 GB), and settle time was only 3 s — hence the non-monotonic `apple-native` N=2 (+877) > N=3
(+564). The **direction and ~per-VM magnitude are real**; exact figures need more reps, longer settle, and
memory-touching workloads. Note the practical implication on this 24 GB host: many concurrent
`apple-native` containers exhaust RAM far sooner than the shared-VM engines.

### 4. Memory bandwidth — **inconclusive, ignore for now** *(noisy)*
The single-run `sysbench memory` figures (99k–185k MiB/s) are cache-dominated and unreplicated; the apparent
`apple-native` lead is not trustworthy. Deferred to a proper STREAM / longer-fio treatment.

### 5. Volumes (host bind-mounts) — they behave very differently *(solid: correctness)*
| engine | read host file | write to host | host sees write | seq write speed |
|---|:--:|:--:|:--:|--:|
| apple-native | ✓ | ✓ | ✓ | ~1.5 GB/s |
| colima | ✓ | ✓ | ✓ | ~1.6 GB/s |
| lima-docker | ✓ | ✗ | ✗ | — (**default mount is read-only**) |
| apple-dockerd (config #2) | ✗ | ✗ (into dind VM only) | ✗ | — (**host mounts don't cross 2 VM layers**) |

Two caveats that directly answer "do volumes work":
- **Lima's `docker` template mounts `$HOME` read-only by default** — `docker run -v` can read host files but not
  write; needs `mounts: [{location: "~", writable: true}]`.
- **Config #2 host bind-mounts don't reach macOS.** `dockerd` runs inside the Apple VM, so `-v $HOME/x:/data`
  resolves against the *dind VM's* filesystem, not the host. To make it work you'd first mount the host dir into
  the apple-dind container (`container run -v`), then `-v` that path in the nested `docker run` — a two-level mount.
- apple-native and Colima both do full read-write host mounts out of the box at ~1.5 GB/s sequential (`dd` 256 MB).

### 6. Rosetta (amd64 emulation) — works on both; ~11% CPU tax *(solid on Apple)*
- **apple-native:** `container run --arch amd64 --rosetta` runs x86_64 images. sysbench cpu:
  **amd64 = 88% (1-thread) / 89% (4-thread) of native arm64** → ~11–12% tax for integer CPU.
- **Colima (Lima-family):** with `--vz-rosetta`, `docker run --platform linux/amd64` runs x86_64 (`uname -m`
  → `x86_64`) ✓. Same underlying Apple Rosetta-for-Linux; comparable tax expected (not separately measured yet).
- Both translate userspace only; the guest kernel stays native arm64.

### 7. Disk I/O (`fio`) *(bind-mount solid; rootfs is cache-bound)*
- **Bind-mount (virtiofs, O_DIRECT, 4K QD64)** — the meaningful host-shared-storage number: apple-native
  randwrite **16.1k IOPS** / randread **34.1k**; colima randwrite **13.5k** / randread **31.5k**. apple-native's
  virtiofs is ~15–20% faster on random write. (lima-docker omitted — read-only mount; config #2 — host mount unreachable.)
- **Rootfs (overlay, buffered)** — 314k–701k IOPS / 1.3–2.9 GB/s across engines: these are **page-cache numbers,
  not storage** (buffered 4K writes never hit the device in 20 s), so "all fast, not a differentiator." A true
  rootfs-device test needs O_DIRECT (overlay doesn't support it) or a dataset > RAM.

### 8. Network — container → macOS host (`iperf3 -P4`) *(real gap, caveated paths)*
- **apple-native 66.5 Gbit/s** (to vmnet gateway 192.168.64.1) vs **lima-docker 2.94 / colima 2.85 Gbit/s** (via
  `host.docker.internal`). The Lima-family Docker path runs through the VM's userspace port-forwarding (~3 Gbit/s
  ceiling); apple-native's vmnet path is far faster. *(\*Caveat: the target addresses differ, so it isn't a
  perfectly controlled comparison — but the order-of-magnitude gap matches the architectures.)*
- **apple-dockerd NA** — `host.docker.internal` inside the dind VM doesn't reach macOS (config #2 two-layer).

### 9. Build time — `--no-cache` bench image *(tied; apt-download-bound)*
All ~**16–25 s** (apple-native 17–25, others ~16–17). Dominated by `apt-get` downloads, so the spread is mostly
network variance, not the engine. Notably **Apple's builder completed the build** — confirming outbound network
works in 1.0 (zot24 had to skip this on 0.11.0).

### 10. 2 GB vs 4 GB sweep — single-container perf is RAM-insensitive *(solid)*
At 2 GB, startup/CPU/memory are **statistically unchanged** from 4 GB (apple-native startup 0.75 s vs 0.71 s —
within noise; CPU identical). RAM size barely affects *single-container* performance; its real impact is on
**host footprint / density** (§3) — fewer large `apple-native` VMs fit before swap. (For docker engines "2 GB"
caps the container while the VM stays 4 GB — the plan's RAM-semantics asymmetry; for apple-native it sizes the whole VM.)

## Qualitative findings (from bring-up)

- **Config #2 works end-to-end.** `dockerd` runs inside an Apple container and is reachable from the host via
  Apple's built-in **`--publish-socket`** forwarder (no TCP/SSH hack needed). It runs real workloads:
  `hello-world`, Alpine with bridge networking (`172.17.0.2/16`), **internet via NAT**, `overlayfs`, cgroup v2.
  Boot-to-reachable ≈ **17 s**. This validates the user's "replicate Colima with Apple's container" idea.
- **Apple's builder has outbound network in 1.0.** `container build` ran `apt-get` successfully — the
  builder-has-no-network limitation zot24 hit on 0.11.0 is **fixed**.
- **Guest kernel is `6.18.15`** (kata-static 3.28.0, installed via `container system kernel set --recommended`),
  newer than the 6.14.9 cited in pre-run research.

## Not yet measured (next slices of the plan)
Real-world workloads (`pgbench`/`redis-benchmark`/`wrk`), a hardened host-scaling pass (more reps, longer settle,
memory-touching workloads), a named-volume `fio` path, Colima's Rosetta tax, and the OrbStack reference bracket.

## Reproduce
```bash
bench/run_all.sh setup      # build the bench image on each engine
bench/run_all.sh startup    # warm startup (hyperfine, 20 runs)
bench/run_all.sh cpumem     # sysbench cpu + memory
SCALE_MEMG=1 bench/run_all.sh hostmem   # host memory scaling
bench/report.sh results/<stamp>/results.csv
```
