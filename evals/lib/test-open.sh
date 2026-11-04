#!/usr/bin/env bash
# Cases for lib/test-open.sh — run them from anywhere:
#
#   bash evals/lib/test-open.sh
#
# Opening a test lets a step finish while it fails, so what it refuses matters as
# much as what it records: a test that was there before, nothing failing, and output
# with no test name in it. The runner is a stub and the profile is written by hand.
#
# Exits 0 when every case matches, 1 otherwise, naming each mismatch.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
script="$root/lib/test-open.sh"
[ -f "$script" ] || { printf 'no test-open.sh at %s\n' "$script" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
fails=0
note() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# Each runner's failure line, and the name it must give.
names_case() { # names_case <what> <output> <want, newline-separated>
  got="$(printf '%b\n' "$2" | bash "$script" --names)"
  [ "$got" = "$(printf '%b' "$3")" ] || note "$1: got '$got'"
}
names_case vitest ' FAIL  src/a.test.ts > Group > Inner > should do a thing\nAssertionError: expected 1 to be 2' 'should do a thing'
names_case 'vitest file that never loaded' ' FAIL  src/a.test.ts [ src/a.test.ts ]\nError: Failed to resolve import' ''
names_case jest '  ● Group › should do a thing\n\n  expect(received).toBe(expected)\n  ● Group › should do a thing' 'should do a thing'
names_case 'jest with no group' '  ● a plain name' 'a plain name'
names_case 'jest file that never loaded' '  ● Test suite failed to run' ''
names_case pytest 'FAILED tests/test_a.py::test_truncate - assert 1 == 2\nFAILED tests/test_a.py::TestX::test_case[one] - nope\n=== 2 failed in 0.1s ===' 'test_truncate\ntest_case'
names_case go '--- FAIL: TestTruncate (0.00s)\n    --- FAIL: TestTruncate/one (0.00s)\nFAIL' 'TestTruncate'
names_case 'go build failure' './a_test.go:9:2: undefined: X\nFAIL\texample.com/a [build failed]' ''
names_case phpunit '1) Tests\\\\SlugTest::testTruncate\nFailed asserting that 1 is 2.\n2) Tests\\\\SlugTest::testOther with data set #0' 'testTruncate\ntestOther'
names_case node '✖ truncate cuts (1.53ms)\nℹ fail 1\n✖ failing tests:\n✖ truncate cuts (1.53ms)' 'truncate cuts'
names_case 'node file that never loaded' '✖ tests/slug.test.js (26.8ms)\nℹ fail 1' ''
names_case cargo 'test tests::truncate ... FAILED\ntest tests::other ... ok\ntest result: FAILED. 1 passed; 1 failed;' 'truncate'
names_case 'a passing run' '✓ everything\nTests  3 passed (3)' ''
printf '%s' "$(bash "$script" --names < "$root/evals/fixtures/vitest/fail.txt")" | grep -q . || note 'the real vitest fixture gave no name'

# The whole thing, in a repository, with a runner that fails as told.
cd "$work" || exit 1
git init -q
git config user.email t@example.com
git config user.name t
mkdir -p .devskills tests
printf '.devskills/\n' > .gitignore
cat > .devskills/profile.json <<'JSON'
{
  "test": "sh ./runner.sh",
  "testScoped": null,
  "timeoutTool": null
}
JSON
cat > runner.sh <<'SH'
#!/bin/sh
[ -s failing.txt ] || { echo "Tests  1 passed (1)"; exit 0; }
while IFS= read -r name; do echo " FAIL  tests/a.test.ts > $name"; done < failing.txt
echo "Tests  $(wc -l < failing.txt | tr -d ' ') failed | 1 passed"
exit 1
SH
printf "it('an old test')\n" > tests/a.test.ts
printf 'failing.txt\n' >> .gitignore
: > failing.txt
git add . >/dev/null
git commit -qm base
open() { out="$(bash "$script" 2>&1)"; rc=$?; first="$(printf '%s\n' "$out" | head -1)"; }
failing() { printf '%s\n' "$@" > failing.txt; }
list() { cat .devskills/open-tests 2>/dev/null; }

: > failing.txt
open
[ "$rc" -eq 1 ] || note "nothing failing: exit $rc"
case "$first" in "OPEN REFUSED — nothing fails"*) ;; *) note "nothing failing: '$first'" ;; esac
[ -z "$(list)" ] || note 'nothing failing: something was recorded'

