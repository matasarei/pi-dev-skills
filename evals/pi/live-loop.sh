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
# It also pins what Pi 1.5.0 does with a tool call that goes silent, as one does on
# LM Studio, which sends the arguments only when they are complete: past
# httpIdleTimeoutMs the call drops as `terminated`, and below it the call arrives.
# A call cut off at the output limit is refused, and the run goes on. The setting
# in the README and in the bench's preflight rests on this, so a new pin re-tests it.
# And that the warning in pi/commands.js sees what Pi really hands an extension.
#
# An edit in the shapes the model really sends, a repeated newText and stray closers:
# pi/edit.js repairs them before Pi validates them, and the file gets the first text.
#
# A step's 5th failing test run: the model sees the note in that tool result, through
# Pi's tool_result hook, and test-open.sh is refused until then.
#
# A runaway reply, stopped mid-stream during a /dev-* command: the next request has
# the nudge and not the repeated text, because Pi leaves an aborted reply out of it,
# and a run started from agent_settled really runs.
#
# A write of what the file already holds: the hook sees the content, the model sees
# the refusal instead of Pi's "Successfully wrote", and the third one ends the run.
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
import { execFileSync, spawn } from "node:child_process"
import { createServer } from "node:http"
import { mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { createInterface } from "node:readline"
const [root, work] = process.argv.slice(2)
const proj = `${work}/proj`
const fails = []

// The mock provider: each request gets the next step of the script, the last one repeating.
let script = []
let served = 0
let bodies = []
const chunk = (delta, finish = null) => `data: ${JSON.stringify({ id: "c", object: "chat.completion.chunk", created: 1, model: "m", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`
const calls = { broken: ["edit", { path: "notes.txt", edits: '[{"oldText": "hello", "newText": "bye' }], repeated: ["edit", { path: "notes.txt", edits: '[{"oldText": "hello", "newText": "bye", "newText": ""}]' }], closers: ["edit", { path: "notes.txt", edits: '[{"oldText": "hello", "newText": "bye"}]}]' }], read: ["read", { path: "notes.txt" }], write: ["write", { path: "written.txt", content: "let x = 3;\n" }] }
// A tool call's name now and its arguments after a silence, or never: the output limit ends it.
const SILENCE_MS = 3000
// One line, over and over, until the client goes or the output limit would end it.
const REPEATED = "The test calls clearZone on a cell with no entity, so let me look again at what it does.\n"
const server = createServer((req, res) => {
  let body = ""
  req.on("data", (d) => { body += d })
  req.on("end", () => {
    if (req.url.includes("chat/completions")) bodies.push(JSON.parse(body))
    const step = script[Math.min(served, script.length - 1)]
    served++
    res.writeHead(200, { "content-type": "text/event-stream" })
    if (step === "repeat") {
      let lines = 0
      const timer = setInterval(() => {
        if (lines++ < 300) return res.write(chunk({ role: "assistant", content: REPEATED }))
        clearInterval(timer)
        res.write(chunk({}, "length"))
        res.end("data: [DONE]\n\n")
      }, 5)
      res.on("close", () => clearInterval(timer))
      return
    }
    if (step === "silent" || step === "cut") {
      const named = { index: 0, id: `call${served}`, type: "function", function: { name: "read", arguments: "" } }
      res.write(chunk({ role: "assistant", content: "Reading: ", tool_calls: [named] }))
      if (step === "cut") {
        res.write(chunk({}, "length"))
        return res.end("data: [DONE]\n\n")
      }
      setTimeout(() => {
        if (res.destroyed) return
        res.write(chunk({ tool_calls: [{ index: 0, function: { arguments: JSON.stringify(calls.read[1]) } }] }))
        res.write(chunk({}, "tool_calls"))
        res.end("data: [DONE]\n\n")
      }, SILENCE_MS)
      return
    }
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
writeFileSync(`${work}/agent/models.json`, JSON.stringify({ providers: { mock: { baseUrl: `http://127.0.0.1:${server.address().port}/v1`, api: "openai-completions", apiKey: "x", models: [{ id: "m", name: "m", input: ["text"], contextWindow: 32768, maxTokens: 8192 }] } } }))

// One Pi process, one prompt per entry: what each prompt's run did, up to agent_settled.
// settles: how many agent_settled to wait for, when a run starts another. linger: how long
// to stay after the last, to see a request that shouldn't come.
const session = (steps, prompts = ["go"], first = [], settings = {}, { settles = prompts.length, linger = 0 } = {}) => new Promise((resolve) => {
  script = steps
  served = 0
  bodies = []
  writeFileSync(`${work}/agent/settings.json`, JSON.stringify(settings))
  const pi = spawn("pi", ["--mode", "rpc", "--no-session", "--no-extensions", ...first.flatMap((e) => ["-e", e]), "-e", `${root}/pi/guard.js`, "-e", `${root}/pi/edit.js`, "--model", "mock/m"], { cwd: proj, env: { ...process.env, PI_CODING_AGENT_DIR: `${work}/agent` }, stdio: ["pipe", "pipe", "ignore"] })
  const runs = []
  const fresh = () => ({ tools: [], notes: [], aborted: null, retries: 0, stops: [] })
  let run = fresh()
  const send = () => pi.stdin.write(JSON.stringify({ type: "prompt", message: prompts[runs.length] }) + "\n")
  // Wait for it to go: a request still in flight would take a step of the next case's script.
  const finish = () => { clearTimeout(timer); pi.once("exit", () => resolve(runs)); pi.kill() }
  // A hang fails by name, not as counts that happen not to match.
  const timer = setTimeout(() => { fails.push(`timed out after 60 s, on the script ${JSON.stringify(steps.slice(0, 6))}`); runs.push(run); finish() }, 60000)
  createInterface({ input: pi.stdout }).on("line", (line) => {
    let e
    try { e = JSON.parse(line) } catch { return }
    if (e.type === "tool_execution_end") run.tools.push({ name: e.toolName, isError: e.isError, text: (e.result?.content || []).map((c) => c.text || "").join("") })
    if (e.type === "auto_retry_start") run.retries++
    if (e.type === "message_end" && e.message?.role === "assistant") run.stops.push(e.message.errorMessage || e.message.stopReason)
    if (e.type === "extension_ui_request" && e.method === "notify") run.notes.push(e.message)
    if (e.type === "agent_settled") {
      run.aborted = e.aborted
      runs.push(run)
      run = fresh()
      if (runs.length < prompts.length) send()
      else if (runs.length >= settles) setTimeout(finish, linger)
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

// The model's own shapes, through Pi's order of events: the repair runs before validation. Repeating newText
// with an empty value used to delete the text and report success, and stray closers used to be refused.
for (const [what, step] of [["a repeated newText", "repeated"], ["stray closers", "closers"]]) {
  writeFileSync(`${proj}/notes.txt`, original)
  const [e] = await session([step, "text"])
  expect(`${what} failed`, e.tools.length === 1 && !e.tools[0].isError && e.tools[0].text.startsWith("Successfully"), e.tools)
  expect(`${what} did not write the first text`, readFileSync(`${proj}/notes.txt`, "utf8") === "bye\n", readFileSync(`${proj}/notes.txt`, "utf8"))
}
writeFileSync(`${proj}/notes.txt`, original)

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

// The same write again: the first goes through, and each one after it changes nothing. The reads
// keep them from being three in a row, which the breaker would answer first. The third refusal stops.
;[r] = await session(["write", "write", "read", "write", "read", "write", "text"])
expect("the no-op write loop did not make 6 calls", r.tools.length === 6 && r.aborted === false, { calls: r.tools.length, aborted: r.aborted })
expect("the first write did not run", r.tools[0]?.text.startsWith("Successfully wrote") && !r.tools[0].isError, r.tools[0])
expect("the wrong calls were refused", r.tools.map((t) => (refused(t) ? "x" : ".")).join("") === ".x.x.x", r.tools.map((t) => t.text.slice(0, 40)))
expect("a no-op write's refusal was not a tool error", [1, 3, 5].every((i) => r.tools[i]?.isError && r.tools[i].text.includes("changes nothing")), r.tools[1])
expect("only the third refusal ended the run", !r.tools[3]?.text.includes("This run stops here.") && r.tools[5]?.text.includes("This run stops here."), r.tools.map((t) => t.text.slice(-30)))
expect("the model was not sent the refusal", String(bodies[2]?.messages.at(-1)?.content).startsWith("dev-guard refuses:"), bodies[2]?.messages.at(-1))
expect("a request followed the stop", bodies.length === 6, bodies.length)
expect("the writes left the wrong content", readFileSync(`${proj}/written.txt`, "utf8") === "let x = 3;\n", "changed")

// Another extension refusing first: Pi stops at the first handler that blocks, so the guard's hook never runs,
// as with a pi/commands.js step-gate refusal. It counts like a rejected call: repeating it is a loop too.
const blocker = `${work}/blocker.mjs`
writeFileSync(blocker, 'export default (pi) => pi.on("tool_call", () => ({ block: true, reason: "the gate refuses" }))\n')
;[r] = await session(["read"], ["go"], [blocker])
expect("another extension's refusal, repeated, did not stop on the 5th", r.tools.length === 5 && r.aborted === true, { calls: r.tools.length, aborted: r.aborted })
expect("those refusals were not the other extension's", r.tools.every((t) => t.text === "the gate refuses"), r.tools[0])
expect("that stop did not tell the user", r.notes.some((n) => n.includes("This run stops here.")), r.notes)

// A dropped stream keeps the count. A new prompt clears it.
let second
;[r, second] = await session(["read", "read", "read", "read", "drop", "read", "read", "text"], ["go", "try again"])
expect("no retry happened", r.retries === 1, r.retries)
expect("the count did not survive a retry", r.tools.length === 5 && refused(r.tools[4]) && r.tools[4].text.includes("This run stops here."), r.tools.map((t) => t.isError))
expect("a new prompt did not start clean", second?.tools.length === 1 && !second.tools[0].isError, second?.tools)

// Silence past the idle timeout: the call is lost as `terminated`, and Pi retries.
;[r] = await session(["silent", "text"], ["go"], [], { httpIdleTimeoutMs: 1000 })
expect("silence past the timeout was not `terminated`", r.stops[0] === "terminated", r.stops)
expect("that drop was not retried", r.retries === 1 && r.tools.length === 0 && r.stops[1] === "stop", { retries: r.retries, tools: r.tools.length, stops: r.stops })

// The same silence under a longer timeout: the call arrives and runs.
;[r] = await session(["silent", "text"], ["go"], [], { httpIdleTimeoutMs: 10000 })
expect("silence under the timeout did not deliver the call", r.retries === 0 && r.stops[0] === "toolUse" && r.tools.length === 1 && !r.tools[0].isError && r.tools[0].text === original, { retries: r.retries, stops: r.stops, tools: r.tools })

// Cut off at the output limit: not run, not retried, and the model is told. The run goes on.
;[r] = await session(["cut", "text"])
expect("a call cut off at the limit was not refused", r.tools.length === 1 && r.tools[0].isError && r.tools[0].text.includes("Re-issue the tool call"), r.tools)
expect("the run did not go on after the cut", r.retries === 0 && r.stops[0] === "length" && r.stops[1] === "stop" && r.aborted === false, { retries: r.retries, stops: r.stops, aborted: r.aborted })

// The warning with what Pi really hands an extension: its model, with baseUrl, and its settings.
const commandsExt = `${root}/pi/commands.js`
;[r] = await session(["text"], ["/dev-init"], [commandsExt])
expect("a /dev-* command on a local model with Pi's default was not warned", r.notes.some((n) => n.includes("httpIdleTimeoutMs") && n.includes("300 s")), r.notes)
expect("the warned command did not run", r.stops[0] === "stop", r.stops)
;[r] = await session(["text"], ["/dev-init"], [commandsExt], { httpIdleTimeoutMs: 1200000 })
expect("a /dev-* command at the limit was warned", !r.notes.some((n) => n.includes("httpIdleTimeoutMs")), r.notes)
expect("the command at the limit did not run", r.stops[0] === "stop", r.stops)

// A runaway during a command: stopped, and the nudge goes out with a clean context.
const nudge = "Your last reply started repeating itself"
const inRequest = (body, text) => JSON.stringify(body.messages).includes(text)
let runs = await session(["repeat", "text"], ["/dev-init"], [commandsExt], { httpIdleTimeoutMs: 1200000 }, { settles: 2 })
expect("a runaway was not stopped", runs[0]?.aborted === true && runs[0]?.notes.some((n) => n.includes("repeating")), runs[0])
expect("no nudged request", bodies.length === 2 && bodies[1].messages.at(-1).role === "user" && inRequest({ messages: [bodies[1].messages.at(-1)] }, nudge), bodies.length)
expect("the repeated text reached the next request", !inRequest(bodies[1] ?? { messages: [] }, REPEATED.trim()), "repeated text in the request")
expect("the nudged run did not finish", runs[1]?.aborted === false && runs[1]?.stops[0] === "stop", runs[1])

// Always repeating: three requests, the third stop ends it, and nothing follows.
runs = await session(["repeat"], ["/dev-init"], [commandsExt], { httpIdleTimeoutMs: 1200000 }, { settles: 3, linger: 500 })
expect("a run that keeps repeating did not stop after 3", bodies.length === 3 && runs.at(-1)?.notes.some((n) => n.includes("This run stops here.")), { requests: bodies.length, notes: runs.at(-1)?.notes })

// The person's own prompt: not stopped, and it runs to the limit as before.
;[r] = await session(["repeat"], ["go"], [commandsExt], { httpIdleTimeoutMs: 1200000 }, { linger: 200 })
expect("the person's own prompt was stopped", bodies.length === 1 && r.aborted === false && r.stops[0] === "length" && !r.notes.some((n) => n.includes("repeating")), { requests: bodies.length, r })

// A cut-off during a command: the model is asked for a smaller change, and every later
// request has the lower limit. The session's own record keeps Pi's text.
const limitOf = (body) => body?.max_completion_tokens ?? body?.max_tokens
const piAsks = "Re-issue the tool call"
const smaller = "Make a smaller change"
const toolTexts = (body) => (body?.messages ?? []).filter((m) => m.role === "tool").map((m) => JSON.stringify(m.content))
const fullLimit = JSON.parse(readFileSync(`${work}/agent/models.json`, "utf8")).providers.mock.models[0].maxTokens
;[r] = await session(["read", "cut", "read", "text"], ["/dev-init"], [commandsExt], { httpIdleTimeoutMs: 1200000 })
expect("the requests before a cut-off did not keep the limit", limitOf(bodies[0]) === fullLimit && limitOf(bodies[1]) === fullLimit, bodies.map(limitOf))
expect("the request after a cut-off did not have the lower limit", limitOf(bodies[2]) === 4096, bodies.map(limitOf))
expect("a later request did not keep the lower limit", limitOf(bodies[3]) === 4096, bodies.map(limitOf))
expect("the model was still told to re-issue", !toolTexts(bodies[2]).some((t) => t.includes(piAsks)) && !toolTexts(bodies[3]).some((t) => t.includes(piAsks)), toolTexts(bodies[3]))
expect("the model was not asked for a smaller change", toolTexts(bodies[2]).some((t) => t.includes(smaller)), toolTexts(bodies[2]))
expect("the other call's result changed", toolTexts(bodies[2]).filter((t) => t.includes(smaller)).length === 1, toolTexts(bodies[2]))
expect("the session's record of the result changed", r.tools[1]?.isError === true && r.tools[1].text.includes(piAsks), r.tools[1])

// The person's own prompt: Pi's text and the full limit, as before.
;[r] = await session(["cut", "text"], ["go"], [commandsExt], { httpIdleTimeoutMs: 1200000 })
expect("the person's own prompt lost the limit", limitOf(bodies[1]) === fullLimit, bodies.map(limitOf))
expect("the person's own prompt lost Pi's text", toolTexts(bodies[1]).some((t) => t.includes(piAsks)), toolTexts(bodies[1]))

// A stuck step: the 5th failing test run carries the offer, once, and test-open.sh waits for it.
const offer = "This step's tests have now failed"
for (const i of [1, 2, 3, 4, 5, 6]) calls[`failing${i}`] = ["bash", { command: `printf 'run ${i}\\nTests  1 failed | 1 passed\\n'; exit 1` }]
calls.opener = ["bash", { command: 'bash "$DEV_SKILLS_LIB/test-open.sh"' }]
const git = (...args) => execFileSync("git", args, { cwd: proj, stdio: "ignore" })
git("init", "-q", "-b", "main")
git("config", "user.email", "t@example.com")
git("config", "user.name", "t")
mkdirSync(`${proj}/.tasks`, { recursive: true })
writeFileSync(`${proj}/.tasks/t.md`, "# A task\n\n## Acceptance criteria\n- [ ] it works\n\n## Steps\n1. [ ] Do it\n   - Create: a.txt\n   - Modify: none\n   - Test: none\n")
writeFileSync(`${proj}/.gitignore`, ".tasks/\n.devskills/\n.pi/\n")
git("add", ".")
git("commit", "-qm", "base")
;[r] = await session(["opener", "failing1", "failing2", "failing3", "failing4", "failing5", "opener", "failing6", "text"], ["/dev-implement .tasks/t.md"], [commandsExt], { httpIdleTimeoutMs: 1200000 })
expect("the step did not run", r.tools.length === 8, r.tools)
expect("test-open.sh was not refused before the 5th", refused(r.tools[0] ?? { text: "" }), r.tools[0])
const toolMessages = (bodies.at(-1)?.messages ?? []).filter((m) => m.role === "tool").map((m) => JSON.stringify(m.content))
expect("the model did not get every tool result", toolMessages.length === 8, toolMessages.length)
expect("the offer is on the wrong result", toolMessages.map((m) => m.includes(offer)).join() === "false,false,false,false,false,true,false,false", toolMessages.map((m) => m.includes(offer)))
expect("the result lost its own text beside the offer", toolMessages[5]?.includes("run 5") && toolMessages[5]?.includes("1 failed"), toolMessages[5])
expect("test-open.sh was refused on and after the 5th", !refused(r.tools[6] ?? { text: "dev-guard refuses:" }) && r.tools[6]?.text.startsWith("OPEN REFUSED"), r.tools[6])

server.close()
for (const f of fails) console.log(`FAIL  ${f}`)
process.exit(fails.length ? 1 : 0)
JS

if node "$work/run.mjs" "$root" "$work"; then
  printf 'live-loop: real Pi stops every loop it should and no other run, and a silent call follows the idle timeout, and a runaway reply is stopped and nudged\n'
  exit 0
fi
printf 'live-loop: case(s) failed\n' >&2
exit 1
