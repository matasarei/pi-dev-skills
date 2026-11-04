// A test run that failed, read from what a bash call returned.
//
// After this many in a /dev-implement session, pi/commands.js offers the model
// lib/test-open.sh. A model can write a test that can never pass and not see it, and
// every later step waits behind it. It's counted here, on every bash result, since
// on a failing run the bench's model mostly calls the runner directly, often through
// grep: test.sh saw at most 4 failures in a session where the model saw 44. It's any
// failing run, not per test, because a grep often hides the name. The one recovery in
// the logs took 6, so 5 can't separate it from a stuck session: it's an offer. This
// isn't an extension itself.

export const OFFER_AT = 5

export const OFFER = `This step's tests have now failed ${OFFER_AT} runs. If what still fails is a test this step added, and you can't fix it, run: bash \${DEV_SKILLS_LIB:-$HOME/.config/opencode/dev-lib}/test-open.sh. It records that test as open, so the step can tick and commit. The test stays failing, and /dev-pr refuses until it passes, so name it in your report. It refuses a test that was there before. Don't use it to skip a fix you can make.`

// The rules are failed_as_test's in lib/test.sh, plus vitest's name line, which a grep
// keeps when it drops the count. An open test isn't a new failure, and a red run fails
// on purpose.
export function failedTestRun(text) {
  if (typeof text !== "string" || /^(TEST OPEN|RED )\b/.test(text)) return false
  let node = false
  let load = false
  for (const line of text.split("\n")) {
    if (/Test Suites:|Test Files /.test(line)) continue
    if (/(^|[^0-9])[1-9][0-9]* failed/.test(line)) return true
    if (/Tests: *[1-9]/.test(line) && /(Failures|Errors): *[1-9]/.test(line)) return true
    if (/^--- FAIL:/.test(line)) return true
    if (/^\s*FAIL\s+\S.* > /.test(line)) return true
    if (/SyntaxError:|Cannot find module|MODULE_NOT_FOUND/.test(line) || /^✖ \S+\.[cm]?[jt]sx? \(/.test(line)) load = true
    if (/\bfail [1-9][0-9]*\s*$/.test(line)) node = true
  }
  return node && !load
}
