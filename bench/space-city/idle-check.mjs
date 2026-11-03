#!/usr/bin/env node
// Is Pi's idle timeout enough to run the bench on? Used by run.sh.
//
//   node idle-check.mjs
//
// Prints the timeout in ms (0: none) and exits 0 when it is, for meta.env. Otherwise
// says what to set on stderr and exits 1. Reads the global settings: the bench's
// target is a fresh clone with no .pi/, so they are the ones in effect.

import { readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import { idleMs, idleProblem } from "../../pi/idle-timeout.js"

const dir = process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent")
const file = join(dir, "settings.json")
const refuse = (why) => {
  console.error(`${why} (${file})`)
  process.exit(1)
}

let settings = {}
let text = null
try { text = readFileSync(file, "utf8") } catch {} // No file is no setting: Pi's default.
if (text !== null) {
  try { settings = JSON.parse(text) } catch (e) { refuse(`settings.json is not valid JSON, so httpIdleTimeoutMs can't be read: ${e.message}`) }
  if (settings === null || typeof settings !== "object" || Array.isArray(settings)) refuse("settings.json is not an object, so httpIdleTimeoutMs can't be read")
}
const problem = idleProblem(settings.httpIdleTimeoutMs)
if (problem) refuse(problem)
console.log(idleMs(settings.httpIdleTimeoutMs))
