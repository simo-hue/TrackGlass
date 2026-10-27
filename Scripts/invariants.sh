#!/bin/bash
# M9.3: replay every fixture with pseudo-random datagram loss and check the safety invariants
# (every button down has an up, every began has an ended/cancelled, nothing after the final lift-off).
# Usage: Scripts/invariants.sh [path-to-tgreplay] [drop-fraction] [last-seed]
set -euo pipefail
shopt -s nullglob

TGREPLAY="${1:-${TRACKGLASS_TGREPLAY:-}}"
# Resolve a relative tool path before leaving the caller's directory.
if [[ -n "$TGREPLAY" && "$TGREPLAY" != /* ]]; then
  TGREPLAY="$(cd "$(dirname "$TGREPLAY")" && pwd)/$(basename "$TGREPLAY")"
fi
cd "$(dirname "$0")/.."
DROP="${2:-0.05}"
LAST_SEED="${3:-20}"

if [[ -z "$TGREPLAY" ]]; then
  DERIVED="${TMPDIR:-/tmp}/trackglass-replay-ci"
  xcodebuild -project Trackglass.xcodeproj -scheme tgreplay -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED" build >/dev/null
  TGREPLAY="$DERIVED/Build/Products/Debug/tgreplay"
fi

fixtures=0
runs=0
recordings=(Tests/Fixtures/*.tgrec)
if [[ ${#recordings[@]} -eq 0 ]]; then
  echo "no .tgrec fixtures found" >&2
  exit 1
fi
for recording in "${recordings[@]}"; do
  stem="${recording%.tgrec}"
  settings="$stem.settings.json"
  [[ -f "$settings" ]] || { echo "missing settings for $recording" >&2; exit 1; }
  fixtures=$((fixtures + 1))
  for seed in $(seq 1 "$LAST_SEED"); do
    if ! "$TGREPLAY" invariants "$recording" --settings "$settings" --drop "$DROP" --seed "$seed" >/dev/null; then
      echo "invariant violation: $(basename "$recording") drop=$DROP seed=$seed" >&2
      exit 1
    fi
    runs=$((runs + 1))
  done
done
echo "invariants held for $fixtures fixtures × $LAST_SEED seeds ($runs replays, drop=$DROP)"
