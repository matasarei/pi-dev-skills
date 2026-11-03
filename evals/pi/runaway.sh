#!/usr/bin/env bash
# The check for a reply that repeats itself, in pi/runaway.js — run it from anywhere:
#
#   bash evals/pi/runaway.sh
#
# At temperature 0 a local model sometimes starts repeating itself in text, and
# writes on to the output limit. Asserted: what fires the check, and what must not.
# How pi/commands.js acts on it is in evals/pi/commands.sh and evals/pi/live-loop.sh.
#
# Exits 0 when every case holds, 1 otherwise, naming each failure.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
command -v node >/dev/null 2>&1 || { printf 'runaway: node is required — not installed\n' >&2; exit 1; }

node --input-type=module - "$root/pi/runaway.js" <<'JS'
const { createWatch, NUDGE, STOP_AT } = await import(process.argv[2])
const fails = []

// How many times the watch fired, feeding it `size` characters at a time.
const fires = (text, size) => {
  const watch = createWatch()
  let n = 0
  for (let i = 0; i < text.length; i += size) if (watch.add(text.slice(i, i + size))) n++
  return n
}
const prose = Array.from({ length: 40 }, (_, i) => `Sentence ${i} says something of its own about cell ${i * 7}, which the next one does not repeat.\n`).join("")

const line = "The test calls clearZone on a cell with no entity, so let me look again at what it does.\n"
const cycle5 = Array.from({ length: 5 }, (_, i) => `Line ${i} of a short cycle, long enough to matter here.\n`).join("")
const cycleLong = Array.from({ length: 24 }, (_, i) => `Part ${i} of a cycle over a thousand characters long, in full.\n`).join("")
if (cycleLong.length <= 1000) fails.push(`the long cycle is only ${cycleLong.length} characters`)

for (const [name, text] of [
  ["one line repeated", line.repeat(60)],
  ["a cycle of 5 lines", cycle5.repeat(30)],
  ["a cycle over 1,000 characters", cycleLong.repeat(6)],
  ["prose, then a line repeated", prose + line.repeat(60)],
]) {
  for (const size of [5, 40, 1000, text.length]) {
    const n = fires(text, size)
    if (n !== 1) fails.push(`${name}, ${size} characters at a time: fired ${n} times, want 1`)
  }
}

const phrase = Array.from({ length: 20 }, (_, i) => `Let me check this: item ${i} needs its own look at ${i * 3}.\n`).join("")
const block = Array.from({ length: 6 }, (_, i) => `const value${i} = compute(${i}) // a line of a code block\n`).join("")
if (block.length < 300) fails.push(`the code block is only ${block.length} characters`)
for (const [name, text] of [
  ["varied prose", prose],
  ["a short phrase repeated with varied text", phrase],
  ["a code block appearing twice", `Here it is:\n${block}\nAnd again:\n${block}`],
  ["empty text", ""],
  ["one short line", "ok"],
]) {
  for (const size of [5, 40, 1000, Math.max(text.length, 1)]) {
    const n = fires(text, size)
    if (n !== 0) fails.push(`${name}, ${size} characters at a time: fired ${n} times, want 0`)
  }
}

// Each reply has its own watch: nothing carries over.
const first = createWatch()
first.add(line.repeat(60))
if (createWatch().add(line)) fails.push("a new watch fired on one line")

if (STOP_AT !== 3) fails.push(`STOP_AT is ${STOP_AT}`)
if (NUDGE !== "Your last reply started repeating itself, so it was stopped and removed. Do not explain again. Reply with one tool call that moves the step forward.") fails.push(`the nudge is not the wording replays tested: ${NUDGE}`)

for (const f of fails) console.log(`FAIL  ${f}`)
process.exit(fails.length ? 1 : 0)
JS
rc=$?
if [ "$rc" -eq 0 ]; then
  printf 'runaway: a repeating reply fires the check once, and varied text never does\n'
  exit 0
fi
printf 'runaway: case(s) failed\n' >&2
exit 1
