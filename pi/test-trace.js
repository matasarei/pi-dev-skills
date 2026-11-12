// The traced re-run of a failing test: a copy of its file where that one test is
// `.only` and reports, line by line, what each top-level statement returned and the
// values its expects check. pi/commands.js runs it on the 2nd failing run with the
// same result for a test the step added, and appends traceNote() to that result.
//
// Why: told a test's code, the bench's model still blamed the code it was writing
// (.tasks/failing-test-block.md). Shown the run, it saw `placeZone(5, 5, Residential)
// returned true → mgr.funds = 1900` and fixed the test (.tasks/test-trace.md).
//
// The rewrite keeps every line where it was: the helpers go on the it( line after
// its `{`, and each statement is rewritten in place. Only plain-path expect subjects
// (`mgr.funds`, `success`) are watched, read after every statement in a try/catch,
// so nothing with side effects runs twice and a name not yet declared is skipped.
// The scanner skips strings, template text, comments and regex literals (by
// pi/brackets.js's rule for when a slash starts one). This isn't an extension.

import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { basename, dirname, join, relative } from "node:path"
import { run } from "./expand.js"
import { REGEX_BEFORE } from "./brackets.js"
import { testBlock } from "./failing-test.js"
import { shellWord } from "./lib-path.js"

const TIMEOUT_MS = 90000

