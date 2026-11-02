#!/usr/bin/env bash
# Cases for lib/profile.sh — run them from anywhere:
#
#   bash evals/lib/profile.sh
#
# The profile is the fact every skill starts from, so what is asserted is that
# each field follows its fixture: family, language, test and lint commands,
# hasDatabase, the CI note, the base branch — and that null is a real answer
# for a repository with none of them. Docker is stubbed out so the result is
# the host fallback on every machine; the mount probe has its own note in the
# README and is not exercised here.
#
# Exits 0 when every case matches, 1 otherwise, naming each mismatch.

set -u

# Pi sets DEV_SKILLS_CONTEXT for every command it runs (pi/commands.js), so a
# suite run from inside Pi would inherit the session's window and fail every
# case that asserts the default. Each case that wants a window sets its own.
unset DEV_SKILLS_CONTEXT

root="$(cd "$(dirname "$0")/../.." && pwd)"
profile="$root/lib/profile.sh"
[ -f "$profile" ] || { printf 'no profile.sh at %s\n' "$profile" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

fails=0
note() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
g() { git -C "$1" -c user.email=t@e -c user.name=t "${@:2}"; }
field() { printf '%s\n' "$out" | sed -n "s/^ *\"$1\": *\(.*\)$/\1/p" | sed -n "${2:-1}p" | sed 's/,$//'; }
want() { [ "$(field "$1")" = "$2" ] || note "$3: $1 = $(field "$1"), want $2"; }
# A field inside a named object. Addressing "kind" by ordinal broke three
# assertions the moment a third object with one was added; this does not.
field_in() { # field_in <object> <key>
  printf '%s\n' "$out" | awk -v o="\"$1\": {" -v k="\"$2\":" '
    index($0, o) { inobj = 1; next }
    inobj && /^  }/ { exit }
    inobj && index($0, k) { sub(/^[^:]*:[[:space:]]*/, ""); sub(/,$/, ""); print; exit }
  '
}
want_runtime() { [ "$(field_in runtime kind)" = "$1" ] || note "$2: runtime.kind = $(field_in runtime kind), want $1"; }

# A docker that is installed but whose daemon never answers: the host fallback,
# deterministically, whatever this machine has.
stub="$work/bin"; mkdir -p "$stub"
printf '#!/bin/sh\nexit 1\n' > "$stub/docker"; chmod +x "$stub/docker"
# HOME is redirected for every case, so nothing in the home directory of the
# developer running the suite reaches a result.
nohome="$work/nohome"; mkdir -p "$nohome"
run() { out="$(cd "$1" && HOME="$nohome" PATH="$stub:$PATH" bash "$profile" "${2:-}" 2>&1)"; }

# A PHP library with PHPUnit, a database call, a CI workflow, no compose file.
lib="$work/lib"; mkdir -p "$lib/src" "$lib/tests" "$lib/.github/workflows"
printf '{"name":"x/y","type":"library","require":{"php":">=7.4"}}\n' > "$lib/composer.json"
printf '<phpunit/>\n' > "$lib/phpunit.xml"
printf '<?php $DB->get_record("user", []);\n' > "$lib/src/Repo.php"
printf 'jobs:\n  t:\n    steps:\n      - run: vendor/bin/phpunit --testsuite unit\n' > "$lib/.github/workflows/ci.yml"
printf '# Conventions\n' > "$lib/CONTRIBUTING.md"
g "$lib" init -q -b main . && g "$lib" add -A && g "$lib" commit -qm init

