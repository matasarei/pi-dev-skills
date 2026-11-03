#!/usr/bin/env bash
# The bench driver against a scripted Pi — run it from anywhere:
#
#   bash evals/bench/pi-rpc.sh
#
# A stand-in `pi` on PATH plays one sequence of RPC events, so this needs neither
# Pi nor a model. Each case asserts the driver's exit code and that it stayed for
# the events it had to see: quitting on the first agent_end killed Pi's own retry
# and scored a step on whatever the first attempt had left.
#
# Exits 0 when every case holds, 1 otherwise, naming each failure.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
driver="$root/bench/space-city/pi-rpc.mjs"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0
note() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

mkdir -p "$work/bin"
cat > "$work/bin/pi" <<'JS'
#!/usr/bin/env node
// Plays FAKE_PI_EVENTS, a JSON list: an event to print, or { "wait": ms } to pause,
// or { "die": code } to exit. Answers get_session_stats, as Pi does, once asked.
import { createInterface } from "node:readline"
const script = JSON.parse(process.env.FAKE_PI_EVENTS)
const play = async () => {
  for (const step of script) {
    if (step.wait) await new Promise((r) => setTimeout(r, step.wait))
    else if (step.die !== undefined) process.exit(step.die)
    else console.log(JSON.stringify(step))
  }
}
createInterface({ input: process.stdin }).on("line", (line) => {
  const msg = JSON.parse(line)
  if (msg.type === "prompt") play()
  if (msg.type === "get_session_stats") console.log(JSON.stringify({ type: "response", command: "get_session_stats", success: true, data: { toolCalls: 1 } }))
})
setInterval(() => {}, 1000)
JS
# An .mjs extension is what lets the stand-in use import without a package.json.
mv "$work/bin/pi" "$work/bin/pi.mjs"
printf '#!/bin/sh\nexec node "%s/bin/pi.mjs" "$@"\n' "$work" > "$work/bin/pi"
chmod +x "$work/bin/pi"

# case <name> <want-exit> <timeout-seconds> <events-json> [text the log must hold]...
check() {
  local name="$1" want="$2" timeout="$3" script="$4"
  shift 4
  local log="$work/$name.jsonl" stats="$work/$name.stats.json" got
  FAKE_PI_EVENTS="$script" PATH="$work/bin:$PATH" node "$driver" "$work" m p "$log" "$stats" "$timeout"
  got=$?
  [ "$got" = "$want" ] || note "$name: exit $got, wanted $want"
  local text
  for text in "$@"; do
    grep -q "$text" "$log" || note "$name: the log never got to $text"
  done
  if [ "$want" != 1 ]; then
    [ -s "$stats" ] || note "$name: no session stats were saved"
  fi
}

start='{"type":"agent_start"}'
failed='{"type":"agent_end","messages":[{"role":"assistant","stopReason":"error","errorMessage":"terminated"}]}'
retry='{"type":"auto_retry_start","attempt":1,"maxAttempts":3,"delayMs":100,"errorMessage":"terminated"}'
answer='{"type":"message_end","message":{"role":"assistant","content":"the retried answer"}}'
ended='{"type":"agent_end","messages":[{"role":"assistant","stopReason":"stop"}]}'
settled='{"type":"agent_settled","aborted":false}'

check plain 0 10 "[$start,$ended,$settled]" agent_settled

# The run the bench lost: a dropped stream, then Pi's retry. The answer comes after the first agent_end.
check retried 0 10 "[$start,$failed,$retry,{\"wait\":200},$start,$answer,{\"type\":\"auto_retry_end\",\"success\":true},$ended,$settled]" \
  'the retried answer' auto_retry_end agent_settled

# Retries used up: the failure stands, and the run is still over.
check gave-up 0 10 "[$start,$failed,{\"type\":\"auto_retry_end\",\"success\":false},$settled]" agent_settled

# A runaway stopped and nudged: the run settles aborted, and another starts straight
# after. The nudge's answer is the session's real end.
aborted='{"type":"agent_settled","aborted":true}'
nudged='{"type":"message_end","message":{"role":"assistant","content":"the nudged answer"}}'
check nudged 0 10 "[$start,$aborted,{\"wait\":100},$start,$nudged,$ended,$settled]" 'the nudged answer'

# Settled just before the limit, with the limit passing during the wait for another run:
# it finished, so it isn't a timeout.
check settled-at-limit 0 1 "[{\"wait\":700},$start,$ended,$settled]" agent_settled
grep -q bench_timeout "$work/settled-at-limit.jsonl" && note "settled-at-limit: counted as a timeout"

# A gated command notifies and never starts the agent.
check gated 3 10 '[{"type":"extension_ui_request","method":"notify","notifyType":"error","message":"STOP"}]' notify

# Nothing settles: the timeout still bounds it, retrying or not.
check timed-out 2 1 "[$start,$failed,$retry]" bench_timeout

# Pi dying mid-retry is a Pi failure, not a finished step.
check died 1 10 "[$start,$failed,$retry,{\"die\":7}]" auto_retry_start

if [ "$fails" -gt 0 ]; then
  printf 'pi-rpc: %s failure(s)\n' "$fails"
  exit 1
fi
printf 'pi-rpc: every case holds\n'
