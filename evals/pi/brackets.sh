#!/usr/bin/env bash
# Where a JS/TS file's brackets stop matching, in pi/brackets.js, and the hint the
# guard adds to a bash result that reports a syntax error — run it from anywhere:
#
#   bash evals/pi/brackets.sh
#
# The fixtures are two test files the bench's model left broken, each with one
# `describe` never closed. vitest said only "Unexpected end of file" at the last
# line, and the model hunted for the missing `});` for 30-40 calls. The count
# decides whether a file is broken; the indent rule only says where.
#
# Exits 0 when every case holds, 1 otherwise, naming each failure.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
command -v node >/dev/null 2>&1 || { printf 'brackets: node is required — not installed\n' >&2; exit 1; }

node --input-type=module - "$root" <<'JS'
import { cpSync, mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs"
import { join } from "node:path"
import { tmpdir } from "node:os"
const root = process.argv[2]
const { unbalanced, syntaxHint } = await import(`${root}/pi/brackets.js`)
const fails = []
const fixtures = `${root}/evals/pi/fixtures/brackets`
const same = (got, want) => JSON.stringify(got) === JSON.stringify(want)

// The two files from the bench, placed where the model needed them.
for (const name of ["edit-left-open.test.ts", "rewrite-left-open.test.ts"]) {
  const got = unbalanced(readFileSync(`${fixtures}/${name}`, "utf8"))
  if (!same(got, { kind: "unclosed", open: 66, next: 147, count: 1 })) fails.push(`${name}: ${JSON.stringify(got)}`)
}

const cases = [
  ["two blocks left open", "describe('a', () => {\n    it('x', () => {\n        expect(1).toBe(1);\n    it('y', () => {\n        expect(2).toBe(2);\n    it('z', () => {\n        expect(3).toBe(3);\n    });\n});\n",
    { kind: "unclosed", open: 2, next: 4, count: 2 }],
  ["a close of the wrong kind", "foo(() => {\n  bar(1;\n});\n", { kind: "mismatch", line: 3, close: "}", open: 2, opened: "(" }],
  ["a close with nothing open", "const a = 1;\n}\n", { kind: "extra", line: 2, close: "}" }],
  ["open at the end", "function f() {\n  if (x) {\n    return 1;\n", { kind: "eof", open: 2, count: 2 }],
]
for (const [what, text, want] of cases) {
  const got = unbalanced(text)
  if (!same(got, want)) fails.push(`${what}: ${JSON.stringify(got)}, want ${JSON.stringify(want)}`)
}

// Brackets that aren't code must not count.
const balanced = [
  ["strings", `const a = '}', b = "{(", c = ')';\n`],
  ["an escaped quote", `const a = 'it\\'s {';\n`],
  ["template text and nesting", "const t = `a { ${x ? '}' : `${y} )`} ]`;\n"],
  ["a template inside a template's expression", "a = () => {\n  return `-${`${r(1)}`.pad(2)}`\n}\nb = (x) => {\n  return x\n}\n"],
  ["regex literals", "const r = /[)}]/g, s = /\\{/;\nif (/^\\(/.test(x)) f(/]/);\nreturn /[/]/.test(y);\n"],
  ["division, not a regex", "const a = b / c / (d) / 2;\nconst e = f[0] / g;\n"],
  ["comments", "// }\n/* { ( */\nf(); // )\n"],
  ["a block that opens at its parent's indent", "if (a) {\nif (b) {\n}\n}\n"],
]
for (const [what, text] of balanced) {
  const got = unbalanced(text)
  if (got !== null) fails.push(`${what} were counted: ${JSON.stringify(got)}`)
}

// Every working file here balances.
const sweep = []
const walk = (dir) => {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    if (name === "node_modules" || name === "runs" || p === fixtures) continue
    if (statSync(p).isDirectory()) walk(p)
    else if (/\.(m?js|ts)$/.test(name)) sweep.push(p)
  }
}
for (const dir of ["pi", "evals", "bench"]) walk(`${root}/${dir}`)
if (sweep.length < 10) fails.push(`the sweep found only ${sweep.length} files`)
for (const p of sweep) {
  const got = unbalanced(readFileSync(p, "utf8"))
  if (got !== null) fails.push(`${p.slice(root.length + 1)} is good code but was counted: ${JSON.stringify(got)}`)
}

// The hint, on a bash result: a project with the broken file and a good one.
const cwd = mkdtempSync(join(tmpdir(), "brackets-"))
mkdirSync(`${cwd}/src/__tests__`, { recursive: true })
cpSync(`${fixtures}/edit-left-open.test.ts`, `${cwd}/src/__tests__/city.test.ts`)
writeFileSync(`${cwd}/src/good.ts`, "export const a = () => {\n  return 1\n}\n")
const esbuild = " FAIL  src/__tests__/city.test.ts [ src/__tests__/city.test.ts ]\nError: Transform failed with 1 error:\n/app/src/__tests__/city.test.ts:355:0: ERROR: Unexpected end of file\n"
const tsc = "src/__tests__/city.test.ts(355,1): error TS1005: '}' expected.\n"
for (const [what, out] of [["esbuild's form, at the container's path", esbuild], ["tsc's form", tsc]]) {
  const hint = syntaxHint(out, cwd)
  if (typeof hint !== "string") { fails.push(`${what}: no hint`); continue }
  for (const part of ["src/__tests__/city.test.ts", "line 66", "describe('Micro Zones (1x1)', () => {", "just before line 147", "with edit"]) {
    if (!hint.includes(part)) fails.push(`${what}: the hint lacks ${part}: ${hint}`)
  }
  if (hint.split("never closes").length !== 2) fails.push(`${what}: the file was hinted more than once: ${hint}`)
}
const many = syntaxHint("/app/src/__tests__/city.test.ts:1:0: ERROR: Unexpected end of file", cwd)
if (many && /\/app\//.test(many)) fails.push(`the hint names the container's path: ${many}`)
for (const [what, out] of [
  ["a file that balances", "/app/src/good.ts:3:0: ERROR: Unexpected end of file"],
  ["output without a syntax error", "src/__tests__/city.test.ts:66:    describe('Micro Zones (1x1)', () => {"],
  ["a test that failed on its assertion", " FAIL  src/__tests__/city.test.ts > Funds > charges\nAssertionError: expected 1900 to be 2000\n ❯ src/__tests__/city.test.ts:160:31"],
  ["a path outside the project", "../../src/__tests__/city.test.ts:355:0: ERROR: Unexpected end of file"],
  ["a file that isn't there", "/app/src/missing.test.ts:9:0: ERROR: Unexpected end of file"],
  ["no output", ""],
]) {
  const hint = syntaxHint(out, cwd)
  if (hint !== null) fails.push(`${what} got a hint: ${hint}`)
}
const shown = syntaxHint(undefined, cwd)
if (shown !== null) fails.push(`undefined output got a hint: ${shown}`)
rmSync(cwd, { recursive: true, force: true })

for (const f of fails) console.log(`FAIL  ${f}`)
process.exit(fails.length ? 1 : 0)
JS
rc=$?
if [ "$rc" -eq 0 ]; then
  printf 'brackets: only a broken file is placed, and its hint names the open line and where its close belongs\n'
  exit 0
fi
printf 'brackets: case(s) failed\n' >&2
exit 1
