// guard — a Pi extension that refuses the commands every skill here bans.
//
// The skills say "never --force, never --amend, never --no-verify, never push
// to the base branch, never merge" in prose. A 30B model follows prose most of
// the time; this is for the rest of the time. It runs on Pi's tool_call event,
// before every tool call, and blocks — { block: true, reason } — on:
//
//   git push --force / --force-with-lease / -f
//   git commit --amend
//   --no-verify on any git command
//   git push to main, master, or the profile's baseBranch, in every ref shape
//   git commit while HEAD is on main, master, or the profile's baseBranch
//   gh pr merge, gh pr review --approve, gh release create|edit|delete|upload,
//   gh workflow run|enable|disable, gh api …/merge
//   rm of node_modules, vendor or a lock file, which the profile's install provides
//   a project's test runner or installer run bare on the host when its profile
//   runs in a container (exec.kind image or compose); the refusal names test.sh,
//   the profile's install, or its exec.prefix
//
// Before any tool runs, it also repairs the argument mistakes local models make
// most — an unescaped backslash in a grep pattern, a file passed to find as its
// directory, a timeout in milliseconds where Pi wants seconds, line endings
// that differ from the file — refuses to read a directory, and breaks a loop of
// tool calls: three identical in a row or a short cycle of them. A write of what the
// file already holds is refused the first time. The third of any of these within 40
// calls ends the run. Calls
// that fail Pi's validation count too, though they never reach this hook:
// checkRejected sees them after the fact. Repairs change event.input in place, which
// Pi runs.
//
// After a bash call that reports a syntax error in a JS/TS file under cwd, it adds
// one line to the result: which block never closes and where its close belongs
// (pi/brackets.js). The test output alone names only the file's last line. After tsc
// errors, it adds each line tsc names as the file holds it now (pi/tsc-lines.js), and
// after an edit Pi couldn't find, which of oldText's lines matched where and the first
// that didn't (pi/edit-miss.js): Pi says only that the text wasn't found.
//
// It refuses sed in place (sed -i): in the bench each one was an edit-sized change
// written as a pattern over the whole file, and on macOS each failed on BSD sed's
// backup suffix. The refusal points to edit.
//
// Quoted text is blanked first, so a commit message may mention a flag.
// Everything else runs — gh pr create and gh pr ready included, which /dev-pr
// uses on purpose. package.json lists this file under pi.extensions, so it is
// on for every session.
//
// Ported from claude-skills' scripts/guard.sh — MIT, same author. The rules are unchanged;
// the argument names are Pi's: bash {command, timeout seconds}, read {path},
// edit {path, edits: [{oldText, newText}]}, write {path, content},
// grep {pattern, literal}, find {path}.

import { existsSync, statSync, readFileSync } from "node:fs"
import { join, dirname, resolve } from "node:path"
import { LIB, shellWord } from "./lib-path.js"
import { syntaxHint } from "./brackets.js"
import { editMissHint } from "./edit-miss.js"
import { tscLines } from "./tsc-lines.js"

const SEG = "[^|;&]*" // the rest of one command in a pipeline or chain
const REFUSES = "dev-guard refuses: "
const LOOP_WINDOW = 12
const LOOP_DISTINCT = 3
const LOOP_STOP_AT = 3 // repeat refusals that end the run...
const LOOP_STOP_WITHIN = 40 // ...when they fall within this many calls: a short cycle only refuses again after 12 fresh calls, so three refusals with anything between them span 26 or more
const LOOP_ADVICE = "Running them again will not change the result. Stop calling tools and say in your answer what blocks you."

// A branch name is a literal here, not a pattern: release.1 must not match release01.
const literal = (s) => s.replace(/[^A-Za-z0-9_/-]/g, "\\$&")

