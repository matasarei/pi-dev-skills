#!/usr/bin/env bash
# The step shape, asserted — run it from anywhere:
#
#   bash evals/skills/file-lists.sh
#
# /dev-plan writes six indented lines under every step and three scripts read
# them: task-step.sh hands /dev-implement the step, step-budget.sh sizes it,
# plan-check.sh checks its paths and that Red: names what must fail first. The template in the skill has to keep the
# shape the parser expects — each line its own, indented, in the same words —
# or the lists become decoration nothing reads. Later steps add the readers.
#
# Exits 0 when the shape holds, 1 otherwise, naming each gap.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
skills="$root/skills"
[ -d "$skills" ] || { printf 'no skills at %s\n' "$skills" >&2; exit 1; }

fails=0
note() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
flat() { tr '\n' ' ' < "$1" | tr -d '`' | tr -s ' '; }

plan="$skills/dev-plan/SKILL.md"
for part in 'Create:' 'Modify:' 'Test:' 'Red:' 'Check:' 'Budget:'; do
  grep -qE "^ +- $part" "$plan" || note "dev-plan: the step template has no indented '$part' line of its own"
done
grep -qE '^[0-9]+\. \[ \] <' "$plan" || note 'dev-plan: the template step is not a numbered "N. [ ]" line'
flat "$plan" | grep -q 'never - \[ \]' || note 'dev-plan: does not warn that "- [ ]" is not a step'

for tool in plan-input.sh plan-check.sh step-budget.sh learned.md; do
  grep -q "$tool" "$plan" || note "dev-plan: never names $tool"
done
grep -q '^!`.*plan-input.sh \$ARGUMENTS' "$plan" || note 'dev-plan: the brief is not injected through plan-input.sh $ARGUMENTS'
flat "$plan" | grep -q 'OVER — kept:' || note 'dev-plan: an unsplittable OVER step has no wording to keep it'
flat "$plan" | grep -q '\[assumed\]' || note 'dev-plan: unanswered questions are not tagged [assumed]'
flat "$plan" | grep -q 'Shell before reading' || note 'dev-plan: the CLI-first block is missing'
grep -q -- '--review' "$plan" && note 'dev-plan: --review is back; judging a proposal is judgement work'
# plan-check.sh refuses a step with no Red: line, so the planner has to know
# what goes in it: the test that fails first, or none with its reason.
flat "$plan" | grep -q 'Red first' || note 'dev-plan: no rule saying what a step names in Red:'
flat "$plan" | grep -q 'none — <reason>' || note 'dev-plan: a step with nothing to be red has no wording for why'

# /dev-implement is handed the step by task-step.sh, which prints NO STEPS when
# the plan is not in the shape steps.awk reads. The skill has to stop on that
# line — a run that went on once rewrote the plan's headings with sed and lost
# fifteen steps — and the rule sits a few bytes under the size cap, where the
# next trim can take it.
impl="$skills/dev-implement/SKILL.md"
flat "$impl" | grep -q 'NO STEPS → print Next: /dev-plan <task-file> and stop' || note 'dev-implement: NO STEPS must print the Next: line and stop, nothing else'
# The three sentences the 2026-09-11 runs lacked: an unlisted branch.sh answer
# let a run commit on master; a bare "scoped test" and a bare script name each
# sent the model to read scripts instead of running them. The first is code now:
# step-start.sh runs branch.sh before the model reads anything and turns any
# other answer into a STOP that pi/commands.js never sends, so what has to hold
# is that the injection is there and the model is told not to branch itself.
grep -q '^!`.*step-start.sh \$ARGUMENTS' "$impl" || note 'dev-implement: no step-start.sh injection — the model would be left to run branch.sh itself'
flat "$impl" | grep -q 'never run branch.sh' || note 'dev-implement: does not tell the model never to run branch.sh itself'
flat "$impl" | grep -q 'test.sh --scoped <name>' || note 'dev-implement: the scoped test command is not spelled out'
flat "$impl" | grep -q 'never cat them' || note 'dev-implement: no rule against reading the dev-lib scripts'
# The bench's model built its own objects in new tests, and the file's setup was what made them work:
# 11-13 tests failed for a reason its code could not fix, and they hid its one real bug.
flat "$impl" | grep -q 'New tests use the setup their file already has' || note 'dev-implement: does not tell new tests to reuse their file'\''s setup'
# Red first: the step's Red: test runs before any production line, and a test
# that already passes stops the build. The import sentence it replaced was
# PHP-only; lint and /dev-review C5 still catch a broken import.
grep -q 'dev-lib}/test.sh --red <name>' "$impl" || note 'dev-implement: the red-first command is not spelled out'
flat "$impl" | grep -q 'RED NOT PROVEN' || note 'dev-implement: no rule for a test that passed before the change'
# RED UNCLEAR has two causes that need opposite fixes: a test that will not load
# is fixed in the test, a profile with no testScoped {name} in the profile.
flat "$impl" | grep -q 'testScoped' || note 'dev-implement: RED UNCLEAR from a missing testScoped is not told apart from a test that will not load'
flat "$impl" | grep -q 'cross-namespace references' && note 'dev-implement: the PHP-only import sentence is back, in the bytes red first needs'

