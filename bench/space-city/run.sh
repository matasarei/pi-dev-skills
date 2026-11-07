#!/usr/bin/env bash
# One benchmark run: the space-city funds plan, built step by step by Pi with
# these skills, headless, then scored.
#
#   bash bench/space-city/run.sh pi
#   bash bench/space-city/run.sh pi --steps 1      # only step 1 (or 1-2, 2-3)
#
# Everything a result depends on is pinned below and checked before anything
# runs: the target commit, Pi's version, the model and its window, and an idle
# timeout that clears the longest reply (idle-check.mjs).
# A mismatch stops the run instead of recording a result against the wrong
# thing. The target is a fresh clone with its remote removed, so nothing the
# model does can reach GitHub. Each step is /dev-implement <plan> --step N in
# a new session, as the README's /new rule says. A step left unticked gets one
# more session with --continue (run-step.sh; BENCH_RESUMES sets how many).
#
# Logs go to bench/space-city/runs/<stamp>-pi/ (git-ignored); the
# scored row is printed and appended to bench/space-city/results.md.

set -u

# --- the pins ---------------------------------------------------------------
SPACE_CITY_URL="https://github.com/matasarei/space-city.git"
SPACE_CITY_SHA="ec643a375175d7d734e262309072a3ff0adbd650"
PI_VERSION="1.5.0"
LMS_MODEL="prism-ml/bonsai-27b"
MODEL="lmstudio/$LMS_MODEL"
CONTEXT=131072
IMAGE="node:lts-alpine"
STEP_TIMEOUT="${BENCH_STEP_TIMEOUT:-1800}"
# -----------------------------------------------------------------------------

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
die() { printf 'bench: %s\n' "$1" >&2; exit 1; }

# "pi" names the harness in the logs and the results row (pi@<commit>).
harness="${1:-}"
[ "$harness" = pi ] || die "usage: run.sh pi [--steps 1-3]"
first=1 last=3
if [ "${2:-}" = "--steps" ]; then
  case "${3:-}" in
    [1-3]) first="$3" last="$3" ;;
    [1-3]-[1-3]) first="${3%-*}" last="${3#*-}" ;;
    *) die "--steps takes 1, 2, 3 or a range such as 1-2" ;;
  esac
fi

# --- preflight: refuse to measure the wrong thing ---------------------------
for tool in git node docker curl; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
docker info >/dev/null 2>&1 || die "docker is not running"
curl -s -m 5 http://127.0.0.1:1234/v1/models >/dev/null || die "LM Studio is not serving on :1234 (lms server start)"
# LM Studio loads a model on first request at its default window when it is not
# loaded already, which would quietly bench a smaller context. Require it loaded
# at the pinned one.
lms="$HOME/.lmstudio/bin/lms"
if [ -x "$lms" ]; then
  "$lms" ps 2>/dev/null | awk -v m="$LMS_MODEL" -v c="$CONTEXT" '$1 == m && $0 ~ (" " c " ") { ok = 1 } END { exit !ok }' \
    || die "$LMS_MODEL is not loaded at $CONTEXT (lms load $LMS_MODEL --context-length $CONTEXT -y)"
else
  printf 'bench: no lms CLI, so the loaded window is not checked — make sure it is %s\n' "$CONTEXT" >&2
fi

command -v pi >/dev/null 2>&1 || die "pi is not installed"
[ "$(pi --version 2>/dev/null)" = "$PI_VERSION" ] || die "pi is $(pi --version 2>/dev/null), the pin is $PI_VERSION"
pi list 2>/dev/null | grep -q "pi-dev-skills" || die "pi-dev-skills is not installed in Pi (pi install $root)"
http_idle_ms="$(node "$here/idle-check.mjs")" || die "Pi's idle timeout would drop long tool calls, so the run would not measure the skills"
# Recorded, not pinned: a runaway tool call costs less at a lower limit, so a row depends on it.
max_tokens="$(node -e '
  const { join } = require("node:path")
  const dir = process.env.PI_CODING_AGENT_DIR || join(require("node:os").homedir(), ".pi", "agent")
  const { providers } = JSON.parse(require("node:fs").readFileSync(join(dir, "models.json"), "utf8"))
  console.log(Object.values(providers).flatMap((p) => p.models ?? []).find((m) => m.id === process.argv[1]).maxTokens ?? "unknown")
' "$LMS_MODEL" 2>/dev/null)" || max_tokens=unknown
harness_rev="$(git -C "$root" rev-parse --short HEAD)"
git -C "$root" diff --quiet HEAD -- pi lib skills || harness_rev="$harness_rev+dirty"

# --- a fresh target at the pinned commit -------------------------------------
stamp="$(date +%Y%m%d-%H%M%S)"
logs="$here/runs/$stamp-$harness"
work="${BENCH_WORK:-$(mktemp -d "${TMPDIR:-/tmp}/bench-space-city.XXXXXX")}"
proj="$work/space-city"
mkdir -p "$logs"
printf 'bench: %s, target in %s, logs in %s\n' "$harness" "$proj" "$logs"

git clone -q "$SPACE_CITY_URL" "$proj" || die "clone failed"
git -C "$proj" checkout -q -B main "$SPACE_CITY_SHA" || die "no commit $SPACE_CITY_SHA"
git -C "$proj" remote remove origin
printf '.tasks/\n.devskills/\n.bench-*\n' >> "$proj/.git/info/exclude"
# Installed inside the image the profile runs tests in: host-built native
# modules (rollup, esbuild) do not load there.
docker run --rm -v "$proj":/app -w /app "$IMAGE" npm ci --no-audit --no-fund >"$logs/npm-ci.log" 2>&1 || die "npm ci failed, see $logs/npm-ci.log"
mkdir -p "$proj/.tasks"
cp "$here/plan.md" "$proj/.tasks/funds.md"

{
  printf 'harness=%s\nharness_rev=%s\nmodel=%s\ncontext=%s\nsteps=%s-%s\n' "$harness" "$harness_rev" "$MODEL" "$CONTEXT" "$first" "$last"
  printf 'target=%s\nimage=%s\n' "$SPACE_CITY_SHA" "$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null)"
  printf 'http_idle_ms=%s\nmax_tokens=%s\n' "$http_idle_ms" "$max_tokens"
} > "$logs/meta.env"

# --- the steps: one session each, and one more for a step left unticked ------
for n in $(seq "$first" "$last"); do
  printf 'bench: step %s ...\n' "$n"
  bash "$here/run-step.sh" "$proj" .tasks/funds.md "$n" "$MODEL" "$logs" "$STEP_TIMEOUT"
done

bash "$here/score.sh" "$proj" "$logs"
