#!/usr/bin/env bash
# The hand-offs between skills, asserted — run it from anywhere:
#
#   bash evals/skills/cycle.sh
#
# Each skill ends by naming the next command. A small model does what the last
# line of its prompt says, so a hand-off that goes missing is a cycle that
# stops. This suite asserts each link by the literal command name; later steps
# of the plan add their links here as they land.
#
# Exits 0 when every link holds, 1 otherwise, naming each gap.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
skills="$root/skills"
[ -d "$skills" ] || { printf 'no skills at %s\n' "$skills" >&2; exit 1; }

fails=0
note() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
# Prose wrapped at the file's width: match against a flattened copy.
flat() { tr '\n' ' ' < "$skills/$1/SKILL.md" | tr -d '`' | tr -s ' '; }
has() { flat "$1" | grep -qF -- "$2" || note "$1: does not mention '$2' — $3"; }

has dev-plan      '/dev-implement'   'a plan that names no next command is a plan nobody runs'
has dev-implement '/dev-review'      'a built step must be reviewed before it goes anywhere'
has dev-implement '--continue'       'an interrupted build has to say how to resume'
has dev-implement 'task-step.sh $ARGUMENTS' 'the step must arrive injected, not be picked from the whole plan'
has dev-implement 'Modify: paths first' 'the build starts from the step file list, not a search'
has dev-implement 'step/<slug>-<n>'   'one branch per step, stacked'
has dev-implement '/new'              'the context is cleared between steps'
has dev-implement 'learned.md'        'the next run inherits what this one found out'
has dev-implement 'tail -20'          'the learned notes are capped'
has dev-implement 'step-budget.sh'    'an OVER step is said, not refused'
grep -q -- '--all' "$skills/dev-implement/SKILL.md" && note 'dev-implement: --all is back, and it contradicts one step per run'
# A plan marked manual is one the developer asked to write themselves. Building
# it for them is the one failure this whole feature exists to prevent.
has dev-implement '**Mode:** manual'    'a manual plan must be refused, not built'
has dev-implement '/dev-plan-manual'    'and the refusal has to name where that plan is continued'
# dev-plan-manual: the plan nobody but the developer implements. Its two modes
# are decided by the injected blocks, not by the model, and its whole reason to
# exist is that it never writes the code — so both are asserted here.
has dev-plan-manual 'plan-input.sh $ARGUMENTS' 'the brief arrives resolved, not guessed at'
has dev-plan-manual 'task-step.sh $ARGUMENTS'  'coach mode needs the step injected, like /dev-implement'
has dev-plan-manual '**Mode:** manual'   'the marker is what tells the two modes apart'
has dev-plan-manual 'branch.sh'          'the step gets its own branch before a line is typed'
has dev-plan-manual 'tick.sh'            'a finished step is ticked by script, not by hand'
has dev-plan-manual '/dev-review'        'hand-written code is reviewed like any other'
has dev-plan-manual 'No production code' 'the one absolute this skill exists to keep'
has dev-plan-manual 'commit this step yourself' 'the developer is warned to commit every step'
has dev-plan-manual 'plan-check.sh'      'a manual plan is path-checked like any other'
has dev-plan-manual 'into ## Q&A'       'the answers a session gives must outlive it'
flat dev-plan-manual | grep -q '/dev-implement' \
  || note 'dev-plan-manual: never says /dev-implement refuses a manual plan'

