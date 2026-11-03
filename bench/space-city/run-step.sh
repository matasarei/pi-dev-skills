#!/usr/bin/env bash
# One bench step on Pi: a session for the step, and when that ends with the step
# unticked, a fresh session to resume it. Used by run.sh.
#
#   run-step.sh <project> <task-file> <n> <model> <logs-dir> <timeout-seconds>
#
# A step used to get one session, so one bad session left uncommitted work that
# gated every later step. The README's recovery for that is a fresh session with
# --continue, and this is that, unattended. The later steps stay gated if the
# resume does not finish it either: each one builds on the last.
#
# Resumed only when this step is the first unticked one and the attempt ran to an
# end (driver exit 0) or to its timeout (2). Not when the start was gated (3): a new
# session meets the same gate. Not when Pi itself failed (1). And not when an
# earlier step is the unticked one: --continue would run that step instead of this.
#
# BENCH_RESUMES sets how many resumes a step may have, default 1; 0 is the
# one-attempt protocol of the first rows in results.md.
#
# Appends step<n>_seconds (all attempts), step<n>_exit (the last attempt's) and
# step<n>_resumes to <logs-dir>/meta.env. Logs: step-<n>.jsonl, step-<n>-retry<k>.jsonl.
# Exits with the last attempt's exit.

set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

proj="$1" task="$2" n="$3" model="$4" logs="$5" timeout="$6"
max="${BENCH_RESUMES:-1}"

# The first unticked step, read the way everything else reads a task file.
first_unticked() {
  local any=0
  grep -q '^## Steps' "$proj/$task" || any=1
  awk -v mode=list -v anywhere="$any" -f "$root/lib/steps.awk" "$proj/$task" |
    awk -F'|' '$2 != "x" { print $1; exit }'
}

attempt() {
  node "$here/pi-rpc.mjs" "$proj" "$model" "$1" "$logs/$2.jsonl" "$logs/$2.stats.json" "$timeout"
}

t0="$(date +%s)"
attempt "/dev-implement $task --step $n" "step-$n"
rc=$?
resumes=0
while [ "$resumes" -lt "$max" ] && { [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; } && [ "$(first_unticked)" = "$n" ]; do
  resumes=$((resumes + 1))
  printf 'bench: step %s unticked, resuming in a fresh session (%s of %s) ...\n' "$n" "$resumes" "$max"
  attempt "/dev-implement $task --continue" "step-$n-retry$resumes"
  rc=$?
done

printf 'step%s_seconds=%s\nstep%s_exit=%s\nstep%s_resumes=%s\n' \
  "$n" "$(( $(date +%s) - t0 ))" "$n" "$rc" "$n" "$resumes" >> "$logs/meta.env"
exit "$rc"
