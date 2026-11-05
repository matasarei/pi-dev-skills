// The check for a reply that repeats itself.
//
// At temperature 0 a local model sometimes starts repeating itself in text and
// writes on to the output limit, about 8 minutes, and a reply with no tool call
// then ends the session. Over 958 logged replies, the check below fired on all 3
// that did this, within about 40 s, and on none of the others. pi/commands.js acts
// on it. This isn't an extension itself.
//
// It sees text only. A local server holds a tool call's arguments back until they
// are complete, so a runaway inside them can't be seen. pi/cut-off.js has those.

const TAIL = 200
const TIMES = 3

// The third runaway in a command ends its run, as with the loop breaker. A tool call
// cut off at the limit counts as one (pi/cut-off.js).
export const STOP_AT = 3

// What replays tested: changing it changes what was proven.
export const NUDGE = "Your last reply started repeating itself, so it was stopped and removed. Do not explain again. Reply with one tool call that moves the step forward."

// One reply's watch. add() returns true once, when the text so far is repeating:
// its last TAIL characters have already appeared TIMES times.
export function createWatch() {
  let text = ""
  let checkedAt = 0
  let fired = false
  return {
    add(delta) {
      text += delta
      if (fired || text.length < TAIL * TIMES || text.length - checkedAt < TAIL) return false
      checkedAt = text.length
      const tail = text.slice(-TAIL)
      let seen = 0
      for (let i = text.indexOf(tail); i >= 0 && seen < TIMES; i = text.indexOf(tail, i + 1)) seen++
      fired = seen >= TIMES
      return fired
    },
  }
}
