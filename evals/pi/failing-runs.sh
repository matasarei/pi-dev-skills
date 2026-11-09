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
# The 2nd failing run with the same result for a test the step added gets that test
# traced (pi/test-trace.js): onToolResult() is driven here in a temp git repo whose
# vitest is a stand-in that runs the copy it is given with node.
#
# Exits 0 when every case holds, 1 otherwise, naming each failure.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
command -v node >/dev/null 2>&1 || { printf 'failing-runs: node is required — not installed\n' >&2; exit 1; }
command -v git >/dev/null 2>&1 || { printf 'failing-runs: git is required — not installed\n' >&2; exit 1; }

node --input-type=module - "$root" <<'JS'
import { execFileSync } from "node:child_process"
import { chmodSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"
const root = process.argv[2]
const { failedTestRun, OFFER, OFFER_AT } = await import(`${root}/pi/failing-runs.js`)
const { gate, onToolResult } = await import(`${root}/pi/commands.js`)
const fails = []
const same = (got, want) => JSON.stringify(got) === JSON.stringify(want)

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
for (const command of ["bash lib/test-open.sh", "sh ./lib/test-open.sh", "lib/test-open.sh", "cd x && bash lib/test-open.sh", "bash $DEV_SKILLS_LIB/test-open.sh 2>&1 | tail -5", `bash ${root}/lib/test-open.sh`,
  // The path as shellWord gives it for a checkout path with a space, and quoted whole.
  "bash '/my dir/lib'/test-open.sh", 'bash "/my dir/lib/test-open.sh"', 'bash "$DEV_SKILLS_LIB/test-open.sh"']) {
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

// --- The trace: a project with one committed test and one this step added, both failing.
const dir = mkdtempSync(join(tmpdir(), "failing-runs-"))
const g = (...a) => execFileSync("git", ["-C", dir, ...a], { stdio: "pipe" })
mkdirSync(join(dir, "src")); mkdirSync(join(dir, "node_modules/.bin"), { recursive: true }); mkdirSync(join(dir, ".devskills"))
writeFileSync(join(dir, ".gitignore"), "node_modules/\n.devskills/\n")
writeFileSync(join(dir, "package.json"), JSON.stringify({ name: "p", private: true, scripts: { test: "vitest run" } }))
writeFileSync(join(dir, "node_modules/.bin/vitest"), '#!/usr/bin/env bash\nexec node "$2"\n')
chmodSync(join(dir, "node_modules/.bin/vitest"), 0o755)
writeFileSync(join(dir, ".devskills/profile.json"), JSON.stringify({ testScoped: "npm test -- {name}" }))
writeFileSync(join(dir, "src/harness.mjs"), `
const tests = []
export const it = (name, fn) => tests.push({ name, fn })
it.only = (name, fn) => tests.push({ name, fn, only: true })
export const expect = (v) => ({ toBe: (w) => { if (!Object.is(v, w)) { const e = new Error("expected " + v + " to be " + w); e.name = "AssertionError"; throw e } } })
process.on("beforeExit", () => { for (const t of tests.filter((t) => t.only)) { try { t.fn() } catch (e) { console.log(" FAIL  " + t.name); console.log(e.name + ": " + e.message) } } })
`)
const base = 'import { it, expect } from "./harness.mjs"\n\nit("was there", () => {\n  const n = 1 + 1\n  expect(n).toBe(3)\n})\n'
writeFileSync(join(dir, "src/a.test.mjs"), base)
g("init", "-q"); g("config", "user.email", "e@x"); g("config", "user.name", "e"); g("add", "."); g("commit", "-q", "-m", "base")
writeFileSync(join(dir, "src/a.test.mjs"), base + '\nit("adds", () => {\n  let total = 0\n  total += 2\n  expect(total).toBe(3)\n})\n')

const stepState = () => ({ step: 1, taskFile: "/nonexistent/t.md", startHead: "x", refusals: 0, failingRuns: 0 })
const out = (...tests) => ({ toolName: "bash", content: [{ type: "text", text: tests.map(([name, result]) => ` FAIL  src/a.test.mjs > ${name}${result ? `\nAssertionError: ${result}` : ""}`).join("\n") + `\n      Tests  ${tests.length} failed (${tests.length})\n` }] })
const added = (r) => (r?.content ?? []).slice(1).map((c) => c.text).join("")
const traced = (r) => added(r).includes("so the guard ran it once more and traced it")
const s = stepState()
const runs = []
for (const ev of [
  out(["adds", "expected 2 to be 3"]), // 1st
  out(["adds", "expected 2 to be 3"]), // 2nd, same: traced
  out(["adds", "expected 2 to be 3"]), // 3rd: shown already
  out(["adds", "expected 4 to be 3"]), // a new result: count 1
  out(["adds", null]),                 // 5th failing run; no result line counts as the same: traced, then the offer
]) runs.push(await onToolResult(s, ev, dir))
if (!same(runs.map(traced), [false, true, false, false, true])) fails.push(`traced on the wrong runs: ${runs.map(traced)}`)
if (!added(runs[1]).startsWith("\n\n`adds` failed again") || !added(runs[1]).includes("10| total += 2   returned 2 → total = 2")) fails.push(`the trace isn't what the model reads: ${added(runs[1])}`)
if (!added(runs[1]).includes("(src/a.test.mjs)")) fails.push(`the trace doesn't name the file from the project root: ${added(runs[1])}`)
if (runs[1].content[0].text !== out(["adds", "expected 2 to be 3"]).content[0].text) fails.push("the result lost its own text")
const fifth = added(runs[4])
if (!(fifth.indexOf("traced it") >= 0 && fifth.indexOf(OFFER) > fifth.indexOf("traced it"))) fails.push(`on the 5th: not the trace then the offer: ${fifth}`)
if (s.failingRuns !== 5) fails.push(`the count is ${s.failingRuns}, want 5`)
if (readdirSync(join(dir, "src")).some((f) => f.includes(".trace."))) fails.push("a traced copy was left behind")

// A committed test that wasn't changed is the project's own: never traced.
const own = stepState()
const twice = [await onToolResult(own, out(["was there", "expected 2 to be 3"]), dir), await onToolResult(own, out(["was there", "expected 2 to be 3"]), dir)]
if (twice.some(traced)) fails.push("a test that was already there was traced")
// Outside a step, and for a result that isn't a failing test run, nothing at all.
if (await onToolResult(null, out(["adds", "x"]), dir) !== undefined) fails.push("outside a step a result was changed")
const quiet = stepState()
if (await onToolResult(quiet, { toolName: "bash", content: [{ type: "text", text: "ok\n" }] }, dir) !== undefined || quiet.failingRuns !== 0) fails.push("a result that isn't a failing run was counted")
if (await onToolResult(stepState(), { toolName: "read", content: [{ type: "text", text: out(["adds", "x"]).content[0].text }] }, dir) !== undefined) fails.push("a read's result was changed")
// Two of the step's tests reach their 2nd run together: one trace per result, the other on the next run naming it.
writeFileSync(join(dir, "src/a.test.mjs"), base + '\nit("adds", () => {\n  let total = 0\n  total += 2\n  expect(total).toBe(3)\n})\n\nit("adds more", () => {\n  const k = 5\n  expect(k).toBe(6)\n})\n')
const both = stepState()
const pair = out(["adds", "expected 2 to be 3"], ["adds more", "expected 5 to be 6"])
const r1 = await onToolResult(both, pair, dir), r2 = await onToolResult(both, pair, dir), r3 = await onToolResult(both, pair, dir)
if (traced(r1) || (added(r2).match(/traced it/g) ?? []).length !== 1 || !added(r2).includes("`adds` failed") || !added(r3).includes("`adds more` failed")) fails.push(`two at once: ${JSON.stringify([added(r1), added(r2), added(r3)])}`)
// "In a row": a run in between where the tests pass, or where the test is shown passing,
// starts its count again, so the next failure is a 1st, not a 2nd.
const bash = (text) => ({ toolName: "bash", content: [{ type: "text", text }] })
const one = out(["adds", "expected 2 to be 3"])
for (const [what, between] of [
  ["a vitest run with nothing failing", bash(" ✓ src/a.test.mjs (3 tests) 4ms\n      Tests  3 passed (3)\n")],
  ["the test shown passing by name", bash(" ✓ src/a.test.mjs > adds 1ms\n")],
]) {
  const st = stepState()
  const seq = [await onToolResult(st, one, dir), await onToolResult(st, between, dir), await onToolResult(st, one, dir)]
  if (seq.some(traced)) fails.push(`${what} didn't restart the count: ${seq.map(traced)}`)
}
{
  // Another test shown passing, or a run that still fails something, doesn't restart this one.
  const st = stepState()
  const seq = [await onToolResult(st, one, dir), await onToolResult(st, bash(" ✓ src/a.test.mjs > was there 1ms\n"), dir), await onToolResult(st, one, dir)]
  if (!traced(seq[2])) fails.push(`another test passing restarted this one's count: ${seq.map(traced)}`)
}
rmSync(dir, { recursive: true, force: true })

for (const f of fails) console.log(`FAIL  ${f}`)
process.exit(fails.length ? 1 : 0)
JS
rc=$?
if [ "$rc" -eq 0 ]; then
  printf 'failing-runs: every runner'"'"'s failure counts, the 2nd same failure of a step'"'"'s own test is traced, and test-open.sh waits for the 5th\n'
  exit 0
fi
printf 'failing-runs: case(s) failed\n' >&2
exit 1
