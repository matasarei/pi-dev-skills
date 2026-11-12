// The lines tsc names, as the files hold them now — the hint the guard adds to a
// bash result that has tsc errors in it.
//
// tsc gives a file, a line and a message. In run 20261109-175338-pi it named two
// one-line fixes in the model's own test file (an unused variable, a string where an
// enum value belongs), and the model then spent about 630 s on edits whose oldText it
// wrote from memory: 40-76 lines, with lines the file didn't have. Shown each line as
// it is, indentation included, the one line is what an edit needs.
// This isn't an extension.

import { readFileSync } from "node:fs"
import { isAbsolute, relative } from "node:path"
import { projectFile } from "./brackets.js"

const MAX_LINES = 5
const MAX_WIDTH = 160
// tsc's plain format, "src/x.ts(57,15): error TS6133: …", and its pretty one,
// "src/x.ts:57:15 - error TS6133: …" once the colours are gone.
const PLAIN = /^(\S+\.[cm]?[jt]sx?)\((\d+),\d+\): error TS\d+/
const PRETTY = /^(\S+\.[cm]?[jt]sx?):(\d+):\d+ - error TS\d+/
const COLOUR = /\x1b\[[0-9;]*m/g

// The hint for a bash result, or null: only output with a tsc error, only files in
// cwd, only lines the file has.
export function tscLines(output, cwd) {
  if (typeof output !== "string") return null
  const plain = output.replace(COLOUR, "")
  if (!/error TS\d+/.test(plain)) return null
  const files = new Map()
  const textOf = (full) => {
    if (!files.has(full)) {
      try {
        files.set(full, readFileSync(full, "utf8").split("\n"))
      } catch {
        files.set(full, null)
      }
    }
    return files.get(full)
  }
  const seen = new Set()
  const found = []
  for (const raw of plain.split("\n")) {
    const line = raw.trim()
    const m = PLAIN.exec(line) ?? PRETTY.exec(line)
    if (!m) continue
    const full = projectFile(m[1], cwd)
    const n = Number(m[2])
    const key = `${full}:${n}`
    if (!full || seen.has(key)) continue
    seen.add(key)
    const lines = textOf(full)
    if (!lines || n < 1 || n > lines.length) continue
    const name = isAbsolute(full) ? relative(cwd, full) : full
    let text = lines[n - 1].replace(/\r$/, "").replace(/`/g, "'")
    if (text.length > MAX_WIDTH) text = text.slice(0, MAX_WIDTH) + "…"
    found.push(`${name}:${n} \`${text}\``)
  }
  if (!found.length) return null
  const more = found.length - MAX_LINES
  return ["The lines tsc names, as the files hold them now:", ...found.slice(0, MAX_LINES), ...(more > 0 ? [`…and ${more} more.`] : [])].join("\n")
}
