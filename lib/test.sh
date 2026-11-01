#!/usr/bin/env bash
# Run this project's tests and say in one line what happened.
#
# Every skill used to spell this out as prose: pick `test` or `testScoped`, wrap
# it in `timeoutTool`, run it, then quote "the runner's result line". That is
# four judgement calls, and a model that drops any one of them reports "tests
# pass" with nothing behind it. They are decided here instead.
#
#   test.sh                    the profile's `test`
#   test.sh --scoped <name>    the profile's `testScoped`, with {name} filled in
#   test.sh --red <name>       the same scoped run, before the code it tests exists:
#                              the test has to fail, and fail as a test
#
# The first line of output is always the verdict, carrying the runner's own
# summary so it can be quoted as evidence:
#
#   TEST PASS | OK (43 tests, 118 assertions)
#   TEST FAIL | FAILURES! Tests: 43, Assertions: 118, Failures: 1.
#   TEST MISSING — no test command in the profile; this repository may have none
#   TEST TIMEOUT — no result after 600s; a hang is a failure, not a slow pass
#
# On anything but PASS the runner's last 20 lines follow, so the failure can be
# read without running it again. Exit 0 pass, 1 fail or timeout, 2 nothing ran.
#
# The verdict is also written to .devskills/test-result as "<HEAD sha> <verdict>",
# so /dev-pr can tell whether anything was actually run for the code it is about
# to propose, instead of taking the model's word for it.
#
# --red answers a different question — was this test red before the change? — so
# it has its own verdicts, first line as always:
#
#   RED PROVEN | FAILURES! Tests: 1, Assertions: 1, Failures: 1.     exit 0
#   RED NOT PROVEN — the test passed before the change; …          exit 1
#   RED UNCLEAR | <summary>                                          exit 1
#
# PROVEN needs a test that ran and failed. A failure with no failing-test count —
# a parse error, a collection error, a build failure, a runner not recognised
# below — is UNCLEAR: something broke, but not necessarily the test. It writes
# .devskills/red-result as "<HEAD sha> <branch> <name> <verdict>" — "-" for the
# branch on a detached HEAD — and never .devskills/test-result: a deliberate
# failure is not the change's test verdict.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"

SECS="${DEV_SKILLS_TEST_TIMEOUT:-600}"
case "$SECS" in ''|*[!0-9]*) SECS=600 ;; esac

[ -f .devskills/profile.json ] || bash "$HERE/profile.sh" >/dev/null 2>&1

field() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\(.*\)\",\{0,1\}$/\1/p" .devskills/profile.json 2>/dev/null | head -1 | sed 's/",\{0,1\}$//; s/\\"/"/g'; }

SCOPED=""; RED=""
case "${1:-}" in
  --scoped|--red)
    [ "$1" = --red ] && RED=1
    SCOPED="${2:-}"
    # A filter name reaches a command line. Anything but a plain test identifier
    # is refused here rather than quoted around later; see lib/lint.sh for why a
    # value spliced into a command string is not made safe by quoting it.
    case "$SCOPED" in
      ''|*[!A-Za-z0-9_.:/-]*) echo "TEST MISSING — '$1 $SCOPED' is not a plain test name"; exit 2 ;;
    esac ;;
  "") ;;
  *) echo "usage: test.sh [--scoped <name> | --red <name>]" >&2; exit 64 ;;
esac

if [ -n "$SCOPED" ]; then
  CMD="$(field testScoped)"
  # A red run needs the name to reach the runner. Without a {name} in testScoped
  # the whole suite runs, and a failure anywhere in it is not this test failing.
  if [ -n "$RED" ]; then
    case "$CMD" in
      *'{name}'*) ;;
      *) echo "RED UNCLEAR — no testScoped with {name} in the profile; the whole suite cannot show that $SCOPED failed"; exit 1 ;;
    esac
  fi
  [ -z "$CMD" ] || [ "$CMD" = null ] && CMD="$(field test)"
else
  CMD="$(field test)"
fi

if [ -z "$CMD" ] || [ "$CMD" = null ]; then
  echo "TEST MISSING — no test command in the profile; this repository may have none"
  exit 2
fi

TIMEOUT="$(field timeoutTool)"
[ "$TIMEOUT" = null ] && TIMEOUT=""

CMD="${CMD//\{name\}/\"\$1\"}"

# $0 for the runner shell. It was "test.sh", so an absent toolchain came back as
# "test.sh: go: command not found" — which reads as this script being broken
# rather than the project's runner being missing. Deriving the runner's own name
# gives "go: go: ...", so say plainly whose command it is.
RUNNER="project test command"

out="$(
  if [ -n "$TIMEOUT" ]; then
    "$TIMEOUT" "$SECS" bash -c "$CMD" "$RUNNER" "$SCOPED" 2>&1
  else
    bash -c "$CMD" "$RUNNER" "$SCOPED" 2>&1
  fi
)"
rc=$?

