#!/usr/bin/env bash
# One benchmark run: the space-city funds plan, built step by step by one
# harness, headless, then scored.
#
#   bash bench/space-city/run.sh pi
#   bash bench/space-city/run.sh opencode
#   bash bench/space-city/run.sh pi --steps 1      # only step 1 (or 1-2, 2-3)
#
# Everything a result depends on is pinned below and checked before anything
# runs: the target commit, the harness versions, the model and its window.
# A mismatch stops the run instead of recording a result against the wrong
# thing. The target is a fresh clone with its remote removed, so nothing the
# model does can reach GitHub. Each step is /dev-implement <plan> --step N in
# a new session, as the README's /new rule says.
#
# Logs go to bench/space-city/runs/<stamp>-<harness>/ (git-ignored); the
# scored row is printed and appended to bench/space-city/results.md.

set -u

# --- the pins ---------------------------------------------------------------
SPACE_CITY_URL="https://github.com/matasarei/space-city.git"
SPACE_CITY_SHA="ec643a375175d7d734e262309072a3ff0adbd650"
OPENCODE_SKILLS_SHA="9365f31bc611037dfd1c8bdfc25bb254ac10be7a"
OPENCODE_VERSION="1.18.20"
PI_VERSION="1.5.0"
LMS_MODEL="prism-ml/bonsai-27b"
MODEL="lmstudio/$LMS_MODEL"
CONTEXT=131072
STEP_TIMEOUT="${BENCH_STEP_TIMEOUT:-1800}"
IMAGE="node:lts-alpine"
# -----------------------------------------------------------------------------

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
die() { printf 'bench: %s\n' "$1" >&2; exit 1; }

harness="${1:-}"
case "$harness" in pi|opencode) ;; *) die "usage: run.sh <pi|opencode> [--steps 1-3]" ;; esac
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

if [ "$harness" = pi ]; then
  command -v pi >/dev/null 2>&1 || die "pi is not installed"
  [ "$(pi --version 2>/dev/null)" = "$PI_VERSION" ] || die "pi is $(pi --version 2>/dev/null), the pin is $PI_VERSION"
  pi list 2>/dev/null | grep -q "pi-dev-skills" || die "pi-dev-skills is not installed in Pi (pi install $root)"
  harness_rev="$(git -C "$root" rev-parse --short HEAD)"
  git -C "$root" diff --quiet HEAD -- pi lib skills || harness_rev="$harness_rev+dirty"
else
  command -v opencode >/dev/null 2>&1 || die "opencode is not installed"
  [ "$(opencode --version 2>/dev/null)" = "$OPENCODE_VERSION" ] || die "opencode is $(opencode --version 2>/dev/null), the pin is $OPENCODE_VERSION"
  oc="${OPENCODE_SKILLS_DIR:-$root/../opencode-skills}"
  git -C "$oc" cat-file -e "$OPENCODE_SKILLS_SHA" 2>/dev/null || die "no opencode-skills checkout with $OPENCODE_SKILLS_SHA at $oc (set OPENCODE_SKILLS_DIR)"
  # The installed copy is what OpenCode runs; it has to be the pinned commit's.
  stale=""
  for f in $(git -C "$oc" ls-tree -r --name-only "$OPENCODE_SKILLS_SHA" -- skills lib); do
    case "$f" in
      skills/*/SKILL.md) dest="$HOME/.config/opencode/$f" ;;
      lib/dev-guard.js) dest="$HOME/.config/opencode/plugins/dev-guard.js" ;;
      lib/*) dest="$HOME/.config/opencode/dev-lib/${f#lib/}" ;;
      *) continue ;;
    esac
    git -C "$oc" show "$OPENCODE_SKILLS_SHA:$f" | cmp -s - "$dest" || stale="$stale ${f}"
  done
  [ -z "$stale" ] || die "the installed opencode-skills is not $OPENCODE_SKILLS_SHA (differs:$stale). Reinstall: git -C $oc worktree add /tmp/oc-pin $OPENCODE_SKILLS_SHA && (cd /tmp/oc-pin && ./install.sh)"
  harness_rev="${OPENCODE_SKILLS_SHA:0:7}"
fi

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
} > "$logs/meta.env"

# --- the steps, one session each --------------------------------------------
for n in $(seq "$first" "$last"); do
  printf 'bench: step %s ...\n' "$n"
  t0="$(date +%s)"
  if [ "$harness" = pi ]; then
    node "$here/pi-rpc.mjs" "$proj" "$MODEL" "/dev-implement .tasks/funds.md --step $n" \
      "$logs/step-$n.jsonl" "$logs/step-$n.stats.json" "$STEP_TIMEOUT"
    rc=$?
  else
    (cd "$proj" && perl -e 'alarm shift; exec @ARGV' "$STEP_TIMEOUT" \
      opencode run --command dev-implement --format json -m "$MODEL" ".tasks/funds.md --step $n") \
      >"$logs/step-$n.jsonl" 2>"$logs/step-$n.stderr"
    rc=$?
    sid="$(grep -o '"sessionID":"[^"]*"' "$logs/step-$n.jsonl" | head -1 | cut -d'"' -f4)"
    [ -n "$sid" ] && opencode export "$sid" >"$logs/step-$n.export.json" 2>/dev/null
  fi
  printf 'step%s_seconds=%s\nstep%s_exit=%s\n' "$n" "$(( $(date +%s) - t0 ))" "$n" "$rc" >> "$logs/meta.env"
done

bash "$here/score.sh" "$proj" "$logs"