const KEYWORD = /^(if|for|while|do|switch|return|try|throw|else|class|function|async\s+function|\{)\b|^\{/
const DECL = /^(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=(?!=)/
const EXPECT = /^(?:await\s+)?expect\s*\(/
const PLAIN = /^[A-Za-z_$][\w$]*(?:\??\.[A-Za-z_$][\w$]*|\[\d+\]|\['[^']*'\]|\["[^"]*"\])*$/
// A line break ends a statement at depth 0 unless the next code continues it or this
// code can't end there.
const CONTINUES = /^(?:\?\.|\.(?!\.\.)|\?|:|\+|-(?!-)|\*|\/|%|&&|\|\||\?\?|=(?!>)|,|\)|\]|instanceof\b|in\b)/
const OPEN_END = /(?:[=+\-*/%&|^!?:,(<>[{.]|=>|\b(?:return|typeof|new|await|in|of))$/

// [{ start, end, from, to, text }] — the top-level statements of a body, by line.
function statements(body, firstLine) {
  const out = []
  let depth = 0
  let i = 0
  let line = firstLine
  let cur = null
  let lastCode = -1
  const finish = (to) => {
    out.push({ ...cur, to, text: body.slice(cur.from, to).trim() })
    cur = null
  }
  const nextCode = (k) => {
    for (;;) {
      while (k < body.length && /\s/.test(body[k])) k++
      if (body.startsWith("//", k)) { while (k < body.length && body[k] !== "\n") k++; continue }
      if (body.startsWith("/*", k)) { const e = body.indexOf("*/", k + 2); k = e < 0 ? body.length : e + 2; continue }
      return body.slice(k, k + 12)
    }
  }
  while (i < body.length) {
    const c = body[i]
    if (c === "\n") {
      if (cur && depth === 0 && !OPEN_END.test(body.slice(cur.from, lastCode + 1)) && !CONTINUES.test(nextCode(i + 1))) finish(lastCode + 1)
      line++
      i++
      continue
    }
    if (/\s/.test(c)) { i++; continue }
    if (body.startsWith("//", i)) { while (i < body.length && body[i] !== "\n") i++; continue }
    if (body.startsWith("/*", i)) {
      const e = body.indexOf("*/", i + 2)
      const stop = e < 0 ? body.length : e + 2
      line += (body.slice(i, stop).match(/\n/g) ?? []).length
      i = stop
      continue
    }
    if (!cur) cur = { start: line, end: line, from: i }
    cur.end = line
    if (c === '"' || c === "'") {
      i++
      while (i < body.length && body[i] !== c && body[i] !== "\n") i += body[i] === "\\" ? 2 : 1
      if (body[i] === "\n") { lastCode = i - 1; continue } // unterminated: the newline is still to count
      lastCode = i++
      continue
    }
    // A regex literal, by the rule pi/brackets.js uses: a quote or a bracket inside it is text.
    // Known miss, shared with that rule: a division right after `x++` or `x--` reads as a
    // regex to the end of the line, so `i++ / 2; const a = 1` traces as one row, not two.
    if (c === "/" && REGEX_BEFORE.test(body.slice(cur.from, i).slice(-12))) {
      i++
      let inClass = false
      while (i < body.length && body[i] !== "\n") {
        if (body[i] === "\\") { i += 2; continue }
        if (body[i] === "[") inClass = true
        else if (body[i] === "]") inClass = false
        else if (body[i] === "/" && !inClass) break
        i++
      }
      if (body[i] === "/") i++
      while (/[a-z]/.test(body[i] ?? "")) i++
      lastCode = i - 1
      continue
    }
    if (c === "`") {
      i++
      let inner = 0
      while (i < body.length && !(body[i] === "`" && inner === 0)) {
        if (body[i] === "\\") { i += 2; continue }
        if (body[i] === "\n") line++
        if (body[i] === "$" && body[i + 1] === "{") { inner++; i += 2; continue }
        if (body[i] === "}" && inner > 0) inner--
        i++
      }
      cur.end = line
      lastCode = i++
      continue
    }
    if ("([{".includes(c)) depth++
    else if (")]}".includes(c)) depth--
    lastCode = i
    i++
    if (c === ";" && depth === 0) finish(i)
  }
  if (cur) finish(lastCode + 1)
  return out
}

// The argument of the first expect( in a statement.
function subject(text) {
  const m = EXPECT.exec(text)
  if (!m) return null
  let depth = 1
  let k = m[0].length
  const from = k
  for (; k < text.length && depth > 0; k++) {
    if (text[k] === "(") depth++
    else if (text[k] === ")") depth--
  }
  return depth === 0 ? text.slice(from, k - 1).trim() : null
}

// { source, rows: [{ line, kind, id?, text }], watched } for the test of that name, or
// null: no such test, or a body that doesn't open with `{` on the it( line.
export function instrument(text, name) {
  const block = testBlock(text, name)
  if (!block) return null
  const lines = text.split("\n")
  const head = lines[block.start - 1]
  if (!/\{\s*$/.test(head)) return null
  const bodyLines = lines.slice(block.start, block.end - 1)
  const body = bodyLines.join("\n")
  const stmts = statements(body, block.start + 1)
  const rows = []
  const watched = []
  let rewritten = ""
  let at = 0
  stmts.forEach((s, k) => {
    const decl = DECL.exec(s.text)
    let kind = "expr"
    if (EXPECT.test(s.text)) kind = "expect"
    else if (decl) kind = "decl"
    else if (KEYWORD.test(s.text) || /^(?:const|let|var)\b/.test(s.text)) kind = "other"
    // Shown as written, trailing comment and all (`// 100` says what the test meant). On
    // a line shared with another statement, only this one's part of it.
    const next = stmts[k + 1]
    const shared = stmts.some((o) => o !== s && (o.start === s.start || o.end === s.start))
    const lineEnd = body.indexOf("\n", s.from) < 0 ? body.length : body.indexOf("\n", s.from)
    const shown = shared ? body.slice(s.from, next && next.from < lineEnd ? next.from : lineEnd).trim() : lines[s.start - 1].trim()
    const row = { row: k, line: s.start, kind, text: s.end > s.start ? `${shown} …` : shown }
    if (kind === "decl") row.id = decl[1]
    rows.push(row)
    if (kind === "expect") {
      const sub = subject(s.text)
      if (sub && PLAIN.test(sub) && !watched.includes(sub)) watched.push(sub)
    }
    const semi = s.text.endsWith(";") ? "" : ";"
    let out
    // Traces carry the statement's index: two statements can share a line.
    if (kind === "expect") out = `__devTrace(${k}); ${s.text}${semi} __devPass(${k});`
    else if (kind === "decl") out = `${s.text}${semi} __devTrace(${k}, ${row.id});`
    else if (kind === "other") out = `${s.text} ;__devTrace(${k});`
    else out = `__devTrace(${k}, (${s.text.replace(/;$/, "")}));`
    rewritten += body.slice(at, s.from) + out
    at = s.to
  })
  rewritten += body.slice(at)
  const prelude = [
    "const __devF = (v) => v === null ? \"null\" : Array.isArray(v) ? `Array(${v.length})` : typeof v === \"object\" ? `${v.constructor?.name ?? \"Object\"} {…}` : typeof v === \"function\" ? \"[Function]\" : (typeof v === \"string\" ? JSON.stringify(v) : String(v)).slice(0, 60);",
    `const __devW = {${watched.map((w) => `${JSON.stringify(w)}: () => ${w}`).join(", ")}};`,
    "const __devTrace = (row, ...v) => { const watch = {}; for (const k in __devW) { try { watch[k] = __devF(__devW[k]()) } catch {} } console.log(\"__TRACE \" + JSON.stringify({ row, ...(v.length && v[0] !== undefined ? { returned: __devF(v[0]) } : {}), watch })) };",
    "const __devPass = (row) => console.log(\"__TRACE \" + JSON.stringify({ row, pass: true }));",
  ].join(" ")
  const only = head.replace(/^(\s*)(it|test)(?:\.(?:only|skip))?\(/, "$1it.only(")
  const source = [
    ...lines.slice(0, block.start - 1),
    `${only} ${prelude}`,
    ...rewritten.split("\n"),
    ...lines.slice(block.end - 1),
  ].join("\n")
  return { source, rows, watched }
}

// What the traced run printed: { rows: Map(row index → { returned?, watch, pass? }), failed,
// error: { type, message } | null }. The error is the first "<Name>Error: …" line after
// the last trace line, where runners put the failure.
export function readTrace(output, inst) {
  const rows = new Map()
  let after = 0
  const lines = typeof output === "string" ? output.split("\n") : []
  lines.forEach((l, k) => {
    const m = /__TRACE (\{.*\})\s*$/.exec(l)
    if (!m) return
    let o
    try { o = JSON.parse(m[1]) } catch { return }
    if (!Number.isInteger(o.row)) return
    const seen = rows.get(o.row) ?? {}
    rows.set(o.row, o.pass ? { ...seen, pass: true } : { ...seen, ...o })
    after = k + 1
  })
  let error = null
  for (const l of lines.slice(after)) {
    const m = /^\s*([A-Za-z]*Error):\s*(.*\S)\s*$/.exec(l)
    if (m) { error = { type: m[1], message: m[2] }; break }
  }
  const rest = lines.slice(after).join("\n")
  const failed = !!error || /(^|\s)FAIL\s|[1-9]\d* failed/.test(rest)
  return { inst, rows, failed, error }
}

// What the model reads, or null when the run traced nothing.
export function traceNote(trace, file, name) {
  const { inst, rows, failed, error } = trace ?? {}
  if (!inst || !rows?.size) return null
  const out = []
  for (const r of inst.rows) {
    const got = rows.get(r.row)
    if (!got) {
      if (failed && r.kind !== "expect") out.push(`${r.line}| ${r.text}   threw: ${error ? `${error.type}: ${error.message}` : "an error"}`)
      break
    }
    if (r.kind === "expect") {
      if (got.pass || !failed) { out.push(`${r.line}| ${r.text}   passes`); continue }
      out.push(`${r.line}| ${r.text}   fails: ${error?.message ?? "see the run"}`)
      break
    }
    const bits = []
    if (r.kind === "expr" && got.returned !== undefined) bits.push(`returned ${got.returned}`)
    const list = []
    if (r.kind === "decl" && !inst.watched.includes(r.id) && got.returned !== undefined) list.push(`${r.id} = ${got.returned}`)
    for (const w of inst.watched) if (got.watch && w in got.watch) list.push(`${w} = ${got.watch[w]}`)
    if (list.length) bits.push(`→ ${list.join(", ")}`)
    out.push(bits.length ? `${r.line}| ${r.text}   ${bits.join(" ")}` : `${r.line}| ${r.text}`)
  }
  const head = failed
    ? `\`${name}\` failed again with the same result, so the guard ran it once more and traced it (${file}).`
    : `\`${name}\` failed again with the same result, but passed when the guard ran it alone (${file}).`
  return `${head} Each line, what it returned, and the values its expects check right after it:\n${out.join("\n")}`
}

// Whether testScoped runs vitest: it names vitest, or runs an npm script that does.
function runsVitest(command, cwd) {
  if (/\bvitest\b/.test(command)) return true
  const m = /\bnpm\s+(?:run(?:-script)?\s+([^\s"';&|]+)|(?:test|t)\b)/.exec(command)
  if (!m) return false
  let scripts
  try { scripts = JSON.parse(readFileSync(join(cwd, "package.json"), "utf8")).scripts ?? {} } catch { return false }
  return /^vitest\b/.test(String(scripts[m[1] ?? "test"] ?? ""))
}

// Runs the test once, traced: { trace } from readTrace(), or { unsupported } (no vitest
// testScoped with {name}, no such test) or { error } (the run didn't finish in time).
// The copy sits beside the file as <base>.trace.<ext>, so its imports resolve, and is
// removed whatever happens. The profile's testScoped runs it, as lib/test.sh would, but
// nothing is written to .devskills/test-result: this isn't a verdict.
export async function runTrace(cwd, file, name, { timeoutMs = TIMEOUT_MS } = {}) {
  let command
  try { command = JSON.parse(readFileSync(join(cwd, ".devskills/profile.json"), "utf8")).testScoped } catch { return { unsupported: "no profile" } }
  if (typeof command !== "string" || !command.includes("{name}")) return { unsupported: "no testScoped with {name}" }
  if (!runsVitest(command, cwd)) return { unsupported: "testScoped doesn't run vitest" }
  let text
  try { text = readFileSync(file, "utf8") } catch { return { unsupported: "the test file can't be read" } }
  const inst = instrument(text, name)
  if (!inst) return { unsupported: "the test isn't found, or its body doesn't open on its it( line" }
  const m = /^(.*?)(\.test\.[^.]+)$/.exec(basename(file))
  if (!m) return { unsupported: "not a .test. file" }
  const copy = join(dirname(file), `${m[1]}.trace${m[2]}`)
  if (existsSync(copy)) return { unsupported: `${basename(copy)} is already there` }
  try {
    writeFileSync(copy, inst.source)
    const output = await run(command.split("{name}").join(shellWord(relative(cwd, copy))), { cwd, timeoutMs })
    if (/\(timed out after \d+s\)$/.test(output)) return { error: `the traced run timed out after ${Math.round(timeoutMs / 1000)}s` }
    return { trace: readTrace(output, inst) }
  } finally {
    rmSync(copy, { force: true })
  }
}
