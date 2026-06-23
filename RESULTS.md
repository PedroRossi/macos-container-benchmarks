# Results — Apple `container` vs Lima (first run)

**Run:** `results/run-4gb/` · 2026-06-23 · macOS 26.2 (25C56) · Apple M4 Pro, 12 cores, 24 GiB.
**Config:** 4 vCPU, 4 GiB per engine, arm64, single Ubuntu 24.04 bench image (same Dockerfile per engine).
**Engines:** `apple-native` (container 1.0.0) · `apple-dockerd` (dockerd in an Apple container, config #2) ·
`lima-docker` (Lima 2.1.1, vz) · `colima` (0.10.1, vz). Docker CLI 29.2.1.

> Status: **partial**. Startup + CPU are solid (repeated). Memory + host-scaling are **directional** (single
> run / whole-system sampling — see caveats). Disk, volumes, network, build, Rosetta, and the 2 GB sweep are
> not yet run. This is the first slice of [PLAN.md](./PLAN.md).

## Comparison table

| metric | apple-native | apple-dockerd | lima-docker | colima |
|---|--:|--:|--:|--:|
| **startup warm** (s) | **0.709** | 0.148 | 0.161 | 0.127 |
| cpu 1-thread (eps) | 5172 | 5217 | 5112 | 5048 |
| cpu 4-thread (eps) | 18303 | 18535 | 18520 | 18661 |
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
Disk I/O (rootfs vs named-volume vs bind-mount, `fio`), volume correctness + speed, networking (`iperf3`),
image build time, real-world (`pgbench`/`redis`/`wrk`), **Rosetta amd64 tax**, the **2 GB** RAM sweep, and a
hardened host-scaling pass. OrbStack reference bracket not yet installed.

## Reproduce
```bash
bench/run_all.sh setup      # build the bench image on each engine
bench/run_all.sh startup    # warm startup (hyperfine, 20 runs)
bench/run_all.sh cpumem     # sysbench cpu + memory
SCALE_MEMG=1 bench/run_all.sh hostmem   # host memory scaling
bench/report.sh results/<stamp>/results.csv
```
