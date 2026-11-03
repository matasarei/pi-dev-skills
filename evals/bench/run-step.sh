#!/usr/bin/env bash
# The bench's one-step runner against a scripted Pi — run it from anywhere:
#
#   bash evals/bench/run-step.sh
#
# A stand-in `pi` on PATH plays one behaviour per session and records each prompt,
# so this needs neither Pi nor a model. Asserted: how many sessions a step gets,
# what the resume asks for, where its log goes, and what meta.env says. A step used
# to get one session, so one bad session cost the rest of the run.
#
# Exits 0 when every case holds, 1 otherwise, naming each failure.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
runner="$root/bench/space-city/run-step.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0
note() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

mkdir -p "$work/bin"
cat > "$work/bin/pi.mjs" <<'JS'
// Each session takes the next word of FAKE_PI_SESSIONS:
//   done    ticks the step named by FAKE_PI_STEP, and finishes
//   stop    finishes without ticking
//   hang    starts and never finishes, for the driver's timeout
//   gated   notifies an error before the agent starts, as a refused branch does
//   die     starts, then Pi exits 7
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs"
import { createInterface } from "node:readline"
const dir = process.env.FAKE_PI_DIR
const countFile = `${dir}/sessions`
const n = existsSync(countFile) ? Number(readFileSync(countFile, "utf8")) : 0
writeFileSync(countFile, String(n + 1))
const word = process.env.FAKE_PI_SESSIONS.split(",")[n] ?? "stop"
const say = (e) => console.log(JSON.stringify(e))
const finish = () => { say({ type: "agent_start" }); say({ type: "agent_end" }); say({ type: "agent_settled", aborted: false }) }
createInterface({ input: process.stdin }).on("line", (line) => {
  const msg = JSON.parse(line)
  if (msg.type === "get_session_stats") return say({ type: "response", command: "get_session_stats", success: true, data: { session: n + 1 } })
  appendFileSync(`${dir}/prompts`, msg.message + "\n")
  if (word === "done") {
    const plan = `${process.cwd()}/.tasks/plan.md`
    const step = process.env.FAKE_PI_STEP
    writeFileSync(plan, readFileSync(plan, "utf8").replace(`${step}. [ ]`, `${step}. [x]`))
    finish()
  }
  if (word === "stop") finish()
  if (word === "hang") say({ type: "agent_start" })
  if (word === "gated") say({ type: "extension_ui_request", method: "notify", notifyType: "error", message: "STOP" })
  if (word === "die") { say({ type: "agent_start" }); process.exit(7) }
})
setInterval(() => {}, 1000)
JS
printf '#!/bin/sh\nexec node "%s/bin/pi.mjs" "$@"\n' "$work" > "$work/bin/pi"
chmod +x "$work/bin/pi"

# scenario <name> <plan-lines> <step> <sessions> <timeout> <resumes|-> <want-exit> <want-sessions>
# Leaves the case's directory in $d for its own further checks.
d=""
scenario() {
  local name="$1" plan="$2" step="$3" sessions="$4" timeout="$5" resumes="$6" want="$7" wantn="$8" got
  d="$work/$name"
  mkdir -p "$d/proj/.tasks" "$d/logs" "$d/fake"
  printf '# P\n\n## Steps\n\n%b' "$plan" > "$d/proj/.tasks/plan.md"
  if [ "$resumes" = - ]; then
    FAKE_PI_DIR="$d/fake" FAKE_PI_SESSIONS="$sessions" FAKE_PI_STEP="$step" PATH="$work/bin:$PATH" \
      bash "$runner" "$d/proj" .tasks/plan.md "$step" m "$d/logs" "$timeout"
  else
    BENCH_RESUMES="$resumes" FAKE_PI_DIR="$d/fake" FAKE_PI_SESSIONS="$sessions" FAKE_PI_STEP="$step" PATH="$work/bin:$PATH" \
      bash "$runner" "$d/proj" .tasks/plan.md "$step" m "$d/logs" "$timeout"
  fi
  got=$?
  [ "$got" = "$want" ] || note "$name: exit $got, wanted $want"
  local count; count="$(cat "$d/fake/sessions" 2>/dev/null || echo 0)"
  [ "$count" = "$wantn" ] || note "$name: $count session(s), wanted $wantn"
  grep -q "^step${step}_exit=$want$" "$d/logs/meta.env" || note "$name: meta.env has no step${step}_exit=$want: $(cat "$d/logs/meta.env")"
  grep -q "^step${step}_resumes=$((wantn - 1))$" "$d/logs/meta.env" || note "$name: meta.env has no step${step}_resumes=$((wantn - 1)): $(cat "$d/logs/meta.env")"
  grep -q "^step${step}_seconds=[0-9][0-9]*$" "$d/logs/meta.env" || note "$name: meta.env has no step${step}_seconds"
}
two='1. [x] one\n2. [ ] two\n'

# Ticked the first time: one session, and it asked for the step by number.
scenario first-time "$two" 2 "done" 10 - 0 1
grep -qx '/dev-implement .tasks/plan.md --step 2' "$d/fake/prompts" || note "first-time: prompt was $(cat "$d/fake/prompts")"
[ -s "$d/logs/step-2.jsonl" ] || note "first-time: no step-2.jsonl"
[ -e "$d/logs/step-2-retry1.jsonl" ] && note "first-time: a resume log exists"

# Unticked, then ticked: a second session, the README's --continue, its own log and stats.
scenario resumed "$two" 2 stop,done 10 - 0 2
[ "$(sed -n 2p "$d/fake/prompts")" = '/dev-implement .tasks/plan.md --continue' ] || note "resumed: second prompt was $(sed -n 2p "$d/fake/prompts")"
[ -s "$d/logs/step-2.jsonl" ] || note "resumed: the first log is gone"
[ -s "$d/logs/step-2-retry1.jsonl" ] || note "resumed: no step-2-retry1.jsonl"
[ -s "$d/logs/step-2-retry1.stats.json" ] || note "resumed: no step-2-retry1.stats.json"

# Unticked both times: it stops there, with no third session.
scenario still-unticked "$two" 2 stop,stop,done 10 - 0 2
grep -q '2. \[ \]' "$d/proj/.tasks/plan.md" || note "still-unticked: a third session ran"

# A timeout is a step not done: it gets the resume too.
scenario timed-out "$two" 2 hang,done 1 - 0 2

# Timed out twice: the last exit is the timeout.
scenario timed-out-twice "$two" 2 hang,hang 1 - 2 2

# Gated: the model never ran, and a new session would hit the same gate.
scenario gated "$two" 2 gated,done 10 - 3 1

# Pi itself failed: not something a fresh session of the model can fix.
scenario died "$two" 2 die,done 10 - 1 1

# An earlier step is the unfinished one: --continue would run that, not this.
scenario earlier-unticked '1. [ ] one\n2. [ ] two\n' 2 stop,done 10 - 0 1

# BENCH_RESUMES sets how many: none, as the earlier rows ran, or more.
scenario no-resumes "$two" 2 stop,done 10 0 0 1
scenario two-resumes "$two" 2 stop,stop,done 10 2 0 3
[ -s "$d/logs/step-2-retry2.jsonl" ] || note "two-resumes: no step-2-retry2.jsonl"

if [ "$fails" -gt 0 ]; then
  printf 'run-step: %s failure(s)\n' "$fails"
  exit 1
fi
printf 'run-step: a step ending unticked gets its fresh session, and nothing else does\n'
