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

fails=0
cd "$work/proj" || exit 1
node "$work/run.mjs" "$root/pi/commands.js" "$work/proj" || fails=$((fails + 1))
DEV_SKILLS_CONTEXT=50000 EXPORTED=50000 node "$work/run.mjs" "$root/pi/commands.js" "$work/proj" || fails=$((fails + 1))

if [ "$fails" -eq 0 ]; then
  printf 'commands: no window outlives the model that declared it\n'
else
  printf 'commands: %s run(s) failed\n' "$fails" >&2
fi
exit $((fails > 0))
