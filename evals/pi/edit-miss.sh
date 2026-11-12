#!/usr/bin/env bash
# Where an edit's oldText stops matching the file — pi/edit-miss.js, which the guard
# adds to an edit result Pi failed. Run it from anywhere:
#
#   bash evals/pi/edit-miss.sh
#
# The fixture is run 20261109-175338-pi's test file as it was at result 49, rebuilt
# from the step log (the model's write, then its three edits that applied, checked
# against every read it made), and the 58-line oldText the model sent there. Pi said
# only "Could not find the exact text", and the model resent blocks of 40-76 lines
# from memory four times in that session.
#
# Exits 0 when every case holds, 1 otherwise, naming each failure.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
command -v node >/dev/null 2>&1 || { printf 'edit-miss: node is required — not installed\n' >&2; exit 1; }

node --input-type=module - "$root" <<'JS'
import { copyFileSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"
const root = process.argv[2]
const fails = []
let editMissHint
try {
  ({ editMissHint } = await import(`${root}/pi/edit-miss.js`))
} catch (e) {
  console.log(`FAIL  pi/edit-miss.js does not load: ${e.message}`)
  process.exit(1)
}
const fixtures = `${root}/evals/pi/fixtures/edit-miss`
const PI_MISS = (path) => `Could not find the exact text in ${path}. The old text must match exactly including all whitespace and newlines.`

const cwd = mkdtempSync(join(tmpdir(), "edit-miss-"))
try {
  mkdirSync(join(cwd, "src/__tests__"), { recursive: true })
  const file = join(cwd, "src/__tests__/cityManager.test.ts")
  copyFileSync(`${fixtures}/run-175338-call-49.test.ts`, file)
  const oldText = readFileSync(`${fixtures}/run-175338-call-49.oldText`, "utf8")

  // Result 49: oldText's lines 1-17 are the file's 52-68; its line 18 is blank where
  // the file's line 69 is a comment the model left out.
  for (const [what, input] of [
    ["Pi's edits[] shape", { path: file, edits: [{ oldText, newText: "x" }] }],
    ["the flat shape the model sent", { path: file, oldText, newText: "x" }],
    ["a relative path", { path: "src/__tests__/cityManager.test.ts", edits: [{ oldText, newText: "x" }] }],
  ]) {
    const hint = editMissHint(input, PI_MISS(file), cwd) ?? ""
    for (const want of [
      "oldText lines 1-17 match lines 52-68 of src/__tests__/cityManager.test.ts",
      "its line 18 `` is not what follows: line 69 is `        // Clear the auto-spawned LandingBase first (costs 0)`",
      "Put only the lines you change in oldText, copied from the file.",
    ]) if (!hint.includes(want)) fails.push(`${what}: no '${want}' in:\n${hint}`)
  }

  writeFileSync(join(cwd, "a.ts"), "function f() {\n    const a = 1;\n    return `a`;\n}\n")
  const a = join(cwd, "a.ts")
  const cases = [
    ["line 1 with other indentation", { path: a, edits: [{ oldText: "  const a = 1;\n  return a;", newText: "" }] },
      "oldText line 1 `  const a = 1;` matches line 2 `    const a = 1;` only with different indentation"],
    ["one line matches", { path: a, edits: [{ oldText: "    const a = 1;\n    return b;", newText: "" }] },
      "oldText line 1 matches line 2 of a.ts; its line 2 `    return b;` is not what follows: line 3 is `    return 'a';`"],
    ["line 1 not in the file", { path: a, edits: [{ oldText: "const b = 2;", newText: "" }] },
      "oldText line 1 `const b = 2;` is not in a.ts"],
    ["the file ends first", { path: a, edits: [{ oldText: "    return `a`;\n}\n// more", newText: "" }] },
      "oldText lines 1-2 match lines 3-4 of a.ts; its line 3 `// more` is not what follows: the file ends at line 4"],
    ["a backtick in a shown line", { path: a, edits: [{ oldText: "    return `b`;", newText: "" }] },
      "oldText line 1 `    return 'b';` is not in a.ts"],
  ]
  for (const [what, input, want] of cases) {
    const hint = editMissHint(input, PI_MISS(a), cwd) ?? ""
    if (!hint.includes(want)) fails.push(`${what}: no '${want}' in:\n${hint}`)
  }
  // With several edits Pi names the one it couldn't find, and that one is placed.
  const multi = { path: a, edits: [{ oldText: "const a = 1;", newText: "" }, { oldText: "const c = 3;", newText: "" }] }
  const m = editMissHint(multi, `Could not find edits[1] in ${a}. The oldText must match exactly including all whitespace and newlines.`, cwd) ?? ""
  if (!m.includes("edits[1]: oldText line 1 `const c = 3;` is not in a.ts")) fails.push(`edits[1]: ${JSON.stringify(m)}`)

  // Both shapes in one call: Pi adds the flat oldText after edits[], as the last edit.
  const both = { path: a, edits: [{ oldText: "const a = 1;", newText: "" }], oldText: "const c = 3;", newText: "" }
  const bm = editMissHint(both, `Could not find edits[1] in ${a}. The oldText must match exactly including all whitespace and newlines.`, cwd) ?? ""
  if (!bm.includes("edits[1]: oldText line 1 `const c = 3;` is not in a.ts")) fails.push(`edits[] and a flat oldText: ${JSON.stringify(bm)}`)

  // Nothing to add.
  const none = [
    ["a result that isn't Pi's miss", { path: a, edits: [{ oldText: "zzz", newText: "" }] }, "Successfully replaced 1 block(s) in a.ts."],
    ["a file that isn't there", { path: join(cwd, "gone.ts"), edits: [{ oldText: "x", newText: "" }] }, PI_MISS("gone.ts")],
    ["an oldText the file has", { path: a, edits: [{ oldText: "const a = 1;", newText: "" }] }, PI_MISS(a)],
    ["no input", undefined, PI_MISS(a)],
  ]
  for (const [what, input, text] of none) {
    const got = editMissHint(input, text, cwd)
    if (got !== null) fails.push(`${what}: ${JSON.stringify(got)}`)
  }
} finally {
  rmSync(cwd, { recursive: true, force: true })
}

for (const f of fails) console.log(`FAIL  ${f}`)
if (fails.length) { console.log(`edit-miss: ${fails.length} failure(s)`); process.exit(1) }
console.log("edit-miss: a missed edit says which oldText lines matched where, and the first that didn't")
JS
