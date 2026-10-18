#!/usr/bin/env bash
# PostgreSQL-wire compatibility gate: run the integration suite against a
# wire-compatible server and compare the *set* of failing tests with the
# recorded baseline.
#
# Why a baseline and not a threshold: a server that answers the wire protocol
# without implementing everything has a stable split — some tests exercise
# PostgreSQL-only SQL and cannot pass there, and the rest must. A pass *count*
# would hide a swap (one test starts passing while another breaks); a named set
# does not. A newly failing name fails the gate, and a name that starts passing
# is reported so the baseline can shrink (it never fails the gate — a fix is not
# a regression).
#
# The server must be **fresh** for the comparison to be meaningful: some tests
# create, drop and re-create tables with `SERIAL` columns, and a server that
# keeps sequences across `DROP TABLE` (HeliosDB Nano does, PostgreSQL does not)
# will otherwise answer different ids on the second run of the day. In CI that
# is free — the job starts an in-memory instance per run — and locally it means
# restart the instance before comparing.
#
# Usage:
#   scripts/check-pg-wire.sh            # compare against the baseline
#   scripts/check-pg-wire.sh --update   # rewrite the baseline (deliberate!)
#
# The DSN comes from PG_WIRE_DSN, defaulting to a local HeliosDB Nano on 55432:
#   PG_WIRE_DSN="host=127.0.0.1 port=55432 dbname=postgres user=postgres"
set -euo pipefail
cd "$(dirname "$0")/.."

DSN="${PG_WIRE_DSN:-host=127.0.0.1 port=55432 dbname=postgres user=postgres}"
BASELINE="tests/integration/pg_wire_baseline.txt"
UPDATE=0
if [ "${1:-}" = "--update" ]; then UPDATE=1; fi

echo "-- building the integration binary --"
zig build test-integration >/dev/null

BIN="$(ls -t .zig-cache/o/*/test 2>/dev/null | head -1 || true)"
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "FAIL: no integration test binary under .zig-cache/o/*/test" >&2
    exit 2
fi

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

echo "-- running against $DSN --"
PG_DSN="$DSN" "$BIN" >"$OUT" 2>&1 || true

SUMMARY="$(grep -a -oE '[0-9]+ passed; [0-9]+ skipped; [0-9]+ failed' "$OUT" | tail -1 || true)"
if [ -z "$SUMMARY" ]; then
    echo "FAIL: the run produced no summary line — the server is probably not reachable at:" >&2
    echo "      $DSN" >&2
    tail -5 "$OUT" >&2
    exit 2
fi
echo "summary: $SUMMARY"

python3 - "$OUT" "$BASELINE" "$UPDATE" <<'PY'
import re
import sys

out_path, baseline_path, update = sys.argv[1], sys.argv[2], sys.argv[3] == "1"

# A test's line is `N/M name...` followed by the outcome: `OK` on the same line
# (`...OK`) or after it, or `FAIL (ErrorName)` possibly several lines later
# (the run prints warnings in between). A failure without the parenthesised
# error does not happen in this runner, so the marker keeps a warning that
# merely contains the word FAIL from being read as one.
header = re.compile(r"^\d+/\d+ (.+?)\.\.\.")
failed = []
pending = None
for line in open(out_path, errors="replace"):
    m = header.match(line)
    if m:
        pending = None
        if line.rstrip().endswith("OK"):
            continue
        pending = m.group(1)
        if "FAIL (" in line[m.end():]:
            failed.append(pending)
            pending = None
        continue
    if pending is None:
        continue
    if "FAIL (" in line:
        failed.append(pending)
        pending = None
    elif line.rstrip().endswith("OK"):
        pending = None

got = sorted(set(failed))
print(f"failing tests: {len(got)}")

if update:
    with open(baseline_path, "w") as f:
        f.write(
            "# Tests that fail against a PostgreSQL-wire server with a partial\n"
            "# catalog (HeliosDB Nano 4.41.1). Regenerate deliberately:\n"
            "#   scripts/check-pg-wire.sh --update\n"
            "# One test name per line; `#` starts a comment.\n"
        )
        for name in got:
            f.write(name + "\n")
    print(f"baseline updated: {baseline_path} ({len(got)} entries)")
    sys.exit(0)

want = []
try:
    for line in open(baseline_path):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        want.append(line)
except FileNotFoundError:
    print(f"FAIL: no baseline at {baseline_path}; run with --update to record one", file=sys.stderr)
    sys.exit(2)

want_set, got_set = set(want), set(got)
new = sorted(got_set - want_set)
fixed = sorted(want_set - got_set)

if fixed:
    print(f"note: {len(fixed)} baselined failure(s) now pass — update the baseline to shrink it:")
    for name in fixed:
        print(f"  - {name}")

if new:
    print("FAIL: tests that regressed against the wire-compatible server:")
    for name in new:
        print(f"  + {name}")
    print("If a new failure is a PostgreSQL-only assumption of the test rather than a")
    print("regression, fix the test or regenerate the baseline with --update.")
    sys.exit(1)

print(f"OK: the failing set matches the baseline ({len(want_set)} known, none new)")
PY
