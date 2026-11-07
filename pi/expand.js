// expand — what a skill's "!`…`" lines become before the model reads them.
//
// Every SKILL.md here computes its facts with lines of the form
//
//   !`bash ${DEV_SKILLS_LIB:-…}/task-step.sh $ARGUMENTS 2>&1`
//
// OpenCode ran those itself. Pi skills follow the Agent Skills spec, which only
// appends arguments, so pi/commands.js runs them here instead: each injection
// line is replaced by what its command printed, $ARGUMENTS by the raw argument
// text, and the frontmatter is dropped. The rule is the one
// evals/skills/injected.sh used to simulate OpenCode with, and that suite now
// runs this file, so the code that is tested is the code that runs.
//
// Run it by hand to see what the model would get:
//
//   node pi/expand.js [--offline] skills/dev-implement/SKILL.md .tasks/plan.md
//
// --offline leaves out injections that call gh, which reach the network.

import { spawn } from "node:child_process"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { pathToFileURL } from "node:url"
import { LIB, withLibPath } from "./lib-path.js"

const INJECTION = /^!`(.*)`$/
// The same test injected.sh made: a command that starts with gh, or runs gh as a word.
const NETWORK = /^gh |\sgh /
const TIMEOUT_MS = 60000

// The text after the frontmatter, or the whole text when there is none.
export function body(text) {
  const m = /^---\r?\n[\s\S]*?\r?\n---\r?\n/.exec(text)
  return m ? text.slice(m[0].length).replace(/^\s*\n/, "") : text
}

// The frontmatter's description line, or "".
export function description(text) {
  const m = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text)
  if (!m) return ""
  const line = m[1].split(/\r?\n/).find((l) => l.startsWith("description:"))
  return line ? line.slice("description:".length).trim() : ""
}

// One injection's output: stdout and stderr in the order printed, trailing
// newlines dropped the way $(…) drops them. A non-zero exit is not an error —
// the output is the fact, usage lines and all, and the evals look for those.
export function run(command, { cwd, env, timeoutMs = TIMEOUT_MS }) {
  return new Promise((done) => {
    const child = spawn("bash", ["-c", `exec 2>&1\n${command}`], {
      cwd,
      env: { ...process.env, ...env },
      stdio: ["ignore", "pipe", "pipe"],
      // Its own process group, so a timeout kills what it started in the
      // background too; one left alive holds the pipe and close never fires.
      detached: true,
    })
    let out = ""
    child.stdout.on("data", (d) => { out += d })
    child.stderr.on("data", (d) => { out += d })
    const timer = setTimeout(() => {
      try { process.kill(-child.pid, "SIGKILL") } catch { child.kill("SIGKILL") }
      out += `\n(timed out after ${Math.round(timeoutMs / 1000)}s)`
    }, timeoutMs)
    child.on("error", (e) => { out += `\n(could not run bash: ${e.message})` })
    child.on("close", () => {
      clearTimeout(timer)
      done(out.replace(/\n+$/, ""))
    })
  })
}

// The skill as the model reads it. Injections run one at a time, in order, so a
// later one sees what an earlier one wrote (profile.sh caches the profile).
// They run with DEV_SKILLS_LIB set, to this checkout's lib/ when nobody set it,
// and the other lines name that lib/ as a path (pi/lib-path.js).
export async function expandSkill(text, { args = "", cwd = process.cwd(), env = {}, offline = false, timeoutMs } = {}) {
  const lib = env.DEV_SKILLS_LIB ?? process.env.DEV_SKILLS_LIB ?? LIB
  const runEnv = { ...env, DEV_SKILLS_LIB: lib }
  const lines = body(text).split("\n")
  const out = []
  for (const line of lines) {
    const m = INJECTION.exec(line)
    if (!m) { out.push(withLibPath(line, lib)); continue }
    const command = m[1].split("$ARGUMENTS").join(args)
    if (offline && NETWORK.test(command)) {
      out.push("(skipped: this injection needs the network)")
      continue
    }
    out.push(await run(command, { cwd, env: runEnv, timeoutMs }))
  }
  return out.join("\n")
}

// CLI: node pi/expand.js [--offline] <SKILL.md> [arguments]
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const argv = process.argv.slice(2)
  const offline = argv[0] === "--offline"
  if (offline) argv.shift()
  const [file, args = ""] = argv
  if (!file) {
    process.stderr.write("usage: node pi/expand.js [--offline] <SKILL.md> [arguments]\n")
    process.exit(2)
  }
  process.stdout.write(`${await expandSkill(readFileSync(file, "utf8"), { args, offline })}\n`)
}
