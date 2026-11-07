#!/usr/bin/env bash
# The rule for a failing test run, in pi/failing-runs.js, and the gate on test-open.sh
# in pi/commands.js — run it from anywhere:
#
#   bash evals/pi/failing-runs.sh
#
# A model that has failed 5 runs is offered lib/test-open.sh. The count has to see
# what the model really runs, which is mostly the runner directly and often through
# grep, so it reads every bash result, not just test.sh's verdict. That the note
# reaches the model is in evals/pi/live-loop.sh.
#
# Exits 0 when every case holds, 1 otherwise, naming each failure.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
command -v node >/dev/null 2>&1 || { printf 'failing-runs: node is required — not installed\n' >&2; exit 1; }

node --input-type=module - "$root" <<'JS'
const root = process.argv[2]
const { failedTestRun, OFFER, OFFER_AT } = await import(`${root}/pi/failing-runs.js`)
const { gate } = await import(`${root}/pi/commands.js`)
const fails = []

for (const [what, text] of [
  ["vitest's count", "      Tests  1 failed | 47 passed (48)"],
  ["vitest's name line, kept by a grep", " FAIL  src/a.test.ts > Group > should deduct"],
  ["test.sh's verdict", "TEST FAIL | Tests  1 failed | 47 passed (48)"],
  ["Jest", "Tests:       2 failed, 3 passed, 5 total"],
  ["pytest", "=========== 1 failed, 2 passed in 0.02s ==========="],
  ["PHPUnit", "FAILURES! Tests: 43, Assertions: 118, Failures: 1."],
  ["Go", "--- FAIL: TestTruncate (0.00s)"],
  ["node --test", "✖ truncate cuts (1.5ms)\nℹ pass 0\nℹ fail 1"],
  ["cargo", "test result: FAILED. 0 passed; 1 failed; 0 ignored"],
]) if (!failedTestRun(text)) fails.push(`${what} was not counted`)

for (const [what, text] of [
  ["a pass", "      Tests  48 passed (48)"],
  ["vitest's file line alone", " Test Files  1 failed (1)\n      Tests  no tests"],
  ["Jest's file line alone", "Test Suites: 1 failed, 1 total\nTests:       0 total"],
  ["vitest's file that never loaded", " FAIL  src/a.test.ts [ src/a.test.ts ]\nError: Failed to resolve import"],
  ["node's file that never loaded", "SyntaxError: Unexpected token\n✖ tests/a.test.js (26ms)\nℹ fail 1"],
  ["0 failed", "test result: ok. 3 passed; 0 failed; 0 ignored"],
  ["a test that is open", "TEST OPEN | Tests  1 failed | 47 passed (48) | open: its name\n FAIL  src/a.test.ts > its name"],
  ["a red run, which fails on purpose", "RED PROVEN | Tests  1 failed (1)\n FAIL  src/a.test.ts > its name"],
  ["a red run that isn't proven", "RED NOT PROVEN — the test passed before the change"],
  ["an unclear red run", "RED UNCLEAR | Tests  1 failed (1)"],
  ["a read of a file", "export const failedLabel = 'not a run'\nit('should fail', () => {})"],
  ["a refusal", "dev-guard refuses: this project runs its tooling in a container"],
]) if (failedTestRun(text)) fails.push(`${what} was counted`)
if (failedTestRun(undefined) || failedTestRun("")) fails.push("no text was counted")

if (OFFER_AT !== 5) fails.push(`the offer comes after ${OFFER_AT}, and the README says 5`)
if (!OFFER.includes("test-open.sh") || !OFFER.includes("/dev-pr") || !OFFER.includes(`${OFFER_AT}`)) fails.push(`the offer doesn't say what it is: ${OFFER}`)
// The script by its path: shown the variable, the model may fill in a home of its own.
if (!OFFER.includes(`bash ${root}/lib/test-open.sh`) || OFFER.includes("DEV_SKILLS_LIB")) fails.push(`the offer doesn't name ${root}/lib/test-open.sh: ${OFFER}`)

