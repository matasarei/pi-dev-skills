#!/usr/bin/env bash
# pi/expand.js's run() against an injection that outlives its timeout — run it
# from anywhere:
#
#   bash evals/pi/expand.sh
#
# A timed-out injection is killed, and run() must return then, with the
# timeout noted, even when the command left a process in the background
# holding its output open. Otherwise the command hangs Pi until that process
# exits.
#
# The text the model reads names this checkout's lib/ as an absolute path:
# shown $DEV_SKILLS_LIB, the model sometimes filled in a home of its own and
# ran whatever copy find turned up. withLibPath() is checked on each form, and
# a skill expanded with the variable unset still runs its injections here.
# Needs node.
#
# Exits 0 when all of that holds, 1 otherwise.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
command -v node >/dev/null 2>&1 || { printf 'expand: node is required to load the expander — not installed\n' >&2; exit 1; }

fails=0
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

node "$work/run.mjs" "$root/pi/expand.js" || fails=1

cat > "$work/lib.mjs" <<'JS'
const [libPath, expandPath, lib] = process.argv.slice(2)
const fails = []
let mod = {}
try { mod = await import(libPath) } catch (e) { fails.push(`pi/lib-path.js does not load: ${e.message}`) }
const { LIB, withLibPath } = mod
if (LIB !== lib) fails.push(`LIB is ${LIB}, want ${lib}`)
if (typeof withLibPath === "function") {
  for (const [text, want] of [
    ["bash $DEV_SKILLS_LIB/tick.sh x", "bash /a/lib/tick.sh x"],
    ["bash ${DEV_SKILLS_LIB}/test.sh", "bash /a/lib/test.sh"],
    ["bash ${DEV_SKILLS_LIB:-$HOME/old/dev-lib}/lint.sh", "bash /a/lib/lint.sh"],
    ["`$DEV_SKILLS_LIB/a.sh` and `$DEV_SKILLS_LIB/b.sh`", "`/a/lib/a.sh` and `/a/lib/b.sh`"],
    ["$DEV_SKILLS_LIBRARY stays", "$DEV_SKILLS_LIBRARY stays"],
    ["no variable here", "no variable here"],
  ]) {
    const got = withLibPath(text, "/a/lib")
    if (got !== want) fails.push(`withLibPath(${JSON.stringify(text)}) is ${JSON.stringify(got)}, want ${JSON.stringify(want)}`)
  }
  const spaced = withLibPath("bash $DEV_SKILLS_LIB/tick.sh", "/my dir/lib")
  if (spaced !== "bash '/my dir/lib'/tick.sh") fails.push(`a path with a space is not quoted: ${spaced}`)
  if (withLibPath("bash $DEV_SKILLS_LIB/x.sh") !== `bash ${lib}/x.sh`) fails.push("withLibPath() without a lib does not use LIB")
} else fails.push("pi/lib-path.js exports no withLibPath")

// A skill expanded with DEV_SKILLS_LIB unset: the prose names LIB, and the
// injection still runs a script from it.
delete process.env.DEV_SKILLS_LIB
const { expandSkill } = await import(expandPath)
const skill = "---\ndescription: x\n---\nTick: `bash $DEV_SKILLS_LIB/tick.sh <file> <n>`\n!`test -f $DEV_SKILLS_LIB/tick.sh && echo LIB-FOUND || echo LIB-MISSING`\n"
const block = await expandSkill(skill, { cwd: process.cwd() })
if (!block.includes(`bash ${lib}/tick.sh <file> <n>`)) fails.push(`the prose does not name ${lib}: ${block}`)
if (!block.includes("LIB-FOUND")) fails.push(`with the variable unset, the injection found no lib: ${block}`)
if (block.includes("DEV_SKILLS_LIB")) fails.push(`the variable reached the block: ${block}`)
for (const f of fails) console.log(`FAIL  ${f}`)
if (!fails.length) console.log("expand: the block names this checkout's lib/, with the variable set or not")
process.exit(fails.length ? 1 : 0)
JS

node "$work/lib.mjs" "$root/pi/lib-path.js" "$root/pi/expand.js" "$root/lib" || fails=1
exit "$fails"
