// The repair pi/edit.js runs on edit's arguments before Pi's own shim. Plain
// node, no Pi import, so evals/pi/edit.sh can test it anywhere.
//
// Pi's prepareEditArguments already turns a string `edits` into the array it
// parses to, a single edit object into a one-element array, and the legacy
// oldText/newText pair into edits. What it cannot take is the string the bench's
// model sent: JSON whose string values hold raw newlines and tabs, which
// JSON.parse rejects ("Bad control character in string literal"). Pi then
// validated the string and refused the call, three times running.
//
// The same model repeats keys, as in "newText": "the fix", "newText": "". JSON.parse
// keeps the last value, so that edit deleted the text it was replacing, and Pi
// reported success. Here a repeated key keeps its first value, or the call is refused.

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

// A later value for a repeated key that adds nothing to the first. In the logs it
// always was one of these, and the first was the real text.
const addsNothing = (first, later) =>
  later === null || later === first || (typeof first === "string" && typeof later === "string" && first.includes(later))

// What JSON.parse would return, except for a repeated key: it keeps the first value,
// and throws with error.repeatedKey when the later one is different text. JSON.parse
// checks the syntax first, since it can't report a repeat: it has lost the first value
// by the time it returns. So what follows only walks JSON already known to be valid.
function readJson(text) {
  JSON.parse(text)
  let at = 0
  const space = () => { while (/\s/.test(text[at] ?? "")) at++ }
  const scalar = () => {
    const start = at
    if (text[at] === '"') {
      for (at++; text[at] !== '"'; at++) if (text[at] === "\\") at++
      at++
    } else {
      while (at < text.length && !/[\s,\]}]/.test(text[at])) at++
    }
    return JSON.parse(text.slice(start, at))
  }
  const value = () => {
    space()
    const open = text[at]
    if (open !== "[" && open !== "{") return scalar()
    at++
    const list = []
    const entries = new Map()
    for (space(); text[at] !== "]" && text[at] !== "}"; space()) {
      if (text[at] === ",") { at++; continue }
      if (open === "[") { list.push(value()); continue }
      const key = scalar()
      space()
      at++ // the colon
      const later = value()
      if (!entries.has(key)) entries.set(key, later)
      else if (!addsNothing(entries.get(key), later)) throw Object.assign(new Error(`repeated ${key}`), { repeatedKey: key })
    }
    at++
    return open === "[" ? list : Object.fromEntries(entries)
  }
  return value()
}

// What a string `edits` reads as: { value }, or { problem } saying why it can't be read.
// The JSON error is the escaped text's: raw newlines aren't the problem, the repair copes.
function readEdits(text) {
  const escaped = escapeControlInStrings(text)
  let problem = null
  for (const candidate of [text, escaped]) {
    try {
      return { value: readJson(candidate) }
    } catch (e) {
      if (e.repeatedKey) return { problem: `edits gives ${e.repeatedKey} twice with different values.` }
      problem = `edits is not valid JSON: ${e.message}.`
    }
  }
  return { problem }
}

// The arguments with a string `edits` read whenever it reads as a list or an object;
// anything else is returned as given, for Pi's shim and editArgsProblem.
export function repairEditArgs(args) {
  if (!args || typeof args !== "object" || typeof args.edits !== "string") return args
  const { value } = readEdits(args.edits)
  return value && typeof value === "object" ? { ...args, edits: value } : args
}

// What is wrong with a string `edits` that cannot be repaired, or null when there
// is nothing to report. Pi's validation would say "edits.0: expected object, got
// string", which names no real problem, and the bench's model sent one such call
// 179 times. Legacy oldText/newText is fine: Pi's shim uses those and drops `edits`.
export function editArgsProblem(args) {
  const repaired = repairEditArgs(args)
  if (!repaired || typeof repaired.edits !== "string") return null
  if (typeof repaired.oldText === "string" && typeof repaired.newText === "string") return null
  const { problem } = readEdits(repaired.edits)
  if (problem) return `${problem} Fix the JSON, or use write.`
  return `edits is not a list of edits: it reads as ${repaired.edits.slice(0, 40)}. Fix the JSON, or use write.`
}
