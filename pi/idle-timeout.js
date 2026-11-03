// Pi's idle timeout against a server that goes silent mid-reply.
//
// A server like LM Studio sends nothing while a model writes a tool call's
// arguments, so a long call is minutes of silence on the wire. Pi's default of
// 300 s takes that for a dead connection: it drops the reply as `terminated`, and
// a retry at temperature 0 can write the same long call again. The longest reply a
// model can write here, 16,384 tokens, took up to about 650 s measured and about
// 920 s at the slowest speeds seen, so 20 minutes clears it and still ends a hang.
//
// httpIdleTimeoutMs is Pi's own setting, in the user's settings.json, so this
// package can't set it. This module says whether it's enough: pi/commands.js warns
// and bench/space-city/idle-check.mjs refuses. It isn't an extension itself.

export const MIN_IDLE_MS = 1_200_000
const PI_DEFAULT_MS = 300_000

// The setting as Pi 1.5.0 reads it (parseHttpIdleTimeoutMs): a number, a numeric
// string or "disabled", 0 meaning no timeout. Unset is Pi's default. null: Pi would
// reject the value.
export function idleMs(value) {
  if (value === undefined) return PI_DEFAULT_MS
  if (typeof value === "string") {
    const text = value.trim()
    if (text.toLowerCase() === "disabled") return 0
    return text === "" ? null : idleMs(Number(text))
  }
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0) return null
  return Math.floor(value)
}

// What's wrong with the setting, in a line to show someone, or null when it's enough.
export function idleProblem(value) {
  const ms = idleMs(value)
  if (ms === 0 || ms >= MIN_IDLE_MS) return null
  const now = ms === null ? `httpIdleTimeoutMs is not a valid value (${JSON.stringify(value)})` : `Pi's idle timeout is ${Math.round(ms / 1000)} s`
  return `${now}, and a local server sends nothing while a model writes a long tool call, so the call would be dropped as \`terminated\`. Set "httpIdleTimeoutMs": ${MIN_IDLE_MS} in Pi's settings.json (~/.pi/agent/settings.json).`
}

// A server on this machine or this network: the kind that holds a tool call back.
export function isLocalUrl(url) {
  let host
  try { host = new URL(url).hostname } catch { return false }
  if (host === "localhost" || host === "[::1]" || host === "0.0.0.0") return true
  const ip = host.match(/^(\d+)\.(\d+)\.\d+\.\d+$/)
  if (!ip) return false
  const [a, b] = [Number(ip[1]), Number(ip[2])]
  return a === 127 || a === 10 || (a === 192 && b === 168) || (a === 172 && b >= 16 && b <= 31)
}
