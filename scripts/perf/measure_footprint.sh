#!/usr/bin/env bash
#
# Local/manual release-binary performance profiles (see docs/performance.md).
#
# Builds the release binary once (into .build/release), runs selected profiles
# against disposable local-fixture configs in a scratch XDG_CONFIG_HOME, lets
# the process settle, samples footprint / CPU / descriptors / idle wakeups,
# SIGTERM-cleans up, and prints JSON identifying the commit SHA, dirty state,
# macOS version, hardware, and Swift toolchain.
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
# IDLEW is a per-interval rate (first -l sample is zeroed, like %CPU), not a
# process-lifetime cumulative counter. Window matches the 60s timer cadence.
wakeup_window_seconds="60"

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

if ! [[ "$settle_seconds" =~ ^[0-9]+$ ]] || [[ "$settle_seconds" -lt 1 ]]; then
    echo "error: settle_seconds must be a positive integer (got '$settle_seconds')" >&2
    exit 1
fi
if ! [[ "$samples" =~ ^[0-9]+$ ]] || [[ "$samples" -lt 1 ]]; then
    echo "error: samples must be a positive integer (got '$samples')" >&2
    exit 1
fi

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
run = "sleep 120; echo late"
interval = "60s"
timeout = "180s"

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

parse_idlew_second_sample() {
    python3 - "$1" <<'PY'
import sys
text = open(sys.argv[1], errors="replace").read()
blocks = []
current = []
for line in text.splitlines():
    if line.startswith("Processes:") and current:
        blocks.append(current)
        current = [line]
    else:
        current.append(line)
if current:
    blocks.append(current)
if len(blocks) < 2:
    print("null")
    raise SystemExit
header = None
pid_line = None
for line in blocks[1]:
    parts = line.split()
    if parts and parts[0] == "PID":
        header = parts
        continue
    if parts and parts[0].isdigit():
        pid_line = parts
if header is None or pid_line is None or "IDLEW" not in header:
    print("null")
    raise SystemExit
raw = pid_line[header.index("IDLEW")].rstrip("+*")
try:
    print(int(raw))
except (ValueError, IndexError):
    print("null")
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

collect_descendants() {
    local parent="$1"
    local child
    while IFS= read -r child; do
        [[ -z "$child" ]] && continue
        printf '%s\n' "$child"
        collect_descendants "$child"
    done < <(pgrep -P "$parent" 2>/dev/null || true)
}

run_profile() (
    profile_id="$1"
    label="$2"
    writer="$3"
    item_count="$4"
    expect_inflight="$5"

    scratch_dir="$(mktemp -d)"
    json_dir="$(mktemp -d)"
    pid=""
    trap '' TTOU TTIN TSTP

    dump_pinchos_err() {
        if [[ -f "$json_dir/pinchos.err" ]]; then
            echo "--- pinchos.err ---" >&2
            cat "$json_dir/pinchos.err" >&2 || true
        fi
    }

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

    XDG_CONFIG_HOME="$scratch_dir" "$repo_root/.build/release/pinchos" \
        >/dev/null 2>"$json_dir/pinchos.err" &
    pid=$!
    sleep "$settle_seconds"

    if ! kill -0 "$pid" 2>/dev/null; then
        echo "error: pinchos (pid $pid) exited before settling ($profile_id)" >&2
        dump_pinchos_err
        exit 1
    fi

    sample_values=()
    rss_samples=()
    cpu_samples=()
    for i in $(seq 1 "$samples"); do
        sample_file="$json_dir/sample-$i.json"
        footprint_err="$json_dir/footprint-$i.err"
        if ! footprint --json "$sample_file" "$pid" >/dev/null 2>"$footprint_err"; then
            echo "error: footprint failed for sample $i (pid $pid, $profile_id)" >&2
            cat "$footprint_err" >&2 || true
            dump_pinchos_err
            exit 1
        fi
        value="$(phys_footprint_from_json "$sample_file")"
        if [[ "$value" == "null" ]]; then
            echo "error: phys_footprint sample $i is null (pid $pid, $profile_id)" >&2
            echo "--- footprint stderr ---" >&2
            cat "$footprint_err" >&2 || true
            echo "--- footprint json ---" >&2
            cat "$sample_file" >&2 || true
            dump_pinchos_err
            exit 1
        fi
        sample_values+=("$value")
        rss_samples+=("$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo null)")
        cpu_samples+=("$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ' || echo null)")
        sleep 1
    done

    set +e
    lsof -nP -a -d 0-65535 -p "$pid" >"$json_dir/lsof.out" 2>"$json_dir/lsof.err"
    lsof_status=$?
    set -e
    fd_count="$(awk 'NR>1 {n++} END {print n+0}' "$json_dir/lsof.out")"
    if [[ -z "$fd_count" || "$fd_count" -eq 0 ]]; then
        echo "error: lsof reported no numeric FDs for pid $pid (exit $lsof_status, $profile_id)" >&2
        cat "$json_dir/lsof.err" >&2 || true
        cat "$json_dir/lsof.out" >&2 || true
        dump_pinchos_err
        exit 1
    fi
    thread_count="$(ps -M -p "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ' || echo null)"
    child_count="$( { pgrep -P "$pid" 2>/dev/null || true; } | wc -l | tr -d ' ' )"
    child_count="${child_count:-0}"

    descendants=""
    while IFS= read -r child; do
        [ -n "$child" ] || continue
        descendants="${descendants:+$descendants }$child"
    done < <(collect_descendants "$pid")
    descendant_count=0
    for _descendant in $descendants; do
        descendant_count=$((descendant_count + 1))
    done
    if [[ "$expect_inflight" == "true" && "$descendant_count" -lt 1 ]]; then
        echo "error: $profile_id expected an in-flight descendant before SIGTERM, found none" >&2
        dump_pinchos_err
        exit 1
    fi

    wakeup_file="$json_dir/top.txt"
    set +e
    set +o pipefail
    top -l 2 -s "$wakeup_window_seconds" -pid "$pid" -stats pid,cpu,th,idlew </dev/null >"$wakeup_file" 2>/dev/null
    set -o pipefail
    set -e
    wakeups="$(parse_idlew_second_sample "$wakeup_file")"
    if [[ "$wakeups" == "null" ]]; then
        echo "error: could not parse IDLEW from the second top sample (${wakeup_window_seconds}s window)" >&2
        cat "$wakeup_file" >&2 || true
        exit 1
    fi
    wakeup_line="$(python3 - "$wakeup_file" <<'PY'
import sys
text = open(sys.argv[1], errors="replace").read()
blocks, current = [], []
for line in text.splitlines():
    if line.startswith("Processes:") and current:
        blocks.append(current)
        current = [line]
    else:
        current.append(line)
if current:
    blocks.append(current)
if len(blocks) < 2:
    raise SystemExit
for line in blocks[1]:
    parts = line.split()
    if parts and parts[0].isdigit():
        print(line.strip())
PY
)"
    ax_detail="$(ax_probe)" || ax_detail="ax_probe_failed"

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

    leftover=0
    for descendant in $descendants; do
        if [ -n "$descendant" ] && kill -0 "$descendant" 2>/dev/null; then
            leftover=$((leftover + 1))
        fi
    done

    commit_sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo unknown)"
    dirty=false
    git -C "$repo_root" diff --quiet --ignore-submodules HEAD -- 2>/dev/null || dirty=true
    macos_version="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
    hardware_model="$(sysctl -n hw.model 2>/dev/null || echo unknown)"
    architecture="$(uname -m)"
    memory_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
    swift_version="$(swift --version 2>/dev/null | head -1)"

    PINCHOS_WAKEUP_LINE="$wakeup_line" \
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
    "descendants_at_sigterm": maybe_int(sys.argv[11]),
    "wakeups": maybe_int(sys.argv[12]),
    "wakeup_window_seconds": maybe_int(sys.argv[22]),
    "wakeup_source": "top-idlew-interval",
    "wakeup_note": "macOS top IDLEW is a per-interval idle-wakeup count (first -l sample is zeroed, like %CPU), not a process-lifetime cumulative counter and not all wakeups",
    "wakeup_sample": os.environ.get("PINCHOS_WAKEUP_LINE", "").strip() or None,
    "menu_latency_ms": None,
    "menu_latency_note": "live GUI menu latency unmeasured: AXIsProcessTrusted() is untrusted/disabled on this Mac",
    "accessibility_probe": sys.argv[13],
    "cleanup": {
        "exited_after_sigterm": sys.argv[14] == "true",
        "descendants_at_sigterm": maybe_int(sys.argv[11]),
        "leftover_descendants": maybe_int(sys.argv[15]) or 0,
    },
    "commit_sha": sys.argv[16],
    "dirty": sys.argv[17] == "true",
    "macos_version": sys.argv[18],
    "hardware_model": sys.argv[19],
    "architecture": sys.argv[20],
    "memory_bytes": maybe_int(sys.argv[21]) or 0,
    "swift_version": os.environ.get("PINCHOS_SWIFT_VERSION", ""),
}, indent=2))
' "$profile_id" "$label" "$item_count" "$settle_seconds" \
      "${sample_values[*]}" "${rss_samples[*]}" "${cpu_samples[*]}" \
      "$fd_count" "$thread_count" "$child_count" "$descendant_count" \
      "$wakeups" "$ax_detail" "$exited_cleanly" "$leftover" "$commit_sha" "$dirty" \
      "$macos_version" "$hardware_model" "$architecture" "$memory_bytes" \
      "$wakeup_window_seconds"
)

result_dir="$(mktemp -d)"
trap 'rm -rf "$result_dir"' EXIT
index=0
run_one() {
    index=$((index + 1))
    run_profile "$1" "$2" "$3" "$4" "$5" > "$result_dir/$index.json"
}

case "$profile" in
    p1)
        run_one "P1-flagship-steady-state" "three-item idle reference" write_p1_config 3 false
        ;;
    five)
        run_one "P1-five-item-mixed" "five-item cached/manual/duplicate/slow/failure" write_five_config 5 true
        ;;
    all)
        run_one "P1-flagship-steady-state" "three-item idle reference" write_p1_config 3 false
        run_one "P1-five-item-mixed" "five-item cached/manual/duplicate/slow/failure" write_five_config 5 true
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
