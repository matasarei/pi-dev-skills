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
// It also ends strings with the wrong closers, as in }]}, and those are replaced.

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

// The text with whatever follows its last string literal replaced by the closers the
// open brackets need, when that is only closers and whitespace; null when it isn't. A
// null value may come first, as the model's repeats end in "newText": null. It changes
// nothing before that point, so the model's text stays as it wrote it.
function withRightClosers(text) {
  const open = []
  let end = -1
  let openAtEnd = []
  let inString = false
  let escaped = false
  for (let i = 0; i < text.length; i++) {
    const ch = text[i]
    if (inString) {
      if (escaped) escaped = false
      else if (ch === "\\") escaped = true
      else if (ch === '"') { inString = false; end = i + 1; openAtEnd = [...open] }
    } else if (ch === '"') inString = true
    else if (ch === "[" || ch === "{") open.push(ch)
    else if (ch === "]" || ch === "}") open.pop()
  }
  const tail = inString || end < 0 ? null : text.slice(end).match(/^(\s*:\s*null)?[\s\]}]*$/)
  if (!tail) return null
  return text.slice(0, end) + (tail[1] ?? "") + openAtEnd.reverse().map((ch) => (ch === "[" ? "]" : "}")).join("")
}

// What a string `edits` reads as: { value }, or { problem } saying why it can't be read.
// The JSON error reported is the escaped text's: raw newlines aren't the problem, the
// repair copes, and with its closers as sent, its position is one the model wrote.
function readEdits(text) {
  const escaped = escapeControlInStrings(text)
  let problem = null
  const read = (candidate, report) => {
    try {
      return { value: readJson(candidate) }
    } catch (e) {
      if (e.repeatedKey) return { problem: `edits gives ${e.repeatedKey} twice with different values.` }
      if (report) problem = `edits is not valid JSON: ${e.message}.`
      return null
    }
  }
  const closed = withRightClosers(escaped)
  return read(text, false) ?? read(escaped, true) ?? (closed === null ? null : read(closed, false)) ?? { problem }
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
//
// The refusal asks for that flat shape. Its values are plain arguments, so there's
// no JSON inside a string to get wrong, which the bench's model gets wrong in long
// edits. It doesn't name write: told "or use write", the model spliced the file from
// the shell instead and broke it. The README has the figures.
const ASK = "Send this change again as one edit with path, oldText and newText as plain arguments, without edits. If it is long, add it in parts of about 40 lines, one edit each. Don't rewrite the file from the shell."

export function editArgsProblem(args) {
  const repaired = repairEditArgs(args)
  if (!repaired || typeof repaired.edits !== "string") return null
  if (typeof repaired.oldText === "string" && typeof repaired.newText === "string") return null
  const { problem } = readEdits(repaired.edits)
  if (problem) return `${problem} ${ASK}`
  return `edits is not a list of edits: it reads as ${repaired.edits.slice(0, 40)}. ${ASK}`
}

// The edit definition with the flat pair in its schema: top-level oldText and newText
// after path, only path required, and a note at the front of its description. Pi's
// shim already folds that pair into edits, but its schema only shows edits, and the
// bench's model sends edits as a JSON string, which it nests wrongly when the text is
// long. The descriptions are the ones replayed on the bench's model, and the README
// has what that showed. path and edits are Pi's own, and the definition given isn't
// changed.
const FLAT_NOTE = "For one replacement, pass oldText and newText directly, next to path. Use edits only for several replacements in one call. "

export function withFlatShape(definition) {
  const params = definition.parameters
  // A schema of another shape, from a later Pi, is left as it is rather than sent broken.
  if (!params?.properties?.path || !params.properties.edits || typeof definition.description !== "string") return definition
  return {
    ...definition,
    description: FLAT_NOTE + definition.description,
    parameters: {
      ...params,
      required: ["path"],
      properties: {
        path: params.properties.path,
        oldText: { type: "string", description: "Exact text to replace, for one replacement. It must be unique in the file. Use with newText instead of edits." },
        newText: { type: "string", description: "Replacement text for oldText." },
        edits: params.properties.edits,
      },
    },
  }
}
