#!/usr/bin/env bash
# The bench's replay tool against a mock provider — run it from anywhere:
#
#   bash evals/bench/replay.sh
#
# bench/space-city/replay.mjs resends one logged reply's request to a model. The
# tool itself is manual and needs a model; this suite needs neither. A log it
# writes itself and a mock that records every request show what the tool lists,
# what it sends, what it records of the answer, and when it sends nothing.
#
# Where Pi is installed it also runs real Pi against the mock and replays every reply
# of that run: each request, whole body, has to equal the one Pi sent. That part skips
# where Pi isn't installed, which includes CI.
#
# Exits 0 when every case holds, 1 otherwise, naming each failure.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
command -v node >/dev/null 2>&1 || { printf 'replay: node is required — not installed\n' >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

cat > "$work/run.mjs" <<'JS'
import { execFile, execFileSync, spawn } from "node:child_process"
import { createServer } from "node:http"
import { createInterface } from "node:readline"
import { chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs"
const [root, work] = process.argv.slice(2)
const tool = `${root}/bench/space-city/replay.mjs`
const fails = []
const expect = (name, ok, got) => { if (!ok) fails.push(`${name}: ${JSON.stringify(got)}`) }

// The mock provider: records every request, and answers each as the current script says.
let requests = []
let answer = null
const chunk = (delta, finish = null) => `data: ${JSON.stringify({ id: "c", object: "chat.completion.chunk", created: 1, model: "m", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`
const server = createServer((req, res) => {
  let body = ""
  req.on("data", (d) => { body += d })
  req.on("end", () => {
    requests.push({ url: req.url, body: JSON.parse(body) })
    if (answer) return answer(res)
    res.writeHead(200, { "content-type": "text/event-stream" })
    res.write(chunk({ role: "assistant", content: "done" }))
    res.write(chunk({}, "stop"))
    res.end("data: [DONE]\n\n")
  })
})
await new Promise((r) => server.listen(0, "127.0.0.1", r))
const baseUrl = `http://127.0.0.1:${server.address().port}/v1`

// Pi's directory: one model, with the settings the tool must copy into the request.
const agent = `${work}/agent`
mkdirSync(agent)
const model = { id: "m", name: "m", input: ["text"], contextWindow: 32768, maxTokens: 1024, samplingParams: { temperature: 0, reasoning_effort: "none" } }
const models = (extra = {}) => ({ providers: { mock: { baseUrl, api: "openai-completions", apiKey: "x", models: [{ ...model, ...extra }] } } })
const setModels = (m) => writeFileSync(`${agent}/models.json`, JSON.stringify(m))
setModels(models())

const replay = (args, env = {}) => new Promise((resolve) => {
  execFile("node", [tool, ...args], { env: { ...process.env, PI_CODING_AGENT_DIR: agent, ...env } }, (err, stdout, stderr) => {
    resolve({ code: err ? err.code : 0, stdout, stderr })
  })
})

// A log as Pi writes it over RPC: two tool calls, a drop that was retried, a call, then an answer.
const params = { type: "object", properties: { path: { type: "string" } } }
const system = { role: "system", content: "", sections: { preamble: "You help.", tools: "<tools>\n- read\n</tools>", cwd: "<cwd>\n/x\n</cwd>" }, toolsAdded: [{ name: "read", description: "Read a file.", parameters: params, constrainedSampling: { x: 1 } }] }
const said = (content, stopReason, more = {}) => ({ role: "assistant", content, provider: "mock", model: "m", usage: { output: 7 }, stopReason, durationMs: 2500, ...more })
const text = (t) => ({ type: "text", text: t })
const call = (id, path) => ({ type: "toolCall", id, name: "read", arguments: { path } })
const result = (id, t) => ({ role: "toolResult", toolCallId: id, toolName: "read", content: [text(t)], isError: false })
const end = (message) => ({ type: "message_end", message })
const log = (events, name = "step-1.jsonl") => {
  const file = `${work}/${name}`
  writeFileSync(file, events.map((e) => JSON.stringify(e)).join("\n") + "\n")
  return file
}
const first = said([text("Reading two:\n\n"), call("a1", "x"), call("a2", "y")], "toolUse")
const dropped = said([text("Reading ")], "error", { errorMessage: "terminated", durationMs: 308000 })
const retried = said([call("a3", "z")], "toolUse", { usage: { output: 9 } })
const last = said([text("All done.")], "stop")
const events = [
  { type: "response", command: "prompt", success: true },
  { type: "message_start", message: system },
  end(system),
  end({ role: "user", content: [text("go")] }),
  { type: "message_start", message: first },
  end(first),
  end(result("a1", "one")),
  end(result("a2", "two")),
  end(dropped),
  { type: "agent_end", messages: [dropped] },
  { type: "auto_retry_start", attempt: 1, maxAttempts: 3, errorMessage: "terminated" },
  end(retried),
  end(result("a3", "three")),
  end(last),
  { type: "agent_settled", aborted: false },
]
const file = log(events)

// With only a log: every reply, numbered, and nothing sent.
requests = []
let r = await replay([file])
expect("the list failed", r.code === 0, r)
const rows = r.stdout.trim().split("\n").slice(1)
expect("the list does not have every reply", rows.length === 4, r.stdout)
expect("reply 1's row", /^1\s+toolUse\s+2\.5\s+7\s+read,read/.test(rows[0] ?? ""), rows[0])
expect("the dropped reply's row", /^2\s+error\s+308\.0\s+7\s+-\s+terminated/.test(rows[1] ?? ""), rows[1])
expect("reply 3's row", /^3\s+toolUse\s+2\.5\s+9\s+read/.test(rows[2] ?? ""), rows[2])
expect("reply 4's row", /^4\s+stop\s+2\.5\s+7\s+-/.test(rows[3] ?? ""), rows[3])
expect("the list sent a request", requests.length === 0, requests.length)

// What the first reply's request holds: the prompt, the tools and the model's settings.
const sent = async (args) => {
  requests = []
  const out = await replay(args)
  expect(`${args.join(" ")} failed`, out.code === 0, out)
  expect(`${args.join(" ")} did not send one request`, requests.length === 1, requests.length)
  return requests[0]?.body ?? {}
}
let b = await sent([file, "1"])
expect("the path it posts to", requests[0]?.url === "/v1/chat/completions", requests[0]?.url)
expect("the request's fields and their order", JSON.stringify(Object.keys(b)) === JSON.stringify(["model", "messages", "stream", "stream_options", "store", "max_completion_tokens", "tools", "temperature", "reasoning_effort"]), Object.keys(b))
expect("the model's settings", b.model === "m" && b.max_completion_tokens === 1024 && b.temperature === 0 && b.reasoning_effort === "none" && b.stream === true && b.store === false && b.stream_options?.include_usage === true, b)
expect("the system prompt is not the sections, joined", b.messages?.[0]?.role === "system" && b.messages[0].content === "You help.\n\n<tools>\n- read\n</tools>\n\n<cwd>\n/x\n</cwd>", b.messages?.[0])
expect("the tools", JSON.stringify(b.tools) === JSON.stringify([{ type: "function", function: { name: "read", description: "Read a file.", parameters: params } }]), b.tools)
expect("reply 1 did not see only the prompt", JSON.stringify(b.messages?.slice(1)) === JSON.stringify([{ role: "user", content: [text("go")] }]), b.messages?.slice(1))

// The dropped reply sees what reply 1 led to, and it keeps two calls in one message.
const two = { role: "assistant", content: "Reading two:\n\n", tool_calls: [{ id: "a1", type: "function", function: { name: "read", arguments: '{"path":"x"}' } }, { id: "a2", type: "function", function: { name: "read", arguments: '{"path":"y"}' } }] }
const results = [{ role: "tool", content: "one", tool_call_id: "a1" }, { role: "tool", content: "two", tool_call_id: "a2" }]
b = await sent([file, "2"])
expect("reply 2's context", JSON.stringify(b.messages?.slice(2)) === JSON.stringify([two, ...results]), b.messages?.slice(2))

// A retry is the same request again: the dropped reply isn't in what follows it.
b = await sent([file, "3"])
expect("reply 3 kept the dropped reply", JSON.stringify(b.messages?.slice(2)) === JSON.stringify([two, ...results]), b.messages?.slice(2))
b = await sent([file, "4"])
const noText = { role: "assistant", content: null, tool_calls: [{ id: "a3", type: "function", function: { name: "read", arguments: '{"path":"z"}' } }] }
expect("reply 4's context", JSON.stringify(b.messages?.slice(2)) === JSON.stringify([two, ...results, noText, { role: "tool", content: "three", tool_call_id: "a3" }]), b.messages?.slice(2))

// --set overrides a field or adds one, and nothing else changes.
const plain = await sent([file, "1"])
b = await sent([file, "1", "--set", '{"temperature":0.2,"frequency_penalty":0.5}'])
expect("--set did not change the fields", b.temperature === 0.2 && b.frequency_penalty === 0.5, b)
const { temperature: _a, frequency_penalty: _b, ...rest } = b
const { temperature: _c, ...restPlain } = plain
expect("--set changed something else", JSON.stringify(rest) === JSON.stringify(restPlain), rest)

// Every refusal says why, and sends nothing. A different request answers a different question.
const refuses = async (name, args, needle) => {
  requests = []
  const out = await replay(args)
  expect(`${name}: not refused`, out.code === 1, out)
  expect(`${name}: does not say why`, out.stderr.includes(needle), out.stderr)
  expect(`${name}: sent a request`, requests.length === 0, requests.length)
}
await refuses("no arguments", [], "usage")
await refuses("a log that isn't there", [`${work}/nope.jsonl`], "nope.jsonl")
await refuses("reply 0", [file, "0"], "no reply 0")
await refuses("a reply past the end", [file, "5"], "no reply 5")
await refuses("a reply that isn't a number", [file, "two"], "usage")
await refuses("an unknown flag", [file, "1", "--nope"], "usage")
await refuses("--set with no value", [file, "1", "--set"], "usage")
await refuses("--set with bad JSON", [file, "1", "--set", "{"], "--set")
await refuses("--set with a list", [file, "1", "--set", "[1]"], "--set")
await refuses("--set with null", [file, "1", "--set", "null"], "--set")
await refuses("--set on a list of replies", [file, "--set", "{}"], "usage")
await refuses("a log with no system message", [log(events.filter((e) => e.message?.role !== "system"), "no-system.jsonl"), "1"], "system")
await refuses("a system message with no sections", [log(events.map((e) => e.message?.role === "system" ? { ...e, message: { ...system, sections: {} } } : e), "no-sections.jsonl"), "1"], "sections")
await refuses("a tool list missing", [log(events.map((e) => e.message?.role === "system" ? { ...e, message: { ...system, toolsAdded: undefined } } : e), "no-tools.jsonl"), "1"], "tool")
const image = { type: "image", data: "x", mimeType: "image/png" }
await refuses("an image from the user", [log(events.map((e) => e.message?.role === "user" ? end({ role: "user", content: [text("go"), image] }) : e), "image.jsonl"), "1"], "image")
await refuses("an image in a tool result", [log(events.map((e) => e.message?.toolCallId === "a1" ? end({ ...result("a1", "one"), content: [image] }) : e), "tool-image.jsonl"), "2"], "image")
await refuses("thinking in a reply", [log(events.map((e) => e.message === first ? end({ ...first, content: [{ type: "thinking", thinking: "hm" }, ...first.content] }) : e), "thinking.jsonl"), "2"], "thinking")
await refuses("a role it doesn't know", [log([...events.slice(0, 4), end({ role: "compactionSummary", summary: "x" }), ...events.slice(4)], "role.jsonl"), "1"], "compactionSummary")
await refuses("an error left in the context", [log(events.filter((e) => e.type !== "auto_retry_start"), "unretried.jsonl"), "3"], "error")
setModels({ providers: {} })
await refuses("a provider not in models.json", [file, "1"], "mock")
setModels(models({ id: "other" }))
await refuses("a model not in models.json", [file, "1"], "m")
setModels(models({ maxTokens: undefined }))
await refuses("a model with no maxTokens", [file, "1"], "maxTokens")
setModels(models({ compat: { maxTokensField: "max_tokens" } }))
await refuses("a model that changes the request's shape", [file, "1"], "compat")
setModels({ providers: { mock: { baseUrl: "https://example.invalid/v1", models: [model] } } })
await refuses("a server that isn't plain http", [file, "1"], "http")
setModels(models())

// What comes back. Each case: what the mock answers, then the JSON line and the files.
const stream = (res) => res.writeHead(200, { "content-type": "text/event-stream" })
const finished = (res, finish, tokens = 11) => {
  res.write(chunk({}, finish))
  res.write(`data: ${JSON.stringify({ id: "c", object: "chat.completion.chunk", choices: [], usage: { completion_tokens: tokens } })}\n\n`)
  res.end("data: [DONE]\n\n")
}
const runReplay = async (args, env) => {
  rmSync(`${work}/replays`, { recursive: true, force: true })
  const out = await replay(args, env)
  let line = {}
  try { line = JSON.parse(out.stdout) } catch {}
  const dirs = existsSync(`${work}/replays`) ? readdirSync(`${work}/replays`) : []
  return { ...out, line, dir: dirs[0] && `${work}/replays/${dirs[0]}`, dirs }
}
const read = (dir, name) => readFileSync(`${dir}/${name}`, "utf8")

// A tool call's name, a silence, its arguments in two pieces: LM Studio's shape, with the silence measured.
answer = (res) => {
  stream(res)
  res.write(chunk({ role: "assistant", content: "Reading ", tool_calls: [{ index: 0, id: "c1", type: "function", function: { name: "read", arguments: "" } }] }))
  setTimeout(() => {
    res.write(chunk({ tool_calls: [{ index: 0, function: { arguments: '{"path":' } }] }))
    res.write(chunk({ tool_calls: [{ index: 0, function: { arguments: '"x"}' } }] }))
    finished(res, "tool_calls")
  }, 1500)
}
r = await runReplay([file, "1"])
expect("a tool call: not exit 0", r.code === 0, r)
expect("a tool call: the line", r.line.finish === "tool_calls" && r.line.tool === "read" && r.line.tokens === 11 && r.line.textChars === 8 && r.line.argsChars === 12 && r.line.argsValidJson === true, r.line)
expect("a tool call: the silence", r.line.longestSilenceSeconds >= 1.3 && r.line.longestSilenceSeconds < 5 && r.line.firstByteSeconds < 1.3 && r.line.seconds >= 1.3, r.line)
expect("a tool call: the directory", r.dirs.length === 1 && /^step-1-1-\d{8}-\d{6}$/.test(r.dirs[0]) && r.line.dir === r.dir, { dirs: r.dirs, line: r.line.dir })
expect("a tool call: request.json is not what was sent", JSON.stringify(JSON.parse(read(r.dir, "request.json"))) === JSON.stringify(requests.at(-1).body), "differs")
expect("a tool call: the files", read(r.dir, "text.txt") === "Reading " && read(r.dir, "args.txt") === '{"path":"x"}\n', { text: read(r.dir, "text.txt"), args: read(r.dir, "args.txt") })
expect("a tool call: stream.log has no times", /^\d+ data: /.test(read(r.dir, "stream.log")), read(r.dir, "stream.log").slice(0, 60))

// Two calls in one reply, each with its own arguments, and one of them cut short.
answer = (res) => {
  stream(res)
  res.write(chunk({ role: "assistant", tool_calls: [{ index: 0, id: "c1", type: "function", function: { name: "read", arguments: '{"path":"x"}' } }, { index: 1, id: "c2", type: "function", function: { name: "bash", arguments: '{"comm' } }] }))
  finished(res, "tool_calls")
}
r = await runReplay([file, "1"])
expect("two calls: the line", r.line.tool === "read,bash" && r.line.argsValidJson === false && r.line.argsChars === 18, r.line)
expect("two calls: args.txt", read(r.dir, "args.txt") === '{"path":"x"}\n{"comm\n', read(r.dir, "args.txt"))
expect("no text where the log had some counted as the same start", r.line.sameStartAsLog === false, r.line)

// A reply that repeats itself: the lines show it, escaped newlines in arguments counted too.
answer = (res) => {
  stream(res)
  res.write(chunk({ role: "assistant", content: "Other\n\nsame\nsame\nsame", tool_calls: [{ index: 0, id: "c1", type: "function", function: { name: "read", arguments: JSON.stringify({ path: "a\nb\nb" }) } }] }))
  finished(res, "length", 1024)
}
r = await runReplay([file, "1"])
expect("repeats: the line", r.line.finish === "length" && r.line.tokens === 1024 && r.line.lines === 8 && r.line.distinctLines === 6, r.line)
expect("the same start as the log was not seen", r.line.sameStartAsLog === false, r.line)
answer = (res) => {
  stream(res)
  res.write(chunk({ role: "assistant", content: "Reading two:\n\n and more" }))
  finished(res, "stop")
}
r = await runReplay([file, "1"])
expect("the same start as the log", r.line.sameStartAsLog === true && r.line.tool === "-" && r.line.argsValidJson === null && r.line.argsChars === 0, r.line)

// A character split across two network chunks is still one character, and its event still parses.
answer = (res) => {
  stream(res)
  const bytes = Buffer.from(chunk({ role: "assistant", content: "a — b" }))
  const middle = bytes.indexOf(Buffer.from("—")) + 1
  res.write(bytes.subarray(0, middle))
  setTimeout(() => {
    res.write(bytes.subarray(middle))
    finished(res, "stop")
  }, 100)
}
r = await runReplay([file, "1"])
expect("a split character was corrupted", read(r.dir, "text.txt") === "a — b" && r.line.textChars === 5, read(r.dir, "text.txt"))
expect("stream.log corrupted a split character", !read(r.dir, "stream.log").includes("\uFFFD"), read(r.dir, "stream.log").slice(0, 200))

// Its own limit, not undici's: a silence past --limit exits 2 and keeps what came.
answer = (res) => {
  stream(res)
  res.write(chunk({ role: "assistant", content: "Reading " }))
}
r = await runReplay([file, "1", "--limit", "1"])
expect("the limit: not exit 2", r.code === 2 && r.line.finish === "limit" && r.line.textChars === 8, r)
expect("the limit: the files", read(r.dir, "text.txt") === "Reading ", "no text.txt")
expect("the tool uses fetch, with undici's 300 s body timeout", !readFileSync(tool, "utf8").match(/\bfetch\(/), "fetch(")
await refuses("--limit with no value", [file, "1", "--limit"], "usage")
await refuses("--limit that isn't a number", [file, "1", "--limit", "soon"], "usage")
await refuses("--limit of nothing", [file, "1", "--limit", "0"], "usage")

// The stream ending without a finish reason: it was cut, and says so.
answer = (res) => {
  stream(res)
  res.write(chunk({ role: "assistant", content: "Reading " }))
  setTimeout(() => res.destroy(), 50)
}
r = await runReplay([file, "1"])
expect("a dropped stream: not exit 1", r.code === 1 && r.line.finish === "dropped" && r.stderr.includes("before it finished"), r)

// Dropped after the headers, before any chunk: still a dropped stream, not a failed request.
answer = (res) => {
  stream(res)
  res.flushHeaders()
  setTimeout(() => res.destroy(), 50)
}
r = await runReplay([file, "1"])
expect("dropped before the first chunk: not reported as dropped", r.code === 1 && r.line.finish === "dropped" && r.line.firstByteSeconds === null, r)

// The server saying no: exit 1, and it says what.
answer = (res) => { res.writeHead(500, { "content-type": "application/json" }); res.end('{"error":"no model loaded"}') }
r = await runReplay([file, "1"])
expect("a 500: not exit 1 with the reason", r.code === 1 && r.stderr.includes("500") && r.stderr.includes("no model loaded"), r)
answer = (res) => { res.writeHead(500, { "content-type": "text/plain" }); res.write("out of memory"); setTimeout(() => res.destroy(), 50) }
r = await runReplay([file, "1", "--limit", "5"])
expect("a 500 that drops: waited for the limit", r.code === 1 && r.stderr.includes("500") && r.stderr.includes("out of memory"), r)
answer = (res) => { stream(res); res.write(`data: ${JSON.stringify({ error: { message: "context is full" } })}\n\n`); res.end() }
r = await runReplay([file, "1"])
expect("an error in the stream: not exit 1 with the reason", r.code === 1 && r.stderr.includes("context is full"), r)
answer = null
setModels({ providers: { mock: { baseUrl: "http://127.0.0.1:9/v1", models: [model] } } })
r = await runReplay([file, "1"])
expect("a closed port: not exit 1", r.code === 1 && r.stderr.includes("request failed"), r)

// On LM Studio it checks the model is loaded at its window, as run.sh does.
const lmHome = `${work}/home`
mkdirSync(`${lmHome}/.lmstudio/bin`, { recursive: true })
const lms = `${lmHome}/.lmstudio/bin/lms`
const fakeLms = (line) => { writeFileSync(lms, `#!/bin/sh\nprintf '%s\\n' 'IDENTIFIER MODEL STATUS' '${line}'\n`); chmodSync(lms, 0o755) }
const lmEvents = events.map((e) => (e.message?.provider ? { ...e, message: { ...e.message, provider: "lmstudio" } } : e))
const lmFile = log(lmEvents, "lm.jsonl")
setModels({ providers: { lmstudio: { baseUrl, models: [model] } } })
const home = { HOME: lmHome }
fakeLms("m m IDLE 8.52 GB 32768 4 Local")
requests = []
r = await replay([lmFile, "1"], home)
expect("loaded at the window: not sent", r.code === 0 && requests.length === 1, r)
fakeLms("m m IDLE 8.52 GB 4096 4 Local")
requests = []
r = await replay([lmFile, "1"], home)
expect("loaded at another window: not refused", r.code === 1 && requests.length === 0 && r.stderr.includes("lms load"), r)
fakeLms("other other IDLE 8.52 GB 32768 4 Local")
requests = []
r = await replay([lmFile, "1"], home)
expect("not loaded: not refused", r.code === 1 && requests.length === 0, r)
rmSync(lms)
requests = []
r = await replay([lmFile, "1"], home)
expect("no lms: not sent with a warning", r.code === 0 && requests.length === 1 && r.stderr.includes("not checked"), r)
setModels(models())

// The same request as real Pi: a run with two calls in a reply, a failed call, a call with
// no text, a dropped stream and its retry, a call cut off at the limit, and an answer.
let hasPi = true
try { execFileSync("pi", ["--version"], { stdio: "ignore" }) } catch { hasPi = false }
if (!hasPi) console.log("replay: Pi is not installed; the comparison with real Pi is skipped")
else {
  const proj = `${work}/proj`
  mkdirSync(proj)
  writeFileSync(`${proj}/notes.txt`, "hello\n")
  writeFileSync(`${agent}/settings.json`, JSON.stringify({ retry: { baseDelayMs: 50 } }))
  const named = (index, id, name, args) => ({ index, id, type: "function", function: { name, arguments: args } })
  const script = [
    (res) => { stream(res); res.write(chunk({ role: "assistant", content: "Reading two:\n\n", tool_calls: [named(0, "p1", "read", '{"path":"notes.txt"}'), named(1, "p2", "read", '{"path":"nope.txt"}')] })); finished(res, "tool_calls") },
    (res) => { stream(res); res.write(chunk({ role: "assistant", tool_calls: [named(0, "p3", "bash", '{"command":"echo hi"}')] })); finished(res, "tool_calls") },
    (res) => { stream(res); res.write(chunk({ role: "assistant", content: "partial " })); setTimeout(() => res.destroy(), 50) },
    (res) => { stream(res); res.write(chunk({ role: "assistant", content: "Cut: ", tool_calls: [named(0, "p4", "read", "")] })); finished(res, "length") },
    (res) => { stream(res); res.write(chunk({ role: "assistant", content: "done" })); finished(res, "stop") },
  ]
  let at = 0
  answer = (res) => script[Math.min(at++, script.length - 1)](res)
  requests = []
  const lines = []
  await new Promise((resolve) => {
    const pi = spawn("pi", ["--mode", "rpc", "--no-session", "--no-extensions", "--model", "mock/m"], { cwd: proj, env: { ...process.env, PI_CODING_AGENT_DIR: agent }, stdio: ["pipe", "pipe", "ignore"] })
    const timer = setTimeout(() => { fails.push("real Pi: timed out after 60 s"); pi.kill() }, 60000)
    pi.once("exit", () => { clearTimeout(timer); resolve() })
    createInterface({ input: pi.stdout }).on("line", (line) => {
      lines.push(line)
      try { if (JSON.parse(line).type === "agent_settled") pi.kill() } catch {}
    })
    pi.stdin.write(JSON.stringify({ type: "prompt", message: "go" }) + "\n")
  })
  const piSent = requests.map((q) => q.body)
  expect("real Pi did not play the whole script", piSent.length === script.length, piSent.length)
  const piLog = `${work}/pi-step.jsonl`
  writeFileSync(piLog, lines.join("\n") + "\n")
  answer = null
  for (const [i, body] of piSent.entries()) {
    requests = []
    const out = await replay([piLog, String(i + 1)])
    expect(`real Pi, reply ${i + 1}: the replay failed`, out.code === 0, out)
    const mine = requests[0]?.body
    if (JSON.stringify(mine) !== JSON.stringify(body)) {
      const fields = [...new Set([...Object.keys(body), ...Object.keys(mine ?? {})])].filter((k) => JSON.stringify(body[k]) !== JSON.stringify(mine?.[k]))
      const at = (body.messages ?? []).findIndex((m, n) => JSON.stringify(m) !== JSON.stringify(mine?.messages?.[n]))
      fails.push(`real Pi, reply ${i + 1}: differs in ${fields.join(",") || "field order"}${at >= 0 ? `; message ${at}: Pi ${JSON.stringify(body.messages[at])} replay ${JSON.stringify(mine?.messages?.[at])}` : ""}`)
    }
  }
}

server.close()
for (const f of fails) console.log(`FAIL  ${f}`)
process.exit(fails.length ? 1 : 0)
JS

fails=0
node "$work/run.mjs" "$root" "$work" || fails=1

# score.sh reads a run's step logs by name at the top of its directory, so a replay's
# files under replays/ can't change a row.
grep -qF '/^step-\d+(-retry\d+)?\.jsonl$/' "$root/bench/space-city/score.sh" || {
  printf 'FAIL  score.sh no longer reads only the step logs by name\n'
  fails=1
}

if [ "$fails" -eq 0 ]; then
  printf 'replay: every reply is listed, its request is rebuilt from the log, its answer is recorded, and a refusal sends nothing\n'
  exit 0
fi
printf 'replay: case(s) failed\n' >&2
exit 1
