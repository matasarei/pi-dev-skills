#!/usr/bin/env bash
# The bench's check on Pi's idle timeout — run it from anywhere:
#
#   bash evals/bench/idle-check.sh
#
# run.sh refuses to start when this fails, so a row can't be recorded with long
# tool calls dropping at Pi's default. Each case has its own PI_CODING_AGENT_DIR,
# so this needs neither Pi nor a model. Asserted: the exit, what stdout says for
# meta.env, and that a refusal names the setting.
#
# Exits 0 when every case holds, 1 otherwise, naming each failure.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
check="$root/bench/space-city/idle-check.mjs"
command -v node >/dev/null 2>&1 || { printf 'idle-check: node is required — not installed\n' >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
fails=0
note() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }

# scenario <name> <settings.json content, or - for no file> <want-exit> <want-stdout>
scenario() {
  local name="$1" content="$2" want="$3" wantout="$4" out err got
  mkdir -p "$work/$name"
  [ "$content" = - ] || printf '%s' "$content" > "$work/$name/settings.json"
  out="$(PI_CODING_AGENT_DIR="$work/$name" node "$check" 2>"$work/$name/err")"
  got=$?
  err="$(cat "$work/$name/err")"
  [ "$got" = "$want" ] || note "$name: exit $got, wanted $want: $err"
  [ "$out" = "$wantout" ] || note "$name: stdout '$out', wanted '$wantout'"
  if [ "$want" = 0 ]; then
    [ -z "$err" ] || note "$name: said something on a pass: $err"
  else
    case "$err" in *httpIdleTimeoutMs*) ;; *) note "$name: the refusal does not name the setting: $err" ;; esac
    case "$err" in *"$work/$name/settings.json"*) ;; *) note "$name: the refusal does not name the file: $err" ;; esac
  fi
}

scenario no-file - 1 ""
scenario no-key '{"packages":[]}' 1 ""
scenario too-low '{"httpIdleTimeoutMs":300000}' 1 ""
scenario just-under '{"httpIdleTimeoutMs":1199999}' 1 ""
scenario invalid '{"httpIdleTimeoutMs":"soon"}' 1 ""
scenario broken '{"httpIdleTimeoutMs":' 1 ""
scenario not-an-object '[1]' 1 ""
scenario enough '{"httpIdleTimeoutMs":1200000}' 0 1200000
scenario above '{"packages":[],"httpIdleTimeoutMs":3600000}' 0 3600000
scenario a-string '{"httpIdleTimeoutMs":"1200000"}' 0 1200000
scenario disabled '{"httpIdleTimeoutMs":"disabled"}' 0 0
scenario zero '{"httpIdleTimeoutMs":0}' 0 0

# With no PI_CODING_AGENT_DIR it reads Pi's default directory, under HOME.
mkdir -p "$work/home/.pi/agent"
printf '{"httpIdleTimeoutMs":1200000}' > "$work/home/.pi/agent/settings.json"
out="$(env -u PI_CODING_AGENT_DIR HOME="$work/home" node "$check" 2>&1)" || note "the default directory: failed: $out"
[ "$out" = 1200000 ] || note "the default directory: stdout '$out'"

# run.sh needs Docker and a model to reach its steps, so here only that it uses the check.
run="$root/bench/space-city/run.sh"
grep -q 'http_idle_ms="$(node "$here/idle-check.mjs")" || die' "$run" || note "run.sh does not refuse on the check"
grep -q "http_idle_ms=%s" "$run" || note "run.sh does not record the timeout in meta.env"

if [ "$fails" -gt 0 ]; then
  printf 'idle-check: %s failure(s)\n' "$fails"
  exit 1
fi
printf 'idle-check: the bench starts only with an idle timeout that clears the longest reply\n'
