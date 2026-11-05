#!/usr/bin/env bash
# The rule for a tool call cut off at the output limit, in pi/cut-off.js — run it from anywhere:
#
#   bash evals/pi/cut-off.sh
#
# Pi answers such a call by asking for it again, at the same limit. Asserted: what
# counts as a cut-off, what the model is told instead, and what the limit becomes.
# How pi/commands.js acts on it is in evals/pi/live-loop.sh.
#
# Exits 0 when every case holds, 1 otherwise, naming each failure.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
command -v node >/dev/null 2>&1 || { printf 'cut-off: node is required — not installed\n' >&2; exit 1; }

node --input-type=module - "$root/pi/cut-off.js" <<'JS'
const { isCutOff, RETRY_LIMIT, withLowerLimit, withSmallerAsk } = await import(process.argv[2])
const fails = []
const expect = (what, ok, got) => { if (!ok) fails.push(`${what}: ${JSON.stringify(got)}`) }

const PI_TEXT = 'Tool call "edit" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments.'
const call = (id, name = "edit") => ({ type: "toolCall", id, name, arguments: {} })
const reply = (stopReason, ...content) => ({ role: "assistant", stopReason, content })
const result = (toolCallId, text = PI_TEXT, toolName = "edit") => ({ role: "toolResult", toolCallId, toolName, isError: true, content: [{ type: "text", text }] })
const textOf = (message) => message.content.map((c) => c.text).join("")

// What counts as a cut-off.
expect("a reply at the limit with a tool call is a cut-off", isCutOff(reply("length", call("a"))) === true, "no")
expect("a reply at the limit with text and a tool call is a cut-off", isCutOff(reply("length", { type: "text", text: "Now" }, call("a"))) === true, "no")
expect("text at the limit is not a cut-off: the runaway watch has that", isCutOff(reply("length", { type: "text", text: "again" })) === false, "yes")
expect("a finished tool call is not a cut-off", isCutOff(reply("toolUse", call("a"))) === false, "yes")
expect("a person's message is not a cut-off", isCutOff({ role: "user", stopReason: "length", content: "x" }) === false, "yes")
expect("a reply with no content is not a cut-off", isCutOff({ role: "assistant", stopReason: "length" }) === false, "yes")

// What the model is told.
const cut = [{ role: "user", content: "go" }, reply("length", call("a")), result("a")]
const frozen = JSON.stringify(cut)
let out = withSmallerAsk(cut)
expect("a context with a cut-off says so", out.cutOff === true, out.cutOff)
expect("Pi's text was left", !textOf(out.messages[2]).includes("Re-issue"), textOf(out.messages[2]))
expect("the new text does not name the call", textOf(out.messages[2]).startsWith('Tool call "edit" was not executed'), textOf(out.messages[2]))
expect("the new text does not give the limit", textOf(out.messages[2]).includes(`${RETRY_LIMIT} tokens`), textOf(out.messages[2]))
expect("the new text does not ask for a smaller change", textOf(out.messages[2]).includes("Make a smaller change"), textOf(out.messages[2]))
expect("the result lost its other fields", out.messages[2].toolCallId === "a" && out.messages[2].isError === true && out.messages[2].role === "toolResult", out.messages[2])
expect("the input was changed", JSON.stringify(cut) === frozen, cut)

out = withSmallerAsk([reply("length", call("a", "write"), call("b", "read")), result("a", PI_TEXT, "write"), result("b", PI_TEXT, "read")])
expect("both calls of a cut-off were not answered", textOf(out.messages[1]).startsWith('Tool call "write"') && textOf(out.messages[2]).startsWith('Tool call "read"'), out.messages)

// A server can reuse an id, so only the results right after the cut-off count.
const other = "Successfully replaced 1 block(s)"
out = withSmallerAsk([reply("length", call("a")), result("a"), reply("toolUse", call("a")), result("a", other)])
expect("the first of two calls with one id was not rewritten", !textOf(out.messages[1]).includes("Re-issue"), out.messages[1])
expect("a later reply's result with the same id was rewritten", textOf(out.messages[3]) === other, out.messages[3])

for (const [name, messages] of [
  ["no messages", []],
  ["text at the limit", [reply("length", { type: "text", text: "again" })]],
  ["a finished call", [reply("toolUse", call("a")), result("a", other)]],
]) {
  out = withSmallerAsk(messages)
  expect(`${name} was taken for a cut-off`, out.cutOff === false, out.cutOff)
  expect(`${name} was changed`, JSON.stringify(out.messages) === JSON.stringify(messages), out.messages)
}

// A cut-off further back still counts, and a call that was never answered changes nothing.
out = withSmallerAsk([reply("length", call("a")), result("a"), reply("toolUse", call("b")), result("b", other), reply("stop", { type: "text", text: "done" })])
expect("an earlier cut-off was missed", out.cutOff === true, out.cutOff)
out = withSmallerAsk([reply("length", call("a"))])
expect("a cut-off with no result yet was missed", out.cutOff === true && out.messages.length === 1, out)

// What the limit becomes.
for (const [name, payload, want] of [
  ["max_completion_tokens", { max_completion_tokens: 12288, a: 1 }, { max_completion_tokens: RETRY_LIMIT, a: 1 }],
  ["max_tokens", { max_tokens: 16384 }, { max_tokens: RETRY_LIMIT }],
  ["both", { max_tokens: 16384, max_completion_tokens: 12288 }, { max_tokens: RETRY_LIMIT, max_completion_tokens: RETRY_LIMIT }],
  ["a limit already lower", { max_completion_tokens: 2000 }, { max_completion_tokens: 2000 }],
  ["the limit itself", { max_tokens: RETRY_LIMIT }, { max_tokens: RETRY_LIMIT }],
  ["neither field", { messages: [] }, { messages: [] }],
]) {
  const before = JSON.stringify(payload)
  const got = withLowerLimit(payload)
  expect(`${name}: wrong limit`, JSON.stringify(got) === JSON.stringify(want), got)
  expect(`${name}: the input was changed`, JSON.stringify(payload) === before, payload)
}
expect("no payload threw or changed", withLowerLimit(undefined) === undefined, "changed")

for (const f of fails) console.log(`FAIL  ${f}`)
process.exit(fails.length ? 1 : 0)
JS
rc=$?
if [ "$rc" -eq 0 ]; then
  printf 'cut-off: a cut-off asks for a smaller change at a lower limit, and nothing else changes\n'
  exit 0
fi
printf 'cut-off: case(s) failed\n' >&2
exit 1
