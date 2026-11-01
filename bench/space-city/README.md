# Benchmark: space-city funds

One fixed task, built by `/dev-implement` one step per session, scored by tests the model never
sees. Everything a result depends on is pinned, so a run today and a run in six months measure
the same thing, and a difference between two rows is the harness, not the task.

## What is pinned

| | Pin | Checked by `run.sh` |
|---|---|---|
| Target | [space-city](https://github.com/matasarei/space-city) at `ec643a3` — TypeScript, vitest, 34 tests, a locked `package-lock.json` | fresh clone, remote removed |
| Task | [`plan.md`](plan.md) — 3 steps: a cost table, funds charged on placement, half refunded on clearing | copied in as `.tasks/funds.md` |
| Score | [`acceptance/`](acceptance) — 26 hidden tests, one file per step | copied in after the run, removed again |
| Model | `lmstudio/prism-ml/bonsai-27b`, loaded at a 131072 window | `lms ps` |
| Pi side | Pi 1.4.0 with this checkout; the commit is recorded per row | `pi --version`, `pi list` |
| OpenCode side | OpenCode 1.18.20 with opencode-skills at `9365f31`, the commit this repository was copied from | the installed files compared with that commit |

Not pinned, so recorded instead: the `node:lts-alpine` image the profile runs tests in (its
digest goes in `runs/<run>/meta.env`), and LM Studio's own version.

The reference solution passes 26/26 hidden tests and all 34 existing ones; the untouched target
passes none of the hidden ones. Both were checked when the benchmark was written.

## Run it

```bash
~/.lmstudio/bin/lms server start
~/.lmstudio/bin/lms load prism-ml/bonsai-27b --context-length 131072 -y

bash bench/space-city/run.sh pi
bash bench/space-city/run.sh opencode     # stops with the reinstall command if the copy is stale

~/.lmstudio/bin/lms unload --all && ~/.lmstudio/bin/lms server stop
```

`--steps 1` (or `1-2`, `2-3`) runs part of the plan. Each step times out after 30 minutes
(`BENCH_STEP_TIMEOUT`, in seconds), which counts as a step not done. Logs land in
`bench/space-city/runs/` (git-ignored); the scored row is appended to [`results.md`](results.md).
Re-score a finished run with `BENCH_RESULTS=/dev/null bash bench/space-city/score.sh <target-dir> <logs-dir>`
(without it, the row is appended to `results.md` again).

The run is headless: a skill that stops to ask ends its session, and the step counts as not done.
That holds for both harnesses alike.

## What a row says

Read from the tree and the logs, never from what the model reported. The tests run in a copy of
the target with the pinned lock file and a fresh install in the container, so a model that broke
`node_modules` still has its code scored. What it changed, the lock file included, is read from
the original tree:

- **Ticked** — steps marked `[x]` in the task file.
- **Step 1 / 2 / 3** — hidden tests passing, per step. A file that does not load scores 0.
- **Other failing** — tests outside the hidden ones that fail, the 34 existing ones and the model's own.
- **tsc** — `npx tsc --noEmit`.
- **Outside the plan** — files changed that no step's `Create:` or `Modify:` names.
- **Commits / step branches**, **guard refusals**, **`TEST PASS` lines** — from git and the session logs.
- **Seconds**, **tokens in/out** — wall time of all steps, and the harness's own token count.

The OpenCode token count is read from `opencode export` by summing every message's `tokens`. That
shape was not seen on a real run when this was written; a `?` means it did not match.

## Known differences between the two sides

- OpenCode also loads the skills under `~/.claude/skills` into its catalog, so its system prompt
  carries more than the nine dev skills. Pi's does not. That cost is OpenCode's, and the token
  column includes it.
- The skills' text is the same on both sides. Only the harness differs: how a skill reaches the
  model, the guard, and where the window comes from.
