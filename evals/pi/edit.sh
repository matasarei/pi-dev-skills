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
# string literals, replaces stray closers at the end, and keeps the first value
# of a repeated key; everything else is left for Pi's shim.
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
const { repairEditArgs, editArgsProblem, withFlatShape } = await import(pathToFileURL(argsModule).href)
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

// A repeated key: JSON.parse keeps the last value, so `"newText":"the fix","newText":""` deleted the text it was
// replacing, and Pi reported success. In 18 logged repeats the later value was empty, null, identical or inside the first.
for (const [what, later] of [["empty", '""'], ["null", "null"], ["identical", '"the fix"'], ["inside the first", '"fix"']]) {
  r = repairEditArgs({ path: "f", edits: `[{"oldText": "a", "newText": "the fix", "newText": ${later}}]` })
  if (!same(r.edits, [{ oldText: "a", newText: "the fix" }])) fails.push(`a repeated newText, later ${what}, did not keep the first: ${JSON.stringify(r.edits)}`)
}
r = repairEditArgs({ path: "f", edits: '[{"oldText": "a", "newText": "b", "oldText": null, "newText": null}]' })
if (!same(r.edits, [{ oldText: "a", newText: "b" }])) fails.push(`a repeated oldText and newText did not keep the first: ${JSON.stringify(r.edits)}`)
r = repairEditArgs({ path: "f", edits: `[{"oldText": "a${NL}b", "newText": "c${NL}d", "newText": ""}]` })
if (!same(r.edits, [{ oldText: `a${NL}b`, newText: `c${NL}d` }])) fails.push(`a repeat with raw newlines did not keep the first: ${JSON.stringify(r.edits)}`)
// Each edit in a list keeps its own, and the same key in another edit isn't a repeat.
r = repairEditArgs({ path: "f", edits: '[{"oldText": "a", "newText": "b"}, {"oldText": "c", "newText": "d", "newText": ""}]' })
if (!same(r.edits, [{ oldText: "a", newText: "b" }, { oldText: "c", newText: "d" }])) fails.push(`repeats across edits were mixed up: ${JSON.stringify(r.edits)}`)
// A key that isn't an ordinary one stays data, and doesn't reach the object's prototype.
r = repairEditArgs({ path: "f", edits: '[{"__proto__": {"x": 1}, "oldText": "a", "newText": "b"}]' })
if (r.edits[0].x !== undefined || Object.getPrototypeOf(r.edits[0]) !== Object.prototype) fails.push("__proto__ in an edit changed its prototype")
// Escapes in the text survive the reader.
r = repairEditArgs({ path: "f", edits: '[{"oldText": "say \\"hi\\"", "newText": "tab\\tback\\\\slash \\u0041"}]' })
if (!same(r.edits, [{ oldText: 'say "hi"', newText: `tab${TAB}back\\slash A` }])) fails.push(`escapes changed: ${JSON.stringify(r.edits)}`)
// Every refusal ends by asking for the flat shape, which can't nest JSON in a string, and doesn't
// name write: after "or use write" the bench's model spliced the file from the shell and broke it.
const ASK = "Send this change again as one edit with path, oldText and newText as plain arguments, without edits. If it is long, add it in parts of about 40 lines, one edit each. Don't rewrite the file from the shell."
const asks = (t) => t.endsWith(` ${ASK}`) && !t.includes("use write")
// A later value that is real, different text is a guess either way: refused, in place of keeping the last.
const differs = { path: "f", edits: '[{"oldText": "a", "newText": "one", "newText": "two"}]' }
if (typeof repairEditArgs(differs).edits !== "string") fails.push("a repeat with different values was repaired")
const twice = editArgsProblem?.(differs) ?? ""
if (!twice.startsWith("edits gives newText twice with different values.") || !asks(twice)) fails.push(`a repeat with different values was not reported: ${twice}`)