// The profile's base branch, when a profile has been written for this directory.
export function baseBranches(directory) {
  const bases = ["main", "master"]
  try {
    const profile = JSON.parse(readFileSync(join(directory, ".devskills", "profile.json"), "utf8"))
    if (typeof profile.baseBranch === "string" && profile.baseBranch && !bases.includes(profile.baseBranch)) {
      bases.push(profile.baseBranch)
    }
  } catch {
    // no profile yet, or not a git repository: main and master still hold
  }
  return bases
}

// The branch HEAD is on, read from .git/HEAD (or the worktree's HEAD when .git
// is a "gitdir:" file); null when detached or not a repository. Read at every
// call, not once: the branch changes during a session, and a run that skipped
// branch.sh — one did, after a failed first try — must be refused by the state
// the tree is actually in.
export function currentBranch(directory) {
  try {
    let git = join(directory, ".git")
    if (statSync(git).isFile()) {
      const m = readFileSync(git, "utf8").match(/^gitdir:\s*(.+)$/m)
      if (!m) return null
      git = resolve(directory, m[1].trim())
    }
    const head = readFileSync(join(git, "HEAD"), "utf8").match(/^ref:\s*refs\/heads\/(.+)$/m)
    return head ? head[1].trim() : null
  } catch {
    return null
  }
}

// The reason to refuse a shell command, or null.
export function reasonToRefuse(command, bases, onBranch) {
  if (typeof command !== "string" || !/\b(git|gh)\b/.test(command)) return null
  // Talk about a flag is not use of it: blank quoted text, keep what is outside.
  const scan = command.replace(/'[^']*'/g, "''").replace(/"[^"]*"/g, '""')
  const has = (re) => new RegExp(re).test(scan)

  if (has(`git${SEG}push${SEG}(--force|--force-with-lease|(^|\\s)-f(\\s|$))`)) {
    return "a forced push rewrites history somebody else may have. Push a new commit instead."
  }
  if (has(`git${SEG}commit${SEG}--amend`)) {
    return "--amend rewrites the last commit. Make a new commit instead."
  }
  if (has(`git${SEG}--no-verify`)) {
    return "--no-verify skips a hook. A failing hook means the code needs fixing."
  }
  if (onBranch && bases.includes(onBranch) && has(`git${SEG}commit(\\s|$)`)) {
    return `a commit on the base branch '${onBranch}'. Cut the step branch first — ` +
      `bash ${shellWord(LIB)}/branch.sh <task-file> <n> — and commit there.`
  }
  if (has(`gh${SEG}pr${SEG}\\smerge(\\s|$)`)) {
    return "merging is where this stops. Open or update the pull request; a person merges it."
  }
  if (has(`gh${SEG}pr${SEG}\\s--approve(\\s|$)`)) {
    return "approving is a reviewer's act. A run that wrote the change cannot also approve it."
  }
  if (has(`gh${SEG}release\\s+(create|edit|delete|upload)(\\s|$)`)) {
    return "a release ships to users. That is a decision a person makes, after the merge."
  }
  if (has(`gh${SEG}workflow\\s+(run|enable|disable)(\\s|$)`)) {
    return "running a workflow reaches CI and whatever it deploys. Ask before triggering it."
  }
  if (has(`gh${SEG}api${SEG}/merge`)) {
    return "that API call merges. Opening the pull request is where this stops."
  }
  for (const b of bases) {
    // After a space or a colon (HEAD:main), with an optional + (itself a force),
    // spelled out or not (refs/heads/main), and ending there.
    if (has(`git${SEG}push${SEG}(\\s|:)\\+?(refs/heads/)?${literal(b)}(\\s|:|$)`)) {
      return `a push to the base branch '${b}'. A change lands through a pull request — /dev-pr opens it.`
    }
  }
  return null
}

// The profile written for this directory, or null.
export function readProfile(directory) {
  try {
    return JSON.parse(readFileSync(join(directory, ".devskills", "profile.json"), "utf8"))
  } catch {
    return null
  }
}