run "$lib"
want family '"php-library"' 'php library'
want language '"PHP >=7.4"' 'php library'
want baseBranch '"main"' 'php library'
want standardsDoc '"CONTRIBUTING.md"' 'php library'
want kind '"host"' 'php library'
want_runtime '"library"' 'php library'
# CI wins over the PHPUnit default: this fixture's workflow runs the suite with
# --testsuite unit, and that is what actually gates the project. Before, the CI
# line was detected and then dropped into notes while test kept the default.
want test '"vendor/bin/phpunit --testsuite unit"' 'php library'
want testScoped '"vendor/bin/phpunit --testsuite unit --filter {name}"' 'php library'
want lint '"php -l {file}"' 'php library'
want install '"composer install"' 'php library'
want hasDatabase 'true' 'php library'
printf '%s\n' "$out" | grep -q 'test comes from CI: vendor/bin/phpunit --testsuite unit' || note 'php library: notes do not say the test command came from CI'
printf '%s\n' "$out" | grep -q '"note": "Docker not available' || note 'php library: the host fallback reason is not recorded'
[ -f "$lib/.devskills/profile.json" ] || note 'php library: the cache was not written'

# composer.json is part of the checkout, so its vendor-dir is repository-controlled
# text landing inside a command something later runs. A value that is not a plain
# relative path is refused, and the refusal is said out loud rather than silently
# defaulted — but a legitimate custom vendor-dir is still honoured.
hostile="$work/hostile"; mkdir -p "$hostile"
printf '{"config":{"vendor-dir":"vend; touch PWNED"},"require":{"php":">=8.1"}}\n' > "$hostile/composer.json"
printf '<phpunit/>\n' > "$hostile/phpunit.xml"
g "$hostile" init -q -b main . && g "$hostile" add -A && g "$hostile" commit -qm init
run "$hostile"
want test '"vendor/bin/phpunit"' 'hostile vendor-dir'
want testScoped '"vendor/bin/phpunit --filter {name}"' 'hostile vendor-dir'
printf '%s\n' "$(field test)$(field testScoped)$(field prefix)" | grep -q ';' && note 'hostile vendor-dir: a command separator reached a command field'
printf '%s\n' "$out" | grep -q 'is not a plain relative path' || note 'hostile vendor-dir: the refusal is not in notes'
[ -f "$hostile/PWNED" ] && note 'hostile vendor-dir: the value executed'

custom="$work/custom"; mkdir -p "$custom"
printf '{"config":{"vendor-dir":"custom-vendor"},"require":{"php":">=8.1"}}\n' > "$custom/composer.json"
printf '<phpunit/>\n' > "$custom/phpunit.xml"
g "$custom" init -q -b main . && g "$custom" add -A && g "$custom" commit -qm init
run "$custom"
want test '"custom-vendor/bin/phpunit"' 'custom vendor-dir'
want notes 'null' 'custom vendor-dir'

# Stacks with no branch of their own get their commands from the manifest, so
# "run the tests and quote the runner's line" has something to run. Before this,
# a Go, Rust or Java repository profiled with every command null.
manifest_case() { # manifest_case <dir> <language> <test> <testScoped>
  d="$work/$1"; mkdir -p "$d"
  shift
  lang="$1"; t="$2"; ts="$3"
  g "$d" init -q -b main . && g "$d" add -A >/dev/null 2>&1
  g "$d" -c user.email=t@e commit -qm init --allow-empty
  run "$d"
  want language "\"$lang\"" "$lang manifest"
  want test "\"$t\"" "$lang manifest"
  [ -n "$ts" ] && want testScoped "\"$ts\"" "$lang manifest"
}

mkdir -p "$work/go"   && printf 'module x\ngo 1.22\n' > "$work/go/go.mod"
manifest_case go Go 'go test ./...' 'go test ./... -run {name}'
mkdir -p "$work/rust" && printf '[package]\nname="x"\n' > "$work/rust/Cargo.toml"
manifest_case rust Rust 'cargo test' 'cargo test {name}'
mkdir -p "$work/java" && printf '<project/>\n' > "$work/java/pom.xml"
manifest_case java Java 'mvn -q test' 'mvn -q test -Dtest={name}'
mkdir -p "$work/rb/spec" && printf "source 'x'\n" > "$work/rb/Gemfile"
manifest_case rb Ruby 'bundle exec rspec' 'bundle exec rspec -e {name}'

