#!/usr/bin/env bash
# Dead-code baseline gate (zdeadcode mechanism via the zmodu CLI from the
# zigmodu repo). Fails when zent src gains NEW dead declarations; removals
# are allowed and the baseline shrinks with --update.
#
# The zmodu binary is found via $ZMODU, else the sibling zigmodu checkout:
#   ZMODU=/tmp/zigmodu/zig-out/bin/zmodu bash scripts/check-deadcode.sh
# CI builds zigmodu@v0.15.5 and points ZMODU at its binary.
#
# Identity = file:kind:name:parent (line numbers are informational, so code
# moves don't cause false positives).
set -euo pipefail
cd "$(dirname "$0")/.."

ZMODU="${ZMODU:-../zigmodu/zig-out/bin/zmodu}"
if [ ! -x "$ZMODU" ]; then
  echo "check-deadcode: zmodu binary not found at $ZMODU" >&2
  echo "set ZMODU=<path-to-zmodu> (build zigmodu v0.15.5 and use zig-out/bin/zmodu)" >&2
  exit 2
fi

if [ "${1:-}" = "--update" ]; then
  "$ZMODU" deadcode -j src | python3 -c "
import json,sys
d=json.load(sys.stdin)
items=[{'file':x['file'],'line':x['line'],'kind':x['kind'],'name':x['name'],'parent':x['parent']} for x in d['dead_declarations']]
items.sort(key=lambda x:(x['file'],x['line']))
json.dump({'items':items},open('scripts/deadcode-baseline.json','w'),indent=2)
print('baseline updated:',len(items),'declarations')
"
  exit 0
fi

python3 - <<'EOF'
import json, subprocess, sys

baseline = json.load(open('scripts/deadcode-baseline.json'))['items']
out = subprocess.run(
    [__import__('os').environ.get('ZMODU', '../zigmodu/zig-out/bin/zmodu'), 'deadcode', '-j', 'src'],
    capture_output=True, text=True,
).stdout
current = json.loads(out)['dead_declarations']

def key(x):
    return (x['file'], x['kind'], x['name'], x.get('parent'))

base = {key(x) for x in baseline}
now = {key(x) for x in current}
added = now - base
removed = base - now

if added:
    print('FAIL: new dead declarations (not in baseline):')
    for x in sorted(added):
        print(f'  {x[0]}: {x[1]} {x[2]}')
    print('Fix them or run: scripts/check-deadcode.sh --update (only for deliberate additions)')
    sys.exit(1)

if removed:
    print(f'OK: {len(removed)} dead declaration(s) removed; run --update to shrink the baseline.')
else:
    print(f'OK: dead-code count within baseline ({len(now)}).')
EOF