failing 'an old test'
open
[ "$rc" -eq 1 ] || note "an old test: exit $rc"
case "$first" in *'"an old test" was there before'*) ;; *) note "an old test: '$first'" ;; esac
[ -z "$(list)" ] || note 'an old test was recorded'

# Added on a tracked file's line.
printf "it('a new test')\n" >> tests/a.test.ts
failing 'a new test'
open
[ "$rc" -eq 0 ] || note "a new test: exit $rc: $out"
[ "$first" = 'OPEN | a new test' ] || note "a new test: '$first'"
[ "$(list)" = 'a new test' ] || note "a new test: the list is '$(list)'"
printf '%s\n' "$out" | grep -q 'refuses until it passes' || note 'it does not say what open means'
rm -f .devskills/open-tests

# A new one and an old one together: nothing is recorded, not even the new one.
failing 'a new test' 'an old test'
open
[ "$rc" -eq 1 ] || note "new and old: exit $rc"
[ -z "$(list)" ] || note "new and old: recorded '$(list)'"

# A test moved, so its name is on a removed line and an added one: it was there before.
git checkout -q tests/a.test.ts
printf "\n// moved\nit('an old test')\n" > tests/a.test.ts
failing 'an old test'
open
[ "$rc" -eq 1 ] || note "a moved old test: exit $rc: $out"
git checkout -q tests/a.test.ts

# In an untracked file.
printf "it('in a new file')\n" > tests/b.test.ts
failing 'in a new file'
open
[ "$rc" -eq 0 ] || note "a new file: exit $rc: $out"
[ "$first" = 'OPEN | in a new file' ] || note "a new file: '$first'"

# Committed, it's in no diff, but an earlier step opened it: the next step's run passes it.
git add tests/b.test.ts >/dev/null
git commit -qm step
printf "it('another new one')\n" > tests/c.test.ts
failing 'in a new file' 'another new one'
open
[ "$rc" -eq 0 ] || note "an earlier step's and a new one: exit $rc: $out"
[ "$first" = 'OPEN | in a new file, another new one' ] || note "an earlier step's and a new one: '$first'"
rm -f .devskills/open-tests tests/c.test.ts

# Committed in this step and not opened: it's in no diff, so it can't be told from an old one.
failing 'in a new file'
open
[ "$rc" -eq 1 ] || note "committed and not open: exit $rc"

# Names in what the skills keep in the tree aren't the step's tests. The test output
# holds every name, and .devskills may not be ignored in a project.
sed -i.bak '/^\.devskills\/$/d' .gitignore && rm -f .gitignore.bak
git add .gitignore >/dev/null
git commit -qm unignore
mkdir -p .tasks
printf "the plan mentions 'only in the plan'\n" > .tasks/plan.md
failing 'only in the plan'
open
[ "$rc" -eq 1 ] || note "a name only in .devskills or .tasks: exit $rc: $out"

# A runner that dies with no test name: nothing to open.
printf '#!/bin/sh\necho "Error: Failed to resolve import"\necho "Tests  no tests"\nexit 1\n' > runner.sh
: > failing.txt
open
[ "$rc" -eq 1 ] || note "no name: exit $rc"
case "$first" in "OPEN REFUSED — no failing test name"*) ;; *) note "no name: '$first'" ;; esac

[ "$(bash "$script" --what 2>/dev/null; echo $?)" = 64 ] || note 'a bad argument was not usage'
cd / && [ "$(cd "$(mktemp -d)" && bash "$script" | head -1 | cut -c1-12)" = 'OPEN REFUSED' ] || note 'outside a repository it did not refuse'

if [ "$fails" -eq 0 ]; then
  printf 'test-open: records what a step added, refuses what was there before\n'
else
  printf 'test-open: %s case(s) failed\n' "$fails" >&2
fi
exit $((fails > 0))