# A node --test suite gets a scoped command that keeps npm test as the runner.
# The name filter has to reach node before the test files — given after them,
# or through `npm test --`, node --test ignores it — so it travels in
# NODE_OPTIONS, and nothing read out of package.json reaches the command.
mkdir -p "$work/nodetest" && printf '{"name":"w","private":true,"scripts":{"test":"node --test tests/*.test.js"}}\n' > "$work/nodetest/package.json"
manifest_case nodetest Node 'npm test' 'env NODE_OPTIONS=--test-name-pattern={name} npm test'
# Another runner behind npm test has no filter this toolkit has proved, so it
# stays null rather than guess.
mkdir -p "$work/nodejest" && printf '{"name":"w","private":true,"scripts":{"test":"jest"}}\n' > "$work/nodejest/package.json"
manifest_case nodejest Node 'npm test' ''
want testScoped 'null' 'a jest suite has no proven scoped form'
# CI that runs npm test on a node --test suite gets the same scoped form.
mkdir -p "$work/nodeci/.github/workflows" && printf '{"name":"w","private":true,"scripts":{"test":"node --test"}}\n' > "$work/nodeci/package.json"
printf 'jobs:\n  t:\n    steps:\n      - run: npm test\n' > "$work/nodeci/.github/workflows/ci.yml"
manifest_case nodeci Node 'npm test' 'env NODE_OPTIONS=--test-name-pattern={name} npm test'
# vitest reads a positional argument as a file filter, which is what a plan's
# Red: line names, and npm passes what follows `--` on to it. Both the plain
# script and a CI command naming a vitest script get it.
mkdir -p "$work/nodevitest" && printf '{"name":"w","private":true,"scripts":{"test":"vitest"}}\n' > "$work/nodevitest/package.json"
manifest_case nodevitest Node 'npm test' 'npm test -- {name}'
mkdir -p "$work/vitestci/.github/workflows" && printf '{"name":"w","private":true,"scripts":{"test":"vitest","test:coverage":"vitest run --coverage"}}\n' > "$work/vitestci/package.json"
printf 'jobs:\n  t:\n    steps:\n      - run: npm run test:coverage\n' > "$work/vitestci/.github/workflows/ci.yml"
manifest_case vitestci Node 'npm run test:coverage' 'npm run test:coverage -- {name}'

# CI is the authority over the manifest default: whatever the workflow runs is
# what actually gates the project.
ci="$work/goci"; mkdir -p "$ci/.github/workflows"
printf 'module x\n' > "$ci/go.mod"
printf 'jobs:\n  t:\n    steps:\n      - run: go test ./... -race\n' > "$ci/.github/workflows/ci.yml"
g "$ci" init -q -b main . && g "$ci" add -A && g "$ci" commit -qm init
run "$ci"
want test '"go test ./... -race"' 'CI over manifest'
printf '%s\n' "$out" | grep -q 'test comes from CI' || note 'CI over manifest: notes do not say where test came from'

# A workflow is a file in the checkout, so its captured text is repository input
# reaching a command. One carrying a shell metacharacter is refused, and the
# manifest default is used instead of it.
evil="$work/goevil"; mkdir -p "$evil/.github/workflows"
printf 'module x\n' > "$evil/go.mod"
printf 'jobs:\n  t:\n    steps:\n      - run: go test ./...; touch PWNED\n' > "$evil/.github/workflows/ci.yml"
g "$evil" init -q -b main . && g "$evil" add -A && g "$evil" commit -qm init
run "$evil"
want test '"go test ./..."' 'hostile CI'
printf '%s\n' "$out" | grep -q 'touch PWNED' && note 'hostile CI: the value reached the profile'
printf '%s\n' "$out" | grep -q 'shell metacharacter was ignored' || note 'hostile CI: the refusal is not in notes'

