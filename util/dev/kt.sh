#!/usr/bin/env bash
# Run koka test files on the C and JS backends and compare with their .out files.
#   util/dev/kt.sh [--new] test/lib/foo.kk ...
# --new writes the C output as the expected .out file.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KOKA="$(cd "$ROOT" && cabal list-bin exe:koka)"
NEW=0; [ "${1:-}" = "--new" ] && { NEW=1; shift; }
fail=0
filter() { grep -vE '^(check|load|parse|compile|link|linking|created|library|warning: Skipping)( |:)' ; }
for f in "$@"; do
  dir="$(dirname "$f")"; base="$(basename "$f")"
  for target in c js; do
    out=$(cd "$dir" && perl -e 'alarm shift; exec @ARGV' "${KT_TIMEOUT:-120}" "$KOKA" --target=$target --builddir="$ROOT/.koka/kt" -i"$ROOT/lib" -e "$base" 2>&1 | filter)
    if [ $NEW = 1 ] && [ $target = c ]; then printf '%s\n' "$out" > "$f.out"; echo "wrote $f.out"; continue; fi
    if [ -f "$f.out" ] && diff -q <(printf '%s\n' "$out") "$f.out" >/dev/null; then
      echo "PASS [$target] $f"
    else
      echo "FAIL [$target] $f"; fail=1
      if [ -f "$f.out" ]; then diff <(printf '%s\n' "$out") "$f.out" | head -200; else printf '%s\n' "$out" | head -200; fi
    fi
  done
done
exit $fail
