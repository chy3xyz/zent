#!/usr/bin/env bash
#
# Compare `zig build benchmark` ns/op against a recorded baseline.
#
# Usage:
#   bash scripts/bench-compare.sh --save [baseline]   # record current run as baseline
#   bash scripts/bench-compare.sh [baseline]          # compare against baseline (default)
#
# Environment:
#   BENCH_REGRESSION_THRESHOLD_PCT  regression % that fails the check (default 100).
#   The default is deliberately loose: ns/op on a shared/consumer machine has
#   ~±15% run-to-run variance (cold start can spike higher), so 50% is only
#   safe on a dedicated, quiet machine. The CI job treats this as a canary for
#   catastrophic (2x+) regressions.
set -euo pipefail

BASELINE="${1:-scripts/benchmark-baseline.txt}"
THRESHOLD_PCT="${BENCH_REGRESSION_THRESHOLD_PCT:-100}"

if [ "${1:-}" = "--save" ]; then
    BASELINE="${2:-scripts/benchmark-baseline.txt}"
fi

# Run benchmarks and emit "name ns_per_op" pairs from the table.
# Note: the benchmark binary prints its table with std.debug.print (stderr),
# so we capture stderr while discarding zig build's stdout.
run_bench() {
    # Warmup run: the first process after build pays cold-start cost
    # (allocator/mmap/CPU frequency ramp) that skews ns/op upward.
    zig build benchmark -Doptimize=ReleaseFast >/dev/null 2>&1 || true
    local out
    out="$(zig build benchmark -Doptimize=ReleaseFast 2>&1 1>/dev/null)" || {
        echo "benchmark: zig build benchmark failed" >&2
        return 1
    }
    printf '%s\n' "$out" | awk 'NR>2 { print $1, $3 }'
}

if [ "${1:-}" = "--save" ]; then
    run_bench > "$BASELINE"
    echo "baseline saved to $BASELINE"
    exit 0
fi

if [ ! -f "$BASELINE" ]; then
    echo "baseline $BASELINE not found; record one with: bash scripts/bench-compare.sh --save" >&2
    exit 2
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
run_bench > "$tmp"

fail=0
while read -r name ns; do
    [ -n "$name" ] || continue
    base="$(awk -v n="$name" '$1==n { print $2; exit }' "$BASELINE")"
    if [ -z "$base" ]; then
        echo "NEW benchmark (no baseline): $name ${ns}ns/op"
        continue
    fi
    if [ "$base" = "0" ]; then
        continue
    fi
    regress="$(awk -v b="$base" -v c="$ns" 'BEGIN { printf "%.0f", (c-b)/b*100 }')"
    if [ "$regress" -gt "$THRESHOLD_PCT" ]; then
        echo "REGRESSION: $name ${base}ns -> ${ns}ns (+${regress}%)"
        fail=1
    fi
done < "$tmp"

if [ "$fail" -ne 0 ]; then
    echo "benchmark regression over ${THRESHOLD_PCT}% threshold" >&2
    exit 1
fi
echo "benchmarks within ${THRESHOLD_PCT}% of baseline"
