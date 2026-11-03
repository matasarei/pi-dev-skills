#!/usr/bin/env bash
# The rule on Pi's idle timeout, in pi/idle-timeout.js — run it from anywhere:
#
#   bash evals/pi/idle-timeout.sh
#
# A server like LM Studio sends nothing while a model writes a tool call's
# arguments, and a long call takes minutes, so Pi's default of 300 s drops good
# work. Asserted: which values of httpIdleTimeoutMs are enough, read the way Pi
# reads them, and which servers the rule applies to. What Pi itself does with the
# setting is in evals/pi/live-loop.sh.
#
# Exits 0 when every case holds, 1 otherwise, naming each failure.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
command -v node >/dev/null 2>&1 || { printf 'idle-timeout: node is required — not installed\n' >&2; exit 1; }

node --input-type=module - "$root/pi/idle-timeout.js" <<'JS'
const { MIN_IDLE_MS, idleMs, idleProblem, isLocalUrl } = await import(process.argv[2])
const fails = []
const same = (what, got, want) => { if (got !== want) fails.push(`${what}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`) }

same("the limit", MIN_IDLE_MS, 1_200_000)

// Read the way Pi reads the setting.
for (const [value, want] of [
  [undefined, 300_000], [300_000, 300_000], [1_200_000, 1_200_000], [1_200_000.9, 1_200_000], ["1200000", 1_200_000],
  [" 1200000 ", 1_200_000], [0, 0], ["0", 0], ["disabled", 0], [" DISABLED ", 0],
  ["", null], ["soon", null], [-1, null], [Infinity, null], [null, null], [true, null], [{}, null],
]) same(`idleMs(${JSON.stringify(value)})`, idleMs(value), want)

// Enough: at the limit, above it, or no timeout at all.
for (const value of [1_200_000, 3_600_000, "1200000", 0, "0", "disabled"]) same(`idleProblem(${JSON.stringify(value)})`, idleProblem(value), null)

// Not enough: below the limit, Pi's default, or a value Pi would not accept.
for (const value of [undefined, 300_000, 1_199_999, "300000", "", "soon", -1, null]) {
  const problem = idleProblem(value)
  if (typeof problem !== "string") fails.push(`idleProblem(${JSON.stringify(value)}) found nothing`)
  else if (!problem.includes("httpIdleTimeoutMs") || !problem.includes("1200000") || !problem.includes("settings.json")) fails.push(`idleProblem(${JSON.stringify(value)}) does not say what to set: ${problem}`)
}
if (!idleProblem(undefined)?.includes("300 s")) fails.push(`the default's problem does not name 300 s: ${idleProblem(undefined)}`)

// A server on this machine or this network, and nothing else.
for (const url of ["http://127.0.0.1:1234/v1", "http://127.8.8.8/v1", "http://localhost:11434/v1", "http://[::1]:1234/v1", "http://0.0.0.0:1234", "http://10.0.0.7:1234/v1", "http://192.168.1.5:1234/v1", "http://172.16.0.1/v1", "http://172.31.255.1/v1"]) same(`isLocalUrl(${url})`, isLocalUrl(url), true)
for (const url of ["https://api.openai.com/v1", "https://openrouter.ai/api/v1", "http://172.32.0.1/v1", "http://172.15.0.1/v1", "http://192.169.1.1/v1", "http://11.0.0.1/v1", "http://127.0.0.1.example.com/v1", "http://localhost.example.com/v1", "not a url", "", undefined, null, 7]) same(`isLocalUrl(${JSON.stringify(url)})`, isLocalUrl(url), false)

for (const f of fails) console.log(`FAIL  ${f}`)
process.exit(fails.length ? 1 : 0)
JS
rc=$?
if [ "$rc" -eq 0 ]; then
  printf 'idle-timeout: every value reads as Pi reads it, and only a local server is warned about\n'
  exit 0
fi
printf 'idle-timeout: case(s) failed\n' >&2
exit 1
