#!/usr/bin/env bash
# The loop breaker through real Pi — run it from anywhere:
#
#   bash evals/pi/live-loop.sh
#
# Runs Pi over RPC with pi/guard.js and pi/edit.js against a local mock provider
# that plays one scripted answer per request, in a throwaway agent directory, so
# it needs no model and leaves ~/.pi alone. It exists because evals/guard/cases.sh
# calls the guard's handlers directly: anything that depends on what Pi does first
# (it validates a call before the hook, and retries a dropped stream) cannot show
# up there. A loop of edits that failed validation got past the breaker that way.
#
# Skips when Pi is not installed, which includes CI.
# Exits 0 when every case holds, 1 otherwise, naming each failure.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
command -v node >/dev/null 2>&1 || { printf 'live-loop: node is required — not installed\n' >&2; exit 1; }
if ! command -v pi >/dev/null 2>&1; then
  printf 'live-loop: Pi is not installed; skipped\n'
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
mkdir -p "$work/agent" "$work/proj"

cat > "$work/run.mjs" <<'JS'
import { spawn } from "node:child_process"
import { createServer } from "node:http"
import { readFileSync, writeFileSync } from "node:fs"
import { createInterface } from "node:readline"
const [root, work] = process.argv.slice(2)
const proj = `${work}/proj`
const fails = []

// The mock provider: each request gets the next step of the script, the last one repeating.
let script = []
let served = 0
const chunk = (delta, finish = null) => `data: ${JSON.stringify({ id: "c", object: "chat.completion.chunk", created: 1, model: "m", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`
const calls = { broken: ["edit", { path: "notes.txt", edits: '[{"oldText": "hello", "newText": "bye"}]}]' }], read: ["read", { path: "notes.txt" }] }
const server = createServer((req, res) => {
  req.resume()
  req.on("end", () => {
    const step = script[Math.min(served, script.length - 1)]
    served++
    res.writeHead(200, { "content-type": "text/event-stream" })
    if (step === "drop") {
      res.write(chunk({ role: "assistant", content: "partial " }))
      setTimeout(() => res.destroy(), 50)
      return
    }
    if (calls[step]) {
      const [name, args] = calls[step]
      res.write(chunk({ role: "assistant", tool_calls: [{ index: 0, id: `call${served}`, type: "function", function: { name, arguments: JSON.stringify(args) } }] }))
      res.write(chunk({}, "tool_calls"))
    } else {
      res.write(chunk({ role: "assistant", content: "done" }))
      res.write(chunk({}, "stop"))
    }
    res.end("data: [DONE]\n\n")
  })
})
await new Promise((r) => server.listen(0, "127.0.0.1", r))
writeFileSync(`${work}/agent/models.json`, JSON.stringify({ providers: { mock: { baseUrl: `http://127.0.0.1:${server.address().port}/v1`, api: "openai-completions", apiKey: "x", models: [{ id: "m", name: "m", input: ["text"], contextWindow: 32768, maxTokens: 1024 }] } } }))

// One Pi process, one prompt per entry: what each prompt's run did, up to agent_settled.
const session = (steps, prompts = ["go"]) => new Promise((resolve) => {
  script = steps
  served = 0
  const pi = spawn("pi", ["--mode", "rpc", "--no-session", "--no-extensions", "-e", `${root}/pi/guard.js`, "-e", `${root}/pi/edit.js`, "--model", "mock/m"], { cwd: proj, env: { ...process.env, PI_CODING_AGENT_DIR: `${work}/agent` }, stdio: ["pipe", "pipe", "ignore"] })
  const runs = []
  const fresh = () => ({ tools: [], notes: [], aborted: null, retries: 0 })
  let run = fresh()
  const send = () => pi.stdin.write(JSON.stringify({ type: "prompt", message: prompts[runs.length] }) + "\n")
  // Wait for it to go: a request still in flight would take a step of the next case's script.
  const finish = () => { clearTimeout(timer); pi.once("exit", () => resolve(runs)); pi.kill() }
  const timer = setTimeout(() => { run.timedOut = true; runs.push(run); finish() }, 60000)
  createInterface({ input: pi.stdout }).on("line", (line) => {
    let e
    try { e = JSON.parse(line) } catch { return }
    if (e.type === "tool_execution_end") run.tools.push({ name: e.toolName, isError: e.isError, text: (e.result?.content || []).map((c) => c.text || "").join("") })
    if (e.type === "auto_retry_start") run.retries++
    if (e.type === "extension_ui_request" && e.method === "notify") run.notes.push(e.message)
    if (e.type === "agent_settled") {
      run.aborted = e.aborted
      runs.push(run)
      run = fresh()
      if (runs.length < prompts.length) send()
      else finish()
    }
  })
  send()
})
const expect = (name, ok, got) => { if (!ok) fails.push(`${name}: ${JSON.stringify(got)}`) }
const refused = (t) => t.text.startsWith("dev-guard refuses:")
const original = "hello\n"
writeFileSync(`${proj}/notes.txt`, original)

// One broken edit, repeated: Pi rejects it before the hook. The 5th in a row ends the run.
let [r] = await session(["broken"])
expect("broken edits did not stop on the 5th", r.tools.length === 5 && r.aborted === true, { calls: r.tools.length, aborted: r.aborted })
expect("the stop did not tell the user", r.notes.some((n) => n.includes("This run stops here.")), r.notes)
expect("the broken edit's error is not the JSON error", r.tools.every((t) => t.isError && t.text.startsWith("edits is not valid JSON:") && t.text.includes("Fix the JSON, or use write.")), r.tools[0])
expect("a broken edit changed the file", readFileSync(`${proj}/notes.txt`, "utf8") === original, "changed")

// Three failures and then an answer: nothing stops.
;[r] = await session(["broken", "broken", "broken", "text"])
expect("three broken edits stopped the run", r.tools.length === 3 && r.aborted === false && !r.notes.length, { calls: r.tools.length, aborted: r.aborted, notes: r.notes })

// A broken edit in a cycle with a valid read: the 14th call is the third hit.
;[r] = await session(Array.from({ length: 40 }, (_, i) => (i % 2 ? "broken" : "read")))
expect("a read alternating with a broken edit did not stop on the 14th", r.tools.length === 14 && r.aborted === true, { calls: r.tools.length, aborted: r.aborted })
expect("the 13th call of that cycle was not refused", refused(r.tools[12] ?? { text: "" }), r.tools[12])

// A valid call repeated: the third refusal ends the run through terminate, not abort.
;[r] = await session(["read"])
expect("a read loop did not stop on the third refusal", r.tools.length === 5 && r.aborted === false && r.tools[4].text.includes("This run stops here."), { calls: r.tools.length, aborted: r.aborted, last: r.tools.at(-1)?.text })

// A dropped stream keeps the count. A new prompt clears it.
let second
;[r, second] = await session(["read", "read", "read", "read", "drop", "read", "read", "text"], ["go", "try again"])
expect("no retry happened", r.retries === 1, r.retries)
expect("the count did not survive a retry", r.tools.length === 5 && refused(r.tools[4]) && r.tools[4].text.includes("This run stops here."), r.tools.map((t) => t.isError))
expect("a new prompt did not start clean", second?.tools.length === 1 && !second.tools[0].isError, second?.tools)

server.close()
for (const f of fails) console.log(`FAIL  ${f}`)
process.exit(fails.length ? 1 : 0)
JS

if node "$work/run.mjs" "$root" "$work"; then
  printf 'live-loop: real Pi stops every loop it should, and no other run\n'
  exit 0
fi
printf 'live-loop: case(s) failed\n' >&2
exit 1
