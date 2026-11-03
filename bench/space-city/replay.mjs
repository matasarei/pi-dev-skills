#!/usr/bin/env node
// Resend one logged reply's request to the model, to see what it does with it.
//
//   node replay.mjs <step-log.jsonl>             lists the log's replies
//   node replay.mjs <step-log.jsonl> <n> [--set '{"temperature":0.2}'] [--limit <seconds>]
//
// A bench run takes an hour or more to reach one long reply. This asks about that
// reply alone. It is a manual tool, never run from evals/run-all.sh: it needs the
// model, and one answer is a sample. The same request has run away on one attempt
// and finished in 26 s on the next.
//
// The request is rebuilt from the log: the system prompt and the tools from the
// system message, the conversation from each message_end before the reply, leaving
// out a reply Pi retried. agent_end doesn't do: after a retry it holds only the new
// messages. What the log lacks, the sampling settings and the server, comes from
// the model's entry in models.json. evals/bench/replay.sh compares the result with
// what real Pi sends. Anything it can't rebuild exactly is refused, not approximated:
// a different request answers a different question.
//
// Prints one JSON line and writes request.json, text.txt, args.txt and stream.log
// (each chunk with its time in ms) to <log dir>/replays/<log>-<n>-<stamp>/. Exits 0
// when the stream finished, 1 on a refusal or an error, 2 at the limit.
//
// It uses node:http, not fetch: fetch has undici's 300 s body timeout, which is what
// cut these replies off in the first place. Its only limit is --limit, default 1200 s.

import { execFileSync } from "node:child_process"
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs"
import { request } from "node:http"
import { homedir } from "node:os"
import { basename, dirname, join } from "node:path"

const refuse = (why) => {
  console.error(`replay: ${why}`)
  process.exit(1)
}
const USAGE = "usage: replay.mjs <step-log.jsonl> [<reply> [--set <json>] [--limit <seconds>]]"

function parseArgs(args) {
  const [log, reply, ...rest] = args
  if (!log || log.startsWith("--")) refuse(USAGE)
  if (reply === undefined) return { log }
  if (!/^\d+$/.test(reply)) refuse(USAGE)
  let set = {}
  let limit = 1200
  for (let i = 0; i < rest.length; i += 2) {
    if (rest[i + 1] === undefined) refuse(USAGE)
    if (rest[i] === "--limit") {
      if (!/^[1-9]\d*$/.test(rest[i + 1])) refuse(USAGE)
      limit = Number(rest[i + 1])
      continue
    }
    if (rest[i] !== "--set") refuse(USAGE)
    let fields
    try { fields = JSON.parse(rest[i + 1]) } catch { refuse(`--set is not JSON: ${rest[i + 1]}`) }
    if (fields === null || typeof fields !== "object" || Array.isArray(fields)) refuse(`--set is not an object: ${rest[i + 1]}`)
    set = { ...set, ...fields }
  }
  return { log, reply: Number(reply), set, limit }
}

// Every assistant reply in the log, with the conversation it was asked in.
function readLog(file) {
  let text
  try { text = readFileSync(file, "utf8") } catch (e) { refuse(`can't read ${file}: ${e.message}`) }
  let system = null
  const context = []
  const replies = []
  for (const line of text.split("\n")) {
    if (!line) continue
    let e
    try { e = JSON.parse(line) } catch { continue } // A run cut off mid-line.
    if (e.type === "message_end") {
      if (e.message.role === "system") system = e.message
      else if (e.message.role === "assistant") {
        replies.push({ message: e.message, context: [...context] })
        context.push(e.message)
      } else context.push(e.message)
    }
    if (e.type === "auto_retry_start" && context.at(-1)?.stopReason === "error") context.pop()
  }
  return { system, replies }
}

const toolNames = (m) => m.content.filter((c) => c.type === "toolCall").map((c) => c.name).join(",") || "-"

function list(replies) {
  const row = (...cells) => console.log(cells.map((c, i) => String(c).padEnd([5, 8, 8, 7, 12, 0][i])).join("  ").trimEnd())
  row("reply", "stop", "seconds", "tokens", "tool", "error")
  replies.forEach(({ message: m }, i) => {
    row(i + 1, m.stopReason, m.durationMs === undefined ? "?" : (m.durationMs / 1000).toFixed(1), m.usage?.output ?? "?", toolNames(m), m.errorMessage ?? "")
  })
}

// One part of a message's content, as text, or a refusal: only text is rebuilt.
function onlyText(parts, whose) {
  for (const p of parts) if (p.type !== "text") refuse(`a ${whose} holds ${p.type}, which this can't rebuild`)
  return parts
}