# CI is not only GitHub. A project on GitLab, Woodpecker or a self-hosted forge
# declares its gating command somewhere else, and reading only .github/workflows
# silently used the manifest default instead — dropping, in the fixture below,
# the -race flag the project actually gates on.
ci_case() { # ci_case <dir> <file> <content> <want kind> <want runs>
  d="$work/ci-$1"; mkdir -p "$d/$(dirname "$2")" 2>/dev/null || mkdir -p "$d"
  printf 'module x\ngo 1.22\n' > "$d/go.mod"
  [ -n "$3" ] && printf '%s\n' "$3" > "$d/$2"
  g "$d" init -q -b main . && g "$d" add -A >/dev/null 2>&1
  g "$d" -c user.email=t@e commit -qm init --allow-empty
  run "$d"
  [ "$(field_in ci kind)" = "\"$4\"" ] || note "ci $1: kind = $(field_in ci kind), want \"$4\""
  [ "$(field_in ci runs)" = "$5" ] || note "ci $1: runs = $(field_in ci runs), want $5"
}

GO='- run: go test ./... -race'
ci_case github     .github/workflows/ci.yml "jobs:
  t:
    steps:
      $GO"                                   github     '"go test ./... -race"'
ci_case gitlab     .gitlab-ci.yml "test:
  script:
    - go test ./... -race"                   gitlab     '"go test ./... -race"'
ci_case circle     .circleci/config.yml "jobs:
  t:
    steps:
      $GO"                                   circle     '"go test ./... -race"'
ci_case jenkins    Jenkinsfile 'sh "go test ./..."'          jenkins    '"go test ./..."'
ci_case woodpecker .woodpecker.yml "steps:
  - commands:
      - go test ./..."                       woodpecker '"go test ./..."'
ci_case bitbucket  bitbucket-pipelines.yml "pipelines:
  default:
    - step:
        script:
          - go test ./..."                   bitbucket  '"go test ./..."'
ci_case azure      azure-pipelines.yml 'steps:
  - script: go test ./...'                   azure      '"go test ./..."'

# No CI at all is a fact about the project, reported as such.
ci_case none       .none "" none null

# A CI file is repository input reaching a command, like composer.json's
# vendor-dir. The forge is still reported; the command is not used.
ci_case hostile    .gitlab-ci.yml "test:
  script:
    - go test ./...; rm -rf /"               gitlab     null

# The ordinary GitHub layout is a lint workflow beside a test workflow. Stopping
# at the first file found loses the test command to whichever sorts earlier —
# every ci_case above has exactly one CI file, which is why that passed.
multi="$work/ci-multi"; mkdir -p "$multi/.github/workflows"
printf 'module x\ngo 1.22\n' > "$multi/go.mod"
printf 'name: lint\njobs:\n  l:\n    steps:\n      - run: gofmt -l .\n' > "$multi/.github/workflows/aaa-lint.yml"
printf 'name: test\njobs:\n  t:\n    steps:\n      - run: go test ./... -race\n' > "$multi/.github/workflows/zzz-test.yml"
g "$multi" init -q -b main . && g "$multi" add -A >/dev/null 2>&1
g "$multi" -c user.email=t@e commit -qm init --allow-empty
run "$multi"
[ "$(field_in ci runs)" = '"go test ./... -race"' ] \
  || note "two workflows: runs = $(field_in ci runs), want the one from the second file"
want test '"go test ./... -race"' 'two workflows, command in the second'

# And CI beats the manifest default, which is the point of reading it at all.
run "$work/ci-gitlab"
want test '"go test ./... -race"' 'gitlab CI over the manifest default'

# What will ever check this code, as a value a skill can branch on rather than a
# paragraph in exec.note. A stub docker that answers is needed for the two
# container cases, because the one at the top of this file refuses on purpose.
okdocker="$work/okbin"; mkdir -p "$okdocker"
printf '#!/bin/sh\nexit 0\n' > "$okdocker/docker"; chmod +x "$okdocker/docker"

verify_case() { # verify_case <dir> <ci file or empty> <bin dir> <want>
  d="$work/verify-$1"; mkdir -p "$d/.github/workflows"
  # A node project: the image table is keyed on `family`, and Go, Rust and the
  # JVM are all `other`, so they could never reach exec.kind: image at all.
  printf '{"name":"w","private":true,"scripts":{"test":"node --test"}}\n' > "$d/package.json"
  [ -n "$2" ] && printf 'jobs:\n  t:\n    steps:\n      - run: npm test\n' > "$d/$2"
  g "$d" init -q -b main . && g "$d" add -A >/dev/null 2>&1
  g "$d" -c user.email=t@e commit -qm init --allow-empty
  out="$(cd "$d" && HOME="$nohome" PATH="$3:$PATH" bash "$profile" 2>&1)"
  want verification "\"$4\"" "verification, $1"
}

