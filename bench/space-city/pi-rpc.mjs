// One headless Pi session: send one prompt, wait for the agent to finish, save
// every RPC event and the session's token stats. Used by run.sh.
//
//   node pi-rpc.mjs <cwd> <model> <prompt> <events.jsonl> <stats.json> <timeout-seconds>
//
// Exits 0 when the agent finished, 2 on timeout, 3 when the command was gated
// (it notified the user instead of starting the agent: a refused branch, a
// manual plan), 1 when Pi itself failed.

import { spawn } from "node:child_process"
import { createWriteStream, writeFileSync } from "node:fs"

const [cwd, model, prompt, eventsFile, statsFile, timeoutSeconds] = process.argv.slice(2)
const pi = spawn("pi", ["--mode", "rpc", "--no-session", "--model", model], { cwd, stdio: ["pipe", "pipe", "inherit"] })
const events = createWriteStream(eventsFile)
let started = false
let finished = false
let timedOut = false
let gated = false
let buf = ""

const send = (msg) => pi.stdin.write(JSON.stringify(msg) + "\n")
const quit = (code) => {
  events.end(() => {
    pi.kill()
    process.exit(code)
  })
}

const timer = setTimeout(() => {
  events.write(JSON.stringify({ type: "bench_timeout", seconds: Number(timeoutSeconds) }) + "\n")
  finished = true
  timedOut = true
  send({ type: "get_session_stats" })
  setTimeout(() => quit(2), 5000)
}, Number(timeoutSeconds) * 1000)

pi.on("exit", () => {
  if (!finished) {
    clearTimeout(timer)
    events.end(() => process.exit(1))
  }
})

pi.stdout.on("data", (d) => {
  buf += d
  let i
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i)
    buf = buf.slice(i + 1)
    events.write(line + "\n")
    let e
    try { e = JSON.parse(line) } catch { continue }
    if (e.type === "agent_start") started = true
    // A command that stops before the model runs only notifies; nothing else follows.
    if (e.type === "extension_ui_request" && e.method === "notify" && e.notifyType === "error" && !started && !finished) {
      finished = true
      gated = true
      send({ type: "get_session_stats" })
    }
    // Not agent_end: Pi ends the agent run on a dropped stream, then retries it.
    if (e.type === "agent_settled" && started && !finished) {
      finished = true
      send({ type: "get_session_stats" })
    }
    if (e.type === "response" && e.command === "get_session_stats") {
      writeFileSync(statsFile, JSON.stringify(e.data ?? {}, null, 2))
      clearTimeout(timer)
      quit(timedOut ? 2 : gated ? 3 : 0)
    }
  }
})

send({ type: "prompt", message: prompt })
