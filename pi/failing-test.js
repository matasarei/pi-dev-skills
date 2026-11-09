// Which test a failing vitest run names, where that test is in its file, and whether
// this step added it. The guard picks the test to trace with these (pi/test-trace.js,
// pi/commands.js). This isn't an extension.
//
// The bench's model mostly runs the tests through grep, so a result often keeps a
// test's name and drops the rest: the name lines are read wherever they are, and the
// `expected … to …` line only when it follows one.

import { execFileSync } from "node:child_process"
import { existsSync, readFileSync } from "node:fs"
import { join } from "node:path"

// vitest's "FAIL  <file> > … > <name>" and the summary's "❯ <file> > … > <name>" or
// "× …". The file line with counts ("❯ <file>  (29 tests | 1 failed)") has no " > ".
const NAMED = /^\s*(?:FAIL|❯|×)\s+(\S+\.test\.[cm]?[jt]sx?) > (.*)$/
const RESULT = /^\s*(?:→|AssertionError:)\s*(expected .*\S)\s*$/

// [{ file, name, result }] — each failing test once, in the order first named; result is
// the "expected … to …" text, or null when no line of this output gave it.
export function failingTests(output) {
  if (typeof output !== "string") return []
  const lines = output.split("\n")
  const found = new Map()
  lines.forEach((line, i) => {
    const m = NAMED.exec(line)
    if (!m) return
    const name = m[2].split(" > ").pop().replace(/\s+\d+ms$/, "").trim()
    const r = RESULT.exec(lines[i + 1] ?? "")
    const key = `${m[1]}\0${name}`
    const seen = found.get(key)
    if (!seen) found.set(key, { file: m[1], name, result: r ? r[1] : null })
    else if (!seen.result && r) seen.result = r[1]
  })
  return [...found.values()]
}

// [{ file, name }] — tests a vitest output shows passing by name (" ✓ <file> > … > <name>").
export function passingTests(output) {
  if (typeof output !== "string") return []
  const out = []
  for (const line of output.split("\n")) {
    const m = /^\s*✓\s+(\S+\.test\.[cm]?[jt]sx?) > (.*)$/.exec(line)
    if (m) out.push({ file: m[1], name: m[2].split(" > ").pop().replace(/\s+\d+ms$/, "").trim() })
  }
  return out
}

// Whether a vitest output's summary says that nothing failed: "Tests  3 passed (3)".
export function nothingFailed(output) {
  return typeof output === "string" && /^\s*Tests\s+\d+ passed\b/m.test(output) && !/^\s*Tests\s.*\bfailed\b/m.test(output)
}

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
const indent = (l) => l.match(/^[ \t]*/)[0].replace(/\t/g, "    ").length

// { start, end } (1-based lines) of the it(…)/test(…) whose first argument is the name
// as a string literal, or null. It ends at the first later line indented no deeper that
// starts with }, or at the end of the file.
export function testBlock(text, name) {
  if (typeof text !== "string" || typeof name !== "string") return null
  const lines = text.split("\n")
  const open = new RegExp(`^\\s*(?:it|test)(?:\\.(?:only|skip))?\\(\\s*(['"\`])${esc(name)}\\1`)
  const s = lines.findIndex((l) => open.test(l))
  if (s < 0) return null
  for (let k = s + 1; k < lines.length; k++) {
    if (/^\s*}/.test(lines[k]) && indent(lines[k]) <= indent(lines[s])) return { start: s + 1, end: k + 1 }
  }
  let end = lines.length
  while (end > s + 1 && lines[end - 1].trim() === "") end--
  return { start: s + 1, end }
}

// lib/test-open.sh's rule, for one file: the name, quoted whole, is on an added line of
// `git diff HEAD` or in the file while it is untracked, and on no removed line.
export function addedByStep(cwd, file, name) {
  const git = (...args) => execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] })
  if (!existsSync(join(cwd, file))) return false
  const declares = (lines) => ["'", '"', "`"].some((q) => lines.some((l) => l.includes(`${q}${name}${q}`)))
  try {
    if (git("ls-files", "--others", "--exclude-standard", "--", file).trim()) return declares(readFileSync(join(cwd, file), "utf8").split("\n"))
    const diff = git("diff", "HEAD", "--unified=0", "--no-color", "--", file).split("\n")
    const added = diff.filter((l) => l.startsWith("+") && !l.startsWith("+++"))
    const removed = diff.filter((l) => l.startsWith("-") && !l.startsWith("---"))
    return declares(added) && !declares(removed)
  } catch {
    return false
  }
}