// What a family runs its tests and installs with. A project whose profile runs
// in a container runs these through it; bare on the host they use the host's
// binaries, which is how a bench run replaced the container's node_modules with
// macOS ones. Plain `node`, `php -l` and the like are not in here on purpose:
// a quick script on the host is not a test run.
const RUNNERS = {
  node: /^(npx|npm|pnpm|yarn|vitest|jest)(\s|$)|^node\s(.*\s)?--test(\s|$)/,
  php: /^(composer|phpunit|(\.\/)?vendor\/bin\/\S+)(\s|$)|^php\s+(artisan|(\.\/)?vendor\/bin\/)/,
  python: /^(pytest|pip3?|tox|poetry)(\s|$)|^python3?\s+-m\s+(pytest|pip)(\s|$)/,
}
const FAMILY = {
  node: "node", "php-app": "php", "php-library": "php", "moodle-plugin": "php", cms: "php", "python-app": "python",
}
const INSTALLS = /^(npm|pnpm|yarn|composer|pip3?|poetry)\s+(ci|i|install|add|require|update)(\s|$)|^yarn$|^python3?\s+-m\s+pip\s+install/
// What `install` puts back. Deleting one breaks every run after it.
const DEPENDENCIES = /^(node_modules|vendor|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|composer\.lock|poetry\.lock|Cargo\.lock)$/

// A command's words without the ones that only wrap it: VAR=value assignments,
// and sudo, env, time, nohup, command and exec with their own flags.
const WRAPPERS = /^(sudo|env|time|nohup|command|exec)$/
function unwrap(words) {
  let i = 0
  while (i < words.length) {
    if (/^\w+=/.test(words[i])) { i++; continue }
    if (!WRAPPERS.test(words[i])) break
    i++
    while (words[i]?.startsWith("-")) i++
  }
  return words.slice(i)
}

