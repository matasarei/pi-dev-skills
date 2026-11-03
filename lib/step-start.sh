#!/usr/bin/env bash
# Put a /dev-implement step on its branch, before the model is handed anything.
#
# The skill used to tell the model to run branch.sh and step-budget.sh itself.
# In the first bench run two of three sessions never did, and built on whatever
# branch they found. This runs both from the same arguments the skill gets, as
# its first injection, so the block the model reads already says where it is.
#
#   step-start.sh <task-file> [--next|--continue | <n> | --step <n>]
#   step-start.sh --continue
#
# The step is resolved by task-step.sh, so the two always agree on it. Output:
#
#   BRANCH step/<slug>-<n> — cut from main          branch.sh's line
#   Budget: 640/1200 lines — fits                   step-budget.sh's, its file lines above it
#
# or, when the step must not start, one line beginning "STOP " and what explains
# it. pi/commands.js sends no block that has a STOP line; the user sees it instead:
#
#   STOP BRANCH refused — uncommitted changes would follow the switch to …   exit 3
#   Step 1 is not finished: /dev-implement <file> --continue resumes it.     when one is
#   STOP <file> is **Mode:** manual — built by hand: /dev-plan-manual …      exit 3
#
# Nothing at all, exit 0, when there is no step to start — no such file, no
# steps, every step ticked: task-step.sh's own line in the block says which.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

step="$(bash "$HERE/task-step.sh" "$@" 2>/dev/null)" || exit 0
n="$(printf '%s\n' "$step" | sed -n 's/^## Step \([0-9][0-9]*\) of .*/\1/p' | head -1)"
file="$(printf '%s\n' "$step" | sed -n 's/^\*\*Task file:\*\* //p' | head -1)"
[ -n "$n" ] && [ -n "$file" ] && [ -f "$file" ] || exit 0

if grep -q '^\*\*Mode:\*\*[[:space:]]*manual' "$file"; then
  echo "STOP $file is **Mode:** manual — written to be built by hand: /dev-plan-manual $file --continue"
  exit 3
fi

branch="$(bash "$HERE/branch.sh" "$file" "$n" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
  printf 'STOP %s\n' "$branch"
  # "Commit or stash" leads the wrong way when the work is an earlier step's.
  first="$(bash "$HERE/task-step.sh" "$file" --next 2>/dev/null | sed -n 's/^## Step \([0-9][0-9]*\) of .*/\1/p' | head -1)"
  if [ -n "$first" ] && [ "$first" -lt "$n" ]; then
    echo "Step $first is not finished: /dev-implement $file --continue resumes it."
  fi
  exit 3
fi
printf '%s\n' "$branch"
bash "$HERE/step-budget.sh" "$file" "$n" 2>&1
exit 0
