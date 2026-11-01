#!/usr/bin/env bash
# Detect this repository's toolchain once and cache it as JSON.
#
# Every dev skill starts by running this. It exists so the model never has to
# *decide* how to test, lint or run the project — the answer is computed here,
# deterministically, and handed over as data.
#
#   profile.sh              print the cached profile, detecting it if absent
#   profile.sh --reprofile  discard the cache and detect again
#   profile.sh --path       print the cache path and nothing else
#
# Output is JSON on stdout. A field that does not apply is null, and null is a
# real answer: a repository with no test command must not be given one.

set -u

CACHE=".devskills/profile.json"

case "${1:-}" in
  --path) echo "$CACHE"; exit 0 ;;
  --reprofile) rm -f "$CACHE" ;;
esac

# The window belongs to the model, not the repository: a cached profile still
# reports the window DEV_SKILLS_CONTEXT names now, so a model switched since the
# cache was written is sized for the window it has.
if [ -f "$CACHE" ] && [ "${1:-}" != "--reprofile" ]; then
  case "${DEV_SKILLS_CONTEXT:-}" in
    ''|*[!0-9]*) cat "$CACHE" ;;
    *) sed "s/\"contextTokens\":[[:space:]]*[0-9]*/\"contextTokens\": $DEV_SKILLS_CONTEXT/" "$CACHE" ;;
  esac
  exit 0
fi

# ---------------------------------------------------------------- helpers ---

# JSON string escape. Enough for paths and commands; these are not arbitrary text.
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g'; }

# Emit "key": value — quoted unless the value is literally null/true/false.
kv() {
  case "$2" in
    null|true|false) printf '  "%s": %s' "$1" "$2" ;;
    *) printf '  "%s": "%s"' "$1" "$(esc "$2")" ;;
  esac
}

have() { command -v "$1" >/dev/null 2>&1; }