// A message as Pi puts it on the wire.
function toWire(m) {
  if (m.role === "user") {
    return { role: "user", content: typeof m.content === "string" ? m.content : onlyText(m.content, "user message").map((p) => ({ type: "text", text: p.text })) }
  }
  if (m.role === "toolResult") {
    return { role: "tool", content: onlyText(m.content, "tool result").map((p) => p.text).join("\n"), tool_call_id: m.toolCallId }
  }
  if (m.role === "assistant") {
    if (m.stopReason === "error" || m.stopReason === "aborted") refuse(`the context holds a reply that ended in ${m.stopReason}, and Pi's handling of that isn't rebuilt here`)
    const parts = m.content.filter((c) => c.type !== "toolCall")
    const text = onlyText(parts, "reply").map((p) => p.text).join("")
    const calls = m.content.filter((c) => c.type === "toolCall").map((c) => ({ id: c.id, type: "function", function: { name: c.name, arguments: JSON.stringify(c.arguments) } }))
    return calls.length ? { role: "assistant", content: text || null, tool_calls: calls } : { role: "assistant", content: text || null }
  }
  refuse(`the context holds a ${m.role} message, which this can't rebuild`)
}

function modelEntry(reply) {
  const file = join(process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent"), "models.json")
  let models
  try { models = JSON.parse(readFileSync(file, "utf8")) } catch (e) { refuse(`can't read ${file}: ${e.message}`) }
  const provider = models.providers?.[reply.provider]
  if (!provider) refuse(`no provider ${reply.provider} in ${file}`)
  const model = provider.models?.find((m) => m.id === reply.model)
  if (!model) refuse(`no model ${reply.model} under ${reply.provider} in ${file}`)
  if (!Number.isInteger(model.maxTokens)) refuse(`model ${reply.model} declares no maxTokens in ${file}`)
  if (model.compat || provider.compat) refuse(`model ${reply.model} sets compat in ${file}, which changes the request's shape, and that isn't rebuilt here`)
  if (!String(provider.baseUrl).startsWith("http://")) refuse(`provider ${reply.provider}'s baseUrl is not plain http: ${provider.baseUrl}`)
  return { baseUrl: provider.baseUrl, model }
}

// LM Studio loads a model on demand at its default window, which would quietly be
// another experiment. As in run.sh: loaded at the window, or refused.
function checkLoaded(reply, model) {
  if (reply.provider !== "lmstudio") return
  const lms = join(homedir(), ".lmstudio", "bin", "lms")
  if (!existsSync(lms)) {
    console.error(`replay: no lms CLI, so the loaded window is not checked: make sure it is ${model.contextWindow}`)
    return
  }
  let ps = ""
  try { ps = execFileSync(lms, ["ps"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }) } catch {}
  const loaded = ps.split("\n").some((line) => line.split(/\s+/)[0] === model.id && line.includes(` ${model.contextWindow} `))
  if (!loaded) refuse(`${model.id} is not loaded at ${model.contextWindow} (lms load ${model.id} --context-length ${model.contextWindow} -y)`)
}

function buildRequest(system, { message, context }, model, set) {
  if (!system) refuse("the log has no system message")
  if (!Array.isArray(system.toolsAdded)) refuse("the log's system message has no tool list")
  const prompt = Object.values(system.sections ?? {}).filter(Boolean).join("\n\n")
  if (!prompt) refuse("the log's system message has no sections to rebuild the prompt from")
  return {
    model: message.model,
    messages: [{ role: "system", content: prompt }, ...context.map(toWire)],
    stream: true,
    stream_options: { include_usage: true },
    store: false,
    max_completion_tokens: model.maxTokens,
    tools: system.toolsAdded.map((t) => ({ type: "function", function: { name: t.name, description: t.description, parameters: t.parameters } })),
    ...model.samplingParams,
    ...set,
  }
}

// Local time, as run.sh names its runs.
const stamp = () => {
  const now = new Date()
  const two = (n) => String(n).padStart(2, "0")
  return `${now.getFullYear()}${two(now.getMonth() + 1)}${two(now.getDate())}-${two(now.getHours())}${two(now.getMinutes())}${two(now.getSeconds())}`
}

// Send it, record what comes back and when, say what happened, and exit.
function send(baseUrl, body, { dir, loggedText, limit }) {
  mkdirSync(dir, { recursive: true })
  writeFileSync(join(dir, "request.json"), JSON.stringify(body))
  writeFileSync(join(dir, "stream.log"), "")
  const start = Date.now()
  let firstByte = null
  let lastByte = null
  let longest = 0
  let text = ""
  let finish = null
  let tokens = null
  let pending = ""
  let reported = false
  const calls = []

  const report = (ending, code, why) => {
    if (reported) return
    reported = true
    const now = Date.now()
    if (lastByte !== null) longest = Math.max(longest, now - lastByte)
    const args = calls.map((c) => c.args)
    writeFileSync(join(dir, "text.txt"), text)
    writeFileSync(join(dir, "args.txt"), args.map((a) => `${a}\n`).join(""))
    const valid = (a) => { try { JSON.parse(a); return true } catch { return false } }
    // Arguments are JSON, so their newlines are escaped: a repeating call counts too.
    const lines = [...(text ? text.split("\n") : []), ...args.flatMap((a) => a.split(/\\n|\n/))]
    const size = Math.min(60, text.length, loggedText.length)
    const secs = (ms) => Math.round(ms / 100) / 10
    console.log(JSON.stringify({
      finish: ending,
      seconds: secs(now - start),
      firstByteSeconds: firstByte === null ? null : secs(firstByte - start),
      longestSilenceSeconds: secs(longest),
      tokens,
      tool: calls.map((c) => c.name).join(",") || "-",
      textChars: text.length,
      argsChars: args.join("").length,
      argsValidJson: args.length ? args.every(valid) : null,
      lines: lines.length,
      distinctLines: new Set(lines).size,
      sameStartAsLog: loggedText ? text.slice(0, size) === loggedText.slice(0, size) : null,
      dir,
    }))
    if (why) console.error(`replay: ${why}`)
    process.exit(code)
  }

  const onEvent = (data) => {
    if (data === "[DONE]") return
    let e
    try { e = JSON.parse(data) } catch { return }
    if (e.error) report("error", 1, `the server said: ${e.error.message ?? JSON.stringify(e.error)}`)
    if (e.usage) tokens = e.usage.completion_tokens ?? tokens
    const choice = e.choices?.[0]
    if (!choice) return
    if (choice.finish_reason) finish = choice.finish_reason
    if (choice.delta?.content) text += choice.delta.content
    for (const call of choice.delta?.tool_calls ?? []) {
      calls[call.index] ??= { name: "", args: "" }
      if (call.function?.name) calls[call.index].name = call.function.name
      if (call.function?.arguments) calls[call.index].args += call.function.arguments
    }
  }

  const ended = () => (finish ? report(finish, 0) : report("dropped", 1, "the stream closed before it finished"))
  const req = request(`${baseUrl}/chat/completions`, { method: "POST", headers: { "content-type": "application/json" } }, (res) => {
    if (res.statusCode !== 200) {
      let answer = ""
      res.on("data", (d) => { answer += d })
      res.on("end", () => refuse(`the server answered ${res.statusCode}: ${answer.slice(0, 300)}`))
      return
    }
    res.on("data", (d) => {
      const now = Date.now()
      firstByte ??= now
      if (lastByte !== null) longest = Math.max(longest, now - lastByte)
      lastByte = now
      appendFileSync(join(dir, "stream.log"), `${now - start} ${d}`)
      pending += d
      let end
      while ((end = pending.indexOf("\n\n")) >= 0) {
        const block = pending.slice(0, end)
        pending = pending.slice(end + 2)
        if (block.startsWith("data: ")) onEvent(block.slice(6))
      }
    })
    res.on("error", () => {}) // A dropped stream: close says so.
    res.on("close", ended)
  })
  req.on("error", (e) => (lastByte === null ? refuse(`request failed: ${e.message}`) : ended()))
  req.end(JSON.stringify(body))
  setTimeout(() => report("limit", 2, `stopped at the ${limit} s limit`), limit * 1000)
}

const { log, reply, set, limit } = parseArgs(process.argv.slice(2))
const { system, replies } = readLog(log)
if (reply === undefined) {
  list(replies)
} else {
  const chosen = replies[reply - 1]
  if (!chosen) refuse(`no reply ${reply}: the log has ${replies.length}`)
  const { baseUrl, model } = modelEntry(chosen.message)
  const body = buildRequest(system, chosen, model, set)
  checkLoaded(chosen.message, model)
  send(baseUrl, body, {
    dir: join(dirname(log), "replays", `${basename(log, ".jsonl")}-${reply}-${stamp()}`),
    loggedText: chosen.message.content.filter((c) => c.type === "text").map((c) => c.text).join(""),
    limit,
  })
}
