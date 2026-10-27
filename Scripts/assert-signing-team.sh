#!/bin/bash
# Release prerequisite: compare the new signed app to a previously shipped app.
set -euo pipefail
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <new.app> <previous.app>" >&2
  exit 2
fi
read_team() {
  local output
  if ! output=$(codesign -dv --verbose=4 "$1" 2>&1); then
    echo "codesign failed for $1: $output" >&2
    exit 1
  fi
  printf '%s\n' "$output" | sed -n 's/^TeamIdentifier=//p'
}
new_team=$(read_team "$1")
previous_team=$(read_team "$2")
if [[ -z "$new_team" || "$new_team" == "not set" || "$new_team" != "$previous_team" ]]; then
  echo "Signing team is missing or differs from the previous app." >&2
  exit 1
fi
codesign --verify --strict "$1"
echo "Signing team matches the previous app."
