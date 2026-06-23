# Benchmark Plan — Apple `container` vs Lima on macOS

**Status:** DRAFT for discussion (not yet executing). Last updated 2026-06-23.

A **narrow, deep** comparison of [apple/container](https://github.com/apple/container) vs
[lima-vm/lima](https://github.com/lima-vm/lima) as Linux-container substrates on Apple Silicon —
across **2 GB / 4 GB** guest RAM, with explicit checks for **Docker usage**, **volumes/bind-mounts**,
**Rosetta (amd64) emulation**, and — the headline — **host-side resource usage & scaling**.

**Scope is deliberately tight.** The broad macOS-container product shootout (Docker Desktop, OrbStack,
Colima, Apple Container, across two macOS versions) is already well covered by
[`zot24/macos-container-benchmarks`](https://github.com/zot24/macos-container-benchmarks) — see §11. We
don't re-run that. We focus on the two architectures the question is actually about, add **Colima** as a
Lima-family "real-world defaults" point, and use **OrbStack** as a single efficiency **reference bracket**.
We reuse zot24's methodology and harness shape rather than reinventing them.

---

## 1. Goal & the questions we want to answer

For a developer on an Apple Silicon Mac choosing between these two:

1. **Startup** — how fast does a container become usable (cold vs warm)?
2. **Compute** — CPU & memory performance of the workload inside the guest.
3. **Storage** — disk I/O on the container rootfs, named volumes, and host bind-mounts (three separate paths).
4. **Volumes** — do host mounts *work correctly* (perms, persistence, large + many-small files) and how fast?
5. **Docker** — can you actually run a Docker workflow on each, and how does it perform?
6. **Networking** — throughput/latency container↔host and container↔container.
7. **Rosetta** — does `linux/amd64` run on each, and what's the emulation tax vs native arm64?
8. **Host resource usage & scaling — the headline.** macOS-side RAM/CPU footprint, idle vs under load, and
   **how it scales as you add containers** (the core architectural trade-off: N micro-VMs vs 1 shared VM).

---

## 2. The two systems — and why this is *not* apples-to-apples

| | **Apple `container`** | **Lima** |
|---|---|---|
| Model | **One micro-VM per container** | **One VM hosting a runtime; many containers** |
| Hypervisor | Virtualization.framework | Virtualization.framework (`vz`) or QEMU |
| Guest kernel | Apple's optimized Linux **6.14.9**, *same for every image* | The VM's distro kernel (default Ubuntu LTS) |
| Container CLI | `container ...` (its own; **not** Docker) | `nerdctl` (containerd) or **real `docker`** (dockerd in VM) |
| Docker API/socket | **None** (shim only — Socktainer) | Native (`dockerd`, forwarded socket) |
| Default CPU/RAM | `--cpus 4`, `--memory 1g` (per container-VM) | `cpus: min(4,host)`, `memory: min(4GiB, ½ host)` (per VM) |
| Rosetta | `--arch amd64` (Rosetta 2) | `rosetta.enabled+binfmt` (vz only) |
| Reference versions | `container` 1.0.0 (Jun 2026) | Lima 2.1.3 (Jun 2026) |

**Scope note — single image, no distro sweep.** We standardize on **one Ubuntu-based bench image** across
all engines (Lima runs its default Ubuntu VM; the workload container is the same image everywhere). We
considered an Ubuntu/Debian/Fedora sweep and **dropped it**: for Apple `container` every image runs on the
*same* Apple kernel, so cross-distro perf is largely redundant, and the marginal Lima-side signal (kernel/fs
differences) doesn't justify 3× the runtime. zot24 likewise used a single image. This keeps the focus on the
substrate.

**Two asymmetries we must handle deliberately — these drive the design:**

### Asymmetry A — "Docker" exists natively only on Lima, but we can mirror it on Apple
Apple `container` is **not** Docker and exposes **no Docker socket/API** (the request was closed "not planned").
We handle "Docker on both" along two tracks:

- **Native-model comparison** — `container run/build` (Apple's per-container-VM model) vs `docker` on Lima.
  Shows what each *intended* architecture gives you.
- **Controlled-substrate comparison (the clean one)** — run **real `dockerd` inside an Apple container**.
  Because each Apple container is its own VM, this turns Apple `container` into "a Linux VM hosting dockerd" —
  the *same shape as Lima/Colima* — so the **only** remaining variable is the VM substrate.

  **Exposure mechanism matters:** a unix socket's endpoint lives in the *guest kernel*; virtiofs/bind-mounts
  share file data, **not** live socket connections — so a *mounted* `docker.sock` does **not** work (this is
  exactly why Lima/Colima *forward* the socket over SSH/vsock rather than sharing a folder). We expose the
  in-container `dockerd` via either:
  - **TCP** — `dockerd` on `tcp://0.0.0.0:2375`; macOS 26 gives each container a routable IP, so the host uses
    `DOCKER_HOST=tcp://<container-ip>:2375`. Simplest.
  - **SSH-forwarded socket** — forward the guest `/var/run/docker.sock` to a host `docker.sock` (exact Colima mirror).

  **Feasibility risk (spike first):** Apple's kernel is minimal — `dockerd` needs `overlay`, `br_netfilter`,
  `iptables/nat`, bridge, cgroups v2. If a module is missing, dockerd won't start. 1.0 also trimmed default
  capabilities. **Testable in ~10 min — gating P0.**

- **Docker-tooling compatibility (footnote)** — can `docker` CLI / Compose / Testcontainers attach? Lima/Colima:
  yes. Apple native: only via the [Socktainer](https://github.com/socktainer/socktainer) shim (partial) —
  a compat matrix, not a perf number.

### Asymmetry B — "RAM" means per-container (Apple) vs per-whole-VM (Lima)
- `container --memory 4g` sizes **one container's VM**.
- Lima `memory: 4GiB` sizes the **whole VM** that hosts *all* containers.
- **Implication:**
  - **Single-container tests (most of the suite):** give both the same sandbox — one workload container with
    2/4 GB + 4 vCPU. Clean and fair.
  - **Multi-container scaling:** the models diverge (N×VMs vs 1×VM). Isolated to the **scaling test** (§6.4),
    where that divergence is the headline, not noise.

---

## 3. Environment (confirmed on this machine)

- **Host:** Apple **M4 Pro**, 12 logical cores, **24 GB** RAM, actively cooled.
- **OS:** macOS **26.2** (Tahoe), build 25C56 — Apple `container`'s primary target; full networking.
- **Installed:** `limactl` 2.x, `lima`, `colima`, `docker` CLI (Homebrew).
- **To install:** Apple `container` 1.0.x; **OrbStack** (bracket); host bench tools `hyperfine fio sysbench iperf3`.
- **RAM budget note:** 24 GB total → ~18 GB usable for VMs. The scaling test (§6.4) realistically tops out
  around **~3–4 concurrent 4 GB** (Apple) or **~6–8 × 2 GB** before swap — we **cap before pressure and report it**.

**Pinned/equalized across every run:**
- Lima backend = **`vz`** only (matches Apple's substrate; QEMU out of scope).
- Lima mount = **virtiofs** (vz default); Lima engine = **`docker`** template (primary).
- **Single Ubuntu-based bench image** (pinned by digest) on every engine.
- **Colima** included as a Lima-family "real-world defaults" point (`vz` + virtiofs + Rosetta).
- **OrbStack** included as a single efficiency **reference bracket** — docker-based perf + resource-usage (§6.4)
  only; **not** in the RAM×arch matrix. (**Docker Desktop excluded** — already known heavy; see §11/zot24.)
- **4 vCPU everywhere** so only RAM varies on the RAM axis. Same image digest, recorded tool versions.

---

## 4. Variables & test matrix

**Variables**

| Axis | Values |
|---|---|
| Engine config | (1) Apple native `container` · (2) Apple+dockerd · (3) Lima docker · (4) Colima — all `vz` (+ OrbStack bracket) |
| Guest RAM | **2 GiB** · **4 GiB** (applied selectively, below) |
| Arch | **arm64** (native) · **amd64** (Rosetta) |

**RAM is applied selectively** — only metrics where RAM plausibly changes the outcome run at *both* 2+4 GB
(memory, startup, build, host-overhead §6.4, page-cache-sensitive volume tests, density/viability). RAM-insensitive
metrics (CPU, network, Rosetta-CPU ratio) run at **4 GB only** — running them twice is wasted runtime.

The engine axis isn't a blind multiply: the **native-model head-to-head** (Apple native vs Lima docker) is the
spine; **Apple+dockerd vs Lima docker vs Colima** is the *controlled-substrate* trio; **OrbStack** appears only as
a bracket in docker-perf + §6.4. We **tier** by cost/signal:

**Tier A — Core sweep** (cheap, fast, automatable): startup · CPU · memory · quick volume I/O. All engines,
both RAM sizes (where RAM-relevant), arm64.

**Tier B — Focused** (expensive, **4 GB · arm64** unless noted): full `fio` storage matrix
(rootfs/volume/bind-mount) · network (`iperf3`) · OCI image build · real-world (`pgbench`/`redis-benchmark`/`wrk`).

**Tier C — Feature/correctness** (pass/fail + notes): Docker-tooling compat · volume correctness · Rosetta correctness.

**Rosetta perf** (§6.5): focused **amd64-vs-arm64 ratio** on CPU/memory/build, **4 GB**, both Apple & Lima.

---

## 5. Workloads, metrics & tools

All in-guest tools run from the **single Ubuntu-based bench image** (so `fio/sysbench/iperf3` etc. are present
and we never confound musl vs glibc or different distros).

| Dimension | Tool / command | Where | Key metrics |
|---|---|---|---|
| **Startup — warm** | `hyperfine --warmup 3 --runs 30 '<tool> run --rm <img> true'` | host | mean ± σ, p95 |
| **Startup — cold** | `hyperfine --prepare '<stop VM/system>' '<start>+run'` | host | mean ± σ |
| **CPU** | `sysbench cpu --cpu-max-prime=20000 --threads={1,4}` | guest | events/s |
| **Memory** | `sysbench memory --block-size=1M --total-size=4G --oper={read,write}` | guest | MB/s |
| **Disk (rootfs/volume/bind)** | `fio --direct=1` 4K randrw QD64 + 1M seq, per storage path | guest | IOPS, MB/s, lat |
| **Volume real-world** | `git clone --depth1`, `tar x` (many small), `dd` 4 GB (one large) | guest→mount | wall-clock |
| **Network** | `iperf3 -P4` (c→host, c→c), `ping -c100`, nginx+`curl -w time_starttransfer` | guest | Gbps, ms, TTFB |
| **Build** | `hyperfine '<tool> build --no-cache'` + warm rebuild | host | mean ± σ |
| **Real-world** | `pgbench -c16 -T60`, `redis-benchmark -P16`, `wrk -t8 -c200 -d30s` | guest | TPS, RPS, p99 |
| **Host resource use** | `footprint <pid>`, `vmmap --summary`, `sudo powermetrics --samplers tasks,cpu_power` | host | phys_footprint MB, CPU ms/s, idle C-state |
| **Rosetta tax** | same CPU/mem/build bench, `--arch/--platform amd64` vs `arm64` | guest | ratio vs native |

**Storage paths are three separate things** (the #1 benchmarking mistake is testing one and generalizing):
**rootfs** (overlay) · **named volume** (Apple virtio-block/ext4; Docker volume) · **host bind-mount**
(virtiofs). We label every `fio` number with its path.

---

## 6. The explicit asks, in detail

### 6.1 Docker usage on both
Four configs (all `vz`-class substrate). **#2–#4 isolate the substrate; #1 vs the rest shows Apple's native model.**
- **#1 Apple native** — `container run/build` on the OCI bench workloads (Apple's per-container-VM model).
- **#2 Apple + dockerd (Colima-analog)** — real `dockerd` inside an Apple container; host `docker` CLI via
  `tcp://<container-ip>:2375` or SSH-forwarded `docker.sock`. *(Gated by the P0 spike — see §2 Asymmetry A.)*
- **#3 Lima docker** — `limactl start template:docker`; `docker context` over the forwarded socket.
- **#4 Colima** — `colima start --vm-type vz`; its bundled docker context.
- **OrbStack** — included here as the efficiency reference bracket (its own docker context).
- **Compat footnote** — point `docker` CLI / Compose / Testcontainers at each; for Apple native, via the
  [Socktainer](https://github.com/socktainer/socktainer) shim. Record what works vs breaks (a matrix, not a speed).

### 6.2 Do volumes work?
For each engine, a **correctness checklist** before any perf number (single bench image):
- bind-mount a host dir → read & **write** back to host; verify on host.
- **permissions / uid-gid** mapping correctness; ownership round-trip.
- **persistence** across container restart (named volume) and across VM restart.
- **large file** (4 GB `dd`) integrity (checksum) — virtiofs large-file edge cases are a known risk.
- **many small files** (`tar x` of a source tree) — the bind-mount worst case.
- **single-file mount** — Apple can't mount an individual file (only the parent dir); record as a limitation.
Then perf via the `fio` + real-world rows in §5, per storage path.

### 6.3 Rosetta emulation on both
- **Lima:** `vmType: vz` + `rosetta.enabled: true` + `rosetta.binfmt: true` (or `--rosetta`).
- **Apple:** `container run --arch amd64 ...` (Rosetta 2 built in).
- **Correctness** (Tier C): does the `linux/amd64` bench image run to completion on each?
- **Perf tax** (§6.5): amd64 vs arm64 ratio on `sysbench cpu` (int), `openssl speed` (crypto), a FP/vector bench
  (worst case), and a build. Report **per-workload ratios** (Rosetta overhead varies a lot by instruction mix).
- Fairness note: Rosetta translates **userspace only**; the guest kernel stays native arm64 on both.

### 6.4 Host-side resource usage & scaling — *the headline* (flagged as a must)
Independent of engine internals; arm64; bench image. Metrics: macOS **phys_footprint** (`footprint` /
`vmmap --summary` — guest RAM is wired/compressed, so plain RSS lies), CPU + energy
(`powermetrics --samplers tasks,cpu_power`).
- **Daemon idle (nothing running):** Apple's per-container VMs *don't exist until you run one* — idle cost is
  just its helper daemon, while **Lima/Colima hold a full VM in RAM even idle.** Expect this to **favor Apple**
  for bursty use. Measure both at zero containers.
- **Per-container scaling:** phys_footprint + CPU at **N = 1, 2, 4 (, 8 if RAM allows)** identical containers, at
  **2 GB and 4 GB** each. Apple grows ~linearly (N micro-VMs, each own kernel+init); Lima stays ~flat (one VM).
  **The key deliverable is the crossover:** bursty/low-N favors Apple; dense/high-N favors Lima. **Cap before swap
  on this 24 GB host; report the cap.**
- **Idle CPU under a running-but-quiet container:** does Apple's VM truly sleep (high package C-state) vs busy-poll?
- **Overhead fraction (2 GB vs 4 GB):** guest `MemTotal`/`MemAvailable` vs `--memory` — fixed VM overhead is a
  *bigger slice* of a 2 GB VM, so this is where the per-VM tax bites hardest.
- **Reference bracket:** **OrbStack** (~200 MB idle) measured here too, so Apple/Lima numbers have an absolute
  scale (behaves Lima-like: flat under scaling).

### 6.5 Rosetta perf subset
4 GB · both Apple & Lima: run §6.3 perf benches in arm64 then amd64; report ratio + absolute numbers.

---

## 7. Methodology & rigor

- **Repetitions:** `hyperfine` (warmup 3, ≥20 runs) for host-launchable; in-guest tools looped ≥10–12 (borrow
  zot24's "4 runs × 3 iters = 12 points/metric"), `--ramp_time`/warmup on, discard first.
- **Report distributions:** median + stddev + **p95/p99**, not just means. Stated outlier rule (drop >5× / <0.01× median).
- **Thermal (Apple Silicon's biggest trap):** actively-cooled M4 Pro helps; still insert cooldowns,
  **interleave engines A,B,A,B** (not all-A-then-all-B) so throttling can't bias one, watch
  `powermetrics --samplers thermal`, discard throttled runs.
- **Cache hygiene:** `fio --direct=1`; size datasets > guest RAM where relevant; drop caches in-guest; always
  separate **cold vs warm**; **pre-pull images** (never fold pull time into "startup").
- **Pinning:** record macOS build, chip, all tool/runtime/kernel versions (`uname -r` differs per engine!), image
  **digest**, resource caps, rep counts. Disable Spotlight (`mdutil -a -i off`), Time Machine, cloud sync,
  browsers; AC power; no Low Power Mode.
- **Equal sandboxes:** 4 vCPU + matched RAM both sides; same image digest.

---

## 8. Deliverables & repo structure

```
macos-container-benchmarks/
├── PLAN.md                  # this file
├── README.md                # scope, zot24 framing, results summary + charts
├── bench/
│   ├── run_all.sh           # orchestrator (tiers, interleaving, cooldowns)
│   ├── lib.sh               # timing, CSV, env capture, footprint sampling
│   ├── 00_setup.sh          # install tools, pull image by digest, build bench image
│   ├── 10_startup.sh  20_cpu_mem.sh  30_disk.sh  40_volume.sh
│   ├── 50_network.sh  60_build.sh    70_realworld.sh  80_host_overhead.sh
│   ├── 90_rosetta.sh        # amd64 vs arm64
│   └── feature_checks.sh    # docker-compat + volume-correctness + rosetta-correctness (pass/fail)
├── images/
│   └── bench/Dockerfile     # fio/sysbench/iperf3/openssl/pgbench/redis/wrk, multi-arch (one image)
├── configs/
│   ├── lima-2gb.yaml  lima-4gb.yaml        # vz + docker + virtiofs + (rosetta variant)
│   └── apple-*.md                          # container run flag sets
├── results/<timestamp>/*.csv               # raw, one row per (engine,ram,arch,workload,rep)
└── analysis/                               # notebook/script → tables + charts
```

**Outputs:** raw CSVs + results tables (median/p95) + charts + a written findings summary, reproducible from
`run_all.sh`. Methodology/harness shape borrowed from zot24 (§11).

---

## 9. Suggested execution phases (after we agree on this plan)

1. **P0 Setup, smoke & the gating spike** — install `container` + OrbStack + bench tools, build the bench image,
   one container running on each engine, capture env. **Gating spike:** can `dockerd` run inside an Apple
   container and be reached from the host (TCP/SSH)? If a kernel module is missing, decide the fallback
   (Socktainer, or drop config #2). (~½ day)
2. **P1 Feature/correctness (Tier C)** — Docker-compat, volume-correctness, Rosetta-correctness. *First — it tells
   us what's runnable before we spend time on perf.* (~½ day)
3. **P2 Core sweep (Tier A)** — startup/CPU/mem/quick-volume across engines × RAM. (~1 day)
4. **P3 Focused (Tier B)** — disk/network/build/real-world. (~1–2 days)
5. **P4 Host resource usage & scaling (§6.4)** + **Rosetta perf (§6.5)**. (~1 day)
6. **P5 Analysis & write-up** — charts, README, findings. (~1 day)

---

## 10. Decisions & remaining open questions

**Resolved:**
- **Docker** → native-model comparison **+** dockerd-in-Apple controlled-substrate config (TCP/SSH), pending the
  P0 spike. Socktainer = optional compat footnote.
- **Contenders** → Apple `container` + Lima(`vz`+docker) + **Colima** + **OrbStack (reference bracket)**.
  **Docker Desktop excluded** (known heavy/resource-hungry — covered by zot24).
- **Distros** → **dropped**; single Ubuntu-based bench image (Apple shares one kernel → multi-distro is low-signal).
- **RAM** → keep **2 GB + 4 GB**, **applied selectively** (RAM-sensitive metrics at both; CPU/net/Rosetta-CPU at 4 GB only).
- **Lima backend** → **`vz` only**.
- **Resource usage (§6.4)** → promoted to **headline deliverable** (idle, per-container scaling, bursty-vs-dense
  crossover, 2 GB overhead fraction).
- **RAM semantics** → main suite single-container with equal sandboxes; N-VM-vs-1-VM isolated to §6.4.

**Still open (have defaults, override anytime):**
- **Lima engine** → `docker` primary; also include **containerd+nerdctl** (Lima default) as a secondary point? *(default: skip)*
- **CPU count** → pin **4 vCPU** everywhere, or also sweep 2 vs 8 (interacts with the per-VM model)? *(default: pin 4)*
- **Depth vs breadth** → the Tier A/B/C split, or the full matrix incl. amd64 everywhere (much longer)? *(default: tiered)*

---

## 11. Relationship to prior art — `zot24/macos-container-benchmarks`

We deliberately **narrow** where zot24 goes wide. zot24 is a **broad product shootout**; this is a **deep
two-architecture dissection**. Notably, zot24 doesn't test **plain Lima** (only Colima, which wraps it), and ran
Apple Container **0.11.0** (pre-1.0).

| Dimension | zot24 | This plan |
|---|---|---|
| Core question | Which of 4 macOS apps is fastest | Apple `container` vs **Lima** as *architectures* |
| Contenders | Colima, Docker Desktop, OrbStack, Apple 0.11.0 | Apple `container` **1.0**, Lima(`vz`+docker), Colima, **+ OrbStack bracket** |
| Lima itself | not tested (Colima only) | tested directly + Colima |
| Docker Desktop | included | **excluded** (known heavy — no new signal) |
| RAM | fixed 4 GB | **swept 2 GB + 4 GB** (selectively) |
| Distros | single fixed image | single fixed image (matched approach) |
| Rosetta / amd64 | not tested | **first-class** (correctness + per-workload tax) |
| Host overhead / N-scaling | not measured | **phys_footprint + powermetrics; N = 1,2,4,8** (headline) |
| dockerd-in-Apple substrate | — | **novel controlled-substrate config** |
| Storage paths | one "volume I/O" (dd-style) | **rootfs vs named-vol vs bind-mount**, fio `--direct=1` |
| Compute / real-world | startup/volume/net/build | + **sysbench, pgbench/redis/wrk** |
| Volume correctness | speed only | **correctness checklist** then speed |
| macOS versions | two (Sequoia + Tahoe) | one (Tahoe 26.2) — *narrower here* |
| Status | done, results + charts | plan (this doc) |

**We reuse from zot24:** its methodology (4 runs × 3 iters = 12 pts/metric; outlier filter >5× / <0.01× median;
clear volume data between runs) and repo shape (`benchmark.sh` + `aggregate.py` + `charts.py` + `results/`). Also
its documented gotcha — Apple's *builder* had no outbound network so the `apk add` build test was skipped on
0.11.0; **we verify whether 1.0 fixed this** before trusting build numbers.

**What zot24 covers that we intentionally don't:** Docker Desktop, two macOS versions — i.e. the breadth. Our bet
is that the unanswered questions worth our time are the **Apple-vs-Lima depth**: 2 GB behavior, Rosetta tax,
host resource usage/scaling, and the dockerd-in-Apple substrate experiment.