// Stray closers at the end, the bench's commonest failure. One model sent the same call 201 times.
for (const tail of ["}]}", "}]}]", "}}]", "}", "]}]", "}]  }\n]"]) {
  r = repairEditArgs({ path: "f", edits: `[{"oldText": "a", "newText": "b"${tail}` })
  if (!same(r.edits, [{ oldText: "a", newText: "b" }])) fails.push(`the closers ${tail} were not repaired: ${JSON.stringify(r.edits)}`)
  if (editArgsProblem?.({ path: "f", edits: `[{"oldText": "a", "newText": "b"${tail}` }) !== null) fails.push(`the closers ${tail} were still reported`)
}
r = repairEditArgs({ path: "f", edits: `[{"oldText": "a${NL}b", "newText": "c", "newText": ""}]}]` })
if (!same(r.edits, [{ oldText: `a${NL}b`, newText: "c" }])) fails.push(`raw newlines, a repeat and stray closers together: ${JSON.stringify(r.edits)}`)
r = repairEditArgs({ path: "f", edits: '{"oldText": "a", "newText": "b"}}' })
if (!same(r.edits, { oldText: "a", newText: "b" })) fails.push(`a single object with a stray closer: ${JSON.stringify(r.edits)}`)
// The bench's other ending: a repeat of both keys with null, then stray closers.
r = repairEditArgs({ path: "f", edits: `[{"oldText": "a${NL}b", "newText": "c", "oldText": null, "newText": null}]}` })
if (!same(r.edits, [{ oldText: `a${NL}b`, newText: "c" }])) fails.push(`a null repeat and stray closers: ${JSON.stringify(r.edits)}`)
// Closers inside the text are the model's text, and only the end of the string is repaired.
r = repairEditArgs({ path: "f", edits: '[{"oldText": "a}]}", "newText": "b]}]"}]}' })
if (!same(r.edits, [{ oldText: "a}]}", newText: "b]}]" }])) fails.push(`closers inside the text were touched: ${JSON.stringify(r.edits)}`)
r = repairEditArgs({ path: "f", edits: '[{"oldText": "a\\"}]", "newText": "b"}]}' })
if (!same(r.edits, [{ oldText: 'a"}]', newText: "b" }])) fails.push(`an escaped quote before closers was misread: ${JSON.stringify(r.edits)}`)
// What cannot be repaired is reported with its real error, for the model to fix. Two edits run together, an
// unterminated string, and text after the closers: where the text was meant to end is a guess.
const together = '[{"oldText": "a", "newText": "b"} {"oldText": "c", "newText": "d"}]'
for (const [what, edits] of [["two edits run together", together], ["an unterminated string", '[{"oldText": "a", "newText": "b'], ["text after the closers", '[{"oldText": "a", "newText": "b"}]}x'], ["a value that isn't text, then closers", '[{"oldText": "a", "newText": 5}]}']]) {
  if (typeof repairEditArgs({ path: "f", edits }).edits !== "string") fails.push(`${what} was repaired`)
  if (!(editArgsProblem?.({ path: "f", edits }) ?? "").startsWith("edits is not valid JSON:")) fails.push(`${what} was not reported`)
}
const stray = editArgsProblem?.({ path: "f", edits: together }) ?? ""
if (!/^edits is not valid JSON: .*position \d+/.test(stray) || !asks(stray)) fails.push(`the stray bracket is not reported with its JSON error: ${stray}`)
if (!(editArgsProblem?.({ path: "f", edits: "not json at all" }) ?? "").startsWith("edits is not valid JSON:")) fails.push("garbage is not reported")
// Raw newlines are something the repair handles, so they are not what gets reported: the bench's model
// was told about a control character when the real problem was further on.
const both = editArgsProblem?.({ path: "f", edits: `[{"oldText": "a${NL}b", "newText": "c"} {"oldText": "d", "newText": "e"}]` }) ?? ""
if (both.includes("control character") || !/^edits is not valid JSON: .*position \d+/.test(both)) fails.push(`raw newlines hid the real JSON error: ${both}`)
const quoted = editArgsProblem?.({ path: "f", edits: `"a${NL}b"` }) ?? ""
if (!quoted.startsWith("edits is not a list of edits:")) fails.push(`a string with a raw newline is not reported as not a list: ${quoted}`)
// Valid JSON that is not edits at all is reported too, without calling it invalid.
const num = editArgsProblem?.({ path: "f", edits: "5" }) ?? ""
if (!num.startsWith("edits is not a list of edits:") || !asks(num)) fails.push(`a number is not reported: ${num}`)
// The schema the model is sent: the flat oldText/newText pair next to path, edits optional, and a note at the
// front of the description. In replays of the bench's broken edits, the model sent that shape where it had sent
// a broken edits string. Nothing else in the definition changes, and the definition given isn't touched.
const FLAT_NOTE = "For one replacement, pass oldText and newText directly, next to path. Use edits only for several replacements in one call. "
const plain = { name: "edit", description: "Edit a file.", parameters: { type: "object", required: ["path", "edits"], properties: { path: { type: "string" }, edits: { type: "array" } } }, execute: () => "ran" }
const before = JSON.stringify(plain)
const flat = withFlatShape?.(plain)
if (!flat) fails.push("withFlatShape is missing")
else {
  if (flat.description !== FLAT_NOTE + "Edit a file.") fails.push(`the description has no note in front: ${flat.description}`)
  if (!same(flat.parameters.required, ["path"])) fails.push(`more than path is required: ${JSON.stringify(flat.parameters.required)}`)
  if (!same(Object.keys(flat.parameters.properties), ["path", "oldText", "newText", "edits"])) fails.push(`the properties are not path, oldText, newText, edits: ${Object.keys(flat.parameters.properties)}`)
  if (flat.parameters.properties.oldText?.type !== "string" || flat.parameters.properties.newText?.type !== "string") fails.push("oldText and newText are not strings")
  if (flat.parameters.properties.edits !== plain.parameters.properties.edits || flat.parameters.properties.path !== plain.parameters.properties.path) fails.push("path or edits changed")
  if (flat.execute !== plain.execute || flat.name !== "edit") fails.push("the rest of the definition changed")
  if (JSON.stringify(plain) !== before) fails.push("the definition given was changed")
}

