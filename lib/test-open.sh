#!/usr/bin/env bash
# Record a failing test this step added as open, so the step can finish.
#
#   test-open.sh            run the suite; record what fails, if all of it is new
#   test-open.sh --names    the failing test names in runner output on stdin
#
# A model can write a test that can never pass, and it can't always tell. A step
# then stays unticked, and every later step is gated behind it. Open doesn't mean
# fine: the test stays in and keeps failing, test.sh reports TEST OPEN, and /dev-pr
# still refuses, so a real bug goes on named instead of holding everything up.
#
# Only a test this step added can be opened: every failing name must be on an added
# line of `git diff HEAD`, or in an untracked file, and not on a removed line. A test
# that was there before is never opened. Whatever can't be read as a test name, such
# as a file that never loaded, is refused.
#
# Prints "OPEN | <names>" and exits 0, or "OPEN REFUSED — <why>" and exits 1.
# The list is .devskills/open-tests, one name per line. test.sh empties it on a
# full pass.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
LIST=.devskills/open-tests
OUTPUT=.devskills/test-output

# One name per line, in order, each once. Each rule is one runner's own failure line.
names() {
  awk '
    function add(name) {
      sub(/[[:space:]]+$/, "", name)
      if (name != "" && !seen[name]++) print name
    }
    function last(text, sep,    parts, n) { n = split(text, parts, sep); return parts[n] }
    # Not ==, which compares symbols by locale, where ● and ✖ can come out equal.
    function is(mark) { return index($1, mark) == 1 && length($1) == length(mark) }
    # vitest: " FAIL  src/a.test.ts > Group > the name"; a file that never loaded has no " > "
    /^[[:space:]]*FAIL[[:space:]]/ && / > / { add(last($0, " > ")); next }
    # Jest: "  ● Group › the name"; "● Test suite failed to run" is not a test
    is("●") {
      if ($0 !~ /Test suite failed to run/) { line = $0; sub(/^[[:space:]]*/, "", line); add(last(substr(line, length($1) + 2), " › ")) }
      next
    }
    # pytest: "FAILED tests/test_a.py::test_name[case] - reason"
    /^FAILED .*::/ { line = $2; sub(/\[.*$/, "", line); add(last(line, "::")); next }
    # Go: "--- FAIL: TestName (0.00s)", unindented: a subtest fails its parent
    /^--- FAIL: / { add($3); next }
    # PHPUnit: "1) Tests\SlugTest::testName with data set #0"
    /^[0-9]+\) .*::/ { add($2 == "" ? "" : last($2, "::")); next }
    # node --test: "✖ the name (1.5ms)"; a file named there never loaded
    is("✖") && NF >= 2 {
      if ($0 ~ /failing tests:/ || $2 ~ /\.[cm]?[jt]sx?$/) next
      line = $0; sub(/^[[:space:]]*/, "", line); line = substr(line, length($1) + 2); sub(/ \([0-9.]+ms\)[[:space:]]*$/, "", line); add(line); next
    }
    # cargo: "test tests::name ... FAILED"
    /^test .* \.\.\. FAILED[[:space:]]*$/ { add(last($2, "::")); next }
  '
}

refuse() { printf 'OPEN REFUSED — %s\n' "$1"; exit 1; }

case "${1:-}" in
  --names) names; exit 0 ;;
  "") ;;
  *) echo "usage: test-open.sh [--names]" >&2; exit 64 ;;
esac

git rev-parse HEAD >/dev/null 2>&1 || refuse "no commit here to compare with"

verdict="$(bash "$HERE/test.sh" 2>&1 | head -1)"
case "$verdict" in
  "TEST PASS"*) refuse "nothing fails: $verdict" ;;
  "TEST FAIL"*|"TEST OPEN"*) ;;
  *) refuse "$verdict" ;;
esac

failing="$(names < "$OUTPUT" 2>/dev/null)"
[ -n "$failing" ] || refuse "no failing test name can be read in the output. Fix what stops the tests from running. $verdict"

# What this step wrote, without what the skills themselves keep in the tree: the
# test output is full of the very names being looked for.
diff_text="$(git diff HEAD --unified=0 --no-color -- . ':(exclude).devskills' ':(exclude).tasks' 2>/dev/null)"
added="$(printf '%s\n' "$diff_text" | grep '^+' | grep -v '^+++')"
removed="$(printf '%s\n' "$diff_text" | grep '^-' | grep -v '^---')"
untracked="$(git ls-files --others --exclude-standard -- . ':(exclude).devskills' ':(exclude).tasks' 2>/dev/null)"
[ -n "$untracked" ] && added="$added
$(printf '%s\n' "$untracked" | while IFS= read -r file; do cat "$file" 2>/dev/null; done)"

while IFS= read -r name; do
  [ -f "$LIST" ] && grep -qxF -- "$name" "$LIST" && continue # opened by an earlier step
  printf '%s\n' "$removed" | grep -qF -- "$name" && refuse "\"$name\" was there before this step. Only a test this step added can be open."
  printf '%s\n' "$added" | grep -qF -- "$name" || refuse "\"$name\" was there before this step. Only a test this step added can be open."
done <<NAMES
$failing
NAMES

mkdir -p .devskills
printf '%s\n' "$failing" > "$LIST"
printf 'OPEN | %s\n' "$(printf '%s\n' "$failing" | paste -sd, - | sed 's/,/, /g')"
printf 'It stays failing and /dev-pr refuses until it passes. Name it in the tick note and the report, then tick and commit.\n'
