// Where an edit's oldText stops matching the file — the hint the guard adds to an
// edit result Pi failed with "Could not find …".
//
// Pi says only that the text wasn't found. In run 20261109-175338-pi the model then
// resent oldText of 40-76 lines written from memory, four times: each time the first
// lines were the file's and a later one wasn't (a comment it had left out, a line it
// had already changed). Told which line that is and what the file has there, it has
// what it needs to send the few lines it means to change.
// This isn't an extension.

import { readFileSync } from "node:fs"
import { relative, resolve } from "node:path"

const MAX_EDITS = 3
const MAX_WIDTH = 100
// Pi's two messages (core/tools/edit-diff.js): one edit, or edits[n] of several.
const MISS = /Could not find (?:the exact text|edits\[(\d+)\]) in /

const show = (line) => "`" + line.replace(/`/g, "'").slice(0, MAX_WIDTH) + "`"
// Trailing spaces don't decide a match, as they don't for Pi.
const same = (a, b) => a.trimEnd() === b.trimEnd()

// Where one oldText stops matching the file's lines, as a sentence.
function place(oldText, lines, name) {
  const old = oldText.split("\n")
  // The longest run of oldText's first lines that are consecutive lines of the file.
  // A first line with no indentation may start mid-line, so it only has to end the
  // file's line; one with indentation has to be the whole line, indentation included.
  const opens = /^\s/.test(old[0]) || !old[0].trim() ? (l) => same(l, old[0]) : (l) => l.trimEnd().endsWith(old[0].trimEnd())
  let best = { at: -1, count: 0 }
  for (let s = 0; s < lines.length; s++) {
    if (!opens(lines[s])) continue
    let k = 1
    while (k < old.length && s + k < lines.length && same(lines[s + k], old[k])) k++
    if (k > best.count) best = { at: s, count: k }
  }
  if (best.count === 0) {
    const loose = lines.findIndex((l) => l.trim() && l.trim() === old[0].trim())
    if (loose >= 0) return `oldText line 1 ${show(old[0])} matches line ${loose + 1} ${show(lines[loose])} only with different indentation.`
    return `oldText line 1 ${show(old[0])} is not in ${name}.`
  }
  if (best.count === old.length) return null // every line matches: Pi's miss is something this can't place
  const next = best.at + best.count
  const there = next < lines.length ? `line ${next + 1} is ${show(lines[next])}` : `the file ends at line ${lines.length}`
  const matched = best.count === 1 ? `oldText line 1 matches line ${next} of ${name}` : `oldText lines 1-${best.count} match lines ${best.at + 1}-${next} of ${name}`
  return `${matched}; its line ${best.count + 1} ${show(old[best.count])} is not what follows: ${there}.`
}

// The hint for an edit result, or null: only Pi's miss, only a file it can read,
// only an oldText the file doesn't have.
export function editMissHint(input, resultText, cwd) {
  if (!input || typeof input !== "object" || typeof input.path !== "string") return null
  const m = typeof resultText === "string" ? MISS.exec(resultText) : null
  if (!m) return null
  const full = resolve(cwd, input.path)
  let text
  try {
    text = readFileSync(full, "utf8")
  } catch {
    return null
  }
  const lines = text.replace(/\r\n/g, "\n").replace(/\n$/, "").split("\n")
  const name = relative(cwd, full)
  // As Pi's shim builds them (core/tools/edit.js): edits[], then a flat oldText last.
  const edits = [...(Array.isArray(input.edits) ? input.edits : []), ...(typeof input.oldText === "string" ? [{ oldText: input.oldText }] : [])]
  // Pi names the one edit it couldn't find when there are several.
  const which = m[1] !== undefined ? [Number(m[1])] : edits.map((_, k) => k)
  const notes = []
  for (const k of which) {
    const oldText = edits[k]?.oldText
    if (typeof oldText !== "string" || !oldText || text.includes(oldText)) continue
    const where = place(oldText.replace(/\r\n/g, "\n"), lines, name)
    if (where) notes.push(edits.length > 1 ? `edits[${k}]: ${where}` : where)
    if (notes.length === MAX_EDITS) break
  }
  if (!notes.length) return null
  return [...notes, "Put only the lines you change in oldText, copied from the file."].join("\n")
}
