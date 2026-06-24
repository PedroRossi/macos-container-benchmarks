# macos-container-benchmarks

A **focused, deep** benchmark of **[Apple `container`](https://github.com/apple/container) vs
[Lima](https://github.com/lima-vm/lima)** on Apple Silicon (macOS 26 Tahoe).

> **Status:** first results are in **[RESULTS.md](./RESULTS.md)**; full design in **[PLAN.md](./PLAN.md)**;
> how to run the harness in **[bench/README.md](./bench/README.md)**.

## The question

For a developer on an Apple Silicon Mac, how do the two container architectures actually compare?

- **Apple `container`** — one lightweight **VM per container** (Apple's optimized kernel, Virtualization.framework).
- **Lima** — one **VM hosting a runtime** (containerd/Docker) that runs many containers.

We measure **startup, CPU/memory, storage (rootfs vs volume vs bind-mount), volumes (correctness + speed),
Docker workflows, Rosetta (amd64) emulation**, and — the headline — **host-side resource usage & how it scales
with container count** (the core micro-VM-vs-shared-VM trade-off), at **2 GB and 4 GB** RAM.

## Scope — deliberately narrow

| In scope | Why |
|---|---|
| Apple `container` 1.0 vs Lima (`vz` + Docker) | The two architectures the question is about |
| **Colima** | Lima-family "what people actually run" data point |
| **OrbStack** (reference bracket only) | Known efficiency ceiling — anchors absolute scale |
| 2 GB / 4 GB RAM | Exposes the per-VM overhead tax (worse at 2 GB) |
| **Docker Desktop** — excluded | Already known heavy/resource-hungry; no new signal |
| Multi-distro sweep — excluded | Apple runs every image on one shared kernel → low signal |

## Relationship to prior art

The **broad** macOS-container shootout (Docker Desktop, OrbStack, Colima, Apple Container, across two macOS
versions) is already well covered by **[`zot24/macos-container-benchmarks`](https://github.com/zot24/macos-container-benchmarks)**.
We don't re-run that — we **reuse its methodology and harness shape** and instead go deep on the Apple-vs-Lima
questions it leaves open: **2 GB behavior, Rosetta tax, host resource usage/scaling, and a novel
"real `dockerd` inside an Apple container" config** that isolates the VM substrate. See
[PLAN.md §11](./PLAN.md#11-relationship-to-prior-art--zot24macos-container-benchmarks) for the full diff.

## Layout

```
PLAN.md          # full benchmark design, matrix, methodology
RESULTS.md       # findings + comparison tables
bench/           # harness: run_all.sh, lib.sh, report.sh, README.md (how to run)
images/bench/    # single Ubuntu bench image (sysbench/fio/iperf3/openssl)
results/         # raw CSVs + logs per run (run-4gb, run-2gb)
```
