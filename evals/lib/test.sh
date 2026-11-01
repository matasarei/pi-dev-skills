#!/usr/bin/env bash
# Cases for lib/test.sh — run them from anywhere:
#
#   bash evals/lib/test.sh
#
# The one thing this script must never do is read as a pass when nothing ran, so
# each outcome is asserted by its exact verdict line: pass, fail, missing,
# timeout, and a scoped run. The runner is a stub and the profile is written by
# hand, so the suite never depends on what this machine has installed.
#
# Exits 0 when every case matches, 1 otherwise, naming each mismatch.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
script="$root/lib/test.sh"
[ -f "$script" ] || { printf 'no test.sh at %s\n' "$script" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

fails=0
note() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
profile() { # profile <test value> <testScoped value> [timeoutTool]
  mkdir -p "$work/.devskills"
  printf '{\n  "baseBranch": "main",\n  "test": %s,\n  "testScoped": %s,\n  "timeoutTool": %s\n}\n' \
    "$1" "$2" "${3:-null}" > "$work/.devskills/profile.json"
}
run() { out="$(cd "$work" && bash "$script" "$@" 2>&1)"; rc=$?; }
first() { printf '%s\n' "$out" | head -1; }

# A stub runner that prints a PHPUnit-shaped summary and fails only on demand.
printf '#!/bin/sh\nif [ "$1" = fail ]; then echo "some noise"; echo "FAILURES! Tests: 43, Failures: 1."; exit 1; fi\nif [ "$1" = hang ]; then sleep 30; fi\necho "some noise"\necho "OK (43 tests, 118 assertions)"\necho ""\n' > "$work/runner.sh"
chmod +x "$work/runner.sh"

# No test command is MISSING, never a pass.
profile null null
run
[ "$rc" -eq 2 ] || note "no test command: exit $rc, want 2"
case "$(first)" in "TEST MISSING"*) ;; *) note "no test command: '$(first)'" ;; esac

# A pass quotes the runner's own summary, not the last line (which is blank).
profile '"sh ./runner.sh"' null
run
[ "$rc" -eq 0 ] || note "pass: exit $rc, want 0"
case "$(first)" in "TEST PASS | OK (43 tests, 118 assertions)"*) ;; *) note "pass: '$(first)'" ;; esac

# With no timeout tool the verdict says so rather than dropping the bound quietly.
printf '%s\n' "$out" | head -1 | grep -q 'unbounded' || note 'pass: a null timeoutTool is not declared in the verdict'

# A failure quotes the failing summary and exits 1.
profile '"sh ./runner.sh fail"' null
run
[ "$rc" -eq 1 ] || note "fail: exit $rc, want 1"
case "$(first)" in "TEST FAIL | FAILURES! Tests: 43, Failures: 1."*) ;; *) note "fail: '$(first)'" ;; esac
printf '%s\n' "$out" | grep -q 'some noise' || note 'fail: the runner output is not shown below the verdict'

# --scoped uses testScoped with {name} filled in, and the name is an argument.
profile '"sh ./runner.sh"' '"sh ./runner.sh {name}"'
run --scoped fail
[ "$rc" -eq 1 ] || note "scoped: exit $rc, want 1 (the stub fails on 'fail')"
case "$(first)" in "TEST FAIL | FAILURES!"*) ;; *) note "scoped: '$(first)'" ;; esac

# A scope that is not a plain test name is refused, not quoted around.
run --scoped 'x; touch PWNED'
[ "$rc" -eq 2 ] || note "hostile scope: exit $rc, want 2"
[ -f "$work/PWNED" ] && note 'hostile scope: the value executed'

# testScoped null falls back to the whole suite rather than running nothing.
profile '"sh ./runner.sh"' null
run --scoped SomeTest
[ "$rc" -eq 0 ] || note "scoped with no testScoped: exit $rc, want 0"
case "$(first)" in "TEST PASS"*) ;; *) note "scoped with no testScoped: '$(first)'" ;; esac

# A hang is a failure, when the host can bound it.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  t=timeout; command -v timeout >/dev/null 2>&1 || t=gtimeout
  profile '"sh ./runner.sh hang"' null "\"$t\""
  out="$(cd "$work" && DEV_SKILLS_TEST_TIMEOUT=1 bash "$script" 2>&1)"; rc=$?
  [ "$rc" -eq 1 ] || note "timeout: exit $rc, want 1"
  case "$(first)" in "TEST TIMEOUT"*) ;; *) note "timeout: '$(first)'" ;; esac
