#!/usr/bin/env bash
# Workflow YAML sanity: every .github/workflows/*.yml parses and no mapping repeats a
# key. A duplicate key is invalid YAML that parsers resolve silently (the last value
# wins), so a job appended twice looks like one job until a diff is read closely —
# this check fails the gate on it.
#
# Usage: scripts/check-workflows.sh [file ...]   (default: .github/workflows/*.yml)
# Passing files is how scripts/check.sh proves the check can fail. Needs python3.
set -euo pipefail
case "${1:-}" in -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;; esac
case "${1:-}" in -*) echo "check-workflows.sh: unknown argument $1 (see --help)" >&2; exit 2 ;; esac
cd "$(dirname "$0")/.."

if (( $# )); then
  files=("$@")
else
  shopt -s nullglob
  files=(.github/workflows/*.yml .github/workflows/*.yaml)
fi
command -v python3 >/dev/null || { echo "check-workflows.sh: python3 is needed" >&2; exit 2; }
((${#files[@]})) || { echo "workflows ok: no workflow files to check"; exit 0; }

python3 - "${files[@]}" <<'PY'
import re, sys

KEY = re.compile(r"^(\s*)(-\s+)?([A-Za-z0-9_'\"][^:]*?)\s*:(\s|$)")
SCALAR = re.compile(r"^\s*[|>][0-9+-]*\s*(#.*)?$")

bad = 0
for path in sys.argv[1:]:
    levels = []          # [(indent, {keys})] — a level's keys persist across its sibling lines
    scalar_at = None     # physical indent of a `key: |`/`>`; block lines are deeper
    for n, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = raw.rstrip("\n")
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped in ("---", "..."):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if scalar_at is not None:
            if indent > scalar_at:
                continue
            scalar_at = None
        m = KEY.match(line)
        if not m:
            continue
        ni = indent + (2 if m.group(2) else 0)   # a "- key" item's keys live one level deeper
        if m.group(2):                            # a new sequence item starts a fresh mapping
            while levels and levels[-1][0] >= ni:
                levels.pop()
        else:
            while levels and levels[-1][0] > ni:
                levels.pop()
        if levels and levels[-1][0] == ni:
            keys = levels[-1][1]
        else:
            keys = set()
            levels.append((ni, keys))
        key = m.group(3).strip().strip("'\"")
        if key in keys:
            print(f"error: {path}:{n}: duplicate key '{key}' in the same mapping", file=sys.stderr)
            bad = 1
        keys.add(key)
        # A `key: |`/`>` opens a block scalar: following lines deeper than the key's
        # indent are content, not keys.
        if SCALAR.match(line.split(":", 1)[1]):
            scalar_at = indent
if bad:
    sys.exit(1)
print(f"workflows ok: {len(sys.argv) - 1} file(s) parse with no duplicate keys")
PY