# The runner's own summary, searched for from the end: the last line is often a
# blank or a coverage footer, and "tests pass" is not evidence of anything.
# node --test prints its counts on separate lines, so neither alone is a summary
# and the generic search below picks up "duration_ms" on a pass and a stray brace
# on a failure. Field-based, because the marker it prefixes them with is
# multibyte and matching it by regex is locale-dependent.
summary="$(printf '%s\n' "$out" | awk '
  NF >= 2 && $(NF-1) == "pass" && $NF ~ /^[0-9]+$/ { p = $NF }
  NF >= 2 && $(NF-1) == "fail" && $NF ~ /^[0-9]+$/ { f = $NF }
  END { if (p != "" && f != "") printf "pass %s, fail %s", p, f }
')"

[ -z "$summary" ] && summary="$(printf '%s\n' "$out" | grep -E \
  '^(OK|FAILURES!|ERRORS!|PASS|FAIL|ok|--- FAIL)\b|Tests:[[:space:]]*[0-9]|test result:|[0-9]+ (passed|failed|error)|=+ .*(passed|failed|error)' \
  | tail -1 | sed 's/^[[:space:]]*//')"
[ -z "$summary" ] && summary="$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1 | sed 's/^[[:space:]]*//')"
[ -z "$summary" ] && summary="(the runner printed nothing)"

# The receipt: what was proved, and for which commit. A verdict with no commit
# behind it is what "tests pass" in a pull request body has always been.
receipt() {
  sha="$(git rev-parse HEAD 2>/dev/null)" || return 0
  [ -n "$sha" ] || return 0
  mkdir -p .devskills 2>/dev/null || return 0
  printf '%s %s\n' "$sha" "$1" > .devskills/test-result 2>/dev/null || true
}

# Did at least one test run and fail? Each rule is one runner's own count:
# PHPUnit "Tests: N … Failures|Errors: N" (a missing class is a real first red
# there), "N failed" from pytest, Jest and cargo — but not Jest's "Test Suites:
# 1 failed", which a file that never loaded also prints — Go's "--- FAIL:", and
# node --test's "fail N". A build or collection failure matches none of them.
# node --test's count is not enough on its own: a test file that never loads —
# a syntax error, a module that does not exist yet, a top-level ReferenceError —
# prints the same "fail 1" a failing assertion does. Node names that failing
# entry after the file ("✖ tests/slug.test.js (26ms)") where a real failure names
# the test ("✖ truncate cuts (1ms)"), so an entry named like a test file is a
# load error, as are the error names that say so. Unclear, as Go's build failure is.
# vitest's "Test Files  1 failed (1)" is its "Test Suites:", printed for a file that
# never loaded too ("Failed to resolve import", then "Tests  no tests"); its own
# "Tests  1 failed (1)" is the count.
failed_as_test() {
  printf '%s\n' "$out" | awk '
    /Test Suites:/ || /Test Files / { next }
    /SyntaxError:|Cannot find module|MODULE_NOT_FOUND/ { load = 1 }
    /✖ [^ ]*\.[cm]?[jt]sx? \(/ { load = 1 }
    /Tests: *[1-9]/ && /(Failures|Errors): *[1-9]/ { r = 1 }
    /(^|[^0-9])[1-9][0-9]* failed/ { r = 1 }
    /^--- FAIL:/ { r = 1 }
    NF >= 2 && $(NF-1) == "fail" && $NF ~ /^[1-9][0-9]*$/ { node = 1 }
    END { exit !(r || (node && !load)) }'
}

if [ -n "$RED" ]; then
  if [ -n "$TIMEOUT" ] && [ "$rc" -eq 124 ]; then
    verdict="RED UNCLEAR | no result after ${SECS}s; a hang is not a failing test"
  elif [ "$rc" -eq 0 ]; then
    verdict="RED NOT PROVEN — the test passed before the change; it proves nothing yet"
  elif failed_as_test; then
    verdict="RED PROVEN | $summary"
  else
    verdict="RED UNCLEAR | $summary"
  fi
  printf '%s\n' "$verdict"
  sha="$(git rev-parse HEAD 2>/dev/null)"
  # The branch this proves red for. The receipt is git-ignored and outlives
  # branches, so a reader refuses one recorded anywhere else; a detached HEAD
  # proves it for no branch at all.
  branch="$(git branch --show-current 2>/dev/null)"
  if [ -n "$sha" ] && mkdir -p .devskills 2>/dev/null; then
    printf '%s %s %s %s\n' "$sha" "${branch:--}" "$SCOPED" "$verdict" > .devskills/red-result 2>/dev/null || true
  fi
  printf '%s\n' "$out" | tail -20
  case "$verdict" in "RED PROVEN"*) exit 0 ;; *) exit 1 ;; esac
fi

if [ -n "$TIMEOUT" ] && [ "$rc" -eq 124 ]; then
  verdict="TEST TIMEOUT — no result after ${SECS}s; a hang is a failure, not a slow pass"
  printf '%s\n' "$verdict"
  receipt "$verdict"
  printf '%s\n' "$out" | tail -20
  exit 1
fi

if [ "$rc" -eq 0 ]; then
  verdict="TEST PASS | $summary$([ -z "$TIMEOUT" ] && printf ' [unbounded: no timeout tool on this host]')"
  printf '%s\n' "$verdict"
  receipt "$verdict"
  exit 0
fi

verdict="TEST FAIL | $summary"
printf '%s\n' "$verdict"
receipt "$verdict"
printf '%s\n' "$out" | tail -20
exit 1
