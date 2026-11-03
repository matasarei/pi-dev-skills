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
#
# The idle timeout: a local model below the limit in pi/idle-timeout.js gets one
# warning a session, and the command still runs. Real Pi handing over a real model
# and real settings is in evals/pi/live-loop.sh.
#
# A runaway reply: during a /dev-* command, a reply that repeats itself is stopped and
# the model nudged, the third time ends the run, and the person's own prompts are left
# alone. The handlers are called in Pi's order; real Pi is in evals/pi/live-loop.sh.
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
const handlers = {}
devCommands({
  registerCommand: (name, opts) => { commands[name] = opts },
  sendUserMessage: (block) => { sent.push(block) },
  on: (event, fn) => { (handlers[event] ??= []).push(fn) },
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
// Asked for a later step with an earlier one unfinished: the user is told which, and how to resume it.
told.length = 0
await commands["dev-implement"].handler(".tasks/plan.md --step 2", ctx)
if (sent.length !== 0) fails.push("a refused later step still sent the block to the model")
if (!told.some(([m]) => m.includes("Step 1 is not finished") && m.includes("--continue resumes it"))) fails.push(`the user was not told which step to resume: ${JSON.stringify(told)}`)
git("checkout -q -- README.md")

// A clean tree: the block is sent, and it already says where the step is.
await commands["dev-implement"].handler(".tasks/plan.md", ctx)
if (sent.length !== 1) fails.push(`want 1 block sent on a clean tree, got ${sent.length}`)
else if (!sent[0].includes("BRANCH step/plan-1 — cut from main")) fails.push(`the block has no BRANCH line`)
if (git("branch --show-current") !== "step/plan-1") fails.push(`not on step/plan-1 after the start: ${git("branch --show-current")}`)

// The step gate. A tool call, as Pi hands it to every tool_call handler; the
// verdict is "2" refused (and whether it terminates), "0" let through.
const call = async (toolName, input) => {
  for (const fn of handlers.tool_call ?? []) {
    const r = await fn({ type: "tool_call", toolCallId: "t", toolName, input }, { cwd })
    if (r?.block) return { got: "2", reason: r.reason ?? "", terminate: r.terminate === true }
  }
  return { got: "0" }
}
const expect = async (want, toolName, input, what) => {
  const r = await call(toolName, input)
  if (r.got !== want) fails.push(`${what}: want ${want}, got ${r.got} ${r.reason ?? ""}`)
  return r
}
if (!(handlers.tool_call ?? []).length) fails.push("commands.js registered no tool_call handler")
const plan = `${cwd}/.tasks/plan.md`
const lib = "${DEV_SKILLS_LIB:-x}"

// Another step's scripts are another session's: refused; this step's are not.
await expect("2", "bash", { command: `bash ${lib}/branch.sh .tasks/plan.md 2` }, "branch.sh for step 2 in a step 1 session")
await expect("2", "bash", { command: `cd . && bash ${lib}/tick.sh ${plan} 2 "x"` }, "tick.sh for step 2")
await expect("2", "bash", { command: `bash ${lib}/task-step.sh .tasks/plan.md --step 2` }, "task-step.sh --step 2")
await expect("2", "bash", { command: `bash ${lib}/step-budget.sh ${plan} 2` }, "step-budget.sh for step 2")
await expect("0", "bash", { command: `bash ${lib}/step-budget.sh ${plan} 1` }, "step-budget.sh for this step")
await expect("0", "bash", { command: `bash ${lib}/test.sh --scoped plan` }, "test.sh")
// Asking for "the next step" is how a session starts, not something one does mid-step.
await expect("2", "bash", { command: `bash ${lib}/task-step.sh .tasks/plan.md --next` }, "task-step.sh --next in a step session")
await expect("2", "bash", { command: `bash ${lib}/task-step.sh --continue` }, "task-step.sh --continue in a step session")
await expect("2", "bash", { command: `bash ${lib}/task-step.sh .tasks/plan.md` }, "task-step.sh with no step in a step session")
await expect("0", "bash", { command: `bash ${lib}/task-step.sh .tasks/plan.md --count` }, "task-step.sh --count")
await expect("0", "bash", { command: `bash ${lib}/task-step.sh .tasks/plan.md --paths 1` }, "task-step.sh --paths for this step")

// Not done yet: ticked but not committed, committed but not ticked, done but dirty.
const tick = (on) => execSync(`sed -i.bak 's/^1\\. \\[${on ? " " : "x"}\\]/1. [${on ? "x" : " "}]/' ${JSON.stringify(plan)}`)
tick(true)
await expect("0", "read", { path: "README.md" }, "ticked but not committed")
tick(false)
appendFileSync(`${cwd}/README.md`, "one\n")
git("commit -qam one")
await expect("0", "read", { path: "README.md" }, "committed but not ticked")
tick(true)
appendFileSync(`${cwd}/README.md`, "more\n")
await expect("0", "read", { path: "README.md" }, "ticked and committed, but the tree is dirty")
git("checkout -q -- README.md")

// Done: ticked, committed, clean. Everything but the learned.md line is refused,
// and the third refusal ends the run.
const r1 = await expect("2", "read", { path: "README.md" }, "a read once the step is done")
if (!/step 1 is done/.test(r1.reason ?? "")) fails.push(`the done refusal does not say the step is done: ${r1.reason}`)
if (r1.terminate) fails.push("the first refusal after done already terminates")
await expect("0", "bash", { command: `echo "2026-11-02 x" >> .devskills/learned.md && tail -20 .devskills/learned.md` }, "the learned.md line after done")
await expect("0", "bash", { command: `printf '%s\\n' "a; b" >> .devskills/learned.md && tail -20 .devskills/learned.md > .devskills/learned.tmp && mv .devskills/learned.tmp .devskills/learned.md` }, "the skill's append-then-trim after done")
// A command that only mentions learned.md is not the learned line.
const rc = await expect("2", "bash", { command: `echo x >> .devskills/learned.md; npm test` }, "a chained command riding on the learned line")
const rp = await expect("2", "bash", { command: `cat .devskills/learned.md | bash` }, "a learned.md read piped into a shell")
if (rc.terminate) fails.push("the second refusal after done already terminates")
if (!rp.terminate) fails.push("the third refusal after done does not terminate")
const r2 = await expect("2", "bash", { command: `bash ${lib}/branch.sh .tasks/plan.md 2` }, "starting step 2 after done")
if (!r2.terminate) fails.push("the fourth refusal after done does not terminate")
const r3 = await expect("2", "write", { path: "src/x.ts", content: "x" }, "a write after done")
if (!r3.terminate) fails.push("the fifth refusal after done does not terminate")

// Any other /dev-* command, or a new session, clears the gate.
await commands["dev-init"].handler("", ctx)
await expect("0", "read", { path: "README.md" }, "after /dev-init")
await commands["dev-implement"].handler(".tasks/plan.md", ctx)
await expect("2", "bash", { command: `bash ${lib}/branch.sh .tasks/plan.md 1` }, "step 1's branch.sh in the step 2 session")
for (const fn of handlers.session_start ?? []) await fn({ type: "session_start" }, ctx)
await expect("0", "bash", { command: `bash ${lib}/branch.sh .tasks/plan.md 1` }, "after a new session")
for (const f of fails) console.log(`FAIL  ${f}`)
process.exit(fails.length ? 1 : 0)
JS

cat > "$work/idle.mjs" <<'JS'
const [ext, cwd] = process.argv.slice(2)
const { default: devCommands } = await import(ext)
const commands = {}, handlers = {}
const sent = [], told = []
let settings = {}
devCommands({
  registerCommand: (name, opts) => { commands[name] = opts },
  sendUserMessage: (block) => { sent.push(block) },
  on: (event, fn) => { (handlers[event] ??= []).push(fn) },
  getSettings: () => settings,
})
const local = { id: "m", baseUrl: "http://127.0.0.1:1234/v1" }
const hosted = { id: "m", baseUrl: "https://api.example.com/v1" }
const fails = []
const run = async (what, model, wantTold) => {
  told.length = 0
  sent.length = 0
  await commands["dev-init"].handler("", { waitForIdle: async () => {}, cwd, model, ui: { notify: (msg, level) => { told.push([msg, level]) } } })
  if (sent.length !== 1) fails.push(`${what}: the block was not sent`)
  if (told.length !== wantTold) fails.push(`${what}: told ${told.length}, want ${wantTold}: ${JSON.stringify(told)}`)
  for (const [msg, level] of told) {
    if (level !== "warning" || !msg.includes("httpIdleTimeoutMs") || !msg.includes("1200000")) fails.push(`${what}: not the warning: ${level} ${msg}`)
  }
}
const newSession = async () => { for (const fn of handlers.session_start ?? []) await fn({ type: "session_start" }, {}) }

await run("hosted, the default", hosted, 0)
await run("no baseUrl, the default", { id: "m" }, 0)
await run("no model", undefined, 0)
settings = { httpIdleTimeoutMs: 1200000 }
await run("local, at the limit", local, 0)
settings = { httpIdleTimeoutMs: "disabled" }
await run("local, disabled", local, 0)
settings = {}
await run("local, the default", local, 1)
await run("local, the default, again in that session", local, 0)
await newSession()
await run("local, the default, in a new session", local, 1)
await newSession()
settings = { httpIdleTimeoutMs: 300000 }
await run("local, too low", local, 1)
for (const f of fails) console.log(`FAIL  ${f}`)
process.exit(fails.length ? 1 : 0)
JS

cat > "$work/runaway.mjs" <<'JS'
const [ext, cwd, gateCwd] = process.argv.slice(2)
const { default: devCommands } = await import(ext)
const { NUDGE } = await import(new URL("runaway.js", new URL(ext, "file:///")).href)
const commands = {}, handlers = {}
const sent = [], told = []
let aborts = 0
devCommands({
  registerCommand: (name, opts) => { commands[name] = opts },
  // As Pi does: a message is a new prompt, so before_agent_start fires for it.
  sendUserMessage: (block) => { sent.push(block) },
  on: (event, fn) => { (handlers[event] ??= []).push(fn) },
})
const fails = []
const ctx = { abort: () => { aborts++ }, ui: { notify: (msg, level) => { told.push([msg, level]) } } }
const emit = async (type, event = {}) => { for (const fn of handlers[type] ?? []) await fn({ type, ...event }, { ...ctx, cwd }) }
const line = "The test calls clearZone on a cell with no entity, so let me look again at what it does.\n"
const prompt = () => emit("before_agent_start")
const command = async (name = "dev-init", args = "", at = cwd) => {
  await commands[name].handler(args, { waitForIdle: async () => {}, cwd: at, model: { id: "m" }, ui: ctx.ui })
  await prompt()
}
// One reply's text, as Pi streams it.
const reply = async (text) => {
  await emit("message_start", { message: { role: "assistant" } })
  for (let i = 0; i < text.length; i += 40) {
    await emit("message_update", { message: {}, assistantMessageEvent: { type: "text_delta", delta: text.slice(i, i + 40) } })
  }
}
const settled = (aborted = false) => emit("agent_settled", { aborted })
const check = (what, want) => {
  const got = { aborts, sent: sent.length, told: told.length }
  if (JSON.stringify(got) !== JSON.stringify(want)) fails.push(`${what}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`)
}
const reset = () => { aborts = 0; sent.length = 0; told.length = 0 }
const repeating = line.repeat(60)

// No command in this session: nothing is watched.
await prompt()
await reply(repeating)
await settled()
check("no command", { aborts: 0, sent: 0, told: 0 })

// A command's normal reply: never interrupted.
await command()
reset()
await reply("A normal reply, of no great length, and then the agent settles.\n")
await settled()
check("a normal reply", { aborts: 0, sent: 0, told: 0 })

// A runaway in a command: stopped once, warned, and nudged when it settles.
await reply(repeating)
check("a runaway, before it settles", { aborts: 1, sent: 0, told: 1 })
if (told[0]?.[1] !== "warning" || !told[0]?.[0].includes("repeating")) fails.push(`the warning: ${JSON.stringify(told[0])}`)
await settled(true)
check("a runaway, settled", { aborts: 1, sent: 1, told: 1 })
if (sent[0] !== NUDGE) fails.push(`the message sent is not the nudge: ${sent[0]}`)
await prompt()

// The nudged run is still watched. A second runaway is nudged too.
await reply(repeating)
await settled(true)
check("a second runaway", { aborts: 2, sent: 2, told: 2 })
await prompt()

// The third ends the run: no more messages, and the person is told.
await reply(repeating)
await settled(true)
check("a third runaway", { aborts: 3, sent: 2, told: 4 })
if (!told.at(-1)?.[0].includes("This run stops here.")) fails.push(`the stop: ${JSON.stringify(told.at(-1))}`)

// A settle that this rule didn't cause, a person pressing Esc: nothing is sent.
await command()
reset()
await reply("A reply the person stops.\n")
await settled(true)
check("a person's Esc", { aborts: 0, sent: 0, told: 0 })

// A new command starts the count again.
await reply(repeating)
await settled(true)
await prompt()
await reply(repeating)
await settled(true)
await prompt()
await command()
reset()
await reply(repeating)
await settled(true)
check("a new command's first runaway", { aborts: 1, sent: 1, told: 1 })
await prompt()

// The person's own prompt after a command: no longer watched.
await settled()
await prompt()
reset()
await reply(repeating)
await settled()
check("the person's own prompt", { aborts: 0, sent: 0, told: 0 })

// A new session: nothing carries over, a stop in flight included.
await command()
reset()
await reply(repeating)
await emit("session_start")
await settled(true)
check("a new session after a stop", { aborts: 1, sent: 0, told: 1 })
await prompt()
reset()
await reply(repeating)
check("a new session's prompt", { aborts: 0, sent: 0, told: 0 })

// The step gate holds through a nudge: a nudge isn't a command.
await command("dev-implement", ".tasks/plan.md", gateCwd)
reset()
await reply(repeating)
await settled(true)
await prompt()
check("a runaway in a step", { aborts: 1, sent: 1, told: 1 })
const lib = "${DEV_SKILLS_LIB:-x}"
let refused = false
for (const fn of handlers.tool_call ?? []) {
  const r = await fn({ type: "tool_call", toolCallId: "t", toolName: "bash", input: { command: `bash ${lib}/branch.sh .tasks/plan.md 2` } }, { cwd: gateCwd })
  if (r?.block) refused = true
}
if (!refused) fails.push("the step gate did not hold after a nudge")

for (const f of fails) console.log(`FAIL  ${f}`)
process.exit(fails.length ? 1 : 0)
JS

fails=0
cp -R "$gp" "$work/gate2"
node "$work/gate.mjs" "$root/pi/commands.js" "$gp" || fails=$((fails + 1))
cd "$work/proj" || exit 1
node "$work/run.mjs" "$root/pi/commands.js" "$work/proj" || fails=$((fails + 1))
DEV_SKILLS_CONTEXT=50000 EXPORTED=50000 node "$work/run.mjs" "$root/pi/commands.js" "$work/proj" || fails=$((fails + 1))
node "$work/idle.mjs" "$root/pi/commands.js" "$work/proj" || fails=$((fails + 1))
node "$work/runaway.mjs" "$root/pi/commands.js" "$work/proj" "$work/gate2" || fails=$((fails + 1))

if [ "$fails" -eq 0 ]; then
  printf 'commands: no window outlives its model, a STOP never reaches the model, a short idle timeout is warned about once, and a runaway reply is stopped and nudged\n'
else
  printf 'commands: %s run(s) failed\n' "$fails" >&2
fi
exit $((fails > 0))
