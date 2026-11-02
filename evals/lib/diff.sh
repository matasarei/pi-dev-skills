#!/usr/bin/env bash
# Cases for lib/diff.sh — run them from anywhere:
#
#   bash evals/lib/diff.sh
#
# The script's one promise is that truncation is announced: a review told it saw
# the whole diff when it saw 600 lines of it is the silent failure this guards.
# So: no diff → says so; under the cap → whole diff, no notice; over the cap →
# exactly the cap, then a notice with the real numbers; uncommitted changes are
# part of the count, not outside it.
#
# Exits 0 when every case matches, 1 otherwise, naming each mismatch.

set -u

# Pi sets DEV_SKILLS_CONTEXT for every command it runs (pi/commands.js), so a
# suite run from inside Pi would inherit the session's window and fail every
# case that asserts the default. Each case that wants a window sets its own.
unset DEV_SKILLS_CONTEXT DEV_SKILLS_QUEUE_CAP

root="$(cd "$(dirname "$0")/../.." && pwd)"
diffsh="$root/lib/diff.sh"
[ -f "$diffsh" ] || { printf 'no diff.sh at %s\n' "$diffsh" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

fails=0
note() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
g() { git -C "$work" -c user.email=t@e -c user.name=t "$@"; }

g init -q -b main .
printf 'one\n' > "$work/a.txt"
g add -A && g commit -qm init
g switch -qc feature

# No diff at all.
out="$(cd "$work" && bash "$diffsh" main)"
[ "$out" = "[no diff against main, staged or unstaged]" ] || note "empty diff: got '$out'"

# A small committed change: printed whole, no truncation notice.
printf 'two\n' >> "$work/a.txt"
g commit -qam 'add two'
out="$(cd "$work" && bash "$diffsh" main)"
printf '%s\n' "$out" | grep -q '^+two$'     || note 'a committed change is missing from the diff'
printf '%s\n' "$out" | grep -q 'TRUNCATED'  && note 'a small diff was reported as truncated'

# Uncommitted work counts too: staged and unstaged both appear.
printf 'three\n' >> "$work/a.txt"; g add a.txt
printf 'four\n'  >> "$work/a.txt"
out="$(cd "$work" && bash "$diffsh" main)"
printf '%s\n' "$out" | grep -q '^+three$' || note 'a staged change is missing from the diff'
printf '%s\n' "$out" | grep -q '^+four$'  || note 'an unstaged change is missing from the diff'

# Over the cap: exactly the cap is shown, and the notice carries real numbers.
seq 1 100 > "$work/big.txt"; g add big.txt; g commit -qm big
out="$(cd "$work" && bash "$diffsh" main 20)"
shown="$(printf '%s\n' "$out" | sed '/^$/,$d' | wc -l | tr -d ' ')"
[ "$shown" -eq 20 ] || note "over the cap: showed $shown lines, want 20"
printf '%s\n' "$out" | grep -q '^\[TRUNCATED: showed 20 of [0-9]* diff lines\. [0-9]* not shown' \
  || note 'over the cap: the truncation notice is missing or has no numbers'
total="$(printf '%s\n' "$out" | sed -n 's/^\[TRUNCATED: showed 20 of \([0-9]*\) diff lines.*/\1/p')"
[ -n "$total" ] && [ "$total" -gt 100 ] || note "over the cap: total '$total' should exceed the 100 added lines"

# The cap follows the context window, the way step-budget.sh's does. A block of
# 600 diff lines is roughly 24,000 bytes -- five times the prompt it is injected
# into -- so a 32k session handed the same block as a 128k one spends a sixth of
# its window on it. Six lines per 1k of context: half the step budget, so the
# diff costs about what the step it reviews costs.
seq 1 800 > "$work/huge.txt"; g add huge.txt; g commit -qm huge

cap_of() { # cap_of <the "showed N of M" number>
  printf '%s\n' "$1" | sed -n 's/^\[TRUNCATED: showed \([0-9]*\) of .*/\1/p'
}
want_cap() { # want_cap <env context> <expected cap> <label>
  o="$(cd "$work" && DEV_SKILLS_CONTEXT="$1" bash "$diffsh" main)"
  [ "$(cap_of "$o")" = "$2" ] || note "$3: cap $(cap_of "$o"), want $2"
}
want_cap 131072 786 '128k'
want_cap 65536  393 '64k'
want_cap 32768  196 '32k'

# Nothing declares a window: the 100k fallback keeps the 600 this script always
# had, so a repository with no profile sees no change at all.
o="$(cd "$work" && bash "$diffsh" main)"
[ "$(cap_of "$o")" = 600 ] || note "no window declared: cap $(cap_of "$o"), want the unchanged 600"

# The profile supplies it when the environment does not.
mkdir -p "$work/.devskills"
printf '{ "contextTokens": 32768 }\n' > "$work/.devskills/profile.json"
o="$(cd "$work" && bash "$diffsh" main)"
[ "$(cap_of "$o")" = 196 ] || note "from the profile: cap $(cap_of "$o"), want 196"
# ...and the environment still wins over it.
o="$(cd "$work" && DEV_SKILLS_CONTEXT=131072 bash "$diffsh" main)"
[ "$(cap_of "$o")" = 786 ] || note "environment over profile: cap $(cap_of "$o"), want 786"
# ...and an explicit argument wins over both.
o="$(cd "$work" && DEV_SKILLS_CONTEXT=131072 bash "$diffsh" main 20)"
[ "$(cap_of "$o")" = 20 ] || note "explicit argument: cap $(cap_of "$o"), want 20"
rm -rf "$work/.devskills"

# A base that does not exist is an error, not an empty diff.
( cd "$work" && bash "$diffsh" nope >/dev/null 2>&1 ); rc=$?
[ "$rc" -eq 1 ] || note "a missing base exited $rc, want 1"

if [ "$fails" -eq 0 ]; then
  printf 'diff: whole when small, capped and announced when large\n'
else
  printf 'diff: %s case(s) failed\n' "$fails" >&2
fi
exit $((fails > 0))