verify_case ci-cont   .github/workflows/ci.yml "$okdocker" ci+container
verify_case ci-host   .github/workflows/ci.yml "$stub"     ci
verify_case none-cont ""                       "$okdocker" container
verify_case none-host ""                       "$stub"     local-only

# The prose escalation is gone: exec.note carries the actionable reason and
# nothing else, so the field a skill branches on is the field, not English.
out="$(cd "$work/verify-none-host" && HOME="$nohome" PATH="$stub:$PATH" bash "$profile" --reprofile 2>&1)"
printf '%s\n' "$(field_in exec note)" | grep -q 'only thing that will ever' \
  && note 'verification: the paragraph is back in exec.note'
printf '%s\n' "$(field_in exec note)" | grep -q 'Docker not available' \
  || note "verification: exec.note lost its actionable reason: $(field_in exec note)"

# The cache is what is printed the second time, even after the tree changes.
rm "$lib/phpunit.xml" "$lib/.github/workflows/ci.yml"
run "$lib"
want test '"vendor/bin/phpunit --testsuite unit"' 'cached'
# --reprofile detects again and sees the change.
run "$lib" --reprofile
want test 'null' 'reprofiled'
printf '%s\n' "$out" | grep -q 'No test command found' || note 'reprofiled: the missing test command is not noted'
# --path prints the cache path and nothing else.
run "$lib" --path
[ "$out" = '.devskills/profile.json' ] || note "--path: got '$out'"

# A repository with none of it: nulls, not inventions.
bare="$work/bare"; mkdir -p "$bare"
g "$bare" init -q -b master . && g "$bare" commit -q --allow-empty -m init   # an unborn branch is no branch
run "$bare"
want family '"other"' 'bare'
want language 'null' 'bare'
want baseBranch '"master"' 'bare'
want standardsDoc 'null' 'bare'
want test 'null' 'bare'
want lint 'null' 'bare'
want install 'null' 'bare'
want hasDatabase 'false' 'bare'
want_runtime '"library"' 'bare'
case "$(field timeoutTool)" in '"timeout"'|'"gtimeout"'|null) ;; *) note "bare: timeoutTool = $(field timeoutTool)" ;; esac

# A python app with pytest: the other detection branch.
py="$work/py"; mkdir -p "$py/tests"
printf '[project]\nrequires-python = ">=3.11"\n[tool.pytest.ini_options]\n' > "$py/pyproject.toml"
printf '\n' > "$py/tests/conftest.py"
printf 'print(1)\n' > "$py/main.py"
g "$py" init -q -b main .
run "$py"
want family '"python-app"' 'python'
want language '"Python >=3.11"' 'python'
want test '"pytest"' 'python'
want install '"pip install -e ."' 'python'
want_runtime '"cli"' 'python'
want how '"python main.py"' 'python'
want contextTokens '100000' 'python'

# contextTokens is the active model's window, which pi/commands.js passes as
# DEV_SKILLS_CONTEXT. Nothing else sets it: an OpenCode config left in a project
# is not read, because its window was declared for a different harness.
ctx_case() { # ctx_case <dir> <DEV_SKILLS_CONTEXT, or empty for unset> <want> <what>
  d="$work/ctx-$1"; mkdir -p "$d"
  g "$d" init -q -b main . && g "$d" commit -qm init --allow-empty
  if [ -n "$2" ]; then
    got="$(cd "$d" && HOME="$nohome" DEV_SKILLS_CONTEXT="$2" PATH="$stub:$PATH" bash "$profile" 2>&1 | sed -n 's/.*"contextTokens": *\([0-9]*\).*/\1/p')"
  else
    got="$(cd "$d" && HOME="$nohome" PATH="$stub:$PATH" bash "$profile" 2>&1 | sed -n 's/.*"contextTokens": *\([0-9]*\).*/\1/p')"
  fi
  [ "$got" = "$3" ] || note "contextTokens, $4: got '$got', want $3"
}