else
  printf 'test: no timeout tool on this host, the timeout case was skipped\n' >&2
fi

# The receipt: what was proved, and for which commit. /dev-pr reads it instead
# of taking the model's word that a suite ran.
if command -v git >/dev/null 2>&1; then
  git -C "$work" init -q -b main . 2>/dev/null
  printf 'x\n' > "$work/f"
  git -C "$work" add -A >/dev/null 2>&1
  git -C "$work" -c user.email=t@e -c user.name=t commit -qm base >/dev/null 2>&1
  head_sha="$(git -C "$work" rev-parse HEAD 2>/dev/null)"

  profile '"sh ./runner.sh"' null
  rm -f "$work/.devskills/test-result"
  run
  [ -f "$work/.devskills/test-result" ] || note 'receipt: a pass wrote none'
  [ "$(cut -d' ' -f1 "$work/.devskills/test-result" 2>/dev/null)" = "$head_sha" ] \
    || note 'receipt: the recorded commit is not HEAD'
  cut -d' ' -f2- "$work/.devskills/test-result" 2>/dev/null | grep -q '^TEST PASS' \
    || note "receipt: the verdict was not recorded: '$(cat "$work/.devskills/test-result" 2>/dev/null)'"

  # A failure is a result too, and must not leave the last pass standing.
  profile '"sh ./runner.sh fail"' null
  run
  cut -d' ' -f2- "$work/.devskills/test-result" 2>/dev/null | grep -q '^TEST FAIL' \
    || note 'receipt: a failure did not overwrite the previous pass'

  # No test command writes nothing: there is no result to record.
  rm -f "$work/.devskills/test-result"
  profile null null
  run
  [ -f "$work/.devskills/test-result" ] && note 'receipt: TEST MISSING wrote a receipt'
fi

# An absent toolchain must read as the project's runner missing, not as this
# script being broken. $0 was "test.sh", so `go test` with no go installed came
# back as "test.sh: go: command not found".
profile '"definitely-not-a-real-command --run"' null
run
[ "$rc" -eq 1 ] || note "absent runner: exit $rc, want 1"
printf '%s\n' "$out" | grep -q '^TEST FAIL' || note "absent runner: '$(first)'"
printf '%s\n' "$out" | grep -q 'test\.sh:' && note 'absent runner: the error names test.sh, as if the toolkit were broken'
printf '%s\n' "$out" | grep -q 'project test command' || note "absent runner: the error does not say whose command it is: '$(first)'"

# node --test prints its counts on separate lines, so the generic summary search
# picked "duration_ms" on a pass and a stray closing brace on a failure -- neither
# quotable as evidence, which is the whole point of the verdict line.
printf '#!/bin/sh\ncat <<EOF\nTAP version 13\nok 1 - slugify\n1..1\n# tests 1\n# suites 0\n\u2139 pass 1\n\u2139 fail $1\n\u2139 duration_ms 37.5\nEOF\nexit $1\n' > "$work/node-ish.sh"
chmod +x "$work/node-ish.sh"

profile '"sh ./node-ish.sh 0"' null
run
[ "$rc" -eq 0 ] || note "node --test pass: exit $rc, want 0"
case "$(first)" in "TEST PASS | pass 1, fail 0"*) ;; *) note "node --test pass: '$(first)'" ;; esac

profile '"sh ./node-ish.sh 1"' null
run
[ "$rc" -eq 1 ] || note "node --test fail: exit $rc, want 1"
case "$(first)" in "TEST FAIL | pass 1, fail 1"*) ;; *) note "node --test fail: '$(first)'" ;; esac

# A runner that prints no counts must still fall through to the generic search.
profile '"sh ./runner.sh"' null
run
case "$(first)" in "TEST PASS | OK (43 tests, 118 assertions)"*) ;; *) note "non-node runner regressed: '$(first)'" ;; esac

