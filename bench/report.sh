#!/usr/bin/env bash
# report.sh <results.csv> — render a per-metric comparison table across engines.
set -uo pipefail
CSV="${1:?usage: report.sh <results.csv>}"
awk -F, '
BEGIN{ ne=split("apple-native,apple-dockerd,lima-docker,colima",order,",") }
NR>1 { key=$3" ("$4")"; v[key SUBSEP $2]=$5; metrics[key]=1 }
END{
  printf "%-26s", "metric";
  for(i=1;i<=ne;i++) printf "%-16s", order[i];
  print "";
  printf "%-26s", "------";
  for(i=1;i<=ne;i++) printf "%-16s", "------";
  print "";
  n=0; for(m in metrics){ n++; ms[n]=m }
  # simple sort of metric names
  for(a=1;a<=n;a++) for(b=a+1;b<=n;b++) if(ms[b]<ms[a]){t=ms[a];ms[a]=ms[b];ms[b]=t}
  for(a=1;a<=n;a++){ m=ms[a]; printf "%-26s", m;
    for(i=1;i<=ne;i++){ k=m SUBSEP order[i]; printf "%-16s", (k in v)?v[k]:"-" }
    print "" }
}' "$CSV"
