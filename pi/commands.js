// commands — every skills/<name>/SKILL.md as a Pi command, /<name>.
//
// The skill is not handed to Pi as a skill: Pi would list it in the system
// prompt and leave its "!`…`" lines unrun. Instead the command runs them here
// (pi/expand.js) and sends the result as the user's message, so the model gets
// the facts already computed, the same block OpenCode used to assemble.
//
// The scripts the injections and the model call live in this checkout's lib/.
// DEV_SKILLS_LIB points there, and DEV_SKILLS_CONTEXT carries the active
// model's window, which profile.sh and step-budget.sh size steps against.
// Both are also set on process.env, which the model's own bash calls inherit.

import { execFileSync } from "node:child_process"
import { existsSync, readdirSync, readFileSync } from "node:fs"
import { dirname, isAbsolute, join } from "node:path"
import { fileURLToPath } from "node:url"
import { description, expandSkill } from "./expand.js"
import { idleProblem, isLocalUrl } from "./idle-timeout.js"

const root = dirname(dirname(fileURLToPath(import.meta.url)))
const skills = join(root, "skills")
const lib = join(root, "lib")

// The skill directories, in name order.
export function skillNames(dir = skills) {
  return readdirSync(dir, { withFileTypes: true })
    .filter((d) => d.isDirectory() && existsSync(join(dir, d.name, "SKILL.md")))
    .map((d) => d.name)
    .sort()
}

// The lines an injection printed to stop the command: from a line starting
// "STOP " to the next blank one, or null. lib/step-start.sh prints one when the
// step's branch is refused or the plan is written to be built by hand — a
// decision code has already made, so the model is never asked to make it again.
export function stopLines(block) {
  const lines = block.split("\n")
  const i = lines.findIndex((l) => l.startsWith("STOP "))
  if (i < 0) return null
  const end = lines.findIndex((l, k) => k > i && l.trim() === "")
  return lines.slice(i, end < 0 ? undefined : end).join("\n").replace(/^STOP /, "")
}

// --- the step gate --------------------------------------------------------
//
// "One step per run" was prose, and the bench's first session ticked and
// committed step 1, then ran branch.sh for step 2 and kept building. While a
// /dev-implement session is on step N, the scripts that start or tick a step
// are refused for any other N; and once step N is ticked, committed and the
// tree is clean, every further tool call is refused but the learned.md line
// the report writes, the third refusal ending the run. Done is read from the
// tree, never from what the model says.

const REFUSES = "dev-guard refuses: "
const STEP_SCRIPTS = /\b(branch|tick|task-step|step-budget)\.sh\b([^|;&\n]*)/g

