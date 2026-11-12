#!/usr/bin/env bash
# The lines tsc names, shown as the files hold them now — pi/tsc-lines.js, which the
# guard adds to a bash result. Run it from anywhere:
#
#   bash evals/pi/tsc-lines.sh
#
# In run 20261109-175338-pi tsc named two one-line fixes in the model's own test
# file, and the model spent about 630 s on edits whose oldText it wrote from memory,
# 40-76 lines of it, with lines the file didn't have. The fixture is that tsc output.
#
# Exits 0 when every case holds, 1 otherwise, naming each failure.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
command -v node >/dev/null 2>&1 || { printf 'tsc-lines: node is required — not installed\n' >&2; exit 1; }

node --input-type=module - "$root" <<'JS'
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"
const root = process.argv[2]
const fails = []
let tscLines
try {
  ({ tscLines } = await import(`${root}/pi/tsc-lines.js`))
} catch (e) {
  console.log(`FAIL  pi/tsc-lines.js does not load: ${e.message}`)
  process.exit(1)
}
const output = readFileSync(`${root}/evals/pi/fixtures/tsc-lines/run-175338-result-27.txt`, "utf8")

const cwd = mkdtempSync(join(tmpdir(), "tsc-lines-"))
try {
  mkdirSync(join(cwd, "src/__tests__"), { recursive: true })
  // The test file, with the lines tsc names where it names them.
  const lines = Array.from({ length: 170 }, (_, k) => `        // line ${k + 1}`)
  for (const n of [57, 88, 103, 118, 133, 145, 163]) lines[n - 1] = "        const startFunds = manager.funds;"
  lines[74] = "        if (cell) cell.terrain = 'Crater';"
  writeFileSync(join(cwd, "src/__tests__/cityManager.test.ts"), lines.join("\n") + "\n")
  writeFileSync(join(cwd, "src/a.ts"), "export const a: number = 'x';\nexport const `b` = 1;\n")

  const hint = tscLines(output, cwd) ?? ""
  const want = [
    "src/__tests__/cityManager.test.ts:57 `        const startFunds = manager.funds;`",
    "src/__tests__/cityManager.test.ts:75 `        if (cell) cell.terrain = 'Crater';`",
  ]
  for (const w of want) if (!hint.includes(w)) fails.push(`the 175338 output: no '${w}' in:\n${hint}`)
  // Eight errors on eight lines: five are shown, and the rest counted.
  const shown = hint.split("\n").filter((l) => /^src\/.*:\d+ `/.test(l)).length
  if (shown !== 5) fails.push(`the 175338 output shows ${shown} lines, want 5:\n${hint}`)
  if (!hint.includes("3 more")) fails.push(`the 175338 output doesn't count the 3 lines it leaves out:\n${hint}`)

  // A container's path, and tsc's pretty format with its colours.
  const pretty = "\x1b[96m/app/src/a.ts\x1b[0m:\x1b[93m1\x1b[0m:\x1b[93m14\x1b[0m - \x1b[91merror\x1b[0m\x1b[90m TS2322: \x1b[0mType 'string' is not assignable to type 'number'.\n"
  const p = tscLines(pretty, cwd) ?? ""
  if (!p.includes("src/a.ts:1 `export const a: number = 'x';`")) fails.push(`pretty format and /app/ path: ${JSON.stringify(p)}`)
  // A backtick in the line is shown as ' so the line stays one quoted span.
  const b = tscLines("src/a.ts(2,14): error TS1003: Identifier expected.\n", cwd) ?? ""
  if (!b.includes("src/a.ts:2 `export const 'b' = 1;`")) fails.push(`a backtick in the line: ${JSON.stringify(b)}`)

  // Nothing to add.
  const none = [
    ["no tsc error", "Tests  3 passed (3)\n"],
    ["a file outside cwd", "/elsewhere/x.ts(1,1): error TS2322: no.\n"],
    ["a line past the file's end", "src/a.ts(900,1): error TS2322: no.\n"],
    ["a file that isn't there", "src/gone.ts(1,1): error TS2322: no.\n"],
    ["not a string", undefined],
  ]
  for (const [what, out] of none) {
    const got = tscLines(out, cwd)
    if (got !== null) fails.push(`${what}: ${JSON.stringify(got)}`)
  }
} finally {
  rmSync(cwd, { recursive: true, force: true })
}

for (const f of fails) console.log(`FAIL  ${f}`)
if (fails.length) { console.log(`tsc-lines: ${fails.length} failure(s)`); process.exit(1) }
console.log("tsc-lines: each line tsc names is shown as the file holds it, five at most, and nothing else is added")
JS
