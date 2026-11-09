#!/usr/bin/env bash
# Which test failed, where it is, and whether this step added it — pi/failing-test.js,
# which the guard uses to pick a test to trace. Run it from anywhere:
#
#   bash evals/pi/failing-test.sh
#
# The outputs are what the bench's model saw (run 20261108-162757-pi, step 2's resume,
# results 85, 89, 99 and 101; run 20261102-003417-pi, step 2, result 23), most of them
# cut by its own grep. The test files are its cityManager.test.ts as it stood then.
#
# Exits 0 when every case holds, 1 otherwise, naming each failure.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
command -v node >/dev/null 2>&1 || { printf 'failing-test: node is required — not installed\n' >&2; exit 1; }
command -v git >/dev/null 2>&1 || { printf 'failing-test: git is required — not installed\n' >&2; exit 1; }

node --input-type=module - "$root" <<'JS'
import { execFileSync } from "node:child_process"
import { mkdtempSync, readFileSync, rmSync, writeFileSync, mkdirSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"
const root = process.argv[2]
const { failingTests, testBlock, addedByStep } = await import(`${root}/pi/failing-test.js`)
const fails = []
const fx = `${root}/evals/pi/fixtures/failing-test`
const read = (name) => readFileSync(`${fx}/${name}`, "utf8")
const same = (got, want) => JSON.stringify(got) === JSON.stringify(want)
const FILE = "src/__tests__/cityManager.test.ts"
const t = (name, result) => ({ file: FILE, name, result })
const EQ = " // Object.is equality"

// --- failingTests: each failing test once, in order, with its result when the output has it.
for (const [what, text, want] of [
  ["#85 (tail -40: one FAIL block)", read("stall-85.txt"), [t("should not deduct cost when placing PowerLine on an entity", `expected 1900 to be 2000${EQ}`)]],
  ["#89 (grep -A3: the summary's ❯/→ lines)", read("stall-89.txt"), [
    t("should not deduct cost when placing Transit on an entity", `expected 1900 to be 2000${EQ}`),
    t("should not deduct cost when placing PowerLine on an entity", `expected 1900 to be 2000${EQ}`),
  ]],
  ["#99 (grep FAIL: names, no results)", read("stall-99.txt"), [
    t("should not deduct cost when funds are insufficient", null),
    t("should deduct correct cost for each zone type", null),
    t("should not deduct cost when placing Transit on an entity", null),
    t("should not deduct cost when placing PowerLine on an entity", null),
  ]],
  ["#23 of the older run (a file line with counts, then the test)", read("older-23.txt"), [t("should handle multiple placements deducting correctly", `expected 840 to be 740${EQ}`)]],
  ["no failure", " ✓ src/a.test.ts > adds (2ms)\n Test Files  1 passed (1)\n", []],
  ["a stdout line naming a test", "stdout | src/a.test.ts > A > adds\nhello\n", []],
  ["a × line (verbose) with its time", "   × src/a.test.ts > A > adds 12ms\n", [{ file: "src/a.test.ts", name: "adds", result: null }]],
  ["a FAIL line with its time", " FAIL  src/a.test.ts > A > adds 12ms\nAssertionError: expected 1 to be 2\n", [{ file: "src/a.test.ts", name: "adds", result: "expected 1 to be 2" }]],
]) {
  const got = failingTests(text)
  if (!same(got, want)) fails.push(`failingTests, ${what}: ${JSON.stringify(got)}`)
}
{
  const got = failingTests(read("stall-101.txt"))
  if (!same(got[0], t("should not deduct cost when funds are insufficient", `expected true to be false${EQ}`))) fails.push(`failingTests, #101's first: ${JSON.stringify(got[0])}`)
  if (got.length !== 4) fails.push(`failingTests, #101 has 4 failing tests: ${JSON.stringify(got)}`)
}
for (const bad of [undefined, null, 42, ""]) if (!same(failingTests(bad), [])) fails.push(`failingTests(${JSON.stringify(bad)}) is not []`)

// --- testBlock: from the it( line to its close, by indent.
const stall = read("stall.test.ts")
for (const [what, text, name, want] of [
  ["the PowerLine test", stall, "should not deduct cost when placing PowerLine on an entity", { start: 158, end: 169 }],
  ["the Transit test", stall, "should not deduct cost when placing Transit on an entity", { start: 145, end: 156 }],
  ["the older run's test", read("older.test.ts"), "should handle multiple placements deducting correctly", { start: 217, end: 223 }],
  ["a name not in the file", stall, "no such test", null],
  ["a name that is only a prefix", stall, "should not deduct cost when placing PowerLine", null],
  ["test( in double quotes", 'describe("a", () => {\n  test("adds (1 + 1)", () => {\n    expect(2).toBe(2);\n  });\n});\n', "adds (1 + 1)", { start: 2, end: 4 }],
  ["it.only in backticks", "  it.only(`adds`, async () => {\n    await x();\n    expect(1).toBe(1);\n  });\n", "adds", { start: 1, end: 4 }],
  ["a nested block inside", "it('adds', () => {\n  if (x) {\n    y();\n  }\n  expect(1).toBe(1);\n});\n", "adds", { start: 1, end: 6 }],
  ["no close: to the last line that isn't blank", "it('adds', () => {\n  expect(1).toBe(1);\n\n", "adds", { start: 1, end: 2 }],
]) {
  const got = testBlock(text, name)
  if (!same(got, want)) fails.push(`testBlock, ${what}: ${JSON.stringify(got)}`)
}
if (testBlock(undefined, "x") !== null) fails.push("testBlock(undefined) is not null")

// --- addedByStep: test-open.sh's rule, for one file.
const dir = mkdtempSync(join(tmpdir(), "failing-test-"))
const git = (...a) => execFileSync("git", ["-C", dir, ...a], { stdio: "pipe" }).toString()
git("init", "-q")
git("config", "user.email", "e@x"); git("config", "user.name", "e")
mkdirSync(join(dir, "src"))
const kept = "it('was there', () => {\n  expect(1).toBe(1);\n});\n\nit('gets changed', () => {\n  expect(2).toBe(2);\n});\n"
writeFileSync(join(dir, "src/a.test.ts"), kept)
writeFileSync(join(dir, "src/b.test.ts"), "it('in b', () => {});\n")
git("add", "."); git("commit", "-q", "-m", "base")
writeFileSync(join(dir, "src/a.test.ts"), kept.replace("it('gets changed', () => {", "it('gets changed', async () => {") + "\nit('added here', () => {\n  expect(3).toBe(4);\n});\n")
writeFileSync(join(dir, "src/c.test.ts"), "it('in a new file', () => {});\n")
for (const [what, file, name, want] of [
  ["a test added to a tracked file", "src/a.test.ts", "added here", true],
  ["a committed test left alone", "src/a.test.ts", "was there", false],
  ["a committed test whose line changed", "src/a.test.ts", "gets changed", false],
  ["a test in an untracked file", "src/c.test.ts", "in a new file", true],
  ["a test in an unchanged file", "src/b.test.ts", "in b", false],
  ["a file that isn't there", "src/none.test.ts", "x", false],
]) {
  const got = addedByStep(dir, file, name)
  if (got !== want) fails.push(`addedByStep, ${what}: ${got}`)
}
if (addedByStep(tmpdir(), "x.test.ts", "x") !== false) fails.push("addedByStep outside a repository is not false")
rmSync(dir, { recursive: true, force: true })

for (const f of fails) console.log(`FAIL  ${f}`)
process.exit(fails.length ? 1 : 0)
JS
rc=$?
if [ "$rc" -eq 0 ]; then
  printf 'failing-test: each failing test is read once with its result, found in its file, and only one this step added counts as its own\n'
  exit 0
fi
printf 'failing-test: case(s) failed\n' >&2
exit 1
