// lib-path — where this checkout's scripts are, as the model is shown it.
//
// The skills write a script as $DEV_SKILLS_LIB/<script>.sh, and the injections
// run with the variable set (pi/commands.js). Text the model reads names the
// absolute path instead: shown the variable, a local model sometimes filled in
// a home of its own (/home/user/...), then ran whatever copy `find /` turned up.
// Not an extension: pi/expand.js, pi/commands.js, pi/guard.js and
// pi/failing-runs.js import it.

import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

export const LIB = join(dirname(dirname(fileURLToPath(import.meta.url))), "lib")

// The path as one shell word: as it is when nothing in it needs quoting.
export function shellWord(path) {
  return /^[A-Za-z0-9_./-]+$/.test(path) ? path : `'${path.replace(/'/g, `'\\''`)}'`
}

// The text with every ${DEV_SKILLS_LIB:-…}, ${DEV_SKILLS_LIB} and $DEV_SKILLS_LIB
// replaced by the path.
export function withLibPath(text, lib = LIB) {
  return text.replace(/\$\{DEV_SKILLS_LIB(?::-[^}]*)?\}|\$DEV_SKILLS_LIB(?![A-Za-z0-9_])/g, () => shellWord(lib))
}
