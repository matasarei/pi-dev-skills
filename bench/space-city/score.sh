#!/usr/bin/env bash
# Score one finished run — run.sh calls it; run it by hand to re-score:
#
#   bash bench/space-city/score.sh <target-dir> <logs-dir>
#
# Facts only, read from the tree and the logs, never from what the model said:
#   - the hidden acceptance tests, one file per step, copied in for the count
#     and removed again (the model never saw them);
#   - every other test in the suite that fails, and tsc;
#   - files changed outside the plan's Create:/Modify: paths;
#   - steps ticked, commits, step branches, guard refusals, TEST PASS lines;
#   - wall time per step and tokens, from the harness's own records.
# The tests run in a copy of the target with the pinned commit's lock file and a
# fresh install in the container, so a model that broke node_modules or the lock
# file still gets its code scored; what it changed is read from the original.
# Prints one markdown row and appends it to results.md (BENCH_RESULTS to change
# where, /dev/null when re-scoring a run that already has its row).

set -u

here="$(cd "$(dirname "$0")" && pwd)"
proj="${1:?usage: score.sh <target-dir> <logs-dir>}"
logs="${2:?usage: score.sh <target-dir> <logs-dir>}"
[ -f "$logs/meta.env" ] || { printf 'score: no meta.env in %s\n' "$logs" >&2; exit 1; }
# shellcheck disable=SC1091
. "$logs/meta.env"
: "${harness:?meta.env has no harness}" "${harness_rev:?}" "${steps:?}" "${target:?}"
IMAGE="node:lts-alpine"
results="${BENCH_RESULTS:-$here/results.md}"

# --- a copy to score in: the model's code, the pinned dependencies -------------
copy="$(mktemp -d "${TMPDIR:-/tmp}/bench-score.XXXXXX")"
trap 'rm -rf "$copy"' EXIT INT TERM
rsync -a --exclude node_modules "$proj"/ "$copy"/ || { printf 'score: could not copy %s\n' "$proj" >&2; exit 1; }
git -C "$copy" checkout -q "$target" -- package-lock.json
box() { docker run --rm -v "$copy":/app -w /app "$IMAGE" "$@"; }
box npm ci --no-audit --no-fund >"$logs/score-install.log" 2>&1 \
  || { printf 'score: npm ci failed in the copy, see %s\n' "$logs/score-install.log" >&2; exit 1; }

# --- the hidden tests, and the rest of the suite -----------------------------
cp "$here"/acceptance/bench-*.test.ts "$copy/src/__tests__/"
box npx vitest run --reporter=json --outputFile=/app/.bench-vitest.json >"$logs/score-vitest.log" 2>&1
tests="$(node -e '
  let r; try { r = require(process.argv[1]) } catch { console.log("? ? ? ?"); process.exit() }
  const count = (f) => {
    const t = r.testResults.filter((x) => x.name.includes(f))
    const all = t.flatMap((x) => x.assertionResults)
    const pass = all.filter((a) => a.status === "passed").length
    // A file that did not load has no assertions; its tests are all missed.
    return `${pass}/${f === "bench-costs" ? 14 : f === "bench-funds" ? 7 : 5}`
  }
  const other = r.testResults.filter((x) => !x.name.includes("bench-"))
  const failing = other.flatMap((x) => x.assertionResults).filter((a) => a.status !== "passed").length
    + other.filter((x) => x.status === "failed" && x.assertionResults.length === 0).length
  console.log(count("bench-costs"), count("bench-funds"), count("bench-refund"), failing)
' "$copy/.bench-vitest.json")"
read -r acc1 acc2 acc3 failing <<EOF
$tests
EOF
if box npx tsc --noEmit >"$logs/score-tsc.log" 2>&1; then tsc=clean; else tsc="$(grep -c 'error TS' "$logs/score-tsc.log") errors"; fi

# --- scope: what changed against the pinned commit ---------------------------
allowed=" src/core/costs.ts src/core/cityManager.ts src/__tests__/costs.test.ts src/__tests__/cityManager.test.ts "
changed="$( { git -C "$proj" diff --name-only "$target"; git -C "$proj" ls-files --others --exclude-standard; } | sort -u)"
outside=""
for f in $changed; do
  case "$allowed" in *" $f "*) ;; *) outside="$outside $f" ;; esac
done
outside="${outside# }"

ticked="$(grep -cE '^[0-9]+\. \[x\]' "$proj/.tasks/funds.md" 2>/dev/null)" || ticked=0
commits="$(git -C "$proj" rev-list --count "$target..HEAD")"
branches="$(git -C "$proj" branch --list 'step/*' | wc -l | tr -d ' ')"
# One per tool result: Pi repeats a result's text in several events of one call,
# so counting the text across every line counts each refusal four or five times.
read -r refusals passes <<EOF
$(node -e '
  const fs = require("fs"), dir = process.argv[1]
  let r = 0, p = 0
  for (const f of fs.readdirSync(dir).filter((f) => /^step-\d+\.jsonl$/.test(f))) {
    for (const l of fs.readFileSync(`${dir}/${f}`, "utf8").split("\n")) {
      let e; try { e = JSON.parse(l) } catch { continue }
      if (e.type !== "tool_execution_end") continue
      const text = e.result?.content?.[0]?.text ?? ""
      if (e.isError && text.startsWith("dev-guard refuses")) r++
      if (text.startsWith("TEST PASS")) p++
    }
  }
  console.log(r, p)
' "$logs")
EOF

# --- time and tokens ----------------------------------------------------------
seconds=0
for n in 1 2 3; do
  eval "s=\${step${n}_seconds:-}"
  # shellcheck disable=SC2154
  [ -n "$s" ] && seconds=$((seconds + s))
done
tokens="$(node -e '
  const fs = require("fs"), dir = process.argv[1], harness = process.argv[2]
  let i = 0, o = 0, found = false
  for (const f of fs.readdirSync(dir)) {
    try {
      if (harness === "pi" && f.endsWith(".stats.json")) {
        const t = JSON.parse(fs.readFileSync(`${dir}/${f}`)).tokens
        if (t) { i += t.input ?? 0; o += t.output ?? 0; found = true }
      }
      if (harness === "opencode" && f.endsWith(".export.json")) {
        // Sum every message that records its own tokens.
        const walk = (v) => {
          if (!v || typeof v !== "object") return
          if (v.tokens && typeof v.tokens.input === "number") { i += v.tokens.input; o += v.tokens.output ?? 0; found = true; return }
          for (const k of Object.keys(v)) walk(v[k])
        }
        walk(JSON.parse(fs.readFileSync(`${dir}/${f}`)))
      }
    } catch {}
  }
  console.log(found ? `${i}/${o}` : "?")
' "$logs" "$harness")"

row="| $(date +%Y-%m-%d) | $harness@$harness_rev | $steps | $ticked | $acc1 | $acc2 | $acc3 | $failing | $tsc | ${outside:-none} | $commits / $branches | $refusals | $passes | $seconds | $tokens |"
printf '%s\n' "$row" | tee -a "$results"
