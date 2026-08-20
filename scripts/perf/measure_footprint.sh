#!/usr/bin/env bash
#
# Local/manual P1 "flagship steady state" footprint check (see docs/performance.md).
#
# Builds the release binary, runs it against a disposable three-item/60s config in a
# scratch XDG_CONFIG_HOME, lets it settle, samples `footprint`'s phys_footprint a few
# times, and prints one JSON object with the measurement plus enough machine identity
# to make the number auditable later.
#
# This is a developer-run harness stub, not part of CI: hosted runners don't reliably
# expose `footprint`, and hosted wall-clock/RSS numbers are too noisy to gate a merge
# on (see "Measurement and enforcement policy" in docs/performance.md). Ordinary CI
# instead enforces the deterministic architectural invariants in
# Tests/pinchosTests/PerformanceInvariantTests.swift and
# Tests/PinchosCoreTests/PerformanceInvariantTests.swift.
#
# Usage: scripts/perf/measure_footprint.sh [settle_seconds] [samples]
#
# Requires: a real macOS session (footprint reads live task info; it will not work
# against a foreign/CI sandbox), the Xcode command line tools (for `footprint`).
# Network-free.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
settle_seconds="${1:-15}"
samples="${2:-3}"

if ! command -v footprint >/dev/null 2>&1; then
    echo "error: 'footprint' is not on PATH (install the Xcode command line tools)" >&2
    exit 1
fi

cd "$repo_root"
swift build -c release >/dev/null

scratch_dir="$(mktemp -d)"
json_dir="$(mktemp -d)"
pid=""

cleanup() {
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -rf "$scratch_dir" "$json_dir"
}
trap cleanup EXIT

mkdir -p "$scratch_dir/pinchos"
cat > "$scratch_dir/pinchos/pinchos.toml" <<'EOF'
[item.alpha]
type = "command"
run = "echo 42"
interval = "60s"

[item.beta]
type = "command"
run = "date '+%H:%M'"
interval = "60s"

[item.gamma]
type = "command"
run = "echo ok"
interval = "60s"
EOF

XDG_CONFIG_HOME="$scratch_dir" "$repo_root/.build/release/pinchos" &
pid=$!
sleep "$settle_seconds"

if ! kill -0 "$pid" 2>/dev/null; then
    echo "error: pinchos (pid $pid) exited before settling" >&2
    exit 1
fi

sample_values=()
for i in $(seq 1 "$samples"); do
    sample_file="$json_dir/sample-$i.json"
    footprint --json "$sample_file" "$pid" >/dev/null 2>&1 || true
    bytes="$(grep -o '"phys_footprint":[0-9]*' "$sample_file" 2>/dev/null | head -1 | cut -d: -f2)"
    sample_values+=("${bytes:-null}")
    sleep 1
done

commit_sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)"
dirty=false
git -C "$repo_root" diff --quiet --ignore-submodules HEAD -- 2>/dev/null || dirty=true
macos_version="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
hardware_model="$(sysctl -n hw.model 2>/dev/null || echo unknown)"
architecture="$(uname -m)"
memory_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
swift_version="$(swift --version 2>/dev/null | head -1 | sed 's/"/\\"/g')"

samples_json="$(IFS=,; echo "${sample_values[*]}")"

cat <<JSON
{
  "profile": "P1-flagship-steady-state",
  "config": {"items": 3, "interval_seconds": 60},
  "settle_seconds": $settle_seconds,
  "phys_footprint_bytes_samples": [$samples_json],
  "commit_sha": "$commit_sha",
  "dirty": $dirty,
  "macos_version": "$macos_version",
  "hardware_model": "$hardware_model",
  "architecture": "$architecture",
  "memory_bytes": $memory_bytes,
  "swift_version": "$swift_version"
}
JSON