# --red: a step's test must fail before its code is written. PROVEN needs a test
# that ran and failed; a pass proves nothing yet; a failure with no failing-test
# count — a parse or collection error, a build failure, an unknown runner — is
# unclear, never proven. Each stub prints what that runner prints.
cat > "$work/red.sh" <<'SH'
case "$1" in
  phpunit-fail)   echo "FAILURES! Tests: 1, Assertions: 1, Failures: 1."; exit 1 ;;
  phpunit-error)  echo "Error: Class \"Slug\" not found"; echo "ERRORS! Tests: 1, Assertions: 0, Errors: 1."; exit 2 ;;
  php-parse)      echo "PHP Parse error: syntax error, unexpected token \"}\" in tests/SlugTest.php on line 9"; exit 255 ;;
  pytest-fail)    echo "FAILED tests/test_slug.py::test_truncate"; echo "=========== 1 failed in 0.02s ==========="; exit 1 ;;
  pytest-collect) echo "ERROR tests/test_slug.py"; echo "!!!!!!! Interrupted: 1 error during collection !!!!!!!"; echo "=========== 1 error in 0.05s ==========="; exit 2 ;;
  node-fail)      echo "✖ truncate cuts (1.539125ms)"; echo "ℹ tests 1"; echo "ℹ pass 0"; echo "ℹ fail 1"; echo "✖ failing tests:"; echo "✖ truncate cuts (1.539125ms)"; exit 1 ;;
  node-syntax)    echo "SyntaxError: Unexpected token ';'"; echo "✖ tests/slug.test.js (26.821ms)"; echo "ℹ tests 1"; echo "ℹ pass 0"; echo "ℹ fail 1"; exit 1 ;;
  node-missing)   echo "Error: Cannot find module '../src/truncate.js'"; echo "  code: 'MODULE_NOT_FOUND',"; echo "✖ tests/slug.test.js (26.821ms)"; echo "ℹ tests 1"; echo "ℹ pass 0"; echo "ℹ fail 1"; exit 1 ;;
  node-reference) echo "ReferenceError: notWrittenYet is not defined"; echo "✖ tests/slug.test.js (26.821ms)"; echo "ℹ tests 1"; echo "ℹ pass 0"; echo "ℹ fail 1"; echo "✖ failing tests:"; echo "✖ tests/slug.test.js (26.821ms)"; exit 1 ;;
  node-type)      echo "TypeError: truncate is not a function"; echo "✖ tests/slug.test.mjs (26.227292ms)"; echo "ℹ tests 1"; echo "ℹ pass 0"; echo "ℹ fail 1"; exit 1 ;;
  jest-fail)      echo "Test Suites: 1 failed, 1 total"; echo "Tests:       1 failed, 1 total"; exit 1 ;;
  jest-empty)     echo "Test Suites: 1 failed, 1 total"; echo "Tests:       0 total"; exit 1 ;;
  go-fail)        echo "--- FAIL: TestTruncate (0.00s)"; echo "FAIL"; exit 1 ;;
  go-build)       echo "./slug_test.go:9:2: undefined: Truncate"; echo "FAIL	example.com/slug [build failed]"; exit 1 ;;
  cargo-fail)     echo "test result: FAILED. 0 passed; 1 failed; 0 ignored"; exit 101 ;;
  pass)           echo "OK (1 test, 1 assertion)"; exit 0 ;;
  *)              echo "boom"; exit 1 ;;
esac
SH
profile '"sh ./runner.sh"' '"sh ./red.sh {name}"'
red_case() { # red_case <name> <verdict prefix> <exit>
  run --red "$1"
  [ "$rc" -eq "$3" ] || note "red $1: exit $rc, want $3"
  case "$(first)" in "$2"*) ;; *) note "red $1: '$(first)', want '$2…'" ;; esac
}
red_case phpunit-fail   'RED PROVEN | FAILURES! Tests: 1' 0
red_case phpunit-error  'RED PROVEN | ERRORS! Tests: 1' 0
red_case php-parse      'RED UNCLEAR |' 1
red_case pytest-fail    'RED PROVEN |' 0
red_case pytest-collect 'RED UNCLEAR |' 1
red_case node-fail      'RED PROVEN |' 0
# node --test counts a test file that never loaded as "fail 1", the same line a
# real failing assertion prints. Any error while the file loads — a syntax error,
# a missing module, a top-level ReferenceError or TypeError — is unclear; node
# names that failing entry after the file, where a real failure names the test.
red_case node-syntax    'RED UNCLEAR |' 1
red_case node-missing   'RED UNCLEAR |' 1
red_case node-reference 'RED UNCLEAR |' 1
red_case node-type      'RED UNCLEAR |' 1
red_case jest-fail      'RED PROVEN |' 0
red_case jest-empty     'RED UNCLEAR |' 1
red_case go-fail        'RED PROVEN |' 0
red_case go-build       'RED UNCLEAR |' 1
red_case cargo-fail     'RED PROVEN |' 0
red_case pass           'RED NOT PROVEN' 1
red_case unknown-runner 'RED UNCLEAR |' 1
printf '%s\n' "$out" | grep -q 'boom' || note 'red unclear: the runner output is not shown below the verdict'

