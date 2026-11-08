// Where a JS/TS file's brackets stop matching, and the hint the guard adds to a
// bash result that reports a syntax error in one.
//
// A test run on a file with a block left open says "Unexpected end of file" at the
// last line, and nothing about where the block opened. In the two bench steps that
// hit it, the model then read the file through moving sed windows for 30-40 calls
// and never found the missing `});`. Told the line, it went there.
//
// Two passes. The count matches {} () [] with a stack, skipping strings, template
// text, regex literals and comments; when it balances, there is no hint. Only a file
// it fails is placed, by indentation: a block that opens at or left of the indent of
// a block still open above it means the one above never closed. The indent rule alone
// misplaces about 2% of good files, so it never decides whether a file is broken.
// This isn't an extension.

import { isAbsolute, join, relative } from "node:path"
import { readFileSync, statSync } from "node:fs"
import { shellWord } from "./lib-path.js"

const MAX_BYTES = 2_000_000
const MAX_HINTS = 3
// A slash after one of these starts a regex literal; after anything else it divides.
const REGEX_BEFORE = /(^|[(,=:[!&|?{};+\-*%<>~^]|\b(return|typeof|case|do|else|in|of|new|delete|void|throw|yield|await))\s*$/
const PAIR = { ")": "(", "]": "[", "}": "{" }

function scan(s, place) {
  const lines = s.split("\n")
  const indent = (n) => lines[n - 1].match(/^[ \t]*/)[0].replace(/\t/g, "    ").length
  const stack = []
  const tpl = [] // the stack depth at which each open template literal resumes
  const found = []
  let i = 0
  let line = 1
  let lineStart = 0
  let prev = "" // the code just before, for the regex decision
  while (i < s.length) {
    const c = s[i]
    const d = s[i + 1]
    if (c === "\n") { line++; i++; lineStart = i; prev += "\n"; continue }
    if (c === "/" && d === "/") { while (i < s.length && s[i] !== "\n") i++; continue }
    if (c === "/" && d === "*") {
      i += 2
      while (i < s.length && !(s[i] === "*" && s[i + 1] === "/")) { if (s[i] === "\n") line++; i++ }
      i += 2
      continue
    }
    if (c === '"' || c === "'") {
      i++
      while (i < s.length && s[i] !== c && s[i] !== "\n") { if (s[i] === "\\") i++; i++ }
      i++
      prev += "x"
      continue
    }
    if (c === "/" && REGEX_BEFORE.test(prev.slice(-12))) {
      i++
      let inClass = false
      while (i < s.length && s[i] !== "\n") {
        if (s[i] === "\\") { i += 2; continue }
        if (s[i] === "[") inClass = true
        else if (s[i] === "]") inClass = false
        else if (s[i] === "/" && !inClass) break
        i++
      }
      i++
      while (/[a-z]/.test(s[i] ?? "")) i++
      prev += "x"
      continue
    }
    if (c === "`" || (c === "}" && tpl.length && tpl[tpl.length - 1] === stack.length)) {
      if (c === "}") tpl.pop()
      i++
      let expression = false
      while (i < s.length && s[i] !== "`") {
        if (s[i] === "\\") { i += 2; continue }
        if (s[i] === "\n") line++
        if (s[i] === "$" && s[i + 1] === "{") { tpl.push(stack.length); i += 2; expression = true; break }
        i++
      }
      if (!expression && s[i] === "`") i++ // the template's end; after ${, a backtick opens a new one
      prev += "x"
      continue
    }
    prev = (prev + c).slice(-40)
    if (c === "{") {
      if (place) {
        const startsLine = /^\s*$/.test(s.slice(lineStart, i)) || /^\s*[\w.$]+\s*\(/.test(lines[line - 1])
        // Each block still open at or right of this line's indent never closed: note
        // it, drop it as if closed, and keep going to count the rest.
        for (;;) {
          const top = stack.findLast((o) => o.c === "{")
          if (!top || top.line === line || !startsLine || indent(line) > indent(top.line)) break
          found.push({ open: top.line, next: line })
          stack.length = stack.lastIndexOf(top)
        }
      }
      stack.push({ c, line })
    } else if (c === "(" || c === "[") {
      stack.push({ c, line })
    } else if (c in PAIR) {
      if (found.length) { stack.pop(); i++; continue } // placed already: what follows is noise
      if (!stack.length) return { kind: "extra", line, close: c }
      const top = stack[stack.length - 1]
      if (top.c !== PAIR[c]) return { kind: "mismatch", line, close: c, open: top.line, opened: top.c }
      stack.pop()
    }
    i++
  }
  if (found.length) return { kind: "unclosed", open: found[0].open, next: found[0].next, count: found.length }
  if (stack.length) return { kind: "eof", open: stack[stack.length - 1].line, count: stack.length }
  return null
}

// null when the file's brackets match; otherwise where they stop.
export function unbalanced(text) {
  if (typeof text !== "string" || text.length > MAX_BYTES) return null
  const counted = scan(text, false)
  if (!counted) return null
  return scan(text, true) ?? counted
}

// The words a parser or compiler uses for a broken file: esbuild (vitest, tsx),
// tsc, node and the bundlers.
const SYNTAX_ERROR = /Unexpected end of file|Unexpected "[})\]]"|'[})\]]' expected|Unterminated|SyntaxError/
const CODE_PATH = /[\w./@-]+\.[cm]?[jt]sx?(?=:\d|\(\d+,)/g

// The file a path in tool output means, inside cwd: a container's /app/src/x.ts is
// cwd's src/x.ts, the longest tail of the path that exists. Never outside cwd.
function projectFile(path, cwd) {
  const parts = path.split("/").filter((p) => p && p !== ".")
  if (parts.includes("..")) return null
  for (let k = 0; k < parts.length; k++) {
    const full = join(cwd, ...parts.slice(k))
    try {
      if (statSync(full).isFile()) return full
    } catch {
      // not this tail
    }
  }
  return null
}

function hintFor(file, text, at) {
  const lines = text.split("\n")
  const show = (n) => "`" + (lines[n - 1] ?? "").trim().replace(/`/g, "'").slice(0, 100) + "`"
  if (at.kind === "unclosed") {
    const where = `line ${at.open} ${show(at.open)} is still open where line ${at.next} ${show(at.next)} starts at the same indent, so its close belongs just before line ${at.next}`
    if (at.count === 1) return `${file} has a block that never closes: ${where}. Add it there with edit; don't rewrite the file.`
    return `${file} has ${at.count} blocks that never close. The first: ${where}. \`git diff -- ${shellWord(file)}\` shows which closes went missing.`
  }
  if (at.kind === "mismatch") return `${file} line ${at.line} closes with \`${at.close}\`, but the bracket still open there is the \`${at.opened}\` from line ${at.open} ${show(at.open)}.`
  if (at.kind === "extra") return `${file} line ${at.line} ${show(at.line)} has a \`${at.close}\` with nothing open before it.`
  return `${file} ends with ${at.count} bracket(s) still open; the innermost opens at line ${at.open} ${show(at.open)}.`
}

// The hint for a bash result, or null: only output that reports a syntax error, only
// files in cwd it names with a line, and only those the count finds broken.
export function syntaxHint(output, cwd) {
  if (typeof output !== "string" || !SYNTAX_ERROR.test(output)) return null
  const seen = new Set()
  const hints = []
  for (const [path] of output.matchAll(CODE_PATH)) {
    const full = projectFile(path, cwd)
    if (!full || seen.has(full)) continue
    seen.add(full)
    let text
    try {
      text = readFileSync(full, "utf8")
    } catch {
      continue
    }
    const at = unbalanced(text)
    if (!at) continue
    hints.push(hintFor(isAbsolute(full) ? relative(cwd, full) : full, text, at))
    if (hints.length === MAX_HINTS) break
  }
  return hints.length ? hints.join("\n\n") : null
}