ctx_case window 65536 65536 "the model's window is used"
ctx_case unset '' 100000 'no window falls back'
ctx_case bad nope 100000 'a malformed window falls back rather than propagating'

d="$work/ctx-opencode"; mkdir -p "$d"
printf '{ "model": "lmstudio/q", "provider": { "lmstudio": { "models": { "q": { "limit": { "context": 65536 } } } } } }\n' > "$d/opencode.jsonc"
ctx_case opencode '' 100000 'an opencode.jsonc left in the project is not read'

# The window belongs to the model, not the repository: a cached profile reports
# the window DEV_SKILLS_CONTEXT names now, and its own when nothing is set.
d="$work/ctx-cached"; mkdir -p "$d"
ctx_case cached 131072 131072 'the window is cached with the profile'
got="$(cd "$d" && HOME="$nohome" DEV_SKILLS_CONTEXT=32768 PATH="$stub:$PATH" bash "$profile" 2>&1 | sed -n 's/.*"contextTokens": *\([0-9]*\).*/\1/p')"
[ "$got" = 32768 ] || note "contextTokens: a cached profile did not take the window the model has now (got '$got', want 32768)"
got="$(cd "$d" && HOME="$nohome" PATH="$stub:$PATH" bash "$profile" 2>&1 | sed -n 's/.*"contextTokens": *\([0-9]*\).*/\1/p')"
[ "$got" = 131072 ] || note "contextTokens: with nothing set, a cached profile no longer reports its own window (got '$got')"
grep -q '"contextTokens": 131072' "$d/.devskills/profile.json" || note "contextTokens: reading the cache with another window rewrote it"

# contextTokens: the default, and the DEV_SKILLS_CONTEXT override (a number, unquoted).
out="$(cd "$py" && PATH="$stub:$PATH" DEV_SKILLS_CONTEXT=64000 bash "$profile" --reprofile 2>&1)"
want contextTokens '64000' 'override'
out="$(cd "$py" && PATH="$stub:$PATH" DEV_SKILLS_CONTEXT=lots bash "$profile" --reprofile 2>&1)"
want contextTokens '100000' 'non-numeric override falls back'

# A PHP app with docker compose having mysql, fpm, nginx:
# verifies that fpm is selected, and mysql is never chosen.
compose_app="$work/compose_app"; mkdir -p "$compose_app"
printf '{"require":{"php":">=8.0"}}\n' > "$compose_app/composer.json"
printf 'services:\n  mysql:\n  fpm:\n  nginx:\n' > "$compose_app/docker-compose.yml"
g "$compose_app" init -q -b main . && g "$compose_app" add -A && g "$compose_app" commit -qm init

compose_stub="$work/compose_bin"; mkdir -p "$compose_stub"
cat > "$compose_stub/docker" <<'DOCKER'
#!/bin/sh
case "$*" in
  "info") exit 0 ;;
  *"config --services"*) printf 'mysql\nfpm\nnginx\n'; exit 0 ;;
  *"ps --status running"*) printf 'mysql\nfpm\nnginx\n'; exit 0 ;;
  *"exec -T fpm which php"*) exit 0 ;;
  *"exec -T mysql which php"*) exit 1 ;;
  *) exit 0 ;;
esac
DOCKER
chmod +x "$compose_stub/docker"
out="$(cd "$compose_app" && PATH="$compose_stub:$PATH" bash "$profile" 2>&1)"
want kind '"compose"' 'compose app'
want prefix '"docker compose exec -T fpm"' 'compose selects fpm over mysql'

if [ "$fails" -eq 0 ]; then
  printf 'profile: every field follows its fixture, null included\n'
else
  printf 'profile: %s case(s) failed\n' "$fails" >&2
fi
exit $((fails > 0))
