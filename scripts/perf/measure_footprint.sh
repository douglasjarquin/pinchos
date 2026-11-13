#!/usr/bin/env bash
#
# Local/manual release-binary performance profiles (see docs/performance.md).
#
# Builds the release binary once, runs selected profiles against disposable
# local-fixture configs in a scratch XDG_CONFIG_HOME, lets the process settle,
# samples footprint / CPU / descriptors, SIGTERM-cleans up, and prints JSON
# identifying the commit SHA, dirty state, macOS version, hardware, and Swift
# toolchain.
#
# Network-free. No provider credentials. Not part of `mise run verify`.
#
# Usage:
#   scripts/perf/measure_footprint.sh [--profile p1|five|all] [settle_seconds] [samples]
#   mise run perf
#
# A bare numeric first argument is still settle_seconds for the P1 profile.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
profile="p1"
settle_seconds="15"
samples="3"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            profile="${2:-}"
            shift 2
            ;;
        --help|-h)
            echo "Usage: scripts/perf/measure_footprint.sh [--profile p1|five|all] [settle_seconds] [samples]"
            exit 0
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -ge 1 ]]; then
    settle_seconds="$1"
fi
if [[ $# -ge 2 ]]; then
    samples="$2"
fi

case "$profile" in
    p1|five|all) ;;
    *)
        echo "error: unknown profile '$profile' (expected p1, five, or all)" >&2
        exit 1
        ;;
esac

if ! command -v footprint >/dev/null 2>&1; then
    echo "error: 'footprint' is not on PATH (install the Xcode command line tools)" >&2
    exit 1
fi

cd "$repo_root"
swift build -c release >/dev/null

write_p1_config() {
    cat > "$1" <<'EOF'
[item.alpha]
run = "echo 42"
interval = "60s"

[item.beta]
run = "date '+%H:%M'"
interval = "60s"

[item.gamma]
run = "echo ok"
interval = "60s"
EOF
}

write_five_config() {
    cat > "$1" <<'EOF'
[item.alpha]
run = "echo 42"
interval = "60s"

[[item.alpha.menu]]
label = "Cached"
run = "echo 42"
cache = "60s"

[[item.alpha.menu]]
label = "Manual"
run = "printf manual-row"

[item.beta]
run = "date '+%H:%M'"
interval = "60s"

[[item.beta.menu]]
label = "Manual"
run = "printf beta-manual"

[item.gamma]
run = "echo 42"
interval = "60s"

[item.delta]
run = "sleep 2; echo late"
interval = "60s"

[item.epsilon]
run = "printf fail; exit 1"
interval = "60s"
EOF
}

phys_footprint_from_json() {
    python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
try:
    with open(path) as fh:
        data = json.load(fh)
except Exception:
    print("null")
    raise SystemExit

def find(obj):
    if isinstance(obj, dict):
        if "phys_footprint" in obj:
            return obj["phys_footprint"]
        for value in obj.values():
            found = find(value)
            if found is not None:
                return found
    elif isinstance(obj, list):
        for value in obj:
            found = find(value)
            if found is not None:
                return found
    return None

found = find(data)
print(int(found) if found is not None else "null")
PY
}

ax_probe() {
    python3 - <<'PY' 2>/dev/null || echo "ax_probe_failed"
import ctypes
try:
    lib = ctypes.cdll.LoadLibrary(
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
    )
except OSError as exc:
    print(f"load-failed:{exc}")
    raise SystemExit
print("ax_trusted" if lib.AXIsProcessTrusted() else "ax_untrusted_or_disabled")
PY
}