// Refused before the offer, and outside a step. Anything else in a step isn't touched by this.
const open = { toolName: "bash", input: { command: 'bash "$DEV_SKILLS_LIB/test-open.sh"' } }
const step = (failingRuns) => ({ step: 1, taskFile: "/nonexistent/t.md", startHead: "x", refusals: 0, failingRuns })
for (const [what, state] of [["outside a step", null], ["with no count yet", step(0)], ["on the 4th", step(OFFER_AT - 1)]]) {
  const v = gate(state, open, process.cwd())
  if (!v?.block || !v.reason.includes("test-open.sh")) fails.push(`test-open.sh was not refused ${what}: ${JSON.stringify(v)}`)
}
if (gate(step(OFFER_AT), open, process.cwd())?.block) fails.push("test-open.sh was refused on the 5th")
if (gate(step(0), { toolName: "bash", input: { command: "echo hello" } }, process.cwd())?.block) fails.push("another command was refused")
if (gate(null, { toolName: "bash", input: { command: "echo hello" } }, process.cwd())?.block) fails.push("another command was refused outside a step")

// Only running the script is refused: reading it, linting it and running its suite aren't.
for (const command of ["cat lib/test-open.sh", "shellcheck lib/test-open.sh", "bash evals/lib/test-open.sh", "grep -n test-open.sh README.md", "git log -- lib/test-open.sh", 'echo "test-open.sh"']) {
  for (const [what, state] of [["outside a step", null], ["in a step", step(0)]]) {
    if (gate(state, { toolName: "bash", input: { command } }, process.cwd())?.block) fails.push(`${command} was refused ${what}`)
  }
}
for (const command of ["bash lib/test-open.sh", "sh ./lib/test-open.sh", "lib/test-open.sh", "cd x && bash lib/test-open.sh", 'bash "${DEV_SKILLS_LIB:-$HOME/.config/opencode/dev-lib}/test-open.sh"', "bash $DEV_SKILLS_LIB/test-open.sh 2>&1 | tail -5"]) {
  if (!gate(step(0), { toolName: "bash", input: { command } }, process.cwd())?.block) fails.push(`${command} was not refused`)
}

// The list is test-open.sh's. Written by hand it would skip both the wait and the new-test check.
for (const event of [
  { toolName: "write", input: { path: ".devskills/open-tests", content: "x" } },
  { toolName: "write", input: { path: "/abs/project/.devskills/open-tests", content: "x" } },
  { toolName: "edit", input: { path: ".devskills/open-tests", edits: [] } },
  ...["echo x > .devskills/open-tests", "printf 'x\\n' >> .devskills/open-tests", "echo x | tee .devskills/open-tests", "cp a .devskills/open-tests", "mv a .devskills/open-tests", "sed -i '' 's/a/b/' .devskills/open-tests", "rm .devskills/open-tests", "cd x && echo y > .devskills/open-tests"].map((command) => ({ toolName: "bash", input: { command } })),
]) {
  for (const state of [null, step(OFFER_AT)]) {
    const v = gate(state, event, process.cwd())
    if (!v?.block || !v.reason.includes("open-tests")) fails.push(`writing the list was not refused: ${JSON.stringify(event.input)}`)
  }
}
for (const command of ["cat .devskills/open-tests", "grep -c x .devskills/open-tests", "wc -l .devskills/open-tests", "ls .devskills", "echo x > other.txt"]) {
  if (gate(step(0), { toolName: "bash", input: { command } }, process.cwd())?.block) fails.push(`${command} was refused`)
}
if (gate(step(0), { toolName: "write", input: { path: "src/open-tests", content: "x" } }, process.cwd())?.block) fails.push("another file named open-tests was refused")

for (const f of fails) console.log(`FAIL  ${f}`)
process.exit(fails.length ? 1 : 0)
JS
rc=$?
if [ "$rc" -eq 0 ]; then
  printf 'failing-runs: every runner'"'"'s failure counts, and test-open.sh waits for the 5th\n'
  exit 0
fi
printf 'failing-runs: case(s) failed\n' >&2
exit 1
