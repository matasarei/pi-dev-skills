#!/usr/bin/env bash
# The edit-argument repair in pi/edit-args.js — run it from anywhere:
#
#   bash evals/pi/edit.sh
#
# The bench's model sent edit's `edits` as a JSON string with raw newlines in
# its string values. Pi's own shim parses a string `edits`, but JSON.parse
# throws on a raw newline, so the string reached validation and the call was
# rejected three times ("edits.0: must be object"); the model fell back to
# rewriting whole files. repairEditArgs escapes control characters inside the
# string literals and parses again; everything else is left for Pi's shim.
#
# Always: the repair on its own, in plain node. When Pi is installed globally
# also: the repair feeding Pi's own edit prepareArguments, as pi/edit.js
# composes them, so every shape Pi already handled still comes out right.
#
# Exits 0 when every case holds, 1 otherwise, naming each mismatch.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
command -v node >/dev/null 2>&1 || { printf 'edit: node is required — not installed\n' >&2; exit 1; }
[ -f "$root/pi/edit-args.js" ] || { printf 'no pi/edit-args.js at %s\n' "$root/pi/edit-args.js" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

pi_edit=""
if command -v npm >/dev/null 2>&1; then
  candidate="$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent/dist/core/tools/edit.js"
  [ -f "$candidate" ] && pi_edit="$candidate"
fi

cat > "$work/run.mjs" <<'JS'
import { pathToFileURL } from "node:url"
const [argsModule, piEdit] = process.argv.slice(2)
const { repairEditArgs } = await import(pathToFileURL(argsModule).href)
const fails = []
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)
const NL = String.fromCharCode(10), TAB = String.fromCharCode(9)

// The bench's shape: a JSON array as a string, raw newlines inside the values.
const raw = `[{"oldText": "import { a } from 'x';${NL}import { b } from 'y';", "newText": "import { a } from 'x';${NL}${TAB}import { c } from \\"z\\";"}]`
let r = repairEditArgs({ path: "f.ts", edits: raw })
if (!same(r.edits, [{ oldText: `import { a } from 'x';${NL}import { b } from 'y';`, newText: `import { a } from 'x';${NL}${TAB}import { c } from "z";` }]))
  fails.push(`raw newlines and a tab: ${JSON.stringify(r.edits)}`)
// A string that is already valid JSON, and an already-correct array: as before.
r = repairEditArgs({ path: "f", edits: '[{"oldText":"a\\nb","newText":"c"}]' })
if (!same(r.edits, [{ oldText: `a${NL}b`, newText: "c" }])) fails.push(`valid JSON string: ${JSON.stringify(r.edits)}`)
const arr = [{ oldText: "a", newText: "b" }]
r = repairEditArgs({ path: "f", edits: arr })
if (r.edits !== arr) fails.push("an array was replaced")
// A single object as a string: handed on as the object, for Pi's shim to wrap.
r = repairEditArgs({ path: "f", edits: `{"oldText": "a${NL}b", "newText": "c"}` })
if (!same(r.edits, { oldText: `a${NL}b`, newText: "c" })) fails.push(`single object string: ${JSON.stringify(r.edits)}`)
// Garbage stays garbage: Pi's validation reports it, nothing is invented.
r = repairEditArgs({ path: "f", edits: "not json at all" })
if (r.edits !== "not json at all") fails.push(`garbage was changed: ${JSON.stringify(r.edits)}`)
// Not an object, or no edits: returned as given.
if (repairEditArgs(null) !== null) fails.push("null was not returned as given")
if (!same(repairEditArgs({ path: "f", oldText: "a", newText: "b" }), { path: "f", oldText: "a", newText: "b" })) fails.push("legacy oldText/newText changed")

if (piEdit) try {
  const { createEditToolDefinition } = await import(pathToFileURL(piEdit).href)
  const base = createEditToolDefinition(process.cwd())
  const prepare = (a) => base.prepareArguments(repairEditArgs(a))
  if (!same(prepare({ path: "f", edits: raw }).edits.map((e) => Object.keys(e).sort()), [["newText", "oldText"]]))
    fails.push("through Pi's shim, the bench's shape does not come out as one {oldText, newText}")
  if (!same(prepare({ path: "f", edits: `{"oldText": "a${NL}b", "newText": "c"}` }).edits, [{ oldText: `a${NL}b`, newText: "c" }]))
    fails.push("through Pi's shim, a single object string is not wrapped in an array")
  if (!same(prepare({ path: "f", oldText: "a", newText: "b" }).edits, [{ oldText: "a", newText: "b" }]))
    fails.push("through Pi's shim, legacy oldText/newText is no longer folded in")
  console.log("edit: checked through Pi's own edit shim too")
} catch (e) {
  fails.push(`through Pi's shim: ${e.message}`)
} else {
  console.log("edit: Pi is not installed globally; checked the repair on its own")
}
for (const f of fails) console.log(`FAIL  ${f}`)
process.exit(fails.length ? 1 : 0)
JS

if node "$work/run.mjs" "$root/pi/edit-args.js" "$pi_edit"; then
  printf 'edit: a JSON string with raw newlines reaches Pi as edits\n'
  exit 0
fi
printf 'edit: case(s) failed\n' >&2
exit 1
