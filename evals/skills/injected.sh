#!/usr/bin/env bash
# The block the model actually sees, assembled by pi/expand.js — the code the
# Pi commands run:
#
#   bash evals/skills/injected.sh
#
# Every other suite tests a script on its own. Nothing tested what those
# scripts put in front of the model once a skill's "!`…`" lines have run —
# and that is where the 2026-09-11 failures lived: a run got a step with no
# task-file path, invented one, and built with no branch. This suite takes
# each SKILL.md, expands it with pi/expand.js in a throwaway project with
# DEV_SKILLS_LIB pointing at this checkout's lib/, substituting $ARGUMENTS
# the way each skill is typically invoked, and asserts what the model reads:
#
#   - no line is a usage message, a "command not found", a stray
#     "$ARGUMENTS", or an injection left unrun — each means the model was
#     handed the toolkit's problem;
#   - a skill that injects task-step.sh with a plan gets the step, and its
#     absolute "**Task file:**" line, so the model can pass the path on;
#   - dev-plan's block names the project root, so the plan lands under it;
#   - no SKILL.md mentions $ARGUMENTS outside an injection, where it would
#     reach the model as literal text.
#
# $ARGUMENTS is replaced as raw unquoted text, which is how OpenCode was seen
# to do it on 2026-09-11 (a typed path reached plan-input.sh and task-step.sh
# whole, a sentence reached them as words). pi/expand.js keeps that rule, so
# the skills read the same under Pi.
#
# Injections that call gh reach the network and are skipped (--offline).
# Needs git and node. Exits 0 when the blocks read as they should, 1 otherwise.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
skills="$root/skills"
[ -d "$skills" ] || { printf 'no skills at %s\n' "$skills" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { printf 'injected: git is required — not installed\n' >&2; exit 1; }
command -v node >/dev/null 2>&1 || { printf 'injected: node is required to run pi/expand.js — not installed\n' >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

fails=0
note() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# A small project: a git repository on main with one commit, a profile, and a
# plan in the canonical shape, so every injected command has something to read.
proj="$work/proj"
mkdir -p "$proj/.tasks" "$proj/.devskills"
git -C "$proj" init -q -b main
printf '{\n  "baseBranch": "main"\n}\n' > "$proj/.devskills/profile.json"
printf 'x\n' > "$proj/README.md"
cat > "$proj/.tasks/plan.md" <<'PLAN'
# Export the roster as CSV

**Type:** feature
**Asked:** add a CSV option to the roster export

## Acceptance criteria
- [ ] `?format=csv` downloads a CSV with the same rows as the XLSX

## Steps
1. [ ] Add the CSV writer
   - Create: classes/export/CsvWriter.php
   - Modify: none
   - Test: tests/export/CsvWriterTest.php
   - Check: `vendor/bin/phpunit tests/export/CsvWriterTest.php`

## Do not touch
- `classes/export/XlsxWriter.php`
PLAN
git -C "$proj" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$proj" -c user.email=t@t -c user.name=t commit -qm base >/dev/null

# How each skill is typically invoked — what replaces $ARGUMENTS.
args_for() {
  case "$1" in
    dev-implement|dev-plan-manual) printf '%s' '.tasks/plan.md' ;;
    dev-plan|dev-fix) printf '%s' 'add a CSV option to the roster export' ;;
    dev-pr-review) printf '%s' '1' ;;
    *) printf '' ;;
  esac
}

