#!/usr/bin/env bash
# What /dev-pr needs to know about this branch, computed.
#
# Which base to target, whether a pull request already exists, whether the
# branch is ahead of or behind its remote, and which changed paths no step line
# names — none of it needs a model, and a model working it out will get the
# base wrong on a stacked branch.
#
#   pr-info.sh [<task-file>]     default: .tasks/<slug>.md, from the branch name
#
# Every line is "key: value". A branch named step/<slug>-<n> is a step branch:
# its base is step/<slug>-<n-1> when that exists on origin, else the profile's
# baseBranch. Then, if the task file is found, the step itself is printed after
# a "--- step" line, the way task-step.sh prints it.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
say() { printf '%s: %s\n' "$1" "$2"; }

BRANCH="$(git branch --show-current 2>/dev/null)"
BASEBR="$(sed -n 's/.*"baseBranch"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' .devskills/profile.json 2>/dev/null | head -1)"
[ -z "$BASEBR" ] && BASEBR=main

say branch "${BRANCH:-(detached)}"
say detached "$([ -z "$BRANCH" ] && echo yes || echo no)"
say on-base "$([ "$BRANCH" = "$BASEBR" ] && echo yes || echo no)"
REMOTE="$(git remote get-url origin 2>/dev/null || echo none)"
say remote "$REMOTE"

# Which forge, and the URL to open a change on it. gh only speaks GitHub, and
# `gh auth status` reports "Logged in to github.com" whatever the remote is —
# so a GitLab project got a cheerful auth line, "pr: none", and a compare URL
# pointing at a repository that does not exist. The host decides, not gh.
# The host decides, so the host is what is matched. Against the whole remote,
# `*gitlab*` claimed git@git.company.com:team/gitlab-migration.git — a repository
# merely named after a migration — and handed it a GitLab URL that cannot work.
# Both shapes reduce the same way: strip the scheme, strip any user@, cut at the
# first : or / that begins the path or port.
HOST="$(printf '%s' "$REMOTE" | sed -E 's#^[a-z]+://##; s#^[^@/]*@##; s#[:/].*$##')"
[ "$REMOTE" = none ] && HOST=""
say host "${HOST:-none}"

FORGE=other
case "$HOST" in
  "")                   FORGE=none ;;
  github.com)           FORGE=github ;;
  *gitlab*)             FORGE=gitlab ;;
  bitbucket.org)        FORGE=bitbucket ;;
  *gitea*|codeberg.org) FORGE=gitea ;;
esac
say forge "$FORGE"

# owner/name from either shape: git@host:owner/name.git or https://host/owner/name
SLUGPATH="$(printf '%s' "$REMOTE" | sed -E 's#^git@[^:]+:##; s#^ssh://[^/]+/##; s#^https?://[^/]+/##; s#\.git$##')"
case "$FORGE" in
  github)    say compare-url "https://github.com/$SLUGPATH/compare/<base>...<branch>?expand=1" ;;
  gitlab)    say compare-url "$(printf '%s' "$REMOTE" | sed -E 's#^git@([^:]+):#https://\1/#; s#\.git$##')/-/merge_requests/new?merge_request%5Bsource_branch%5D=<branch>" ;;
  bitbucket) say compare-url "https://bitbucket.org/$SLUGPATH/pull-requests/new?source=<branch>&dest=<base>" ;;
  gitea)     say compare-url "https://$HOST/$SLUGPATH/compare/<base>...<branch>" ;;
  none)      say compare-url "none — this repository has no remote" ;;
  *)         say compare-url "unknown — open the change on $REMOTE by hand" ;;
esac