// The step and task file a dev-implement block was handed, or null.
export function stepOf(block) {
  const step = block.match(/^## Step (\d+) of \d+/m)
  const file = block.match(/^\*\*Task file:\*\* (.+)$/m)
  return step && file ? { step: Number(step[1]), taskFile: file[1].trim() } : null
}

// The step numbers a command passes to the step scripts.
export function stepsNamed(command) {
  const named = []
  for (const m of command.matchAll(STEP_SCRIPTS)) {
    const words = m[2].trim().split(/\s+/).map((w) => w.replace(/^["']|["']$/g, "")).filter((w) => w && w !== "--step")
    const n = words.slice(1).find((w) => /^\d+$/.test(w))
    if (n) named.push(Number(n))
  }
  return named
}

// Whether a command asks task-step.sh for "the next step" — --next, --continue,
// or no step at all — which is how a session starts, never something it does
// mid-step. --count and --paths <n> only read.
export function asksForNextStep(command) {
  for (const m of command.matchAll(STEP_SCRIPTS)) {
    if (m[1] !== "task-step") continue
    const words = m[2].trim().split(/\s+/).filter(Boolean)
    if (words.some((w) => w === "--count" || w === "--paths")) continue
    if (words.some((w) => w === "--next" || w === "--continue")) return true
    if (!words.slice(1).some((w) => /^\d+$/.test(w.replace(/^["']|["']$/g, "")))) return true
  }
  return false
}

function git(cwd, ...args) {
  try {
    return execFileSync("git", ["-C", cwd, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim()
  } catch {
    return null
  }
}

// Whether step n is ticked in the task file, read by steps.awk as every script reads it.
function ticked(taskFile, n) {
  try {
    const anywhere = /^## Steps/m.test(readFileSync(taskFile, "utf8")) ? 0 : 1
    const list = execFileSync("awk", ["-v", "mode=list", "-v", `anywhere=${anywhere}`, "-f", join(lib, "steps.awk"), taskFile], { encoding: "utf8" })
    return list.split("\n").some((l) => l === `${n}|x|` || l.startsWith(`${n}|x|`))
  } catch {
    return false
  }
}

// Done: ticked, HEAD past where the step started, nothing uncommitted.
export function stepDone(state, cwd) {
  if (!ticked(state.taskFile, state.step)) return false
  const head = git(cwd, "rev-parse", "HEAD")
  if (!head || head === state.startHead) return false
  return git(cwd, "status", "--porcelain") === ""
}

// A command line's simple commands, as written. Split where the line splits
// outside quotes, so a ";" inside a quoted note does not split it.
function simpleCommands(command) {
  const blank = command.replace(/'[^']*'|"[^"]*"/g, (q) => " ".repeat(q.length))
  const parts = []
  let from = 0
  for (const m of blank.matchAll(/\|\||&&|[;|\n]/g)) {
    parts.push(command.slice(from, m.index))
    from = m.index + m[0].length
  }
  parts.push(command.slice(from))
  return parts.map((p) => p.trim()).filter(Boolean)
}

// The only call a finished step still makes: the report's one learned.md line —
// a command line in which every simple command is a text tool working on
// .devskills/learned…, nothing else riding along.
const LEARNED = /(^|[\s"'=/])\.devskills\/learned[.\w-]*/
const TEXT_TOOL = /^(echo|printf|tail|head|mv|cp|mkdir)(\s|$)/
const learnedOnly = (toolName, input) => {
  if (toolName === "write" || toolName === "edit") return /(^|\/)\.devskills\/learned\.md$/.test(input?.path ?? "")
  if (toolName !== "bash" || typeof input?.command !== "string") return false
  const parts = simpleCommands(input.command)
  return parts.length > 0 && parts.every((p) => TEXT_TOOL.test(p) && LEARNED.test(p))
}

export function gate(state, event, cwd) {
  if (!state) return undefined
  const input = event.input ?? {}
  // Done first: once the step is finished, every refusal counts towards the end.
  if (stepDone(state, cwd)) {
    if (learnedOnly(event.toolName, input)) return undefined
    state.refusals = (state.refusals ?? 0) + 1
    return {
      block: true,
      reason: `${REFUSES}step ${state.step} is done — ticked and committed, the tree clean. Make no more tool calls: ` +
        "write the report now (what landed, criteria, the quoted test line), then the next step is /new and /dev-review.",
      terminate: state.refusals >= 3,
    }
  }
  if (event.toolName === "bash" && typeof input.command === "string") {
    const next = asksForNextStep(input.command)
    const other = next ? "the next one" : stepsNamed(input.command).find((n) => n !== state.step)
    if (other !== undefined) {
      return {
        block: true,
        reason: `${REFUSES}this session is step ${state.step} of ${state.taskFile}; ${next ? "the next step" : `step ${other}`} starts in its own session. ` +
          `Finish step ${state.step}, tick it, commit, report — then /new and /dev-implement for the next one.`,
      }
    }
  }
  return undefined
}

// What the injections run with, for the model this session has selected.
export function injectionEnv(model) {
  const env = { DEV_SKILLS_LIB: lib }
  const window = model?.contextWindow
  if (Number.isInteger(window) && window > 0) env.DEV_SKILLS_CONTEXT = String(window)
  if (typeof model?.id === "string" && model.id) env.PI_MODEL = model.id
  return env
}

export default function devCommands(pi) {
  process.env.DEV_SKILLS_LIB = lib
  // What the user exported, if anything: a model that declares no window gets
  // this back, never the window of the model selected before it.
  const exported = process.env.DEV_SKILLS_CONTEXT
  // The /dev-implement step this session is on, or null.
  let state = null
  // The idle timeout's warning, once a session: it's a setup problem, not a step's.
  let warned = false
  pi.on?.("session_start", () => { state = null; warned = false })
  pi.on?.("tool_call", (event, ctx) => gate(state, event, ctx?.cwd || process.cwd()))
  for (const name of skillNames()) {
    const file = join(skills, name, "SKILL.md")
    pi.registerCommand(name, {
      description: description(readFileSync(file, "utf8")),
      handler: async (args, ctx) => {
        await ctx.waitForIdle()
        state = null
        const settings = pi.getSettings?.()
        const problem = settings && isLocalUrl(ctx.model?.baseUrl) ? idleProblem(settings.httpIdleTimeoutMs) : null
        if (problem && !warned) {
          warned = true
          if (ctx.ui?.notify) ctx.ui.notify(`/${name}: ${problem}`, "warning")
          else console.error(`/${name}: ${problem}`)
        }
        const env = injectionEnv(ctx.model)
        const window = env.DEV_SKILLS_CONTEXT ?? exported
        if (window === undefined) delete process.env.DEV_SKILLS_CONTEXT
        else process.env.DEV_SKILLS_CONTEXT = window
        // Read at run time, so an edited SKILL.md applies without /reload.
        const block = await expandSkill(readFileSync(file, "utf8"), {
          args: (args ?? "").trim(),
          cwd: ctx.cwd,
          env,
        })
        const stop = stopLines(block)
        if (stop) {
          if (ctx.ui?.notify) ctx.ui.notify(`/${name}: ${stop}`, "error")
          else console.error(`/${name}: ${stop}`)
          return
        }
        if (name === "dev-implement") {
          const at = stepOf(block)
          if (at) {
            const taskFile = isAbsolute(at.taskFile) ? at.taskFile : join(ctx.cwd, at.taskFile)
            state = { ...at, taskFile, startHead: git(ctx.cwd, "rev-parse", "HEAD"), refusals: 0 }
          }
        }
        pi.sendUserMessage(block)
      },
    })
  }
}