for skill in "$skills"/*/SKILL.md; do
  name="$(basename "$(dirname "$skill")")"
  args="$(args_for "$name")"

  # $ARGUMENTS outside an injection reaches the model as literal text.
  stray="$(grep -v '^!`' "$skill" | grep -c '\$ARGUMENTS')"
  [ "$stray" -eq 0 ] || note "$name: \$ARGUMENTS appears $stray time(s) outside an injection"

  ran="$(grep -c '^!`' "$skill")"
  [ "$ran" -gt 0 ] || continue
  # --offline skips an injection that starts with gh: it reaches the network.
  # pr-comments.sh calls gh too, but exits before it does in a project with
  # no remote — which is why the throwaway project must never get one.
  block="$(cd "$proj" && DEV_SKILLS_LIB="$root/lib" node "$root/pi/expand.js" --offline "$skill" "$args" 2>&1)"
  printf '%s\n' "$block" | grep -q '^!`' && note "$name: an injection reached the model unrun: $(printf '%s\n' "$block" | grep -m1 '^!`')"

  printf '%s\n' "$block" | grep -qi '^usage:' && note "$name: an injection printed a usage line — the model is handed the toolkit's problem: $(printf '%s\n' "$block" | grep -i -m1 '^usage:')"
  printf '%s\n' "$block" | grep -q 'command not found' && note "$name: an injection could not run: $(printf '%s\n' "$block" | grep -m1 'command not found')"
  printf '%s\n' "$block" | grep -q '\$ARGUMENTS' && note "$name: a literal \$ARGUMENTS reached the block"

  if grep -q '^!`.*task-step.sh' "$skill" && [ -n "$args" ]; then
    printf '%s\n' "$block" | grep -q '^\*\*Task file:\*\* /' \
      || note "$name: the step block has no absolute Task file line — the model cannot pass the path to branch.sh, step-budget.sh or tick.sh"
    printf '%s\n' "$block" | grep -q '^## Step 1 of 1' \
      || note "$name: the step block does not hand over step 1: '$(printf '%s\n' "$block" | grep -m1 '^## Step')'"
  fi
  if [ "$name" = dev-plan ]; then
    printf '%s\n' "$block" | grep -qF "$proj" || note "dev-plan: the block does not name the project root, so the plan may land under ~"
  fi
done

# dev-review names a manual plan only when it is this branch's plan. A stray
# one elsewhere in .tasks/ used to turn every review's findings into "fix it by
# hand". The branch step/<slug>-<n> belongs to .tasks/<slug>.md, as branch.sh
# cuts it; run after the loop so the stray plan reaches no other skill's block.
review_cmd="$(grep -A2 '^Manual plan:' "$skills/dev-review/SKILL.md" | grep -m1 '^!`')"
review_cmd="${review_cmd#\!\`}"; review_cmd="${review_cmd%\`}"
if [ -z "$review_cmd" ]; then
  note "dev-review: no injection under 'Manual plan:'"
else
  printf '# Other\n\n**Mode:** manual\n' > "$proj/.tasks/manual-other.md"
  got="$(cd "$proj" && bash -c "$review_cmd" 2>&1)"
  [ "$got" = "(none)" ] || note "dev-review: on main it named a manual plan that belongs to another branch: $got"
  git -C "$proj" switch -q -c step/manual-other-1 >/dev/null 2>&1
  got="$(cd "$proj" && bash -c "$review_cmd" 2>&1)"
  [ "$got" = ".tasks/manual-other.md" ] || note "dev-review: on step/manual-other-1 it did not name .tasks/manual-other.md: $got"
  git -C "$proj" switch -q -c step/manual-other-1a >/dev/null 2>&1
  got="$(cd "$proj" && bash -c "$review_cmd" 2>&1)"
  [ "$got" = "(none)" ] || note "dev-review: step/manual-other-1a is no step branch to pr-info.sh, yet it named: $got"
fi

# dev-review hands C11 the red receipt under the rule pr-info.sh uses: the
# test's name and verdict when the receipt names this branch and its sha is
# behind HEAD, and "(none)" for no receipt, another branch's, or a sha that is
# not — the receipt is git-ignored and outlives branches.
red_cmd="$(grep -A2 '^Red receipt:' "$skills/dev-review/SKILL.md" | grep -m1 '^!`')"
red_cmd="${red_cmd#\!\`}"; red_cmd="${red_cmd%\`}"
if [ -z "$red_cmd" ]; then
  note "dev-review: no injection under 'Red receipt:'"
else
  pb="$(git -C "$proj" branch --show-current)"; ph="$(git -C "$proj" rev-parse HEAD)"
  rm -f "$proj/.devskills/red-result"
  got="$(cd "$proj" && bash -c "$red_cmd" 2>&1)"
  [ "$got" = "(none)" ] || note "dev-review: with no red receipt the block says '$got', want (none)"
  printf '%s %s TwoTest RED NOT PROVEN — the test passed before the change\n' "$ph" "$pb" > "$proj/.devskills/red-result"
  got="$(cd "$proj" && bash -c "$red_cmd" 2>&1)"
  [ "$got" = "TwoTest RED NOT PROVEN — the test passed before the change" ] || note "dev-review: this branch's red receipt reads '$got'"
  printf '%s main OldStepTest RED PROVEN | FAILURES! Tests: 1, Failures: 1.\n' "$ph" > "$proj/.devskills/red-result"
  got="$(cd "$proj" && bash -c "$red_cmd" 2>&1)"
  [ "$got" = "(none)" ] || note "dev-review: another branch's red receipt reads '$got', want (none)"
  printf '0000000000000000000000000000000000000000 %s OldStepTest RED PROVEN | FAILURES! Tests: 1, Failures: 1.\n' "$pb" > "$proj/.devskills/red-result"
  got="$(cd "$proj" && bash -c "$red_cmd" 2>&1)"
  [ "$got" = "(none)" ] || note "dev-review: a red receipt for a sha not behind HEAD reads '$got', want (none)"
fi

if [ "$fails" -eq 0 ]; then
  printf 'injected: every skill hands the model a block it can act on\n'
else
  printf 'injected: %s gap(s)\n' "$fails" >&2
fi
exit $((fails > 0))
