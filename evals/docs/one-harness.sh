#!/usr/bin/env bash
# No tracked file names the harness this repository was ported from — run it
# from anywhere:
#
#   bash evals/docs/one-harness.sh
#
# Its leftovers reached the model: a script path whose default pointed at that
# harness's frozen install, which the model filled in and ran, and a pull
# request footer naming the wrong harness. Pi is the only harness here. The
# word is split below so this file does not match itself; bench/space-city/runs
# is git-ignored and holds logs, not code.
#
# Exits 0 when nothing matches, 1 otherwise, naming each line.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
word="open""code"
hits="$(git -C "$root" grep -n -i -I -e "$word" -- . 2>/dev/null)"
if [ -n "$hits" ]; then
  printf '%s\n' "$hits" | sed 's/^/FAIL  /' | cut -c1-200
  printf 'one-harness: %s line(s) name the old harness\n' "$(printf '%s\n' "$hits" | wc -l | tr -d ' ')" >&2
  exit 1
fi
printf 'one-harness: no tracked file names the old harness\n'
