#!/usr/bin/env node
// Resend one logged reply's request to the model, to see what it does with it.
//
//   node replay.mjs <step-log.jsonl>             lists the log's replies
//   node replay.mjs <step-log.jsonl> <n> [--set '{"temperature":0.2}']
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

import { readFileSync } from "node:fs"
import { request } from "node:http"
import { homedir } from "node:os"
import { join } from "node:path"

const refuse = (why) => {
  console.error(`replay: ${why}`)
  process.exit(1)
}
const USAGE = "usage: replay.mjs <step-log.jsonl> [<reply> [--set <json>]]"

function parseArgs(args) {
  const [log, reply, ...rest] = args
  if (!log || log.startsWith("--")) refuse(USAGE)
  if (reply === undefined) return { log }
  if (!/^\d+$/.test(reply)) refuse(USAGE)
  let set = {}
  for (let i = 0; i < rest.length; i += 2) {
    if (rest[i] !== "--set" || rest[i + 1] === undefined) refuse(USAGE)
    let fields
    try { fields = JSON.parse(rest[i + 1]) } catch { refuse(`--set is not JSON: ${rest[i + 1]}`) }
    if (fields === null || typeof fields !== "object" || Array.isArray(fields)) refuse(`--set is not an object: ${rest[i + 1]}`)
    set = { ...set, ...fields }
  }
  return { log, reply: Number(reply), set }
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
  console.log("reply  stop      seconds  tokens  tool  error")
  replies.forEach(({ message: m }, i) => {
    const seconds = m.durationMs === undefined ? "?" : (m.durationMs / 1000).toFixed(1)
    console.log(`${i + 1}  ${m.stopReason}  ${seconds}  ${m.usage?.output ?? "?"}  ${toolNames(m)}  ${m.errorMessage ?? ""}`.trimEnd())
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

function send(baseUrl, body) {
  const req = request(`${baseUrl}/chat/completions`, { method: "POST", headers: { "content-type": "application/json" } }, (res) => {
    res.resume()
    res.on("end", () => process.exit(0))
  })
  req.on("error", (e) => refuse(`request failed: ${e.message}`))
  req.end(JSON.stringify(body))
}

const { log, reply, set } = parseArgs(process.argv.slice(2))
const { system, replies } = readLog(log)
if (reply === undefined) {
  list(replies)
} else {
  const chosen = replies[reply - 1]
  if (!chosen) refuse(`no reply ${reply}: the log has ${replies.length}`)
  const { baseUrl, model } = modelEntry(chosen.message)
  send(baseUrl, buildRequest(system, chosen, model, set))
}
