#!/usr/bin/env bash
# Runs every never-panics fuzz target with a bounded case count — the CI smoke for
# the fuzz suite in tests/attacks. Each target also replays its seed corpus
# (tests/attacks/fuzz/corpus) inside `seed_corpus_replays_without_panics`.
#
# Usage: scripts/fuzz-smoke.sh [--cases N]
#   --cases N   proptest cases per target (default 512, or $PROPTEST_CASES).
set -euo pipefail

cases="${PROPTEST_CASES:-512}"
while (($#)); do
    case "$1" in
        --help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --cases)
            cases="${2:?'--cases needs a value'}"
            shift 2
            ;;
        *)
            echo "unknown argument: $1 (see --help)" >&2
            exit 2
            ;;
    esac
done

echo "fuzz smoke: $cases generated cases per target + corpus replay"
PROPTEST_CASES="$cases" cargo test -p rwacredit-attacks --test fuzz --locked
