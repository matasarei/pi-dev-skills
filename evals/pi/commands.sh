#!/usr/bin/env bash
# What pi/commands.js leaves in the environment between commands — run it from
# anywhere:
#
#   bash evals/pi/commands.sh
#
# The extension is loaded the way Pi loads it: the default export called with a
# pi whose registerCommand() records each command, and a handler called with a
# context carrying cwd and the selected model. A command run with a model that
# declares a window puts that window in DEV_SKILLS_CONTEXT; a later one run
# with a model that declares none must not keep the earlier model's window,
# because the injections and the model's own bash calls inherit process.env.
# What the user exported before Pi started is what that later command gets.
#
# The gates, with the real dev-implement skill in a throwaway project: a block
# with a "STOP " line (a refused branch) is never sent, and the user is told
# instead; a block that is sent already carries the BRANCH line.
# Needs git and node.
#
# Exits 0 when every case holds, 1 otherwise, naming each mismatch.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
command -v node >/dev/null 2>&1 || { printf 'commands: node is required to load the extension — not installed\n' >&2; exit 1; }

# Run from inside Pi, this would inherit the session's window.
unset DEV_SKILLS_CONTEXT

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
mkdir "$work/proj"
git -C "$work/proj" init -q

cat > "$work/run.mjs" <<'JS'
const [ext, cwd] = process.argv.slice(2)
const { default: devCommands } = await import(ext)
const commands = {}
const sent = []
devCommands({
  registerCommand: (name, opts) => { commands[name] = opts },
  sendUserMessage: (block) => { sent.push(block) },
})
const fails = []
const run = (model) => commands["dev-init"].handler("", { waitForIdle: async () => {}, cwd, model })
const want = process.env.EXPORTED
await run({ id: "big", contextWindow: 65536 })
if (process.env.DEV_SKILLS_CONTEXT !== "65536") fails.push(`a model with a 65536 window left DEV_SKILLS_CONTEXT=${process.env.DEV_SKILLS_CONTEXT}`)
await run({ id: "bare" })
if (process.env.DEV_SKILLS_CONTEXT !== want) fails.push(`a model with no window after one with 65536 left DEV_SKILLS_CONTEXT=${process.env.DEV_SKILLS_CONTEXT}, want ${want ?? "unset"}`)
if (sent.length !== 2) fails.push(`want 2 blocks sent, got ${sent.length}`)
for (const f of fails) console.log(`FAIL  ${f}`)
process.exit(fails.length ? 1 : 0)
JS

# A project with a plan, for dev-implement: .tasks/ ignored as in a real one.
gp="$work/gate"
mkdir -p "$gp/.tasks" "$gp/.devskills"
git -C "$gp" init -q -b main
printf '.tasks/\n.devskills/\n' >> "$gp/.git/info/exclude"
printf '{\n  "baseBranch": "main"\n}\n' > "$gp/.devskills/profile.json"
printf 'x\n' > "$gp/README.md"
printf '# Plan\n\n**Type:** feature\n\n## Steps\n1. [ ] one\n   - Modify: README.md\n   - Test: none\n\n2. [ ] two\n   - Modify: README.md\n   - Test: none\n' > "$gp/.tasks/plan.md"
git -C "$gp" -c user.email=t@t -c user.name=t add -A >/dev/null
git -C "$gp" -c user.email=t@t -c user.name=t commit -qm base

cat > "$work/gate.mjs" <<'JS'
import { execSync } from "node:child_process"
import { appendFileSync } from "node:fs"
const [ext, cwd] = process.argv.slice(2)
const { default: devCommands } = await import(ext)
const commands = {}
const sent = [], told = []
devCommands({
  registerCommand: (name, opts) => { commands[name] = opts },
  sendUserMessage: (block) => { sent.push(block) },
  on: () => {},
})
const ctx = { waitForIdle: async () => {}, cwd, model: { id: "m", contextWindow: 131072 }, ui: { notify: (msg, level) => { told.push([msg, level]) } } }
const fails = []
const git = (c) => execSync(`git -C ${JSON.stringify(cwd)} -c user.email=t@t -c user.name=t ${c}`, { encoding: "utf8" }).trim()

// Uncommitted work on main would follow the switch: refused, nothing sent.
appendFileSync(`${cwd}/README.md`, "dirty\n")
await commands["dev-implement"].handler(".tasks/plan.md", ctx)
if (sent.length !== 0) fails.push(`a refused branch still sent the block to the model`)
if (!told.some(([m]) => m.includes("BRANCH refused"))) fails.push(`the user was not told the branch was refused: ${JSON.stringify(told)}`)
if (git("branch --show-current") !== "main") fails.push(`a refused start moved HEAD to ${git("branch --show-current")}`)
git("checkout -q -- README.md")

// A clean tree: the block is sent, and it already says where the step is.
await commands["dev-implement"].handler(".tasks/plan.md", ctx)
if (sent.length !== 1) fails.push(`want 1 block sent on a clean tree, got ${sent.length}`)
else if (!sent[0].includes("BRANCH step/plan-1 — cut from main")) fails.push(`the block has no BRANCH line`)
if (git("branch --show-current") !== "step/plan-1") fails.push(`not on step/plan-1 after the start: ${git("branch --show-current")}`)
for (const f of fails) console.log(`FAIL  ${f}`)
process.exit(fails.length ? 1 : 0)
JS

fails=0
node "$work/gate.mjs" "$root/pi/commands.js" "$gp" || fails=$((fails + 1))
cd "$work/proj" || exit 1
node "$work/run.mjs" "$root/pi/commands.js" "$work/proj" || fails=$((fails + 1))
DEV_SKILLS_CONTEXT=50000 EXPORTED=50000 node "$work/run.mjs" "$root/pi/commands.js" "$work/proj" || fails=$((fails + 1))

if [ "$fails" -eq 0 ]; then
  printf 'commands: no window outlives its model, and a STOP never reaches the model\n'
else
  printf 'commands: %s run(s) failed\n' "$fails" >&2
fi
exit $((fails > 0))
