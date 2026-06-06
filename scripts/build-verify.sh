#!/usr/bin/env bash
set -uo pipefail
cd "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p logs out
S="logs/verify-$(date +%H%M%S 2>/dev/null || echo run)"
SUM="${S}-summary.txt"; : > "$SUM"
runs=(
  "e20c-alpine|BOARD=e20c DISTRO=alpine SKIP_FETCH=1"
  "e20c-arch|BOARD=e20c DISTRO=archlinux SKIP_FETCH=1"
  "opiz3-arch|BOARD=opiz3 DISTRO=archlinux SKIP_FETCH=1"
)
for e in "${runs[@]}"; do
  n="${e%%|*}"; v="${e#*|}"; log="${S}-${n}.log"
  echo "===== [$(date +%H:%M:%S)] ${n} (${v})" | tee -a "$SUM"
  if env ${v} scripts/build.sh >"$log" 2>&1; then
    echo "  OK ${n}" | tee -a "$SUM"
  else
    echo "  FAIL ${n} (exit $?) tail:" | tee -a "$SUM"; tail -12 "$log" | sed 's/^/    /' | tee -a "$SUM"
  fi
done
echo "===== images:" | tee -a "$SUM"; ls -lh out/*.img.zst 2>/dev/null | tee -a "$SUM"