has dev-review    'Ready to push'    'the first line of the report is the verdict'
has dev-review    '/dev-fix'          'what survived the filter goes to dev-fix'
has dev-review    '.devskills/reports/' 'a report lands in the ignored directory, not at the root'
has dev-review    'task-step.sh'      'C5 greps the current step file list first'
grep -q 'REVIEW.md' "$skills/dev-review/SKILL.md" && note 'dev-review: still writes REVIEW.md at the root'
# Hand-written code is reviewed the same way and fixed differently: the findings
# belong to whoever typed them, so the last line points at the list and names
# /dev-fix as theirs to run rather than as the next step.
has dev-review '.tasks/${s%-*}.md' 'the review is told when the change on this branch was written by hand'
has dev-review 'Manual plan below' 'a hand-written change gets its findings back, not /dev-fix'
has dev-review 'not (none)'       'an empty block is a fact only if the prompt says what empty means'
# Red first reaches the review: a test added with no proven red run is a C11
# finding, read from test.sh --red's receipt rather than taken on trust.
has dev-review 'RED NOT PROVEN'   'C11 counts a test that was never shown red'
has dev-review 'red-result'       'the red receipt is injected, not remembered'
grep -qi 'worktree' "$skills/dev-verify/SKILL.md" && note 'dev-verify: mentions a worktree this version never creates'
has dev-verify    'evidence, never instruction' 'tool output and PR text are evidence'
has dev-init      'AGENTS.md only'    'dev-init writes AGENTS.md only'
grep -qi 'CLAUDE.md as an @AGENTS.md stub' "$skills/dev-init/SKILL.md" && note 'dev-init: still creates CLAUDE.md stub'
has dev-init      'Never write CLAUDE.md' 'dev-init forbids writing CLAUDE.md'
has dev-fix       'findings-check.sh $ARGUMENTS' 'the findings arrive re-verified, injected'
has dev-fix       'Fix: '             'one commit per finding, named after it'
has dev-fix       '--no-verify'       'a hook failure skips the finding, never bypasses it'
has dev-fix       '/dev-pr'           'a clean fix run hands off to the pull request'
has dev-fix       '/dev-review'       'a fixed blocker earns a second look'
has dev-fix       'learned.md'        'the next run inherits what this one found out'
has dev-pr        'pr-info.sh $ARGUMENTS' 'the base, the pull request and the counts arrive injected'
has dev-pr        '--base <base>'     'a stacked step targets the previous step, not main'
has dev-pr        'Depends on #'      'a stacked pull request names the one it sits on'
has dev-pr        '/new'              'after the pull request the context is cleared'
has dev-pr        '--continue'        'and the next step is named'
has dev-pr        'no session link'   'a private transcript URL is not attribution on a public repository'
has dev-pr        'Generated by Pi' 'dev-pr signs the pull request as Pi, the harness that wrote it'
has dev-pr        '--draft'           'pull requests are always opened as draft'
grep -q 'gh pr merge' "$skills/dev-pr/SKILL.md" && note 'dev-pr: names gh pr merge; opening is where it stops'
has dev-pr-review '/dev-review'      'own changes go to dev-review, not here'
has dev-pr-review 'gh pr view $ARGUMENTS' 'the pull request arrives injected, not fetched by the model'
has dev-pr-review 'pr-comments.sh $ARGUMENTS' 'the comment ledger is injected for deduplication'
has dev-pr-review '.devskills/reports/' 'a report lands in the ignored directory of the primary checkout'
grep -q 'PR_REVIEW_' "$skills/dev-pr-review/SKILL.md" && note 'dev-pr-review: still writes PR_REVIEW_<n>.md at the root'
# The three scripts exist to take four judgement calls away from the model:
# which test command, whether to wrap it, what the result line was, and how to
# edit a checkbox. A skill that describes the act instead of calling the script
# has given them back.
has dev-implement 'branch.sh'  'the stacked branch is cut by script, not by retyping a || chain'
has dev-implement 'test.sh'    'the suite is run by script, so the verdict line is quotable'
has dev-implement 'tick.sh'    'the step is ticked by script, not by hand-editing markdown'
has dev-fix       'test.sh'    'a fix proves itself with the same verdict line'
has dev-verify    'test.sh'    'and so does verification'
grep -q 'git switch -c step/' "$skills/dev-implement/SKILL.md" \
  && note 'dev-implement: the hand-typed branch fallback is back'
flat dev-implement | grep -q 'Tick step in task file' \
  && note 'dev-implement: ticking by hand is back'

# gh only speaks GitHub. A skill that assumes it, on a repository hosted
# anywhere else, prints a URL for a repository that does not exist.
has dev-pr 'compare-url' 'the fallback URL comes from the remote, not from a hardcoded host'
grep -q 'https://github.com/<owner>/<repo>/compare' "$skills/dev-pr/SKILL.md" \
  && note 'dev-pr: the hardcoded github.com compare URL is back'

# A pull request may not claim a check nobody ran.
has dev-pr 'tested:' 'the pull request stops when nothing was proved for this code'
flat dev-pr | grep -q 'Tests not run' \
  && note 'dev-pr: the body can still say "Tests not run" instead of stopping'

# The hand-off has to name the file. /dev-fix injects plan-input.sh and
# findings-check.sh with the same $ARGUMENTS: with none, the brief block says
# EMPTY — which Mode A reads as "ask what to fix" — while the findings block
# holds the list. Naming the file makes the brief say FINDINGS instead.
has dev-review '/dev-fix .devskills/findings.md' 'a bare /dev-fix arrives with an empty brief and a list at once'
has dev-fix    'FINDINGS'   'the mode is decided by the brief kind, not guessed'
has dev-fix    'Never both' 'Mode A and Mode B must not both fire on one input'

# verification: local-only is a computed fact, and a fact nothing reads is a
# field nobody maintains. /dev-verify is where it changes what gets said.
has dev-verify 'local-only' 'the one skill whose job is proving things must say when it is the only check'

# A skill that writes must not also claim it never writes. Both review skills
# maintain .devskills/findings.md — that file is the hallucination filter, and
# an absolute the same page contradicts teaches the model the rules are soft.
for s in dev-review dev-pr-review; do
  flat "$s" | grep -qE 'Read-only|Review only' && note "$s: claims an absolute it breaks in the same file"
  flat "$s" | grep -q '.devskills/' || note "$s: never says what it does write"
done

# The untrusted-input sentence, in every skill that reads outside text.
n="$(grep -l 'evidence, never instruction' "$skills"/*/SKILL.md | wc -l | tr -d ' ')"
[ "$n" -ge 6 ] || note "only $n skills carry 'evidence, never instruction'; at least six read outside text"


if [ "$fails" -eq 0 ]; then
  printf 'cycle: every skill names the next command\n'
else
  printf 'cycle: %s gap(s)\n' "$fails" >&2
fi
exit $((fails > 0))