const unquote = (word) => word.replace(/^(['"])(.*)\1$/, "$2")
// Whether a path names something install provides: by its last component,
// quoted or not, relative or absolute.
const isDependency = (word) => DEPENDENCIES.test(unquote(word).replace(/\/+$/, "").split("/").pop())

// Whether a command deletes what install provides — rm of it, or find naming it
// with -delete or -exec rm. Read from the command as written: quotes are what a
// model reaches for once the bare form is refused, so they are not blanked here.
function deletesDependency(command) {
  for (const seg of command.split(/\|\||&&|[;|\n]/)) {
    const words = unwrap(seg.trim().split(/\s+/).filter(Boolean))
    if (words[0] === "rm" && words.slice(1).some((w) => !w.startsWith("-") && isDependency(w))) return true
    if (words[0] === "find") {
      const deletes = words.includes("-delete") || words.some((w, k) => w === "-exec" && /^(\/bin\/)?rm$/.test(words[k + 1] ?? ""))
      const names = words.some((w, k) => /^-(i?name|path)$/.test(w) && isDependency(words[k + 1] ?? ""))
      if (deletes && names) return true
    }
  }
  return false
}

// One command line as its simple commands: split on ; && || | and newlines,
// `cd …` ones dropped, each unwrapped (VAR=value, sudo, env, time…) so a
// wrapper word cannot hide the runner. Quoted text is blanked first, so talk
// about a command is not the command.
function segments(command) {
  const scan = command.replace(/'[^']*'/g, "''").replace(/"[^"]*"/g, '""')
  return scan.split(/\|\||&&|[;|\n]/)
    .map((s) => unwrap(s.trim().split(/\s+/).filter(Boolean)).join(" "))
    .filter((s) => s && !/^cd(\s|$)/.test(s))
}

// The reason to refuse a shell command that runs a project's tooling the wrong
// way or deletes what install provides, or null.
export function reasonToRefuseRun(command, profile) {
  if (typeof command !== "string") return null
  const install = typeof profile?.install === "string" && profile.install ? profile.install : null
  if (deletesDependency(command)) {
    return "node_modules, vendor and lock files come from the profile's install" +
      (install ? ` (${install})` : "") + ", and deleting them breaks every run after this one. " +
      "Leave them, and say in the report what was wrong instead. A test that fails to load is a problem to report, not a reinstall."
  }
  const kind = profile?.exec?.kind
  const family = RUNNERS[FAMILY[profile?.family]]
  if ((kind !== "image" && kind !== "compose") || !family) return null
  const prefix = typeof profile.exec.prefix === "string" ? profile.exec.prefix : ""
  for (const seg of segments(command)) {
    if (!family.test(seg)) continue
    const where = `this project runs its tooling in a container (exec.kind ${kind}); on the host it runs with the host's binaries and a different set of dependencies.`
    if (INSTALLS.test(seg)) {
      return `${where} Install with the profile's command${install ? `: ${install}` : `, through ${prefix}`}.`
    }
    return `${where} Run the tests with bash ${shellWord(LIB)}/test.sh (--scoped <name> for one file), or run the command after the profile's prefix: ${prefix} <command>`
  }
  return null
}

// The reason to refuse sed in place, or null. In the bench every `sed -i` was an
// edit-sized change written as a pattern over the whole file, and on macOS each one
// failed: BSD sed reads the word after -i as a backup suffix, then the file's name as
// the script. Made to work, some would have changed every `});` in a test file.
// Only sed as the command itself: inside quotes (sh -c '…') or after another command
// (grep sed -i) it isn't run here.
const IN_PLACE = /^(-[a-zA-Z]*i|--in-place(=|$))/
export function inPlaceSedReason(command, platform = process.platform) {
  if (typeof command !== "string") return null
  if (!segments(command).some((seg) => { const w = seg.split(" "); return w[0] === "sed" && w.slice(1).some((x) => IN_PLACE.test(x)) })) return null
  const bsd = platform === "darwin" ? ", and this host's sed is BSD sed, which reads the word after -i as a backup suffix" : ""
  return `sed -i rewrites every line its pattern matches${bsd}. Make the change with edit: read or grep -n the lines first, and put only those lines in oldText.`
}

// Sanitizes grep regex patterns from local models.
// Local models frequently search for namespaces, Windows paths, or strings containing backslashes
// (e.g. "App\Models\User" or "C:\Path\To\File") without double-escaping for ripgrep's Rust regex engine.
// Rust regex throws fatal "unrecognized escape sequence" on unescaped backslashes, causing infinite retry loops.
export function sanitizeGrepPattern(pattern) {
  if (typeof pattern !== "string") return pattern
  // Match single backslash (not preceded by another backslash) followed by an alphanumeric character
  return pattern.replace(/(^|[^\\])\\([a-zA-Z0-9_])/g, (match, prefix, char, offset, fullStr) => {
    // Valid standard Rust regex escapes:
    // Classes: d, D, s, S, w, W
    // Boundaries: b, B, A, z
    // Whitespace/control: a, f, t, n, r, v, 0
    if (/^[dDsSwWbBAzaftnrv0]$/.test(char)) {
      return match
    }
    const after = fullStr.slice(offset + match.length - 1)
    // Hex: \xHH
    if (/^x[0-9a-fA-F]{2}/.test(after)) return match
    // Unicode: \uHHHH or \u{...}
    if (/^u([0-9a-fA-F]{4}|\{[0-9a-fA-F]+\})/.test(after)) return match
    // Unicode category: \p{...} or \P{...}
    if (/^[pP]\{[^}]+\}/.test(after)) return match

    // Anything else is an invalid escape in ripgrep that causes Exit 2.
    // Escape the backslash so ripgrep searches for literal \ + char.
    return prefix + "\\\\" + char
  })
}

// Sanitizes find's directory argument.
// Local models frequently pass a file path (e.g. "src/components/Header.tsx") as the directory
// to search in. If the target is a file (or has a file extension whose parent exists), search
// its parent directory instead. Relative paths are judged against the session's directory and
// returned in the form they were given.
export function sanitizeSearchDir(targetPath, cwd) {
  if (typeof targetPath !== "string" || !targetPath) return targetPath
  const full = resolve(cwd, targetPath)
  try {
    if (existsSync(full) && statSync(full).isFile()) {
      return dirname(targetPath)
    }
    if (!existsSync(full) && /\.[a-zA-Z0-9]{1,8}$/.test(targetPath)) {
      const parent = dirname(full)
      if (existsSync(parent) && statSync(parent).isDirectory()) {
        return dirname(targetPath)
      }
    }
  } catch {}
  return targetPath
}

// Sanitizes the bash timeout. Pi counts it in seconds; models trained on other
// harnesses pass milliseconds (timeout: 120000), which Pi reads as 33 hours.
// Anything of 1000 or more is taken as milliseconds and divided by 1000. Then a
// floor of 30 s, so heavy commands like grep and tests are not cut off before
// they start. The cost, accepted: a real seconds value of 1000 or more (3600,
// an hour) is read as milliseconds and runs with 30 s. Millisecond values from
// 1000 to 29999 are far more common, and read as seconds they would run for
// hours. A timeout that is <= 0 or not a finite number returns undefined,
// and the caller deletes it: Pi then runs the command without one.
export function sanitizeBashTimeout(timeout) {
  if (typeof timeout !== "number" || !Number.isFinite(timeout) || timeout <= 0) {
    return undefined
  }
  let seconds = timeout >= 1000 ? timeout / 1000 : timeout
  if (seconds < 30) {
    seconds = 30
  }
  return seconds
}

// How many times in a row this exact call has been made, counted in the history
// of one extension instance, to detect and abort infinite retry loops.
export function checkConsecutiveCalls(callHistory, tool, args) {
  const sig = JSON.stringify({ tool, args })
  callHistory.push(sig)
  if (callHistory.length > 20) callHistory.shift()
  let count = 0
  for (let i = callHistory.length - 1; i >= 0; i--) {
    if (callHistory[i] === sig) count++
    else break
  }
  return count
}

// A short cycle: the newest calls are only a few different calls, each made more
// than once. It catches what an in-a-row count cannot, a loop with something
// between its repeats. A call made once in the window has not repeated, so
// answering a refusal with something new lets that call, and the rerun after it, run.
export function isShortCycle(callHistory) {
  const recent = callHistory.slice(-LOOP_WINDOW)
  if (recent.length < LOOP_WINDOW) return false
  const counts = new Map()
  for (const sig of recent) counts.set(sig, (counts.get(sig) ?? 0) + 1)
  return counts.size <= LOOP_DISTINCT && [...counts.values()].every((n) => n >= 2)
}

// Counts one repeat. True when it is the one that ends the run: a model that keeps
// looping keeps ignoring what it is told, so the third within the limit stops it.
function countRepeat(loop) {
  loop.refusals = loop.refusals.filter((at) => loop.count - at <= LOOP_STOP_WITHIN)
  loop.refusals.push(loop.count)
  return loop.refusals.length >= LOOP_STOP_AT
}

// A call Pi rejected before the hook: it fails validation first, so tool_call and
// tool_result never fire for it, and only the execution events show it happened.
// It has already failed, so there is nothing to refuse: it goes in the same history
// and count, and when the count says stop, this ends the run from here.
export function checkRejected(event, ctx, loop) {
  const call = loop.started.get(event?.toolCallId)
  loop.started.delete(event?.toolCallId)
  if (!call || !event.isError) return
  loop.count++
  const inARow = checkConsecutiveCalls(loop.calls, call.tool, call.args)
  if (inARow < 3 && !isShortCycle(loop.calls)) return
  if (countRepeat(loop)) {
    ctx?.ui?.notify?.(`dev-guard: ${call.tool} calls keep failing before they run. This run stops here.`, "error")
    ctx?.abort?.()
  }
}

// Make text use the file's line endings: CRLF when the file has them, LF otherwise.
function matchLineEndings(text, crlf) {
  if (typeof text !== "string") return text
  if (crlf) return !text.includes("\r\n") && text.includes("\n") ? text.replace(/\r?\n/g, "\r\n") : text
  return text.includes("\r\n") ? text.replace(/\r\n/g, "\n") : text
}

// The text of the file a tool names, or null when there is none to read.
function fileText(path, cwd) {
  if (typeof path !== "string" || !path) return null
  try {
    const full = resolve(cwd, path)
    return existsSync(full) && statSync(full).isFile() ? readFileSync(full, "utf8") : null
  } catch {
    return null
  }
}

// One tool call, judged: { block: true, reason } to refuse it, undefined to let
// it run. event.input may be repaired in place first.
export function check(event, cwd, loop) {
  loop.started.delete(event?.toolCallId) // it reached the hook: counted here, not as rejected
  const tool = event?.toolName
  const input = event?.input
  if (!input || typeof input !== "object") return undefined
  const refuse = (reason) => ({ block: true, reason: REFUSES + reason })
  const callHistory = loop.calls
  loop.count++
  // Pi ends the run only when every result in a batch sets terminate
  // (pi-agent-core agent-loop.js, shouldTerminateToolBatch), so a looping call made in
  // parallel with a different one gets through that batch; it's caught on the next.
  const refuseRepeat = (reason) => {
    if (!countRepeat(loop)) return refuse(reason)
    return { ...refuse(`${reason} This run stops here.`), terminate: true }
  }

  // 1. Sanitize grep regex patterns to prevent fatal ripgrep crashes on unescaped
  //    backslashes. A literal search has no escapes to fix: its backslashes are text.
  if (tool === "grep" && typeof input.pattern === "string" && input.literal !== true) {
    input.pattern = sanitizeGrepPattern(input.pattern)
  }

  // 2. Sanitize find's directory when a file was mistakenly passed
  if (tool === "find" && typeof input.path === "string") {
    input.path = sanitizeSearchDir(input.path, cwd)
  }

  // 3. Prevent reading directories as files (which throws EISDIR)
  if (tool === "read" && typeof input.path === "string") {
    try {
      const full = resolve(cwd, input.path)
      if (existsSync(full) && statSync(full).isDirectory()) {
        return refuse(
          `"${input.path}" is a directory, not a file. ` +
          `Use 'find' or bash 'ls' to inspect its contents, or 'read' a file inside it.`
        )
      }
    } catch {}
  }

  // 4. Normalize line endings to match the target file (CRLF vs LF) to prevent spurious diff explosions
  if (tool === "edit" && Array.isArray(input.edits)) {
    const content = fileText(input.path, cwd)
    if (content !== null) {
      const crlf = content.includes("\r\n")
      for (const e of input.edits) {
        if (!e || typeof e !== "object") continue
        e.oldText = matchLineEndings(e.oldText, crlf)
        e.newText = matchLineEndings(e.newText, crlf)
      }
    }
  }
  if (tool === "write" && typeof input.content === "string") {
    const existing = fileText(input.path, cwd)
    if (existing !== null && existing.includes("\r\n")) {
      input.content = matchLineEndings(input.content, true)
    }
  }

  // 5. Prevent infinite edit retry loops on already-updated or mismatched files
  if (tool === "edit" && typeof input.path === "string") {
    const repeatCount = checkConsecutiveCalls(callHistory, "edit", input)
    if (repeatCount >= 2) {
      const content = fileText(input.path, cwd)
      const edits = Array.isArray(input.edits) ? input.edits : []
      if (content !== null && edits.length) {
        const applied = edits.find((e) => typeof e?.newText === "string" && e.newText && content.includes(e.newText))
        if (applied && edits.every((e) => typeof e?.newText === "string" && e.newText && content.includes(e.newText))) {
          return refuseRepeat(
            `"${applied.newText.trim().slice(0, 80)}" is already present in ${input.path}. ` +
            `This edit has already been applied. Do not retry; move on to the next file or task.`
          )
        }
        if (edits.some((e) => typeof e?.oldText === "string" && e.oldText && !content.includes(e.oldText))) {
          return refuseRepeat(
            `oldText was not found in ${input.path} and this edit call was already attempted. ` +
            `Do not retry the exact same call; read the file with 'read' or 'sed' to verify its actual content, or proceed to the next file.`
          )
        }
      }
      return refuseRepeat(
        `repeated identical edit call on ${input.path}. ` +
        `The previous call failed. Do not retry the exact same edit; inspect the file first or move on.`
      )
    }
  }

  // 6. General tool call loop breaker (any tool repeated 3x consecutively with identical args)
  if (tool !== "edit" && checkConsecutiveCalls(callHistory, tool, input) >= 3) {
    return refuseRepeat(
      `repeated identical tool call detected (3x for ${tool}). ${LOOP_ADVICE}`
    )
  }
  if (isShortCycle(callHistory)) {
    return refuseRepeat(
      `the last ${LOOP_WINDOW} tool calls repeat ${LOOP_DISTINCT} or fewer different calls with nothing new between them. ${LOOP_ADVICE}`
    )
  }

  // A write that changes nothing. Pi would answer "Successfully wrote", and the model
  // takes that for the fix it announced but left out. After the rules above, so the
  // call is in the history, and after the line endings repair, so this is what Pi would write.
  if (tool === "write" && typeof input.content === "string" && fileText(input.path, cwd) === input.content) {
    return refuseRepeat(
      `${input.path} already has exactly this content, so this write changes nothing and anything that failed will fail the same way. ` +
      `If you meant to change it, the change is not in what you wrote.`
    )
  }

  // 7. Sanitize the bash timeout when the model passes milliseconds instead of seconds
  if (tool === "bash" && "timeout" in input) {
    const sanitized = sanitizeBashTimeout(input.timeout)
    if (sanitized !== undefined) {
      input.timeout = sanitized
    } else {
      delete input.timeout
    }
  }

  // 8. Refuse forbidden bash operations
  if (tool !== "bash") return undefined
  const reason = reasonToRefuse(input.command, baseBranches(cwd), currentBranch(cwd)) ??
    reasonToRefuseRun(input.command, readProfile(cwd)) ??
    inPlaceSedReason(input.command)
  return reason ? refuse(reason) : undefined
}

export default function devGuard(pi) {
  // Per instance, not per module load: another instance's calls must not count.
  const fresh = () => ({ calls: [], refusals: [], count: 0, started: new Map() })
  let loop = fresh()
  // A new prompt starts over: "try again" is not refused for what the last prompt did.
  // Not agent_start: Pi fires that for its own retries too, and a dropped stream
  // must not wipe the count of a loop that is still going.
  pi.on("before_agent_start", () => { loop = fresh() })
  pi.on("tool_call", async (event, ctx) => check(event, ctx?.cwd || process.cwd(), loop))
  pi.on("tool_execution_start", (event) => { loop.started.set(event.toolCallId, { tool: event.toolName, args: event.args }) })
  pi.on("tool_execution_end", (event, ctx) => checkRejected(event, ctx, loop))
  pi.on("tool_result", (event, ctx) => {
    const content = event?.content ?? []
    const text = content.map((c) => c.text ?? "").join("")
    const cwd = ctx?.cwd || process.cwd()
    let hints = []
    if (event?.toolName === "bash") hints = [syntaxHint(text, cwd), tscLines(text, cwd)]
    else if (event?.toolName === "edit" && event.isError) hints = [editMissHint(event.input, text, cwd)]
    hints = hints.filter(Boolean)
    return hints.length ? { content: [...content, ...hints.map((h) => ({ type: "text", text: `\n\n${h}` }))] } : undefined
  })
}
