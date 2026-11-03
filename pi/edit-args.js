// The repair pi/edit.js runs on edit's arguments before Pi's own shim. Plain
// node, no Pi import, so evals/pi/edit.sh can test it anywhere.
//
// Pi's prepareEditArguments already turns a string `edits` into the array it
// parses to, a single edit object into a one-element array, and the legacy
// oldText/newText pair into edits. What it cannot take is the string the bench's
// model sent: JSON whose string values hold raw newlines and tabs, which
// JSON.parse rejects ("Bad control character in string literal"). Pi then
// validated the string and refused the call, three times running.

// The text with every control character inside a JSON string literal escaped,
// so JSON.parse reads it as the model meant. Outside a literal they are
// whitespace, and stay as they are.
function escapeControlInStrings(text) {
  let out = ""
  let inString = false
  let escaped = false
  for (const ch of text) {
    if (inString) {
      if (escaped) { escaped = false; out += ch; continue }
      if (ch === "\\") { escaped = true; out += ch; continue }
      if (ch === '"') { inString = false; out += ch; continue }
      const code = ch.charCodeAt(0)
      if (code < 0x20) {
        out += ch === "\n" ? "\\n" : ch === "\r" ? "\\r" : ch === "\t" ? "\\t" : `\\u${code.toString(16).padStart(4, "0")}`
        continue
      }
      out += ch
      continue
    }
    if (ch === '"') inString = true
    out += ch
  }
  return out
}

// The arguments with a string `edits` parsed whenever it reads as JSON — as it
// is, or with the raw control characters in its strings escaped; anything else
// is returned as given, for Pi's shim and editArgsProblem.
export function repairEditArgs(args) {
  if (!args || typeof args !== "object" || typeof args.edits !== "string") return args
  for (const text of [args.edits, escapeControlInStrings(args.edits)]) {
    try {
      const parsed = JSON.parse(text)
      if (parsed && typeof parsed === "object") return { ...args, edits: parsed }
    } catch {
      // try the lenient read, then give up: editArgsProblem reports it
    }
  }
  return args
}

// What is wrong with a string `edits` that cannot be repaired, or null when there
// is nothing to report. Pi's validation would say "edits.0: expected object, got
// string", which names no real problem, and the bench's model sent one such call
// 179 times. Legacy oldText/newText is fine: Pi's shim uses those and drops `edits`.
export function editArgsProblem(args) {
  const repaired = repairEditArgs(args)
  if (!repaired || typeof repaired.edits !== "string") return null
  if (typeof repaired.oldText === "string" && typeof repaired.newText === "string") return null
  try {
    JSON.parse(escapeControlInStrings(repaired.edits)) // the repair copes with those, so they are not the problem
  } catch (e) {
    return `edits is not valid JSON: ${e.message}. Fix the JSON, or use write.`
  }
  return `edits is not a list of edits: it reads as ${repaired.edits.slice(0, 40)}. Fix the JSON, or use write.`
}
