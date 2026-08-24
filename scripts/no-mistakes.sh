#!/usr/bin/env bash
#
# House format/lint/test entrypoint for .no-mistakes.yaml.
# Mirrors .github/workflows/ci.yml: swift build, swift test, swift build -c release.
# This repo has no formatter and no browser tests; format and --screencast are no-ops.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

run() {
    echo "== $* =="
    "$@"
}

require_swift() {
    if ! command -v swift >/dev/null 2>&1; then
        echo "error: swift is not on PATH (Pinchos CI runs on macos-14)" >&2
        exit 1
    fi
}

mode="${1:-}"
shift || true

case "$mode" in
    format)
        if [ "$#" -ne 0 ]; then
            echo "usage: $0 format" >&2
            exit 2
        fi
        echo "== format: no formatter configured; skipping =="
        ;;
    lint)
        if [ "$#" -ne 0 ]; then
            echo "usage: $0 lint" >&2
            exit 2
        fi
        require_swift
        run swift build
        ;;
    test)
        if [ "$#" -gt 0 ]; then
            if [ "$#" -ne 1 ] || [ "$1" != "--screencast" ]; then
                echo "usage: $0 test [--screencast]" >&2
                exit 2
            fi
            echo "== screencast: no browser tests; skipping =="
        fi
        require_swift
        run swift test
        run swift build -c release
        ;;
    *)
        echo "usage: $0 [format|lint|test [--screencast]]" >&2
        exit 2
        ;;
esac