// A schema without path or edits, as a later Pi might have, is left as Pi gives it rather than sent broken.
for (const odd of [{ name: "edit", description: "d", parameters: { type: "object", properties: { file: { type: "string" } } } }, { name: "edit", description: "d" }]) {
  let got
  try { got = withFlatShape?.(odd) } catch (e) { got = e }
  if (got !== odd) fails.push(`a schema without path and edits was changed: ${got instanceof Error ? got.message : JSON.stringify(got)}`)
}

// Everything the repair or Pi can use has no problem.
for (const ok of [{ path: "f", edits: raw }, { path: "f", edits: '[{"oldText":"a","newText":"b"}]' }, { path: "f", edits: arr }, { path: "f", oldText: "a", newText: "b" }, { path: "f", edits: `{"oldText": "a${NL}b", "newText": "c"}` }, { path: "f", edits: "junk", oldText: "a", newText: "b" }, null])
  if (editArgsProblem?.(ok) !== null) fails.push(`a usable shape was reported: ${JSON.stringify(ok)}`)

if (piEdit) try {
  const { createEditToolDefinition } = await import(pathToFileURL(piEdit).href)
  const base = createEditToolDefinition(process.cwd())
  const prepare = (a) => base.prepareArguments(repairEditArgs(a))
  if (!same(prepare({ path: "f", edits: raw }).edits.map((e) => Object.keys(e).sort()), [["newText", "oldText"]]))
    fails.push("through Pi's shim, the bench's shape does not come out as one {oldText, newText}")
  if (!same(prepare({ path: "f", edits: `{"oldText": "a${NL}b", "newText": "c"}` }).edits, [{ oldText: `a${NL}b`, newText: "c" }]))
    fails.push("through Pi's shim, a single object string is not wrapped in an array")
  if (!same(prepare({ path: "f", edits: '[{"oldText": "a", "newText": "b", "newText": ""}]' }).edits, [{ oldText: "a", newText: "b" }]))
    fails.push("through Pi's shim, a repeated newText does not keep the first")
  if (!same(prepare({ path: "f", edits: '[{"oldText": "a", "newText": "b"}]}]' }).edits, [{ oldText: "a", newText: "b" }]))
    fails.push("through Pi's shim, stray closers are not repaired")
  if (!same(prepare({ path: "f", oldText: "a", newText: "b" }).edits, [{ oldText: "a", newText: "b" }]))
    fails.push("through Pi's shim, legacy oldText/newText is no longer folded in")
  // Pi's own definition, as pi/edit.js gives it: edits kept as Pi has it, and the flat pair folded in by Pi's shim.
  const piFlat = withFlatShape?.(base)
  if (piFlat && piFlat.parameters.properties.edits !== base.parameters.properties.edits) fails.push("through Pi, the flat schema changed edits")
  if (piFlat && (base.parameters.required ?? []).length !== 2) fails.push(`through Pi, its own definition was changed: ${JSON.stringify(base.parameters.required)}`)
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
