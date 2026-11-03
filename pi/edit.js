// edit — Pi's own edit tool, with one more argument repair in front of it.
//
// The bench's model sent `edits` as a JSON string with raw newlines inside its
// values. Pi's shim gives up on that (JSON.parse throws), so validation refused
// the call, three times, and the model rewrote whole files with write instead.
// This registers Pi's edit definition under the same name — an extension tool
// replaces the built-in of that name — with prepareArguments running
// repairEditArgs (pi/edit-args.js) first and Pi's own shim after it. A string it
// cannot repair fails here with its JSON error; nothing is guessed. Nothing else
// about the tool changes: its schema, its execution and its rendering are Pi's.

import { createEditToolDefinition } from "@earendil-works/pi-coding-agent"
import { repairEditArgs, editArgsProblem } from "./edit-args.js"

function definition(cwd) {
  const base = createEditToolDefinition(cwd)
  const prepare = base.prepareArguments
  return {
    ...base,
    prepareArguments: (args) => {
      const problem = editArgsProblem(args)
      if (problem) throw new Error(problem) // Pi returns this as the tool's error
      const repaired = repairEditArgs(args)
      return prepare ? prepare(repaired) : repaired
    },
  }
}

export default function devEdit(pi) {
  let cwd = process.cwd()
  pi.registerTool(definition(cwd))
  // The tool resolves relative paths against the directory it was made for.
  pi.on("session_start", (_event, ctx) => {
    if (ctx?.cwd && ctx.cwd !== cwd) {
      cwd = ctx.cwd
      pi.registerTool(definition(cwd))
    }
  })
}