# vitest, from real output (evals/fixtures/vitest, captured in space-city through
# `npm run test:coverage -- <name>`). A file that never loads prints
# "Test Files  1 failed (1)" beside "Tests  no tests": that is not a failing test.
fixtures="$root/evals/fixtures/vitest"
printf '#!/bin/sh\ncat "%s/$1.txt"\n[ "$1" = pass ]\n' "$fixtures" > "$work/vitest.sh"
profile '"sh ./runner.sh"' '"sh ./vitest.sh {name}"'
red_case fail 'RED PROVEN |' 0
red_case load 'RED UNCLEAR |' 1
red_case pass 'RED NOT PROVEN' 1

# With no testScoped the whole suite runs and the name never reaches it, so a
# failure anywhere in the suite is not this test failing. Never PROVEN.
profile '"sh ./red.sh phpunit-fail"' null
run --red BrandNewTest
[ "$rc" -eq 1 ] || note "red with no testScoped: exit $rc, want 1"
case "$(first)" in "RED UNCLEAR"*testScoped*) ;; *) note "red with no testScoped: '$(first)'" ;; esac
profile '"sh ./runner.sh"' '"sh ./red.sh {name}"'

# A red name reaches a command line exactly as a scoped one does.
run --red 'x; touch PWNED'
[ "$rc" -eq 2 ] || note "hostile red name: exit $rc, want 2"
[ -f "$work/PWNED" ] && note 'hostile red name: the value executed'
run --red
[ "$rc" -eq 2 ] || note "red with no name: exit $rc, want 2"

# The red receipt is its own file. .devskills/test-result is /dev-pr's green
# gate, and a deliberate failure must never be recorded there.
if [ -d "$work/.git" ]; then
  printf 'feedface TEST PASS | kept\n' > "$work/.devskills/test-result"
  rm -f "$work/.devskills/red-result"
  run --red phpunit-fail
  [ "$(cat "$work/.devskills/test-result")" = 'feedface TEST PASS | kept' ] \
    || note "red receipt: a red run rewrote test-result: '$(cat "$work/.devskills/test-result")'"
  # The receipt names the branch it proves red for, so a reader can refuse one
  # recorded on another branch or an earlier step.
  [ "$(cut -d' ' -f1-3 "$work/.devskills/red-result" 2>/dev/null)" = "$head_sha main phpunit-fail" ] \
    || note "red receipt: not '<HEAD> <branch> <name> …': '$(cat "$work/.devskills/red-result" 2>/dev/null)'"
  cut -d' ' -f4- "$work/.devskills/red-result" 2>/dev/null | grep -q '^RED PROVEN' \
    || note 'red receipt: the verdict was not recorded'
  # A detached HEAD has no branch to prove red for: "-", which matches none.
  git -C "$work" checkout -q --detach 2>/dev/null
  run --red phpunit-fail
  [ "$(cut -d' ' -f2 "$work/.devskills/red-result" 2>/dev/null)" = "-" ] \
    || note "red receipt: a detached HEAD did not record '-': '$(cat "$work/.devskills/red-result" 2>/dev/null)'"
  git -C "$work" checkout -q main 2>/dev/null
  rm -f "$work/.devskills/red-result"
  run --red 'x; y'
  [ -f "$work/.devskills/red-result" ] && note 'red receipt: a refused name wrote a receipt'
fi

if [ "$fails" -eq 0 ]; then
  printf 'test: pass, fail, missing, scoped, timeout and red each get their verdict line\n'
else
  printf 'test: %s case(s) failed\n' "$fails" >&2
fi
exit $((fails > 0))
