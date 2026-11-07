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
2:@LIB@/test.sh|npx vitest run src/__tests__/costs.test.ts
2:test.sh|cd /some/where && npx vitest run src/a.test.ts 2>&1 | tail -80
2:npm ci|npm ci
2:npm ci|cd . && npm install
2|npm run test:coverage
2|npm test
2|yarn test
2|pnpm install
2|vitest run
2|node --test
2:test.sh|time npm test
2:test.sh|env CI=1 npx vitest run
2|sudo npm ci
2|FOO=1 env BAR=2 time npx vitest
0|time docker run --rm -v "$PWD":/app -w /app node:lts-alpine npm test
0|env FOO=1 bash $DEV_SKILLS_LIB/test.sh
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
import { dirname, join } from "node:path"
import { pathToFileURL } from "node:url"
const [pluginPath, casesPath, dir, label] = process.argv.slice(2)
// "@LIB@" in a case's text is this checkout's lib/: a reason names the script by
// its path, never by $DEV_SKILLS_LIB, which the model may fill in itself.
const lib = join(dirname(dirname(pluginPath)), "lib")
const mod = await import(pathToFileURL(pluginPath).href)
let fails = 0
const fail = (what) => { fails++; console.log(`FAIL  ${label} ${what}`) }
// A fresh extension instance: its own loop history, its own tool_call handler.
const load = () => {
  const handlers = {}
  mod.default({ on: (name, fn) => { handlers[name] = fn } })
  if (typeof handlers.tool_call !== "function") throw new Error("the extension registered no tool_call handler")
  const fn = (toolName, input, cwd = dir, toolCallId = "t") => handlers.tool_call({ type: "tool_call", toolCallId, toolName, input }, { cwd })
  fn.handlers = handlers
  return fn
}
let call = load()
// The verdict on one call: "2" refused, "0" allowed, "threw" for a throw. Third, whether it ends the run.
const verdict = async (toolName, input) => {
  try {
    const r = await call(toolName, input)
    if (r === undefined) return ["0", ""]
    if (r?.block === true && typeof r.reason === "string" && r.reason.startsWith("dev-guard refuses:")) return ["2", r.reason, r.terminate === true]
    return [`bad result ${JSON.stringify(r)}`, ""]
  } catch (e) { return ["threw", e.message] }
}
for (const line of readFileSync(casesPath, "utf8").split("\n")) {
  if (!line || line.startsWith("#")) continue
  const i = line.indexOf("|")
  // "2:text" is a refusal whose reason has to contain text: the command to use.
  const [want, said] = line.slice(0, i).split(":"), cmd = line.slice(i + 1)
  const mustSay = said?.replaceAll("@LIB@", lib)
  const [got, reason] = await verdict("bash", { command: cmd })
  if (got !== want) fail(`want=${want} got=${got}  ${cmd}${reason ? "  (" + reason + ")" : ""}`)
  else if (mustSay && !reason.includes(mustSay)) fail(`the reason does not say '${mustSay}': ${cmd}  (${reason})`)
  if (reason.includes("DEV_SKILLS_LIB")) fail(`the reason names $DEV_SKILLS_LIB, not the path: ${cmd}  (${reason})`)
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
// ...and its reason says to stop and report. "Next step" is a call the step gate refuses.
if (loop[2][1].includes("next step") || !loop[2][1].includes("what blocks you")) fail(`the in-a-row refusal does not say to stop and report: ${loop[2][1]}`)
// A short cycle: calls that repeat with something between them never reach three in a row.
const reads = (n) => ["read", { path: sample, offset: n }]
const test = () => ["bash", { command: "echo test" }]
const inTurn = async (calls) => { const out = []; for (const [t, a] of calls) out.push(await verdict(t, a)); return out }
const codes = (vs) => vs.map((v) => v[0]).join("")
const times = (n, ...calls) => Array.from({ length: n }, () => calls).flat()
call = load()
const alternating = await inTurn(times(6, reads(1), test()))
if (codes(alternating) !== "000000000002") fail(`two alternating calls were not refused on the 12th: ${codes(alternating)}`)
if (!alternating[11][1].includes("what blocks you")) fail(`the cycle refusal does not say to stop and report: ${alternating[11][1]}`)
// The cycle from the bench run: a test run three times, the third refused, then the same read.
call = load()
const logged = await inTurn(times(3, test(), test(), test(), reads(1)))
if (codes(logged) !== "002000200022") fail(`the logged test, test, test, read cycle was not refused on the 12th: ${codes(logged)}`)
// An edit in a cycle with a read is a cycle too: the edit rule alone sees no repeat in a row.
call = load()
const sameEdit = () => ["edit", { path: dummy, edits: [{ oldText: "absent", newText: "x" }] }]
if (codes(await inTurn(times(6, sameEdit(), reads(1)))) !== "000000000002") fail("an edit alternating with a read was not refused on the 12th")
// A real edit/test cycle is not a loop: each edit is different.
call = load()
const fixes = Array.from({ length: 12 }, (_, i) => [["edit", { path: dummy, edits: [{ oldText: "absent", newText: `fix ${i}` }] }], test()]).flat()
if (/2/.test(codes(await inTurn(fixes)))) fail("an edit/test cycle with different edits was refused")
// Neither is reading around.
call = load()
if (/2/.test(codes(await inTurn(Array.from({ length: 20 }, (_, i) => reads(i)))))) fail("twenty different reads were refused")
// A refusal the model answers with something new has worked: that call, and the rerun after it, run.
call = load()
await inTurn(times(6, reads(1), test()))
const recovered = await inTurn([["edit", { path: dummy, edits: [{ oldText: "absent", newText: "the fix" }] }], test()])
if (codes(recovered) !== "00") fail(`a new call after a cycle refusal, or the rerun after it, was refused: ${codes(recovered)}`)
// Refusing alone never stopped the bench's loop: the third repeat refusal ends the run.
const stops = (vs) => vs.flatMap((v, i) => (v[2] ? [i + 1] : [])).join(",")
call = load()
const held = await inTurn(times(6, test()))
if (codes(held) !== "002222" || stops(held) !== "5,6") fail(`the third in-a-row refusal did not end the run: ${codes(held)} stops at ${stops(held)}`)
if (!held[4][1].includes("This run stops here.") || held[3][1].includes("This run stops here.")) fail(`only a refusal that ends the run says so: ${held[3][1]} / ${held[4][1]}`)
// Calls 25 to 39 of the bench's step 2: it would have ended at 39, not at the timeout after 104.
const [x, otherRead, oneRead, y] = [test(), reads(2), reads(3), reads(1)]
call = load()
const bench = await inTurn([x, x, otherRead, oneRead, x, x, x, y, x, x, x, y, x, x, x])
if (codes(bench) !== "000000200020002" || stops(bench) !== "15") fail(`the logged calls 25-39 did not end on the last: ${codes(bench)} stops at ${stops(bench)}`)
// The other two loop rules count as well.
call = load()
const cycling = await inTurn(times(7, reads(1), test()))
if (codes(cycling) !== "00000000000222" || stops(cycling) !== "14") fail(`the third cycle refusal did not end the run: ${codes(cycling)} stops at ${stops(cycling)}`)
call = load()
const retried = await inTurn(times(5, sameEdit()))
if (codes(retried) !== "02222" || stops(retried) !== "4,5") fail(`the third repeated-edit refusal did not end the run: ${codes(retried)} stops at ${stops(retried)}`)
if (!retried[3][1].includes("oldText was not found")) fail(`the edit rule lost its own reason: ${retried[3][1]}`)
// A write that changes nothing: Pi would answer "Successfully wrote", and the model takes that for its fix.
const sameFile = `${dir}/same.txt`
const sameText = "let x = 3;\n"
writeFileSync(sameFile, sameText)
const same = () => ["write", { path: sameFile, content: sameText }]
call = load()
const [noop, whyNoop, noopStops] = await verdict(...same())
if (noop !== "2" || !whyNoop.includes("changes nothing") || !whyNoop.includes(sameFile) || noopStops) fail(`a write of the file's own content was not refused: ${noop} ${whyNoop}`)
if (readFileSync(sameFile, "utf8") !== sameText) fail("a refused write changed the file")
// It can't know a change was meant: one logged write only re-created a file the model thought was missing.
if (!whyNoop.includes("If you meant to change it")) fail(`the refusal assumes a change was meant: ${whyNoop}`)
// Anything that differs goes through, and so does anything with no file to compare with.
writeFileSync(`${dir}/empty.txt`, "")
for (const [what, input] of [
  ["different content", { path: sameFile, content: "let x = 10;\n" }],
  ["a missing trailing newline", { path: sameFile, content: "let x = 3;" }],
  ["an extra trailing newline", { path: sameFile, content: "let x = 3;\n\n" }],
  ["CRLF over an LF file", { path: sameFile, content: "let x = 3;\r\n" }],
  ["a new file", { path: `${dir}/new.txt`, content: sameText }],
  ["an empty write to a new file", { path: `${dir}/new-empty.txt`, content: "" }],
  ["content to an empty file", { path: `${dir}/empty.txt`, content: sameText }],
  ["a directory", { path: dir, content: sameText }],
  ["content that isn't text", { path: sameFile, content: 5 }],
]) {
  call = load()
  const [code, why] = await verdict("write", input)
  if (code !== "0") fail(`${what} was refused as a write that changes nothing: ${code} ${why}`)
}
// An empty file written empty is as much of a no-op as any other.
call = load()
if ((await verdict("write", { path: `${dir}/empty.txt`, content: "" }))[0] !== "2") fail("an empty write to an empty file was not refused")
// A relative path is the session's file, not the guard's.
call = load()
if ((await verdict("write", { path: "same.txt", content: sameText }))[0] !== "2") fail("a relative path was not compared with the file it names")
call = load()
if ((await call("write", { path: "same.txt", content: sameText }, "/")) !== undefined) fail("a relative path was compared outside the session's cwd")
// The comparison is with what Pi would write: LF over a CRLF file becomes CRLF first, so this is a no-op too.
call = load()
if ((await verdict("write", { path: crlf, content: "first line\nsecond line\n" }))[0] !== "2") fail("LF over the same text in CRLF was not refused")
// The logged loop: the same write, the filtered test, a read. It ends on the third write, not 32 replies later.
call = load()
const loggedWrites = await inTurn(times(3, same(), test(), reads(1)))
if (codes(loggedWrites) !== "200200200" || stops(loggedWrites) !== "7") fail(`the logged write, test, read loop did not end on the third write: ${codes(loggedWrites)} stops at ${stops(loggedWrites)}`)
if (!loggedWrites[6][1].includes("changes nothing") || !loggedWrites[6][1].includes("This run stops here.")) fail(`the stop lost the rule's reason: ${loggedWrites[6][1]}`)
// Real writes between them don't excuse them.
call = load()
const between = await inTurn(times(3, same(), ["write", { path: sameFile, content: "let x = 10;\n" }]).slice(0, 5))
if (codes(between) !== "20202" || stops(between) !== "5") fail(`real writes between no-op writes reset the count: ${codes(between)} stops at ${stops(between)}`)
// The count doesn't look at the path: three different files already holding what's written end the run too.
call = load()
const paths = ["one.txt", "two.txt", "three.txt"]
for (const path of paths) writeFileSync(`${dir}/${path}`, sameText)
const manyPaths = await inTurn(paths.map((path) => ["write", { path, content: sameText }]))
if (codes(manyPaths) !== "222" || stops(manyPaths) !== "3") fail(`no-op writes to different files did not share the count: ${codes(manyPaths)} stops at ${stops(manyPaths)}`)
// A refused write is still in the history: three in a row is the breaker's refusal, which sees them.
call = load()
const inARow = await inTurn(times(3, same()))
if (codes(inARow) !== "222" || !inARow[2][1].includes("3x for write")) fail(`refused writes did not reach the history: ${codes(inARow)} ${inARow[2][1]}`)
// One now and then is not a loop: the stop only counts three within 40 calls.
call = load()
const apart = []
for (let round = 0; round < 3; round++) {
  apart.push(...await inTurn([same()]))
  await inTurn(Array.from({ length: 41 }, (_, i) => reads(1000 * (round + 1) + i)))
}
if (codes(apart) !== "222" || stops(apart) !== "") fail(`no-op writes far apart ended the run: ${codes(apart)} stops at ${stops(apart)}`)
// Other refusals are not loops: a model refused for several different commands keeps its run.
call = load()
const others = await inTurn(Array.from({ length: 5 }, (_, i) => ["bash", { command: `rm -f a${i}/package-lock.json` }]))
if (codes(others) !== "22222" || stops(others) !== "") fail(`different refused commands counted as a loop: ${codes(others)} stops at ${stops(others)}`)
// A short cycle refuses again only after 12 fresh calls, so a model that makes anything new after each refusal
// spaces them out. In the logged run, 2 new calls gave 17 refusals and no stop, until the 30-minute limit.
const varied = async (news) => {
  call = load()
  const between = Array.from({ length: news }, (_, i) => reads(2 + i))
  const vs = await inTurn([...times(6, reads(1), test()), ...times(2, ...between, ...times(6, reads(1), test()))])
  return [vs.flatMap((v, i) => (v[0] === "2" ? [i + 1] : [])).join(","), stops(vs), vs.at(-1)[1] ?? ""]
}
for (const [news, refused, stop] of [[1, "12,25,38", "38"], [2, "12,26,40", "40"], [8, "12,32,52", "52"], [9, "12,33,54", ""]]) {
  const [at, stoppedAt, why] = await varied(news)
  if (at !== refused || stoppedAt !== stop) fail(`${news} new call(s) after each cycle refusal: refused at ${at}, stops at ${stoppedAt}, wanted ${refused} and ${stop}`)
  if (stop && !why.includes("This run stops here.")) fail(`the varied cycle's stop did not say so: ${why}`)
}
// Old refusals expire: the stop counts three within 40 calls, so a long run may slip twice.
const spread = async (between) => {
  call = load()
  await inTurn(times(4, reads(1)))
  await inTurn(Array.from({ length: between }, (_, i) => reads(100 + i)))
  return (await inTurn(times(3, test())))[2]
}
const near = await spread(36)
if (near[0] !== "2" || !near[2]) fail("a third refusal 40 calls after the first did not end the run")
const far = await spread(37)
if (far[0] !== "2" || far[2]) fail("a third refusal 41 calls after the first ended the run")
// A new prompt starts over: "try again" is not refused for what the last prompt did.
call = load()
await inTurn(times(4, reads(1)))
call.handlers.before_agent_start?.()
const fresh = await inTurn(times(3, reads(1)))
if (codes(fresh) !== "002") fail(`a new prompt did not clear the call history: ${codes(fresh)}`)
if (fresh[2][2]) fail("a new prompt did not clear the refusals: the first refusal after it ended the run")
// A retry does not. Pi fires agent_start again for it, and a loop must not earn a clean slate from a dropped stream.
call = load()
await inTurn(times(4, reads(1)))
call.handlers.agent_start?.()
const retry = await inTurn([reads(1)])
if (codes(retry) !== "2" || !retry[0][2]) fail(`a retry's agent_start cleared the loop: ${codes(retry)} stop ${retry[0][2]}`)
// A call that fails Pi's validation never reaches the hook: Pi rejects it first, so
// only the two execution events tell the guard it happened. The bench's step 2 sent
// one such edit 179 times in a row.
let ids = 0
const session = () => { const ctx = { aborts: 0, notes: [], abort() { ctx.aborts++ }, ui: { notify: (m, t) => ctx.notes.push([m, t]) } }; return ctx }
const rejected = (ctx, [toolName, args]) => {
  const toolCallId = `rejected-${ids++}`
  call.handlers.tool_execution_start?.({ type: "tool_execution_start", toolCallId, toolName, args }, ctx)
  call.handlers.tool_execution_end?.({ type: "tool_execution_end", toolCallId, toolName, result: { content: [] }, isError: true }, ctx)
}
const brokenEdit = (n = 0) => ["edit", { path: dummy, edits: `[{"oldText": "a${n}"}]}]` }]
const rejectedTimes = (ctx, n, c = brokenEdit()) => { for (let i = 0; i < n; i++) rejected(ctx, c) }
// The fifth identical failure in a row is the third repeat hit: the run ends there, and the user is told why.
call = load()
let ctx = session()
rejectedTimes(ctx, 4)
if (ctx.aborts !== 0 || ctx.notes.length) fail(`four failed calls already stopped the run: ${ctx.aborts} ${JSON.stringify(ctx.notes)}`)
rejectedTimes(ctx, 1)
if (ctx.aborts !== 1) fail(`the fifth identical failed call did not abort the run: ${ctx.aborts}`)
if (ctx.notes.length !== 1 || ctx.notes[0][1] !== "error" || !ctx.notes[0][0].includes("This run stops here.")) fail(`the stop did not notify the user: ${JSON.stringify(ctx.notes)}`)
// A model that fails three times and then does something else is fine: the bench's first runs did that, then used write.
call = load()
ctx = session()
rejectedTimes(ctx, 3)
await inTurn(Array.from({ length: 5 }, (_, i) => reads(i)))
if (ctx.aborts !== 0) fail("three failed calls and then other work stopped the run")
// Different failed calls are not a loop.
call = load()
ctx = session()
for (let i = 0; i < 8; i++) rejected(ctx, brokenEdit(i))
if (ctx.aborts !== 0) fail("eight different failed calls stopped the run")
// A failed call in a cycle with a valid one: the short-cycle rule sees both.
call = load()
ctx = session()
const seq = []
for (let i = 0; i < 7; i++) { seq.push(await verdict(...reads(1))); rejected(ctx, brokenEdit()); seq.push(ctx.aborts) }
if (seq[12][0] !== "2") fail(`a read alternating with a failed edit was not refused on the 13th call: ${seq[12][0]}`)
if (ctx.aborts !== 1 || seq[11] !== 0) fail(`a read alternating with a failed edit did not stop on the 14th call: ${seq[11]} then ${ctx.aborts}`)
// One counter: hits from failed calls and from refusals add up.
call = load()
ctx = session()
rejectedTimes(ctx, 4)
const mixed = await inTurn(times(3, reads(1)))
if (codes(mixed) !== "002" || !mixed[2][2]) fail(`hits from failed calls and refusals did not add up to the stop: ${codes(mixed)} stop ${mixed[2][2]}`)
// A call that reached the hook is counted there and not again, even when it then fails: a failing test run is not a rejected call.
call = load()
ctx = session()
const ran = async ([toolName, args]) => {
  const toolCallId = `ran-${ids++}`
  call.handlers.tool_execution_start?.({ type: "tool_execution_start", toolCallId, toolName, args }, ctx)
  const r = await call(toolName, args, dir, toolCallId)
  call.handlers.tool_execution_end?.({ type: "tool_execution_end", toolCallId, toolName, result: { content: [] }, isError: true }, ctx)
  return r
}
const twice = [await ran(test()), await ran(test())]
if (twice.some(Boolean)) fail("a call that reached the hook and then failed was counted twice")
if (ctx.aborts !== 0) fail("a call that reached the hook and then failed stopped the run")
// A call that succeeds, or an end with no start, records nothing.
call = load()
ctx = session()
for (let i = 0; i < 6; i++) {
  call.handlers.tool_execution_start?.({ type: "tool_execution_start", toolCallId: `ok-${i}`, toolName: "read", args: { path: sample } }, ctx)
  call.handlers.tool_execution_end?.({ type: "tool_execution_end", toolCallId: `ok-${i}`, toolName: "read", result: { content: [] }, isError: false }, ctx)
  call.handlers.tool_execution_end?.({ type: "tool_execution_end", toolCallId: `none-${i}`, toolName: "read", result: { content: [] }, isError: true }, ctx)
}
if (ctx.aborts !== 0) fail("a successful call, or an end with no start, was counted")
// Old hits expire, as they do for refusals.
const spreadFailed = async (between) => {
  call = load()
  ctx = session()
  rejectedTimes(ctx, 4)
  await inTurn(Array.from({ length: between }, (_, i) => reads(200 + i)))
  rejectedTimes(ctx, 3, brokenEdit(9))
  return ctx.aborts
}
if ((await spreadFailed(36)) !== 1) fail("a third hit 40 calls after the first did not abort the run")
if ((await spreadFailed(37)) !== 0) fail("a third hit 41 calls after the first aborted the run")
// A new prompt clears it, and a retry does not.
call = load()
ctx = session()
rejectedTimes(ctx, 4)
call.handlers.before_agent_start?.()
rejectedTimes(ctx, 4)
if (ctx.aborts !== 0) fail("a new prompt did not clear the failed calls")
call = load()
ctx = session()
rejectedTimes(ctx, 4)
call.handlers.agent_start?.()
rejectedTimes(ctx, 1)
if (ctx.aborts !== 1) fail("a retry's agent_start cleared the failed calls")
process.exit(fails ? 1 : 0)
JS

# A commit is refused while HEAD is on a base branch — a run that skipped
# branch.sh once committed a step straight onto master — and allowed on a step
# branch, or where there is no repository at all (the two tables above).
cat > "$work/onbase-cases.txt" <<'TABLE'
2:@LIB@/branch.sh|git commit -m "x"
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
