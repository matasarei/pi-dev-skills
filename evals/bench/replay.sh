#!/usr/bin/env bash
# The bench's replay tool against a mock provider — run it from anywhere:
#
#   bash evals/bench/replay.sh
#
# bench/space-city/replay.mjs resends one logged reply's request to a model. The
# tool itself is manual and needs a model; this suite needs neither. A log it
# writes itself and a mock that records every request show what the tool lists,
# what it sends, and when it sends nothing.
#
# Exits 0 when every case holds, 1 otherwise, naming each failure.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
command -v node >/dev/null 2>&1 || { printf 'replay: node is required — not installed\n' >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

cat > "$work/run.mjs" <<'JS'
import { execFile } from "node:child_process"
import { createServer } from "node:http"
import { mkdirSync, writeFileSync } from "node:fs"
const [root, work] = process.argv.slice(2)
const tool = `${root}/bench/space-city/replay.mjs`
const fails = []
const expect = (name, ok, got) => { if (!ok) fails.push(`${name}: ${JSON.stringify(got)}`) }

// The mock provider: records every request, and answers each as the current script says.
let requests = []
const chunk = (delta, finish = null) => `data: ${JSON.stringify({ id: "c", object: "chat.completion.chunk", created: 1, model: "m", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`
const server = createServer((req, res) => {
  let body = ""
  req.on("data", (d) => { body += d })
  req.on("end", () => {
    requests.push({ url: req.url, body: JSON.parse(body) })
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

server.close()
for (const f of fails) console.log(`FAIL  ${f}`)
process.exit(fails.length ? 1 : 0)
JS

if node "$work/run.mjs" "$root" "$work"; then
  printf 'replay: every reply is listed, its request is rebuilt from the log, and a refusal sends nothing\n'
  exit 0
fi
printf 'replay: case(s) failed\n' >&2
exit 1