# A value read out of a repository file ends up inside a command string that
# something later runs, so it must not be able to *be* a command. composer.json
# is part of the checkout, and `"vendor-dir": "vend; touch PWNED"` used to reach
# the test command verbatim. Anything that is not a plain relative path is
# refused and the fallback used instead; REJECTED records it, because silently
# substituting a default would hide a real misconfiguration too.
REJECTED=""
# Assigns through printf -v rather than printing: a command substitution would
# run this in a subshell and REJECTED would not survive it.
safe_path() { # safe_path <varname> <value> <fallback> <what it was>
  case "$2" in
    ""|*[!A-Za-z0-9._/-]*|/*|*..*)
      # Truncated: notes are read into the model's context, and this value came
      # out of the repository. Enough to recognise it, not enough to instruct.
      [ -n "$2" ] && REJECTED="${REJECTED:+$REJECTED; }$4 (starting '$(printf '%.20s' "$2")') is not a plain relative path — using '$3'"
      printf -v "$1" '%s' "$3" ;;
    *) printf -v "$1" '%s' "$2" ;;
  esac
}

# ------------------------------------------------------------- 0 platform ---

case "$(uname -s 2>/dev/null || echo unknown)" in
  Darwin) PLATFORM=macos ;;
  Linux)  PLATFORM=linux ;;
  MINGW*|MSYS*|CYGWIN*)
    # Native Windows is not supported. Refusing here is deliberate: under a POSIX
    # translation layer these scripts mostly work, and "mostly" is the problem —
    # container mounts land in the wrong place and a false pass reads like a real
    # one. WSL is a real Linux kernel and needs none of the special cases.
    echo "Native Windows (Git Bash / MSYS / Cygwin) is not supported." >&2
    echo "Run Pi inside WSL and install there — everything works as on Linux." >&2
    echo "Keep repositories in the WSL filesystem, not under /mnt/c, or git will be slow." >&2
    exit 78
    ;;
  *) PLATFORM=unknown ;;
esac

# ---------------------------------------------------------- 1 base branch ---

BASE="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/origin/##')"
if [ -z "$BASE" ]; then
  for candidate in main master; do
    if git show-ref --verify --quiet "refs/heads/$candidate" 2>/dev/null; then BASE="$candidate"; break; fi
  done
fi
[ -z "$BASE" ] && BASE="main"

# -------------------------------------------------------- 2 standards doc ---

STANDARDS=null
for f in AGENTS.md CLAUDE.md CONTRIBUTING.md README.md; do
  [ -f "$f" ] && { STANDARDS="$f"; break; }
done

# --------------------------------------------------------------- 3 family ---

FAMILY=other
LANGUAGE=null

if [ -f version.php ] && grep -qs 'plugin->component' version.php; then
  FAMILY=moodle-plugin
elif [ -d wp-content ] || { [ -f functions.php ] && [ -f style.css ]; }; then
  FAMILY=cms
elif [ -f composer.json ] && { [ -d public ] || [ -d web ] || [ -d app ] || [ -d application ] || [ -f artisan ] || [ -f bin/console ] || [ -f run ]; }; then
  FAMILY=php-app
elif [ -f composer.json ] && grep -qs '"type"[[:space:]]*:[[:space:]]*"library"' composer.json; then
  FAMILY=php-library
elif [ -f composer.json ] && [ -d src ] && [ -d tests ]; then
  FAMILY=php-library
elif [ -f composer.json ]; then
  FAMILY=php-app
elif [ -f pyproject.toml ] || [ -f requirements.txt ]; then
  FAMILY=python-app
elif [ -f package.json ]; then
  FAMILY=node
fi

# Language and version, read from the project's own declaration rather than the host.
case "$FAMILY" in
  moodle-plugin|cms|php-app|php-library)
    PHPREQ="$(grep -os '"php"[[:space:]]*:[[:space:]]*"[^"]*"' composer.json 2>/dev/null | head -1 | sed 's/.*"php"[[:space:]]*:[[:space:]]*"//; s/"$//')"
    [ -n "$PHPREQ" ] && LANGUAGE="PHP $PHPREQ" || LANGUAGE="PHP"
    ;;
  python-app)
    # Anchor on the opening quote of the value. A bare `s/.*"//` is greedy and eats
    # through the closing quote instead, leaving nothing.
    PYREQ="$(grep -os 'requires-python[[:space:]]*=[[:space:]]*"[^"]*"' pyproject.toml 2>/dev/null | head -1 | sed 's/.*=[[:space:]]*"//; s/"$//')"
    [ -n "$PYREQ" ] && LANGUAGE="Python $PYREQ" || LANGUAGE="Python"
    ;;
  node) LANGUAGE="Node" ;;
esac

# ------------------------------------------------------------------ 4 exec ---
#
# Container first, on every platform — the project targets a specific runtime and
# the host's is often a different one. Host is a fallback, and it is recorded as
# such so a green run against the wrong version is never reported as a pass.

EXEC_KIND=host
EXEC_PREFIX=""
EXEC_NOTE=null

COMPOSE_FILE=""
for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
  [ -f "$f" ] && { COMPOSE_FILE="$f"; break; }
done

docker_up() { have docker && docker info >/dev/null 2>&1; }

if ! docker_up; then
  EXEC_NOTE="Docker not available or daemon not running; falling back to the host toolchain."
elif [ -n "$COMPOSE_FILE" ]; then
  # Target runtime binary expected in the application container
  RUNTIME_BIN=""
  case "$FAMILY" in
    moodle-plugin|cms|php-app|php-library) RUNTIME_BIN="php" ;;
    python-app) RUNTIME_BIN="python" ;;
    node) RUNTIME_BIN="node" ;;
  esac

  is_infra_svc() {
    case "$1" in
      mysql|mariadb|postgres|postgresql|db|database|redis|memcached|mongo|mongodb|elasticsearch|opensearch|rabbitmq|mailhog|mailer|minio|nginx|caddy|traefik|proxy)
        return 0
        ;;
      *)
        return 1
        ;;
    esac
  }

  # Prefer an application service (e.g. app, php, fpm, web, api, backend, workspace).
  SERVICES="$(docker compose config --services 2>/dev/null || true)"
  SVC=""
  CANDIDATE_OFFLINE=""
  for want in app php fpm php-fpm web api backend workspace server webserver; do
    for s in $SERVICES; do
      if [ "$s" = "$want" ]; then
        if docker compose ps --status running 2>/dev/null | grep -qs "$s"; then
          if [ -z "$RUNTIME_BIN" ] || docker compose exec -T "$s" which "$RUNTIME_BIN" >/dev/null 2>&1; then
            SVC="$s"
            break 2
          fi
        else
          [ -z "$CANDIDATE_OFFLINE" ] && CANDIDATE_OFFLINE="$s"
        fi
      fi
    done
  done

  # If no candidate matched, check any running non-infra service that has the runtime
  if [ -z "$SVC" ] && [ -n "$RUNTIME_BIN" ]; then
    for s in $SERVICES; do
      if ! is_infra_svc "$s" && docker compose ps --status running 2>/dev/null | grep -qs "$s"; then
        if docker compose exec -T "$s" which "$RUNTIME_BIN" >/dev/null 2>&1; then
          SVC="$s"
          break
        fi
      fi
    done
  fi

  # Fall back to candidate service if containers are offline, or first non-infra service
  if [ -z "$SVC" ]; then
    if [ -n "$CANDIDATE_OFFLINE" ]; then
      SVC="$CANDIDATE_OFFLINE"
    else
      for s in $SERVICES; do
        if ! is_infra_svc "$s"; then
          SVC="$s"
          break
        fi
      done
    fi
  fi

  safe_path SVC "$SVC" "" "compose service name"
  if [ -n "$SVC" ] && ! is_infra_svc "$SVC"; then
    EXEC_KIND=compose
    EXEC_PREFIX="docker compose exec -T $SVC"
    if ! docker compose ps --status running 2>/dev/null | grep -qs "$SVC"; then
      EXEC_NOTE="Service '$SVC' is not running; use 'docker compose run --rm $SVC' or start it first."
    fi
  else
    EXEC_NOTE="Compose file found, but no application service containing '$RUNTIME_BIN' was identified; falling back to host."
  fi
fi

if [ "$EXEC_KIND" = "host" ] && docker_up && [ -z "$COMPOSE_FILE" ]; then
  # No compose file. Infer an image from the language, then PROVE the bind mount
  # works before storing it. A mount can succeed and still be empty — commands
  # then run, find nothing, and report something that looks like a result.
  IMAGE=""
  case "$FAMILY" in
    moodle-plugin|cms|php-app|php-library) IMAGE="composer:lts" ;;
    python-app) IMAGE="python:3-slim" ;;
    node) IMAGE="node:lts-alpine" ;;
  esac
  # Probe with any file we know is here. It must not be the standards doc: that can
  # legitimately be absent, and a repository without one would then never get an
  # image prefix for a reason that has nothing to do with Docker.
  PROBE=""
  for p in "$STANDARDS" composer.json package.json pyproject.toml version.php .gitignore; do
    [ "$p" != "null" ] && [ -f "$p" ] && { PROBE="$p"; break; }
  done

  if [ -n "$IMAGE" ] && [ -n "$PROBE" ]; then
    if docker run --rm -v "${PWD}":/app -w /app "$IMAGE" \
         ls "/app/$PROBE" >/dev/null 2>&1; then
      EXEC_KIND=image
      EXEC_PREFIX="docker run --rm -v \"\${PWD}\":/app -w /app $IMAGE"
    else
      EXEC_NOTE="Bind mount into $IMAGE could not see /app/$PROBE — the daemon is probably remote. Using the host."
    fi
  fi
fi

if [ "$EXEC_KIND" = "host" ] && [ "$EXEC_NOTE" = "null" ]; then
  EXEC_NOTE="No container runtime resolved; commands run against this machine's toolchain, which may not be the version the project targets."
fi

# Wrap a project command in the resolved prefix.
wrap() { [ -n "$EXEC_PREFIX" ] && printf '%s %s' "$EXEC_PREFIX" "$1" || printf '%s' "$1"; }

# ------------------------------------------ 5 install / lint / test / build ---
#
# Read these out of the repository rather than inventing them. CI is the most
# reliable source: whatever the workflow runs is the real command.

INSTALL=null; LINT=null; TEST=null; TEST_SCOPED=null; BUILD=null

# PHPUnit — check composer.json for a non-default vendor-dir before assuming vendor/.
if [ -f phpunit.xml ] || [ -f phpunit.xml.dist ]; then
  VENDOR="$(grep -os '"vendor-dir"[[:space:]]*:[[:space:]]*"[^"]*"' composer.json 2>/dev/null | head -1 | sed 's/.*"vendor-dir"[[:space:]]*:[[:space:]]*"//; s/"$//')"
  safe_path VENDOR "$VENDOR" vendor "composer.json vendor-dir"
  if [ -f "$VENDOR/bin/phpunit" ] || [ ! -d "$VENDOR" ]; then
    TEST="$(wrap "$VENDOR/bin/phpunit")"
    TEST_SCOPED="$(wrap "$VENDOR/bin/phpunit --filter {name}")"
  fi
fi

# pytest
if [ -f pytest.ini ] || [ -f tests/conftest.py ] || [ -f conftest.py ] || grep -qs '\[tool.pytest' pyproject.toml 2>/dev/null; then
  TEST="$(wrap "pytest")"
  TEST_SCOPED="$(wrap "pytest -k {name}")"
fi

# package.json scripts
if [ -f package.json ]; then
  grep -qs '"test"[[:space:]]*:' package.json && [ "$TEST" = "null" ] && TEST="$(wrap "npm test")"
  # A scoped run for a node --test suite, with npm test still the runner. node
  # --test ignores a name filter given after its test files, which is where
  # `npm test --` appends one, so the filter travels in NODE_OPTIONS instead and
  # nothing read out of package.json reaches the command. Only node --test: no
  # other runner's filter behind npm test has been proved here, so it stays null.
  if [ "$TEST" = "$(wrap "npm test")" ] && grep -qsE '"test"[[:space:]]*:[[:space:]]*"node --test' package.json; then
    TEST_SCOPED="$(wrap "env NODE_OPTIONS=--test-name-pattern={name} npm test")"
  fi
  grep -qs '"build"[[:space:]]*:' package.json && BUILD="$(wrap "npm run build")"
  grep -qs '"lint"[[:space:]]*:' package.json && LINT="$(wrap "npm run lint")"
fi

# Install
if [ -f composer.json ]; then
  if [ "$EXEC_KIND" = "compose" ]; then
    INSTALL="docker compose run --rm ${EXEC_PREFIX##* } composer install"
  else
    INSTALL="$(wrap "composer install")"
  fi
elif [ -f requirements.txt ]; then
  INSTALL="$(wrap "pip install -r requirements.txt")"
elif [ -f pyproject.toml ]; then
  INSTALL="$(wrap "pip install -e .")"
elif [ -f package.json ]; then
  INSTALL="$(wrap "npm ci")"
fi

# Lint. {file} is substituted by the caller.
case "$FAMILY" in
  moodle-plugin|cms|php-app|php-library) [ "$LINT" = "null" ] && LINT="$(wrap "php -l {file}")" ;;
  python-app) have ruff && LINT="$(wrap "ruff check {file}")" ;;
esac

# Manifests, for every stack the branches above do not name. `family` is
# deliberately left alone — it picks a /dev-init template and the Moodle rules —
# so this fills commands by what the repository actually contains. A stack with
# no branch here still gets a real command from CI below.
set_if_null() { # set_if_null <varname> <value>
  eval "[ \"\${$1}\" = null ] && $1=\"\$2\""
  return 0
}
if [ -f go.mod ]; then
  [ "$LANGUAGE" = null ] && LANGUAGE="Go"
  set_if_null TEST "$(wrap "go test ./...")"
  set_if_null TEST_SCOPED "$(wrap "go test ./... -run {name}")"
  set_if_null LINT "$(wrap "gofmt -l {file}")"
  set_if_null BUILD "$(wrap "go build ./...")"
  set_if_null INSTALL "$(wrap "go mod download")"
elif [ -f Cargo.toml ]; then
  [ "$LANGUAGE" = null ] && LANGUAGE="Rust"
  set_if_null TEST "$(wrap "cargo test")"
  set_if_null TEST_SCOPED "$(wrap "cargo test {name}")"
  set_if_null LINT "$(wrap "cargo fmt --check --")"
  set_if_null BUILD "$(wrap "cargo build")"
  set_if_null INSTALL "$(wrap "cargo fetch")"
elif [ -f pom.xml ]; then
  [ "$LANGUAGE" = null ] && LANGUAGE="Java"
  set_if_null TEST "$(wrap "mvn -q test")"
  set_if_null TEST_SCOPED "$(wrap "mvn -q test -Dtest={name}")"
  set_if_null BUILD "$(wrap "mvn -q package")"
  set_if_null INSTALL "$(wrap "mvn -q dependency:resolve")"
elif [ -f build.gradle ] || [ -f build.gradle.kts ]; then
  [ "$LANGUAGE" = null ] && LANGUAGE="Java/Kotlin"
  GRADLE="gradle"; [ -x ./gradlew ] && GRADLE="./gradlew"
  set_if_null TEST "$(wrap "$GRADLE test")"
  set_if_null TEST_SCOPED "$(wrap "$GRADLE test --tests {name}")"
  set_if_null BUILD "$(wrap "$GRADLE build")"
elif [ -f Gemfile ]; then
  [ "$LANGUAGE" = null ] && LANGUAGE="Ruby"
  if [ -d spec ]; then
    set_if_null TEST "$(wrap "bundle exec rspec")"
    set_if_null TEST_SCOPED "$(wrap "bundle exec rspec -e {name}")"
  else
    set_if_null TEST "$(wrap "bundle exec rake test")"
  fi
  set_if_null INSTALL "$(wrap "bundle install")"
elif [ -f mix.exs ]; then
  [ "$LANGUAGE" = null ] && LANGUAGE="Elixir"
  set_if_null TEST "$(wrap "mix test")"
  set_if_null INSTALL "$(wrap "mix deps.get")"
else
  for proj in ./*.sln ./*.csproj; do
    [ -f "$proj" ] || continue
    [ "$LANGUAGE" = null ] && LANGUAGE=".NET"
    set_if_null TEST "$(wrap "dotnet test")"
    set_if_null TEST_SCOPED "$(wrap "dotnet test --filter {name}")"
    set_if_null BUILD "$(wrap "dotnet build")"
    set_if_null INSTALL "$(wrap "dotnet restore")"
    break
  done
fi

# CI is the authority: whatever the workflow runs is what actually gates the
# project, whichever stack it belongs to. This used to be detected and then
# thrown away into notes, so a Go repository whose CI says `go test ./...`
# reported test: null and every skill had nothing to run.
#
# The workflow is a file in the checkout, so the captured text is repository
# input reaching a command. Only a known runner prefix is accepted, and a
# capture carrying a shell metacharacter is refused outright.
#
# Which forge, as well as what it runs. Not every project has CI, and several
# cannot: a repository on a private GitLab, a self-hosted forge, or no remote at
# all. Knowing there is none is what lets the rest of the toolkit stop implying a
# second opinion that is never coming.
CI_KIND=none
CI_FILES=""
for probe in \
  "github:.github/workflows/*.yml .github/workflows/*.yaml" \
  "gitlab:.gitlab-ci.yml" \
  "circle:.circleci/config.yml" \
  "jenkins:Jenkinsfile" \
  "woodpecker:.woodpecker.yml .woodpecker/*.yml" \
  "bitbucket:bitbucket-pipelines.yml" \
  "azure:azure-pipelines.yml azure-pipelines.yaml"; do
  kind="${probe%%:*}"
  # Every file the forge has, not the first: the ordinary GitHub layout is
  # lint.yml beside test.yml, and stopping at the first one silently loses the
  # test command to whichever sorts earlier. The loop below tries them in turn.
  files=""
  for f in ${probe#*:}; do
    [ -f "$f" ] && files="${files:+$files }$f"
  done
  # First forge with any file wins. GitHub before GitLab is deliberate: a
  # repository carrying both is usually mirrored, and GitHub is the original.
  [ -n "$files" ] && { CI_KIND="$kind"; CI_FILES="$files"; break; }
done

CI_TEST=""
for wf in $CI_FILES; do
  [ -f "$wf" ] || continue
  CI_TEST="$(grep -hoE '(vendor/bin/phpunit|phpunit|pytest|npm (run )?test|yarn test|go test|cargo test|mvn [^"'"'"']*test|(\./)?gradlew? [^"'"'"']*test|dotnet test|bundle exec (rspec|rake test)|mix test|pnpm test)[^"'"'"']*' "$wf" 2>/dev/null | head -1)"
  [ -n "$CI_TEST" ] && break
done
case "$CI_TEST" in
  *[\;\&\|\`\$\<\>]*|*$'\n'*)
    REJECTED="${REJECTED:+$REJECTED; }a CI test command carrying a shell metacharacter was ignored"
    CI_TEST="" ;;
esac
if [ -n "$CI_TEST" ]; then
  TEST="$(wrap "$CI_TEST")"
  # testScoped has to be the same runner as test, or a scoped run and a full run
  # exercise different configurations and comparing them means nothing. Derived
  # from the CI command where the flag is known, and null where it is not —
  # keeping the default branch's scoped command would point at the other runner.
  TEST_SCOPED=null
  case "$CI_TEST" in
    *phpunit*)   TEST_SCOPED="$(wrap "$CI_TEST --filter {name}")" ;;
    *pytest*)    TEST_SCOPED="$(wrap "$CI_TEST -k {name}")" ;;
    *cargo\ test*) TEST_SCOPED="$(wrap "$CI_TEST {name}")" ;;  # before *go test*: "cargo test" contains it
    *go\ test*)   TEST_SCOPED="$(wrap "$CI_TEST -run {name}")" ;;
    npm\ test*|npm\ run\ test*)
      grep -qsE '"test"[[:space:]]*:[[:space:]]*"node --test' package.json \
        && TEST_SCOPED="$(wrap "env NODE_OPTIONS=--test-name-pattern={name} $CI_TEST")" ;;
  esac
fi

# --------------------------------------------------------------- 6 runtime ---

RUNTIME_KIND=library
RUNTIME_HOW=null
case "$FAMILY" in
  moodle-plugin)
    RUNTIME_KIND=hosted
    RUNTIME_HOW="needs a Moodle installation; cannot run standalone"
    ;;
  php-app)
    if [ -f run ]; then RUNTIME_KIND=cli; RUNTIME_HOW="$(wrap "./run <command>")"; fi
    ;;
  python-app)
    if [ -f main.py ]; then RUNTIME_KIND=cli; RUNTIME_HOW="$(wrap "python main.py")"; fi
    ;;
esac

# A published port means the runtime is reachable from the HOST, not through exec.
if [ -n "$COMPOSE_FILE" ]; then
  PORT="$(grep -oE '^\s+-\s+"?[0-9]+:[0-9]+' "$COMPOSE_FILE" 2>/dev/null | head -1 | grep -oE '[0-9]+:' | head -1 | tr -d ':')"
  if [ -n "$PORT" ]; then
    RUNTIME_KIND=http
    RUNTIME_HOW="http://localhost:$PORT (from the host, not through exec)"
  fi
fi

# ------------------------------------------------------------ 7 timeoutTool ---
#
# Verify by behaviour, never by presence. macOS has no `timeout` at all unless
# coreutils is installed, where it is `gtimeout`. A presence check that guesses
# wrong produces checks that run nothing and report success, so run the thing.

TIMEOUT=null
if timeout 1 true >/dev/null 2>&1; then
  TIMEOUT=timeout
elif gtimeout 1 true >/dev/null 2>&1; then
  TIMEOUT=gtimeout
fi

# ---------------------------------------------------------- 7b contextTokens ---
#
# The context window the step sizing assumes. step-budget.sh turns it into a
# per-step line cap. It is a recommendation the planner follows when a split
# exists, not a limit anything refuses on. DEV_SKILLS_CONTEXT overrides it for a
# machine whose window is bigger or smaller than the default. Inside Pi the
# model's contextWindow takes its place; an exported value applies only to a
# model that declares none.

# Detected, not assumed. Pi knows the active model's window (contextWindow in
# ~/.pi/agent/models.json), and pi/commands.js passes it here as
# DEV_SKILLS_CONTEXT whenever a skill runs. Assuming it is the expensive
# mistake: a step sized for 100k on a 64k machine authorises half again what
# fits, and on a 32k one it authorises the whole window before the model writes
# a line -- silently, because an oversized step still runs, it just degrades.
# Run outside Pi, with nothing set, the default stands.
CONTEXT="${DEV_SKILLS_CONTEXT:-}"
case "$CONTEXT" in ''|*[!0-9]*) CONTEXT=100000 ;; esac

# ----------------------------------------------------------- 8 hasDatabase ---
#
# Gates the data-safety rules, so a wrong `false` silently disables them. When
# unsure the answer is true: the cost is a few extra questions about dry-runs.

HASDB=false
if have rg; then
  rg -q --no-messages -e '\$DB->' -e 'get_records?\(' -e 'PDO' -e 'sqlalchemy' -e 'knex' \
       -e 'SELECT .* FROM' -g '!vendor' -g '!node_modules' . 2>/dev/null && HASDB=true
else
  grep -rqsE '\$DB->|get_records?\(|PDO|sqlalchemy|knex|SELECT .* FROM' \
       --exclude-dir=vendor --exclude-dir=node_modules --exclude-dir=.git . 2>/dev/null && HASDB=true
fi
if [ "$HASDB" = "false" ]; then
  for m in schema.sql db/install.xml db/upgrade.php migrations alembic db/tables; do
    [ -e "$m" ] && { HASDB=true; break; }
  done
fi

# --------------------------------------------------------- 9 verification ---
#
# What will ever check this code, computed once from the two fields that decide
# it. Both are already in the profile, but combining them is a derivation, and
# derivations are what this file exists to take away from the model — the same
# reason hasDatabase and timeoutTool are facts rather than hints.
#
#   ci+container  CI re-runs it, and locally it runs in the target environment
#   ci            CI is the clean-machine check
#   container     no CI, but the container is the clean environment
#   local-only    nothing will ever run this anywhere but here
#
# It also gives a skill something to branch on. The first version of this wrote
# a paragraph into exec.note instead, which cost 195 characters on every read
# and could only be acted on by grepping English.
if [ "$CI_KIND" != none ] && [ "$EXEC_KIND" != host ]; then
  VERIFICATION="ci+container"
elif [ "$CI_KIND" != none ]; then
  VERIFICATION="ci"
elif [ "$EXEC_KIND" != host ]; then
  VERIFICATION="container"
else
  VERIFICATION="local-only"
fi

# ----------------------------------------------------------------- notes -----

NOTES=""
[ -n "$REJECTED" ] && NOTES="$REJECTED"
[ -n "$CI_TEST" ] && NOTES="${NOTES:+$NOTES; }test comes from CI: $CI_TEST"
[ "$TEST" = "null" ] && NOTES="${NOTES:+$NOTES; }No test command found — this repository may have no test suite."
[ -z "$NOTES" ] && NOTES=null

# ------------------------------------------------------------------ emit -----

mkdir -p .devskills
{
  printf '{\n'
  kv platform     "$PLATFORM";     printf ',\n'
  kv family       "$FAMILY";       printf ',\n'
  kv language     "$LANGUAGE";     printf ',\n'
  kv baseBranch   "$BASE";         printf ',\n'
  kv standardsDoc "$STANDARDS";    printf ',\n'
  printf '  "exec": {\n'
  printf '  '; kv kind "$EXEC_KIND"; printf ',\n'
  printf '  '; kv prefix "${EXEC_PREFIX:-null}"; printf ',\n'
  printf '  '; kv note "$EXEC_NOTE"; printf '\n'
  printf '  },\n'
  kv install    "$INSTALL";     printf ',\n'
  kv lint       "$LINT";        printf ',\n'
  kv test       "$TEST";        printf ',\n'
  kv testScoped "$TEST_SCOPED"; printf ',\n'
  kv build      "$BUILD";       printf ',\n'
  printf '  "ci": {\n'
  printf '  '; kv kind "$CI_KIND"; printf ',\n'
  printf '  '; kv runs "${CI_TEST:-null}"; printf '\n'
  printf '  },\n'
  printf '  "runtime": {\n'
  printf '  '; kv kind "$RUNTIME_KIND"; printf ',\n'
  printf '  '; kv how "$RUNTIME_HOW"; printf '\n'
  printf '  },\n'
  kv verification "$VERIFICATION"; printf ',\n'
  kv hasDatabase "$HASDB";  printf ',\n'
  kv timeoutTool "$TIMEOUT"; printf ',\n'
  printf '  "contextTokens": %s,\n' "$CONTEXT"   # a number, so kv's quoting does not apply
  kv notes       "$NOTES";   printf '\n'
  printf '}\n'
} > "$CACHE"

cat "$CACHE"
