# pi-dev-skills

Development skills for Pi Coding Agent, engineered for local ~30B models. These scripts compute facts before prompts run and advance work one discrete step at a time.

## Commands

| What | Command |
|---|---|
| Install | `pi install /path/to/pi-dev-skills` (loads the checkout in place; `-l` for one project) |
| Test | `bash evals/run-all.sh` |
| Test Scoped | `bash evals/lib/<script>.sh` (e.g. `bash evals/lib/http-check.sh`) |
| Lint | `shellcheck --severity=warning lib/*.sh evals/*.sh evals/*/*.sh` |
| Size Check | `bash evals/skills/size.sh` |
| Verify Loaded | `pi --verbose` (startup errors), then the `/dev-*` commands in the editor |
| Build | none — no build system; shell scripts, SKILL.md files and two plain-JS Pi extensions |
| Run | none — not a runtime application; the skills run as Pi commands |

Commands run on the host system (no container). Ensure you have `gh`, `node` (the guard and expander suites load the extensions), `shellcheck`, Pi 1.4.0, and a model server at 64k or 128k; Docker is not needed here.

`pi/commands.js` passes the active model's `contextWindow` to `profile.sh` as `DEV_SKILLS_CONTEXT`, and `step-budget.sh` sizes each step against it: 1,572 lines at 128k, 786 at 64k, 393 at 32k. A 32k window does not carry implement → review → fix → pr in one context — see **What each window buys** in the README.

## Skill Development & Testing Workflow

When developing, updating, or debugging skills in this repository:

1. **Prompt & Script Edits**:
   - Skills live in `skills/<skill-name>/SKILL.md`.
   - Reusable scripts live in `lib/<script>.sh`; the Pi extensions in `pi/` (`commands.js` registers the commands, `expand.js` runs a skill's `!` lines, `guard.js` is the guard); templates in `skills/dev-init/templates/`.
2. **Invariants to Check**:
   - **Size cap**: Run `bash evals/skills/size.sh` — every `SKILL.md` must remain under 90 lines and 5,000 bytes (description under 200 chars).
   - **Lint**: Run `shellcheck --severity=warning lib/*.sh evals/*.sh evals/*/*.sh` — 0 warnings allowed.
   - **Cycles & Frontmatter**: Run `bash evals/skills/cycle.sh` and `bash evals/skills/frontmatter.sh` to confirm skill handoffs hold.
   - **The assembled block**: Run `bash evals/skills/injected.sh` — it expands every skill with `pi/expand.js` in a throwaway project and asserts what the model reads: no usage line, no injection left unrun, an absolute `**Task file:**` line with the step, the project root for `/dev-plan`.
3. **Evals**:
   - Every file under `lib/` must have test cases in `evals/lib/`: `<script>.sh` for a shell script, and `steps.sh` for `steps.awk`. The guard has `evals/guard/cases.sh`; the expander is covered by `evals/skills/injected.sh`.
   - A suite that reads `DEV_SKILLS_CONTEXT` or `PI_MODEL` unsets it at the top: run from inside Pi, it would inherit the session's.
   - Run the target test during iteration (`bash evals/lib/<script>.sh`), then run the full suite: `bash evals/run-all.sh` (every suite must pass; it prints the count itself).
4. **No sync step**: `pi install` of a local directory loads it from the checkout. A changed `SKILL.md` or `lib/` script applies on the next command; a changed `pi/*.js` after `/reload`.
5. **Verify Loaded in Pi**:
   - Testing is not only running evals — verify that Pi actually boots and loads the extensions.
   - Run `pi --verbose` and confirm no extension errors at startup; `pi list` shows this checkout among the packages.
   - Type `/dev-` in the editor: every skill appears as a command. None appears among Pi's skills — they are commands on purpose.
6. **PR & Guard Rules**:
   - The guard (`pi/guard.js`) forbids `git push --force`, `git commit --amend`, `--no-verify`, and pushing to `main`/`master`. Make new commits instead.
   - Clean up any generated files (`.tasks/`, `plans/`, stray `.md` files) before creating or updating PRs.
   - Always open PRs as draft (`--draft`) using `/dev-pr` or `gh pr create --draft`.

## Adding support for a stack

`lib/profile.sh` decides every command the skills run. CI wins, then the manifest table, then the language branch, then `null` — and `null` is a real answer, never replaced by a guess. A new stack needs a branch in the manifest block, a `manifest_case` fixture in `evals/lib/profile.sh`, and its extensions in `lib/lint.sh` if the linter is per-file. See **Supported Stacks** in the README.

## This project specifically

- **Commands, not skills**: each `skills/<name>/SKILL.md` is the Pi command `/<name>`, expanded by `pi/expand.js` before the model reads it.
- **Step cycle:** `/dev-init` → `/dev-plan` → `/dev-implement` → `/dev-review` → `/dev-pr`. Each step runs on a stacked branch (`step/<slug>-<n>`).
- **Manual cycle:** `/dev-plan-manual` → you write the code and commit it → `/dev-review` → you fix it by hand. The plan carries `**Mode:** manual`; `/dev-implement` refuses one.
- **Learned facts** persist across sessions in `.devskills/learned.md`.
- **Model config:** `models.example.json` sends `reasoning_effort: none` and `temperature: 0` with every request, to avoid local model latency in agent loops. Copy it to `~/.pi/agent/models.json`.