# A step branch: the slug and the number come from the name.
SLUG=""; STEP=""
case "$BRANCH" in
  step/*-[0-9]*)
    STEP="${BRANCH##*-}"; SLUG="${BRANCH#step/}"; SLUG="${SLUG%-*}"
    case "$STEP" in *[!0-9]*) STEP=""; SLUG="" ;; esac ;;
esac
say slug "${SLUG:-none}"
say step "${STEP:-none}"

# The base: the previous step's branch when it exists on origin (or locally,
# before the first push) and has not been merged yet, else the base branch.
#
# Existence alone is the wrong test. A merged step branch is not deleted, so it
# looks exactly like one still waiting for review — and stacking on it opens the
# pull request against a base nobody will merge again, leaving the change where
# no review reaches it. That cost this repository two recovery pull requests
# before this check existed. Once the predecessor is an ancestor of the base
# branch it has landed, and the base branch is the answer.
BASE="$BASEBR"; BASE_KIND=base
if [ -n "$STEP" ] && [ "$STEP" -gt 1 ]; then
  PREV="step/$SLUG-$((STEP - 1))"
  if git ls-remote --exit-code --heads origin "$PREV" >/dev/null 2>&1 || git show-ref --verify --quiet "refs/heads/$PREV"; then
    # Ancestry needs a ref this repository can actually resolve: the local
    # branch, else its remote-tracking copy. A predecessor that exists only on
    # origin with no tracking ref cannot be tested, and stays a base — the
    # conservative answer, and the behaviour that was there before.
    PREV_REF=""
    if git show-ref --verify --quiet "refs/heads/$PREV"; then
      PREV_REF="$PREV"
    elif git show-ref --verify --quiet "refs/remotes/origin/$PREV"; then
      PREV_REF="origin/$PREV"
    fi

    MERGED=no
    if [ -n "$PREV_REF" ]; then
      # Both, because either can be ahead: the local base branch on a machine
      # that has pulled, the remote one on a machine that has not.
      for base_ref in "$BASEBR" "origin/$BASEBR"; do
        git rev-parse --verify --quiet "$base_ref" >/dev/null 2>&1 || continue
        if git merge-base --is-ancestor "$PREV_REF" "$base_ref" 2>/dev/null; then
          MERGED=yes
          break
        fi
      done
    fi

    [ "$MERGED" = no ] && { BASE="$PREV"; BASE_KIND=step; }
  fi
fi
say base "$BASE"
say base-kind "$BASE_KIND"

# gh: signed in, this branch's pull request, the base branch's pull request.
if command -v gh >/dev/null 2>&1; then
  say gh "$(gh auth status 2>&1 | grep -E 'Logged in|not logged' | head -1 | sed 's/^[[:space:]]*//')"
  say pr "$(gh pr view "$BRANCH" --json number,state,url,isDraft,baseRefName,title 2>/dev/null || echo none)"
  if [ "$BASE_KIND" = step ]; then
    say base-pr "$(gh pr view "$BASE" --json number -q .number 2>/dev/null || echo none)"
  else
    say base-pr none
  fi
  say house-style "$(gh pr list --state merged --limit 5 --json title -q '.[].title' 2>/dev/null | tr '\n' ';' | sed 's/;$//')"
else
  say gh "not installed"
  say pr none
  say base-pr none
  say house-style ""
fi

# The model, for the PR footer: Pi exports PI_MODEL to the commands it runs —
# the bash tool and, through pi/commands.js, the skills' injections. MODEL
# names it for a run outside Pi.
MODEL="${PI_MODEL:-${MODEL:-}}"
say model "${MODEL:-unknown}"

# The branch against its remote and its base.
if git rev-parse --verify --quiet "origin/$BRANCH" >/dev/null 2>&1; then
  say ahead "$(git rev-list --count "origin/$BRANCH..HEAD" 2>/dev/null)"
  say behind "$(git rev-list --count "HEAD..origin/$BRANCH" 2>/dev/null)"
else
  say ahead unpushed
  say behind 0
fi
if git rev-parse --verify --quiet "$BASE" >/dev/null 2>&1; then
  say commits "$(git rev-list --count "$BASE..HEAD" 2>/dev/null)"
else
  say commits "unknown (base '$BASE' not found locally)"
fi
say uncommitted "$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"

