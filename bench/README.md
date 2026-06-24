# Benchmark harness

Drives four engines through the same workloads and writes one CSV per run.
See [`../PLAN.md`](../PLAN.md) for design and [`../RESULTS.md`](../RESULTS.md) for findings.

## Engines

| engine | what it is | how the harness reaches it |
|---|---|---|
| `apple-native` | Apple `container` — one micro-VM per container | `container run …` |
| `apple-dockerd` | real `dockerd` **inside** an Apple container (config #2) | `docker --context apple-dockerd …` |
| `lima-docker` | `dockerd` in a Lima `vz` VM | `docker --context lima-docker …` |
| `colima` | `dockerd` in a Colima (Lima) `vz` VM | `docker --context colima …` |
| `orbstack` | OrbStack's own lightweight VM | `docker --context orbstack …` |

`lib.sh` abstracts these: `engine_oneshot`, `engine_run_detached`, `engine_rm`, `host_used_mb`, CSV helpers.

## 1. Bring the engines up (once per machine)

```bash
# Apple container + default kernel
container system start
container system kernel set --recommended

# config #2: dockerd inside an Apple container, socket published to the host
container run -d --name apple-dind --cpus 4 --memory 4G --cap-add ALL \
  -e DOCKER_TLS_CERTDIR="" \
  --publish-socket "$HOME/apple-docker.sock:/var/run/docker.sock" docker:dind
docker context create apple-dockerd --docker "host=unix://$HOME/apple-docker.sock"

# Lima docker VM (vz, 4 vCPU, 4 GiB)
limactl start --name=bench-docker --cpus=4 --memory=4 --vm-type=vz --yes template://docker
docker context create lima-docker --docker "host=unix://$HOME/.lima/bench-docker/sock/docker.sock"

# Colima VM (vz). add --vz-rosetta to enable amd64/Rosetta
colima start --cpu 4 --memory 4 --vm-type vz

# OrbStack (its own VM; auto-creates the `orbstack` docker context)
brew install --cask orbstack && orb start
```

## 2. Build the bench image + run phases

```bash
STAMP=run-4gb bash run_all.sh setup     # build images/bench/Dockerfile on every engine (parallel)
STAMP=run-4gb bash run_all.sh startup   # warm startup latency      (hyperfine, 20 runs)
STAMP=run-4gb bash run_all.sh cpumem    # CPU + memory throughput   (sysbench cpu / memory)
STAMP=run-4gb bash run_all.sh disk      # disk I/O                  (fio: rootfs buffered + bind-mount O_DIRECT)
STAMP=run-4gb bash run_all.sh net       # container -> macOS host   (iperf3 -P4)
STAMP=run-4gb bash run_all.sh build     # image build               (--no-cache, /usr/bin/time)
SCALE_MEMG=1 STAMP=run-4gb bash run_all.sh hostmem   # host RAM delta as N containers added
STAMP=run-4gb bash run_all.sh all       # everything above in order

# 2 GB sweep (apple-native sizes the VM; docker engines cap the container, VM stays 4 GB)
MEMG=2 STAMP=run-2gb bash run_all.sh startup
MEMG=2 STAMP=run-2gb bash run_all.sh cpumem

# render a comparison table from any run's CSV
bash report.sh results/run-4gb/results.csv

# idle host-memory bracket: OrbStack vs Colima (isolated, one engine at a time)
bash idle_compare.sh
```

### Env vars
- `STAMP` — results subdir (`results/<STAMP>/`). `MEMG` — guest/container RAM in GiB (default 4).
- `CPUS` — vCPU (default 4). `REPS` — reserved. `SCALE_MEMG` — per-container RAM for `hostmem` (default 1).

## What each phase measures

| phase | metric(s) | tool | notes |
|---|---|---|---|
| `startup` | warm container start (s) | `hyperfine` | 3 warmup + 20 runs of `run … true` |
| `cpumem` | CPU events/s (1 & 4 threads), mem write MiB/s | `sysbench` | mem write is **cache-bound/noisy** |
| `disk` | 4K random IOPS, rootfs + bind-mount | `fio` | rootfs is buffered (psync) → cache; bind-mount is O_DIRECT (libaio QD64) |
| `net` | container→host throughput (Gbit/s) | `iperf3 -P4` | apple-native→vmnet gateway, docker→`host.docker.internal` (**different paths**) |
| `build` | `--no-cache` image build (s) | `/usr/bin/time` | apt-download-bound → basically tied |
| `hostmem` | host RAM Δ per added container (MB) | `vm_stat` | whole-system delta; **directional** (±~100 MB noise) |

## Caveats (see RESULTS.md for detail)
- Bind-mount tests only run on `apple-native` + `colima` (Lima's default mount is read-only; config #2 host mounts don't reach macOS).
- `hostmem` and `mem write` are directional, not publication-grade — need more reps / longer settle / memory-touching workloads.
- This host's locale uses comma decimals; `build` parsing normalizes them (`gsub(/,/,".")`).

## 3. Tear down (free the VMs)

```bash
container stop apple-dind && container builder stop && container system stop
limactl stop bench-docker
colima stop
rm -f "$HOME/apple-docker.sock"
```
