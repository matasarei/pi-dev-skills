#!/usr/bin/env bash
# pi/expand.js's run() against an injection that outlives its timeout — run it
# from anywhere:
#
#   bash evals/pi/expand.sh
#
# A timed-out injection is killed, and run() must return then, with the
# timeout noted, even when the command left a process in the background
# holding its output open. Otherwise the command hangs Pi until that process
# exits. Needs node.
#
# Exits 0 when it returns in time, 1 otherwise.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
command -v node >/dev/null 2>&1 || { printf 'expand: node is required to load the expander — not installed\n' >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

cat > "$work/run.mjs" <<'JS'
const { run } = await import(process.argv[2])
const started = Date.now()
const out = await Promise.race([
  run("echo before; sleep 20 & sleep 20", { cwd: process.cwd(), env: {}, timeoutMs: 300 }),
  new Promise((done) => setTimeout(() => done(null), 5000)),
])
const fails = []
if (out === null) fails.push("run() was still waiting 5 s after a 0.3 s timeout")
else {
  if (!out.includes("before")) fails.push(`the output before the timeout was lost: ${JSON.stringify(out)}`)
  if (!out.includes("(timed out after")) fails.push(`the timeout is not noted: ${JSON.stringify(out)}`)
}
for (const f of fails) console.log(`FAIL  ${f}`)
console.log(fails.length ? "" : `expand: a timed-out injection returns (${Date.now() - started} ms)`)
process.exit(fails.length ? 1 : 0)
JS

node "$work/run.mjs" "$root/pi/expand.js"
