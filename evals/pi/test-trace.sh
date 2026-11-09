#!/usr/bin/env bash
# The traced re-run of a failing test — pi/test-trace.js. Run it from anywhere:
#
#   bash evals/pi/test-trace.sh
#
# instrument() rewrites one test so each top-level statement reports what it returned
# and the values its expects check; readTrace() and traceNote() turn that run's output
# into what the model reads. The run cases execute the rewritten file with node and a
# small it/expect harness, so the inserted code is run here, not only read.
#
# Exits 0 when every case holds, 1 otherwise, naming each failure.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
command -v node >/dev/null 2>&1 || { printf 'test-trace: node is required — not installed\n' >&2; exit 1; }

node --input-type=module - "$root" <<'JS'
import { execFileSync } from "node:child_process"
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"
const root = process.argv[2]
const { instrument, readTrace, traceNote } = await import(`${root}/pi/test-trace.js`)
const fails = []
const same = (got, want) => JSON.stringify(got) === JSON.stringify(want)
const fx = `${root}/evals/pi/fixtures/failing-test`

// --- instrument on the bench's test: the rows, the watched values, and nothing else moved.
const stall = readFileSync(`${fx}/stall.test.ts`, "utf8")
const powerLine = "should not deduct cost when placing PowerLine on an entity"
const inst = instrument(stall, powerLine)
if (!inst) fails.push("instrument found no PowerLine test")
else {
  const rows = inst.rows.map((r) => [r.line, r.kind, r.id ?? null])
  const want = [[159, "decl", "mgr"], [161, "decl", "zones"], [162, "expr", null], [163, "expr", null], [165, "decl", "success"], [166, "expect", null], [168, "expect", null]]
  if (!same(rows, want)) fails.push(`PowerLine rows: ${JSON.stringify(rows)}`)
  if (!same(inst.watched, ["success", "mgr.funds"])) fails.push(`PowerLine watched: ${JSON.stringify(inst.watched)}`)
  const a = stall.split("\n"), b = inst.source.split("\n")
  if (!same(a.slice(0, 157), b.slice(0, 157))) fails.push("lines before the test changed")
  const tail = a.length - 169
  if (!same(a.slice(169), b.slice(b.length - tail))) fails.push("lines after the test changed")
  if (!b[157].includes(`it.only('${powerLine}'`)) fails.push(`the test isn't made .only: ${b[157]}`)
  if ((inst.source.match(/\.only\(/g) ?? []).length !== 1) fails.push("more than one .only in the copy")
}
const older = instrument(readFileSync(`${fx}/older.test.ts`, "utf8"), "should handle multiple placements deducting correctly")
if (!older || !same(older.rows.map((r) => [r.line, r.kind]), [[218, "decl"], [219, "expr"], [220, "expr"], [221, "expr"], [222, "expect"]])) fails.push(`older rows: ${JSON.stringify(older?.rows)}`)
if (!older || !same(older.watched, ["manager.funds"])) fails.push(`older watched: ${JSON.stringify(older?.watched)}`)
if (older?.rows[1].text !== "manager.placeZone(5, 5, ZoneType.Residential); // 100") fails.push(`a row lost its trailing comment: ${older?.rows[1].text}`)
for (const [what, text, name] of [
  ["a name not in the file", stall, "no such test"],
  ["a body that doesn't open on the it( line", "it('x',\n  () =>\n  {\n    a();\n  });\n", "x"],
  ["not a string", undefined, "x"],
]) if (instrument(text, name) !== null) fails.push(`instrument, ${what}: not null`)
{
  const skip = instrument("it.skip('x', () => {\n  a();\n});\n", "x")
  if (!skip || !skip.source.startsWith("it.only('x'")) fails.push(`it.skip isn't made .only: ${skip?.source}`)
}

// --- Run the rewritten file with node and a small harness, and read what it printed.
const dir = mkdtempSync(join(tmpdir(), "test-trace-"))
writeFileSync(join(dir, "harness.mjs"), `
const tests = []
export const describe = (_n, fn) => fn()
export const it = (name, fn) => tests.push({ name, fn })
it.only = (name, fn) => tests.push({ name, fn, only: true })
export const expect = (v) => ({ toBe: (w) => { if (!Object.is(v, w)) { const e = new Error("expected " + v + " to be " + w); e.name = "AssertionError"; throw e } } })
process.on("beforeExit", () => {
  const run = tests.some((t) => t.only) ? tests.filter((t) => t.only) : tests
  for (const t of run) { try { t.fn(); console.log(" ✓ " + t.name) } catch (e) { console.log(" FAIL  a.test.mjs > " + t.name); console.log(e.name + ": " + e.message) } }
})
`)
const counter = [
  'import { describe, it, expect } from "./harness.mjs"',
  "class Counter { constructor() { this.total = 0 } add(n) { this.total += n; return this.total } }",
  'describe("counter", () => {',
  '  it("adds", () => {',
  "    const c = new Counter()",
  "    // two adds",
  "    c.add(2);",
  "    const x = c.add(3)",
  "    expect(x).toBe(5)",
  "    expect(c.total)",
  "      .toBe(6)",
  "    c.add(100)",
  "  })",
  '  it("other", () => { throw new Error("must not run") })',
  "})",
  "",
].join("\n")
const run = (text, name) => {
  const i = instrument(text, name)
  if (!i) return null
  writeFileSync(join(dir, "a.trace.test.mjs"), i.source)
  const out = execFileSync("node", [join(dir, "a.trace.test.mjs")], { encoding: "utf8" })
  return { i, out, trace: readTrace(out, i) }
}
{
  const r = run(counter, "adds")
  if (!r) fails.push("the counter test wasn't instrumented")
  else {
    if (r.out.includes("must not run")) fails.push("a test other than the .only one ran")
    if (!same(r.i.rows.map((x) => [x.line, x.kind]), [[5, "decl"], [7, "expr"], [8, "decl"], [9, "expect"], [10, "expect"], [12, "expr"]])) fails.push(`counter rows: ${JSON.stringify(r.i.rows)}`)
    if (!same(r.i.watched, ["x", "c.total"])) fails.push(`counter watched: ${JSON.stringify(r.i.watched)}`)
    const note = traceNote(r.trace, "src/a.test.mjs", "adds")
    const want = [
      "`adds` failed again with the same result, so the guard ran it once more and traced it (src/a.test.mjs). Each line, what it returned, and the values its expects check right after it:",
      "5| const c = new Counter()   → c = Counter {…}, c.total = 0",
      "7| c.add(2);   returned 2 → c.total = 2",
      "8| const x = c.add(3)   → x = 5, c.total = 5",
      "9| expect(x).toBe(5)   passes",
      "10| expect(c.total) …   fails: expected 5 to be 6",
    ].join("\n")
    if (note !== want) fails.push(`counter note:\n${note}\n--- want:\n${want}`)
  }
}
{
  // A test that passes alone: said so, rows and all.
  const r = run(counter.replace(".toBe(6)", ".toBe(5)").replace("    c.add(100)\n", ""), "adds")
  const note = r && traceNote(r.trace, "src/a.test.mjs", "adds")
  if (!note?.startsWith("`adds` failed again with the same result, but passed when the guard ran it alone (src/a.test.mjs).")) fails.push(`passing note: ${note}`)
  if (!note?.includes("10| expect(c.total) …   passes")) fails.push(`passing note lacks its last row: ${note}`)
}
{
  // A statement that throws: the row says threw, and no later row is shown.
  const r = run(counter.replace("    c.add(2);", "    c.boom();"), "adds")
  const note = r && traceNote(r.trace, "src/a.test.mjs", "adds")
  if (!note?.endsWith("7| c.boom();   threw: TypeError: c.boom is not a function")) fails.push(`throwing note: ${note}`)
}
{
  // A watched value read before its declaration is left out; a subject with a call isn't watched.
  const text = 'import { describe, it, expect } from "./harness.mjs"\nit("late", () => {\n  let n = 1\n  n += 1\n  const y = n * 2\n  expect(y).toBe(4)\n  expect(String(y)).toBe("4")\n})\n'
  const r = run(text, "late")
  if (!r || !same(r.i.watched, ["y"])) fails.push(`late watched: ${JSON.stringify(r?.i.watched)}`)
  const note = r && traceNote(r.trace, "src/a.test.mjs", "late")
  if (!note?.includes("3| let n = 1   → n = 1\n4| n += 1   returned 2\n5| const y = n * 2   → y = 4")) fails.push(`late note: ${note}`)
}
{
  // Nothing traced (the run never reached the test): no note.
  const i = instrument(counter, "adds")
  if (traceNote(readTrace("Error: Cannot find module './harness.mjs'\n", i), "src/a.test.mjs", "adds") !== null) fails.push("a run with no trace rows made a note")
}
rmSync(dir, { recursive: true, force: true })

for (const f of fails) console.log(`FAIL  ${f}`)
process.exit(fails.length ? 1 : 0)
JS
rc=$?
if [ "$rc" -eq 0 ]; then
  printf 'test-trace: the copy traces each line of the one test, and the note shows what each returned and where it failed\n'
  exit 0
fi
printf 'test-trace: case(s) failed\n' >&2
exit 1