run_profile() (
    profile_id="$1"
    label="$2"
    writer="$3"
    item_count="$4"

    scratch_dir="$(mktemp -d)"
    json_dir="$(mktemp -d)"
    pid=""

    cleanup() {
        if [[ -n "${pid:-}" ]] && kill -0 "$pid" 2>/dev/null; then
            kill -TERM "$pid" 2>/dev/null || true
            waited=0
            while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 50 ]]; do
                sleep 0.1
                waited=$((waited + 1))
            done
            if kill -0 "$pid" 2>/dev/null; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
            wait "$pid" 2>/dev/null || true
        fi
        rm -rf "$scratch_dir" "$json_dir"
    }
    trap cleanup EXIT

    mkdir -p "$scratch_dir/pinchos"
    "$writer" "$scratch_dir/pinchos/pinchos.toml"

    XDG_CONFIG_HOME="$scratch_dir" "$repo_root/.build/release/pinchos" &
    pid=$!
    sleep "$settle_seconds"

    if ! kill -0 "$pid" 2>/dev/null; then
        echo "error: pinchos (pid $pid) exited before settling ($profile_id)" >&2
        exit 1
    fi

    sample_values=()
    rss_samples=()
    cpu_samples=()
    for i in $(seq 1 "$samples"); do
        sample_file="$json_dir/sample-$i.json"
        footprint --json "$sample_file" "$pid" >/dev/null 2>&1 || true
        sample_values+=("$(phys_footprint_from_json "$sample_file")")
        rss_samples+=("$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo null)")
        cpu_samples+=("$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ' || echo null)")
        sleep 1
    done

    fd_count="$(lsof -nP -p "$pid" 2>/dev/null | wc -l | tr -d ' ' || echo null)"
    thread_count="$(ps -M -p "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ' || echo null)"
    child_count="$(pgrep -P "$pid" 2>/dev/null | wc -l | tr -d ' ')"
    child_count="${child_count:-0}"
    wakeup_text="$(top -l 2 -s 1 -pid "$pid" -stats pid,cpu,th 2>/dev/null | tail -n 8 || true)"
    ax_detail="$(ax_probe)"

    kill -TERM "$pid" 2>/dev/null || true
    waited=0
    exited_cleanly=true
    while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 50 ]]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        exited_cleanly=false
        kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    pid=""
    leftover_children="$(pgrep -f "$scratch_dir" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"

    commit_sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)"
    dirty=false
    git -C "$repo_root" diff --quiet --ignore-submodules HEAD -- 2>/dev/null || dirty=true
    macos_version="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
    hardware_model="$(sysctl -n hw.model 2>/dev/null || echo unknown)"
    architecture="$(uname -m)"
    memory_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
    swift_version="$(swift --version 2>/dev/null | head -1)"

    PINCHOS_WAKEUP_SAMPLE="$wakeup_text" \
    PINCHOS_SWIFT_VERSION="$swift_version" \
    python3 -c '
import json, os, sys
def nums(text):
    out = []
    for part in text.split():
        if part in ("", "null"):
            out.append(None)
        else:
            try:
                out.append(int(part) if part.isdigit() else float(part))
            except ValueError:
                out.append(None)
    return out
def maybe_int(text):
    try:
        return int(text)
    except ValueError:
        return None
print(json.dumps({
    "profile": sys.argv[1],
    "label": sys.argv[2],
    "config": {"items": int(sys.argv[3]), "interval_seconds": 60, "commands": "local-fixtures"},
    "settle_seconds": int(sys.argv[4]),
    "phys_footprint_bytes_samples": nums(sys.argv[5]),
    "rss_kb_samples": nums(sys.argv[6]),
    "cpu_percent_samples": nums(sys.argv[7]),
    "open_descriptors": maybe_int(sys.argv[8]),
    "threads": maybe_int(sys.argv[9]),
    "child_processes_at_sample": maybe_int(sys.argv[10]),
    "wakeup_source": "top-pid-sample" if os.environ.get("PINCHOS_WAKEUP_SAMPLE", "").strip() else "unavailable",
    "wakeup_sample": os.environ.get("PINCHOS_WAKEUP_SAMPLE", "").strip() or None,
    "menu_latency_ms": None,
    "menu_latency_note": "live GUI menu latency not measured: Accessibility/screen capture is not granted in this session",
    "accessibility_probe": sys.argv[11],
    "cleanup": {
        "exited_after_sigterm": sys.argv[12] == "true",
        "leftover_scratch_children": maybe_int(sys.argv[13]) or 0,
    },
    "commit_sha": sys.argv[14],
    "dirty": sys.argv[15] == "true",
    "macos_version": sys.argv[16],
    "hardware_model": sys.argv[17],
    "architecture": sys.argv[18],
    "memory_bytes": maybe_int(sys.argv[19]) or 0,
    "swift_version": os.environ.get("PINCHOS_SWIFT_VERSION", ""),
}, indent=2))
' "$profile_id" "$label" "$item_count" "$settle_seconds" \
      "${sample_values[*]}" "${rss_samples[*]}" "${cpu_samples[*]}" \
      "$fd_count" "$thread_count" "$child_count" "$ax_detail" \
      "$exited_cleanly" "$leftover_children" "$commit_sha" "$dirty" \
      "$macos_version" "$hardware_model" "$architecture" "$memory_bytes"
)

result_dir="$(mktemp -d)"
trap 'rm -rf "$result_dir"' EXIT
index=0
run_one() {
    index=$((index + 1))
    run_profile "$1" "$2" "$3" "$4" > "$result_dir/$index.json"
}

case "$profile" in
    p1)
        run_one "P1-flagship-steady-state" "three-item idle reference" write_p1_config 3
        ;;
    five)
        run_one "P1-five-item-mixed" "five-item cached/manual/duplicate/slow/failure" write_five_config 5
        ;;
    all)
        run_one "P1-flagship-steady-state" "three-item idle reference" write_p1_config 3
        run_one "P1-five-item-mixed" "five-item cached/manual/duplicate/slow/failure" write_five_config 5
        ;;
esac

python3 - "$result_dir" <<'PY'
import json, pathlib, sys
folder = pathlib.Path(sys.argv[1])
docs = [json.loads(path.read_text()) for path in sorted(folder.glob("*.json"))]
if len(docs) == 1:
    print(json.dumps(docs[0], indent=2))
else:
    print(json.dumps({"profiles": docs}, indent=2))
PY