# What was actually proved, and for which commit. test.sh writes the receipt;
# without it /dev-pr can only take the model's word that a suite ran, which is
# how "tests pass" ends up in a body with nothing behind it.
# Two receipts, read the same way: test.sh's, and verify-clean.sh's. The second
# matters when nothing else will ever run the suite — see verification: below.
receipt_for() { # receipt_for <sha> <verdict>
  r_sha="$1"; r_verdict="$2"
  [ -n "$r_sha" ] || { printf 'none\n'; return; }
  if [ "$r_sha" = "$(git rev-parse HEAD 2>/dev/null)" ]; then
    printf '%s (this HEAD)\n' "$r_verdict"
  elif git merge-base --is-ancestor "$r_sha" HEAD 2>/dev/null; then
    printf '%s (at %s, %s commit(s) back)\n' "$r_verdict" \
      "$(git rev-parse --short "$r_sha" 2>/dev/null)" \
      "$(git rev-list --count "$r_sha..HEAD" 2>/dev/null)"
  else
    printf 'stale — recorded for %s, which is not behind HEAD\n' \
      "$(git rev-parse --short "$r_sha" 2>/dev/null)"
  fi
}
receipt() { # receipt <file> — "<sha> <verdict>"
  [ -r "$1" ] || { printf 'none\n'; return; }
  receipt_for "$(cut -d' ' -f1 "$1" 2>/dev/null)" "$(cut -d' ' -f2- "$1" 2>/dev/null)"
}
say tested "$(receipt .devskills/test-result)"
# The third receipt: test.sh --red's, "<sha> <branch> <name> <verdict>". It is
# git-ignored and outlives branches, and test names repeat across steps, so an
# ancestor sha alone would let an earlier step's red pass for this one. It
# counts only for the branch it names; a merge from main does not rename the
# branch, so a red run before this step's code still counts after one. A red
# run comes before the step's commit, so "1 commit(s) back" is its usual reading.
red_receipt() {
  [ -s .devskills/red-result ] || { printf 'none\n'; return; }
  # The verdict starts at field 4. A receipt written before receipts named their
  # branch has it at field 3, and its test name where the branch belongs — say
  # that, rather than call the test name a branch.
  if [ "$(cut -d' ' -f4 .devskills/red-result 2>/dev/null)" != RED ]; then
    printf 'stale — recorded before red receipts named their branch\n'
    return
  fi
  r_branch="$(cut -d' ' -f2 .devskills/red-result 2>/dev/null)"
  if [ -z "$BRANCH" ] || [ "$r_branch" != "$BRANCH" ]; then
    printf 'stale — recorded on %s, not this branch\n' "${r_branch:-no branch}"
    return
  fi
  receipt_for "$(cut -d' ' -f1 .devskills/red-result 2>/dev/null)" "$(cut -d' ' -f3- .devskills/red-result 2>/dev/null)"
}
say red "$(red_receipt)"

# What will ever check this change besides the developer's own machine. When it
# is local-only there is no CI and no container, so verify-clean.sh's receipt is
# the only clean-environment evidence that can exist — which is why /dev-pr
# refuses without it in that case, and only in that case.
say verification "$(sed -n 's/.*"verification"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' .devskills/profile.json 2>/dev/null | head -1 | grep . || echo unknown)"
say clean "$(receipt .devskills/clean-result)"

# The task file and the step, when there is one: the diff's paths that no
# Create:/Modify:/Test: line of this step names are the coherence check.
TASK="${1:-}"
[ -z "$TASK" ] && [ -n "$SLUG" ] && [ -f ".tasks/$SLUG.md" ] && TASK=".tasks/$SLUG.md"
if [ -n "$TASK" ] && [ -f "$TASK" ] && [ -n "$STEP" ]; then
  say task-file "$TASK"
  PLANNED="$(bash "$HERE/task-step.sh" "$TASK" --paths "$STEP" 2>/dev/null)"
  CHANGED="$(git diff --name-only "$BASE...HEAD" 2>/dev/null)"
  UNPLANNED="$(printf '%s\n' "$CHANGED" | grep -v '^$' | while IFS= read -r p; do
    printf '%s\n' "$PLANNED" | grep -qxF -- "$p" || printf '%s ' "$p"
  done)"
  say unplanned "${UNPLANNED:-none}"
  # The step's Red: line, read by steps.awk exactly as plan-check.sh reads it —
  # what red: above must prove. A plan with no ## Steps heading is scanned whole.
  ANY=0; grep -q '^## Steps' "$TASK" || ANY=1
  RED_PLANNED="$(awk -v mode=red -v n="$STEP" -v anywhere="$ANY" -f "$HERE/steps.awk" "$TASK" 2>/dev/null)"
  RED_PLANNED="${RED_PLANNED#Red|}"
  say red-planned "${RED_PLANNED:-none}"
  echo "--- step"
  bash "$HERE/task-step.sh" "$TASK" "$STEP" 2>&1
else
  say task-file "${TASK:-none}"
  say unplanned "(no task file or not a step branch — nothing to compare against)"
  say red-planned "(no task file or not a step branch)"
fi