# /dev-fix's Mode B names its lint and scoped-test commands in full: a bare
# "lint.sh <path>" and a bare "testScoped" sent a model to read scripts.
fix="$skills/dev-fix/SKILL.md"
grep -q 'dev-lib}/lint.sh <path>' "$fix" || note 'dev-fix: Mode B does not spell the lint command'
grep -q 'dev-lib}/test.sh --scoped <name>' "$fix" || note 'dev-fix: Mode B does not spell the scoped test command'
# Mode A writes a plan plan-check.sh reads, so its step lines include Red:.
flat "$fix" | grep -q 'Test:, Red:' || note 'dev-fix: the Mode A step lines do not include Red:'

# The same omission in three more skills: a script named without its path, or
# a rule left out, is what a byte-cap trim removes first.
pr="$skills/dev-pr/SKILL.md"
manual="$skills/dev-plan-manual/SKILL.md"
grep -q 'dev-lib}/verify-clean.sh' "$pr" || note 'dev-pr: verify-clean.sh is named without its invocation'
# Red first reaches the pull request: a step that planned a red test and has no
# proven receipt stops here, and the body quotes the red line beside the green.
flat "$pr" | grep -q 'red-planned: names a test and red:' || note 'dev-pr: no stop for a planned red test with no proven receipt'
flat "$pr" | grep -q 'the tested: verdict, and red:' || note 'dev-pr: the Testing section does not quote red:'
grep -q 'dev-lib}/plan-check.sh <file>' "$manual" || note 'dev-plan-manual: plan-check.sh is named without its invocation'
grep -q 'dev-lib}/step-budget.sh <file> <n>' "$manual" || note 'dev-plan-manual: step-budget.sh is named without its invocation'
flat "$plan" | grep -q 'never cat them' || note 'dev-plan: no rule against reading the dev-lib scripts'

# The manual plan keeps the same step shape — task-step.sh, step-budget.sh and
# plan-check.sh parse it the same way — plus the two lines that are only its:
# the commit the developer owes, and the walkthrough that is not written yet.
for part in 'Create:' 'Modify:' 'Test:' 'Red:' 'Check:' 'Budget:' 'Commit:'; do
  grep -qE "^ +- $part" "$manual" || note "dev-plan-manual: the step template has no indented '$part' line of its own"
done
grep -qE '^[0-9]+\. \[ \] <' "$manual" || note 'dev-plan-manual: the template step is not a numbered "N. [ ]" line'
grep -qE '^ +Walkthrough:' "$manual" || note 'dev-plan-manual: no placeholder line for the walkthrough written later'
# The developer writes the code, so the developer runs red first — spelled out,
# or a coach session skips it the way a builder would.
grep -q 'dev-lib}/test.sh --red <name>' "$manual" || note 'dev-plan-manual: Mode B does not spell the red-first command'
# The walkthrough sits inside a step block, where steps.awk reads Create:,
# Modify: and Test: as path lists wherever they appear. Its labels must not
# collide with those three, and the skill has to say so.
flat "$manual" | grep -q 'Never Create:, Modify: or Test: in a walkthrough' \
  || note 'dev-plan-manual: does not warn that the walkthrough labels must avoid the path kinds'
flat "$manual" | grep -q 'No implementation' \
  || note 'dev-plan-manual: does not forbid a finished implementation in the plan'

if [ "$fails" -eq 0 ]; then
  printf 'file-lists: the plan template keeps the shape the scripts parse\n'
else
  printf 'file-lists: %s gap(s)\n' "$fails" >&2
fi
exit $((fails > 0))
