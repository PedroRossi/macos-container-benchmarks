# Single bench image used by every engine (built per-engine from the same Dockerfile).
# Ubuntu so fio/sysbench/iperf3/openssl are all packaged (no musl/glibc confound).
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      sysbench fio iperf3 openssl ca-certificates curl git procps \
  && rm -rf /var/lib/apt/lists/*
CMD ["sleep", "infinity"]
