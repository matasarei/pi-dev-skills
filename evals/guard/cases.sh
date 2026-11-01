#!/usr/bin/env bash
# Behaviour cases for pi/guard.js — run them from anywhere:
#
#   bash evals/guard/cases.sh
#
# Every case is "expected | the command the hook is asked about": 2 refused,
# 0 allowed. The extension is loaded the way Pi loads it — the default export
# called with a pi whose on() records the tool_call handler, the handler called
# with { toolName, input } and a context carrying cwd — and { block: true } is a
# refusal. A throw is never one: Pi reports it as an extension error and runs
# the tool anyway, so a throw fails the case. The table runs once with no
# profile (main and master are the base branches) and once with a profile
# naming another base branch. Needs node; says so and fails without it.
#
# The table is claude-skills' evals/guard/cases.sh, quotes unescaped — MIT,
# same author.
#
# Exits 0 when every case matches, 1 otherwise, naming each mismatch.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
plugin="$root/pi/guard.js"
[ -f "$plugin" ] || { printf 'no pi/guard.js at %s\n' "$plugin" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { printf 'guard: node is required to run the extension — not installed\n' >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

cat > "$work/cases.txt" <<'TABLE'
# refused — a forced push, however it is spelled
2|git push --force origin x
2|git push --force-with-lease
2|git push -f origin x
2|cd sub && git push --force
# refused — rewriting or skipping
2|git commit --amend -m "x"
2|git commit --no-verify -m "x"
2|git push --no-verify
# refused — a push to the base branch, in each of its shapes
2|git push origin main
2|git push -u origin master
2|git push origin HEAD:main
2|git push origin master:master
2|git push origin +main
2|git push origin HEAD:refs/heads/main
2|git push origin +refs/heads/master
2|git push --delete origin main
# allowed — an ordinary branch whose name merely contains one
0|git push origin feature/x
0|git push origin feature/main-thing
0|git push origin main-thing
0|git push origin domain
0|git push -u origin step/local-model-step-cycle-8
# allowed — talk about a flag is not use of it
0|git commit -m "never pass --no-verify"
0|git commit -m "push --force is banned here"
0|git commit -m 'do not --amend'
# allowed — and the flags outside the quotes are still seen
2|git commit -m "msg" && git push --force
# refused — the gh commands that end or ship a change
2|gh pr merge 12
2|gh pr merge --squash --delete-branch 12
2|gh pr merge --admin
2|gh pr review 12 --approve
2|gh release create v1.2.0
2|gh release upload v1.2.0 dist.zip
2|gh workflow run deploy.yml
2|gh api repos/o/r/pulls/12/merge -X PUT
# allowed — the gh a skill actually needs, including the ones that say merge
0|gh pr create --base main --head x
0|gh pr ready 12
0|gh pr view 12 --json mergeable,mergeStateStatus
0|gh pr list --search "merge conflict"
0|gh pr comment 12 --body "this needs a merge from main"
0|gh repo view --json isPrivate
0|gh api repos/o/r/pulls/12/comments
# allowed — nothing to do with git, or nothing to read
0|ls -la
0|rm -rf build
0|rm -rf coverage dist
0|rm src/vendor.ts
0|rm -rf src/vendor-utils
# refused under any profile — dependencies and lock files come from the
# profile's install; a run that deleted them broke every test after it
2:install|rm -rf node_modules package-lock.json && npm ci
2|rm -rf node_modules
2|cd . && rm -rf ./node_modules/
2|rm package-lock.json
2|rm -f composer.lock
2|rm -rf vendor
2|rm yarn.lock pnpm-lock.yaml
2|rm -rf poetry.lock Cargo.lock
# …however it is spelled: quoted, absolute, behind sudo, through find
2|rm -rf "node_modules"
2|rm -rf 'vendor/'
2|rm -rf /work/app/node_modules
2|sudo rm -rf node_modules
2|cd . && sudo -E rm -f ./package-lock.json
2|find . -name node_modules -prune -exec rm -rf {} +
2|find . -name package-lock.json -delete
# …and a name that only looks like one is not
0|rm -rf "build"
0|rm -rf /work/app/node_modules_backup
0|find . -name "*.log" -delete
0|find . -name node_modules -prune -o -name "*.ts" -print
TABLE

# A project whose profile runs everything in a container (exec.kind image): its
# runners and installers run bare on the host use the host's binaries, which is
# how the bench's first run broke node_modules. Refused, with the command to use;
# the same commands through the container, or through test.sh, are allowed.
cat > "$work/container-cases.txt" <<'TABLE'
2:test.sh|npx vitest run src/__tests__/costs.test.ts
2:test.sh|cd /some/where && npx vitest run src/a.test.ts 2>&1 | tail -80
2:npm ci|npm ci
2:npm ci|cd . && npm install
2|npm run test:coverage
2|npm test
2|yarn test
2|pnpm install
2|vitest run
2|node --test
0|docker run --rm -v "${PWD}":/app -w /app node:lts-alpine npx vitest run src/x.test.ts
0|cd . && docker run --rm -v "$PWD":/app -w /app node:lts-alpine npm ci
0|bash $DEV_SKILLS_LIB/test.sh --scoped costs.test
0|bash ${DEV_SKILLS_LIB:-$HOME/.config/opencode/dev-lib}/test.sh
0|git status
0|grep -rn "npm ci" src/
0|cat package.json
0|node -e "console.log(1)"
0|echo "run npm ci in the container"
0|ls node_modules
TABLE
mkdir -p "$work/container/.devskills"
printf '{\n  "family": "node",\n  "exec": {\n    "kind": "image",\n    "prefix": "docker run --rm -v \\"${PWD}\\":/app -w /app node:lts-alpine",\n    "note": null\n  },\n  "install": "docker run --rm -v \\"${PWD}\\":/app -w /app node:lts-alpine npm ci"\n}\n' > "$work/container/.devskills/profile.json"

# PHP in a container: its own runners.
cat > "$work/phpcontainer-cases.txt" <<'TABLE'
2|composer install
2|vendor/bin/phpunit --filter X
2|php artisan test
0|docker run --rm -v "$PWD":/app -w /app composer:lts composer install
0|npm ci
TABLE
mkdir -p "$work/phpcontainer/.devskills"
printf '{ "family": "php-library", "exec": { "kind": "image", "prefix": "docker run --rm -v \\"${PWD}\\":/app -w /app composer:lts" }, "install": null }\n' > "$work/phpcontainer/.devskills/profile.json"

# The same commands on a host profile are how that project runs: allowed.
cat > "$work/host-cases.txt" <<'TABLE'
0|npx vitest run src/__tests__/costs.test.ts
0|npm ci
0|cd . && npm install
0|composer install
TABLE
mkdir -p "$work/hostprofile/.devskills"
printf '{ "family": "node", "exec": { "kind": "host", "prefix": null }, "install": "npm ci" }\n' > "$work/hostprofile/.devskills/profile.json"

# The same table with a profile naming another base branch: it is refused too,
# and main and master still are.
cat > "$work/profile-cases.txt" <<'TABLE'
2|git push origin release
2|git push origin HEAD:release
2|git push origin main
0|git push origin release-notes
0|git push origin feature/release
TABLE
mkdir -p "$work/withprofile/.devskills"
printf '{ "baseBranch": "release" }\n' > "$work/withprofile/.devskills/profile.json"

cat > "$work/run.mjs" <<'JS'
import { readFileSync, writeFileSync } from "node:fs"
import { pathToFileURL } from "node:url"
const [pluginPath, casesPath, dir, label] = process.argv.slice(2)
const mod = await import(pathToFileURL(pluginPath).href)
let fails = 0
const fail = (what) => { fails++; console.log(`FAIL  ${label} ${what}`) }
// A fresh extension instance: its own loop history, its own tool_call handler.
const load = () => {
  const handlers = {}
  mod.default({ on: (name, fn) => { handlers[name] = fn } })
  if (typeof handlers.tool_call !== "function") throw new Error("the extension registered no tool_call handler")
  return (toolName, input, cwd = dir) => handlers.tool_call({ type: "tool_call", toolCallId: "t", toolName, input }, { cwd })
}
let call = load()
// The verdict on one call: "2" refused, "0" allowed, "threw" for a throw.
const verdict = async (toolName, input) => {
  try {
    const r = await call(toolName, input)
    if (r === undefined) return ["0", ""]
    if (r?.block === true && typeof r.reason === "string" && r.reason.startsWith("dev-guard refuses:")) return ["2", r.reason]
    return [`bad result ${JSON.stringify(r)}`, ""]
  } catch (e) { return ["threw", e.message] }
}
for (const line of readFileSync(casesPath, "utf8").split("\n")) {
  if (!line || line.startsWith("#")) continue
  const i = line.indexOf("|")
  // "2:text" is a refusal whose reason has to contain text: the command to use.
  const [want, mustSay] = line.slice(0, i).split(":"), cmd = line.slice(i + 1)
  const [got, reason] = await verdict("bash", { command: cmd })
  if (got !== want) fail(`want=${want} got=${got}  ${cmd}${reason ? "  (" + reason + ")" : ""}`)
  else if (mustSay && !reason.includes(mustSay)) fail(`the reason does not say '${mustSay}': ${cmd}  (${reason})`)
}
// Another tool's arguments are never read: an edit whose text mentions a push is not a push.
if ((await verdict("edit", { command: "git push --force" }))[0] !== "0") fail("a non-bash tool was refused")
// Grep patterns with unescaped backslashes (e.g. namespaces, paths) are sanitized...
const grepArgs = { pattern: "Vendor\\Modules\\Resource" }
await call("grep", grepArgs)
if (grepArgs.pattern !== "Vendor\\\\Modules\\\\Resource") fail(`grep pattern was not sanitized: ${grepArgs.pattern}`)
// ...unless the search is literal, where a backslash is text, not an escape
const literalArgs = { pattern: "Vendor\\Modules", literal: true }
await call("grep", literalArgs)
if (literalArgs.pattern !== "Vendor\\Modules") fail(`a literal grep pattern was changed: ${literalArgs.pattern}`)
// find's directory: a file path becomes its parent, absolute or relative
const sample = `${dir}/sample.txt`
writeFileSync(sample, "hello\n")
const findArgs = { path: sample, pattern: "*.txt" }
await call("find", findArgs)
if (findArgs.path !== dir) fail(`find file path was not sanitized to dirname: ${findArgs.path}`)
const findRel = { path: "sample.txt", pattern: "*.txt" }
await call("find", findRel)
if (findRel.path !== ".") fail(`a relative find file path was not sanitized to '.': ${findRel.path}`)
// Bash timeout: Pi counts seconds. Milliseconds are divided down, anything under 30 s is raised to 30, invalid removed.
// 3600 is read as 3600 ms on purpose (see sanitizeBashTimeout): the cutoff stays at 1000.
for (const [given, want] of [[5, 30], [45, 45], [120000, 120], [1000, 30], [3600, 30]]) {
  const args = { command: `ls # ${given}`, timeout: given }
  await call("bash", args)
  if (args.timeout !== want) fail(`bash timeout: ${given} was not sanitized to ${want}: ${args.timeout}`)
}
for (const given of [-1, 0, "60"]) {
  const args = { command: `ls # ${given}`, timeout: given }
  await call("bash", args)
  if ("timeout" in args) fail(`invalid bash timeout ${JSON.stringify(given)} was not deleted`)
}
// Repeated identical edit call on an already-updated file is refused on retry
const dummy = `${dir}/dummy.txt`
writeFileSync(dummy, "const AUTH_CONFIG = { enabled: true };\n")
const editArgs = () => ({ path: dummy, edits: [{ oldText: "const AUTH_CONFIG = { enabled: false };", newText: "const AUTH_CONFIG = { enabled: true };" }] })
call = load()
if ((await verdict("edit", editArgs()))[0] !== "0") fail("a first edit call was refused")
const [again, why] = await verdict("edit", editArgs())
if (again !== "2" || !why.includes("is already present")) fail(`repeated edit on already-updated file was not refused: ${again} ${why}`)
// ...and one whose oldText is not in the file is refused with that reason
writeFileSync(dummy, "something else\n")
call = load()
await call("edit", editArgs())
const [missing, whyMissing] = await verdict("edit", editArgs())
if (missing !== "2" || !whyMissing.includes("oldText was not found")) fail(`repeated edit with absent oldText was not refused: ${missing} ${whyMissing}`)
// Line ending preservation (CRLF in file normalizes LF in edit arguments, and in a write)
const crlf = `${dir}/crlf.txt`
writeFileSync(crlf, "first line\r\nsecond line\r\n")
const crlfEdit = { path: crlf, edits: [{ oldText: "second line\n", newText: "second line updated\n" }] }
await call("edit", crlfEdit)
if (!crlfEdit.edits[0].oldText.includes("\r\n") || !crlfEdit.edits[0].newText.includes("\r\n")) fail("edit arguments did not preserve CRLF line endings")
const crlfWrite = { path: crlf, content: "first line\nsecond line\n" }
await call("write", crlfWrite)
if (crlfWrite.content !== "first line\r\nsecond line\r\n") fail(`write content did not take the file's CRLF: ${JSON.stringify(crlfWrite.content)}`)
// Reading a directory as a file is refused, pointing at find or ls instead
const [readDir, whyDir] = await verdict("read", { path: dir })
if (readDir !== "2" || !whyDir.includes("is a directory, not a file")) fail("reading a directory was not refused")
// ...and reading a file is not: a refusal that caught every path would stop the model reading anything
if ((await verdict("read", { path: sample }))[0] !== "0") fail("reading a file was refused")
// The same call three times in a row is a loop, and the third is refused
call = load()
const loop = await Promise.all([0, 1, 2].map(() => verdict("read", { path: sample })))
if (loop.map((v) => v[0]).join(",") !== "0,0,2") fail(`three identical reads were not refused on the third: ${loop.map((v) => v[0]).join(",")}`)
process.exit(fails ? 1 : 0)
JS

# A commit is refused while HEAD is on a base branch — a run that skipped
# branch.sh once committed a step straight onto master — and allowed on a step
# branch, or where there is no repository at all (the two tables above).
cat > "$work/onbase-cases.txt" <<'TABLE'
2|git commit -m "x"
2|cd sub && git commit -m "x"
2|git add . && git commit -m "step 1"
0|git status
0|git add application/
0|echo "git commit later"
TABLE
cat > "$work/onstep-cases.txt" <<'TABLE'
0|git commit -m "x"
0|git add . && git commit -m "step 1"
2|git push origin master
TABLE
g() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=master "$@" >/dev/null 2>&1; }
mkdir -p "$work/onbase" "$work/onstep" "$work/onrelease/.devskills"
g -C "$work/onbase" init -q
g -C "$work/onstep" init -q && g -C "$work/onstep" switch -c step/mytask-1
g -C "$work/onrelease" init -q && g -C "$work/onrelease" switch -c release
printf '{ "baseBranch": "release" }\n' > "$work/onrelease/.devskills/profile.json"

fails=0
node "$work/run.mjs" "$plugin" "$work/cases.txt" "$work" 'no-profile' || fails=$((fails + 1))
node "$work/run.mjs" "$plugin" "$work/profile-cases.txt" "$work/withprofile" 'profile' || fails=$((fails + 1))
node "$work/run.mjs" "$plugin" "$work/onbase-cases.txt" "$work/onbase" 'on-master' || fails=$((fails + 1))
node "$work/run.mjs" "$plugin" "$work/onstep-cases.txt" "$work/onstep" 'on-step' || fails=$((fails + 1))
node "$work/run.mjs" "$plugin" "$work/onbase-cases.txt" "$work/onrelease" 'on-release' || fails=$((fails + 1))
node "$work/run.mjs" "$plugin" "$work/container-cases.txt" "$work/container" 'container' || fails=$((fails + 1))
node "$work/run.mjs" "$plugin" "$work/phpcontainer-cases.txt" "$work/phpcontainer" 'php-container' || fails=$((fails + 1))
node "$work/run.mjs" "$plugin" "$work/host-cases.txt" "$work/hostprofile" 'host' || fails=$((fails + 1))

if [ "$fails" -eq 0 ]; then
  printf 'guard: all cases pass\n'
else
  printf 'guard: %s table(s) with failures\n' "$fails" >&2
fi
exit $((fails > 0))
