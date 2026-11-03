#!/usr/bin/env bash
# Cases for lib/step-start.sh — run them from anywhere:
#
#   bash evals/lib/step-start.sh
#
# /dev-implement used to tell the model to run branch.sh and step-budget.sh
# itself, and two of the bench's three sessions never did. step-start.sh runs
# them before the model is handed anything, from the same arguments the skill
# gets. Asserted: the step it resolves, the branch it lands on, the budget
# line, and that a refused branch, or a manual plan, prints a line starting
# with "STOP " — pi/commands.js does not send a block that has one.
#
# Exits 0 when every case matches, 1 otherwise, naming each mismatch.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
script="$root/lib/step-start.sh"
[ -f "$script" ] || { printf 'no step-start.sh at %s\n' "$script" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
repo="$work/repo"; mkdir -p "$repo"

fails=0
note() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
g() { git -C "$repo" -c user.email=t@e -c user.name=t "$@"; }
run() { out="$(cd "$repo" && bash "$script" "$@" 2>&1)"; rc=$?; }
on() { g branch --show-current; }
has() { printf '%s\n' "$out" | grep -qF -- "$1"; }

g init -q -b main .
mkdir -p "$repo/.devskills" "$repo/.tasks"
# .tasks/ and .devskills/ are git-ignored in a real project, so a tick never
# dirties the tree.
printf '.tasks/\n.devskills/\n' >> "$repo/.git/info/exclude"
printf '{\n  "baseBranch": "main"\n}\n' > "$repo/.devskills/profile.json"
printf 'x\n' > "$repo/README.md"
printf '# T\n\n## Steps\n\n1. [ ] one\n   - Modify: README.md\n\n2. [ ] two\n   - Modify: README.md\n' > "$repo/.tasks/mytask.md"
g add -A && g commit -qm base

# No step given: the first unticked one, cut from the base, with its budget.
run .tasks/mytask.md
[ "$rc" -eq 0 ] || note "first unticked: exit $rc, want 0: $out"
[ "$(on)" = "step/mytask-1" ] || note "first unticked: on '$(on)', want step/mytask-1"
has 'BRANCH step/mytask-1 — cut from main' || note "first unticked: no BRANCH line: $out"
has 'Budget:' || note "first unticked: no Budget line: $out"
has 'STOP' && note "first unticked: a STOP line on a branch that was cut: $out"

# --step 2, once step 1 has a commit: stacked on step 1.
printf 'one\n' > "$repo/one.txt"; g add -A && g commit -qm one
run .tasks/mytask.md --step 2
[ "$(on)" = "step/mytask-2" ] || note "--step 2: on '$(on)', want step/mytask-2"
has 'BRANCH step/mytask-2 — cut from step/mytask-1' || note "--step 2: $out"

# A bare step number, the way task-step.sh also takes it.
run .tasks/mytask.md 2
has 'BRANCH step/mytask-2 — already on it' || note "bare 2: $out"

# --continue alone: the newest task file's first unticked step.
run --continue
has 'BRANCH step/mytask-1' || note "--continue: $out"

# Uncommitted work that a switch would carry: refused, and the model never runs.
printf 'dirty\n' >> "$repo/README.md"
run .tasks/mytask.md --step 2
[ "$(on)" = "step/mytask-1" ] || note "dirty switch: moved to '$(on)'"
printf '%s\n' "$out" | head -1 | grep -q '^STOP BRANCH refused' || note "dirty switch: first line is not 'STOP BRANCH refused': $out"
[ "$rc" -eq 3 ] || note "dirty switch: exit $rc, want 3"
# Step 1 is still unticked: the refusal names it and how to resume it, not only "commit or stash".
has "Step 1 is not finished: /dev-implement $repo/.tasks/mytask.md --continue resumes it." || note "dirty switch: the unfinished step is not named: $out"
# With no earlier step unticked there is nothing to resume, and the message says nothing of it.
printf '# T\n\n## Steps\n\n1. [x] one — done\n2. [ ] two\n' > "$repo/.tasks/ticked.md"
run .tasks/ticked.md --step 2
printf '%s\n' "$out" | head -1 | grep -q '^STOP BRANCH refused' || note "dirty, earlier step ticked: not refused: $out"
has 'is not finished' && note "dirty, earlier step ticked: named an unfinished step: $out"
rm -f "$repo/.tasks/ticked.md"

# Dirty, but on the step's own branch already: the resume case, not a stop.
run .tasks/mytask.md --step 1
has 'BRANCH step/mytask-1 — already on it' || note "resume: $out"
has 'STOP' && note "resume: in-progress work on its own branch was stopped: $out"
g checkout -q -- README.md

# Every step ticked: nothing to branch; task-step.sh says PLAN DONE itself.
printf '# T\n\n## Steps\n\n1. [x] one — done\n' > "$repo/.tasks/done.md"
run .tasks/done.md
[ -z "$out" ] || note "plan done: printed '$out', want nothing"
[ "$rc" -eq 0 ] || note "plan done: exit $rc, want 0"

# No such file: nothing here; task-step.sh reports it in the block.
run .tasks/nope.md
[ -z "$out" ] || note "no such file: printed '$out', want nothing"

# A manual plan is built by hand: no branch, and a STOP.
printf '# M\n\n**Mode:** manual\n\n## Steps\n\n1. [ ] by hand\n' > "$repo/.tasks/manual.md"
before="$(on)"
run .tasks/manual.md
printf '%s\n' "$out" | head -1 | grep -q '^STOP .*manual' || note "manual: first line is not a STOP naming manual: $out"
[ "$(on)" = "$before" ] || note "manual: a branch was cut for a manual plan: on '$(on)'"

if [ "$fails" -eq 0 ]; then
  printf 'step-start: branch and budget before the model, STOP when refused\n'
else
  printf 'step-start: %s case(s) failed\n' "$fails" >&2
fi
exit $((fails > 0))
