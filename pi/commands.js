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

import { existsSync, readdirSync, readFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { description, expandSkill } from "./expand.js"

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
  for (const name of skillNames()) {
    const file = join(skills, name, "SKILL.md")
    pi.registerCommand(name, {
      description: description(readFileSync(file, "utf8")),
      handler: async (args, ctx) => {
        await ctx.waitForIdle()
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
        pi.sendUserMessage(block)
      },
    })
  }
}
