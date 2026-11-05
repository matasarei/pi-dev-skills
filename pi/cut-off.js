// The rule for a tool call cut off at the output limit.
//
// A local server holds a call's arguments back until they are complete, so a call
// that starts repeating itself can't be seen: it runs to the limit, 7 to 9 minutes.
// Pi then tells the model to send it again, at the same limit, and the model often
// does: one logged session spent 1,385 of its 1,800 s on three of these in a row.
//
// So once one is in the context, the model is asked for a smaller change instead, and
// a reply gets a lower limit. Of 80 finished replies after a cut-off in the logs, 78
// were under 1,600 tokens. It reads the context, not a count, so a session reopened
// with pi --continue keeps it. pi/commands.js acts on it. This isn't an extension itself.

// About 135 s at the model's 30 tokens/s, and about 16,000 characters.
export const RETRY_LIMIT = 4096

const smallerAsk = (name) => `Tool call "${name}" was not executed: the reply hit the output limit, which usually means it started repeating itself. From here on a reply is limited to ${RETRY_LIMIT} tokens, about 16,000 characters, so do not send a whole file. Make a smaller change: edit only the lines that need to change, one edit at a time.`

const toolCalls = (message) => (message.content ?? []).filter((c) => c.type === "toolCall")

// A reply the output limit ended inside a tool call. Text at the limit isn't one: Pi
// runs nothing and asks for nothing, and pi/runaway.js has that.
export function isCutOff(message) {
  return message?.role === "assistant" && message.stopReason === "length" && toolCalls(message).length > 0
}

// The context with each cut-off's answer replaced, and whether it holds a cut-off. Only
// the results right after one count, since a local server can reuse a call's id.
export function withSmallerAsk(messages) {
  let cutOff = false
  let names = null
  const out = messages.map((message) => {
    if (message.role !== "toolResult") {
      names = isCutOff(message) ? new Map(toolCalls(message).map((c) => [c.id, c.name])) : null
      cutOff ||= names !== null
      return message
    }
    if (!names?.has(message.toolCallId)) return message
    return { ...message, content: [{ type: "text", text: smallerAsk(names.get(message.toolCallId)) }] }
  })
  return { messages: out, cutOff }
}

// A provider's request with its output limit lowered, never raised. It names the
// limit one of two ways, depending on the server.
export function withLowerLimit(payload) {
  const lowered = {}
  for (const field of ["max_completion_tokens", "max_tokens"]) {
    if (payload?.[field] > RETRY_LIMIT) lowered[field] = RETRY_LIMIT
  }
  return Object.keys(lowered).length ? { ...payload, ...lowered } : payload
}
