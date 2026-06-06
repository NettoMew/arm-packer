#!/usr/bin/env bash
# scripts/build-all.sh — build every board + variant once, each to its own log.
# First build fetches all source trees; the rest reuse them (SKIP_FETCH=1), except
# opiz3 which fetches its arm-trusted-firmware tree on its first run.
set -uo pipefail
cd "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p logs out
STAMP="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
SUMMARY="logs/refactor-build-summary-${STAMP}.txt"
: > "${SUMMARY}"

# name | env assignments
runs=(
  "e20c|BOARD=e20c"
  "m28k-screen|BOARD=m28k M28K_OLED=1 SKIP_FETCH=1"
  "m28k-noscreen|BOARD=m28k M28K_OLED=0 SKIP_FETCH=1"
  "rock5c|BOARD=rock5c SKIP_FETCH=1"
  "opiz3|BOARD=opiz3"
)

for entry in "${runs[@]}"; do
  name="${entry%%|}"; name="${entry%%|*}"; envs="${entry#*|}"
  log="logs/refactor-${name}-${STAMP}.log"
  echo "===== [$(date +%H:%M:%S)] building ${name}  (${envs}) -> ${log}" | tee -a "${SUMMARY}"
  if env ${envs} scripts/build.sh >"${log}" 2>&1; then
    img="$(ls -1 out/*.img.zst 2>/dev/null | tail -1)"
    sz="$( [ -n "${img}" ] && du -h "${img}" | cut -f1 || echo '?')"
    echo "  OK   ${name}: $(ls -1t out/*.img.zst 2>/dev/null | head -1) (${sz})" | tee -a "${SUMMARY}"
  else
    rc=$?
    echo "  FAIL ${name}: exit ${rc} (see ${log}, tail:)" | tee -a "${SUMMARY}"
    tail -15 "${log}" | sed 's/^/      /' | tee -a "${SUMMARY}"
  fi
done

echo "===== [$(date +%H:%M:%S)] all builds done. Images:" | tee -a "${SUMMARY}"
ls -lh out/*.img.zst 2>/dev/null | tee -a "${SUMMARY}"
