# Benchmark: space-city funds

One fixed task, built by `/dev-implement` one step per session, scored by tests the model never
sees. Everything a result depends on is pinned, so a run today and a run in six months measure
the same thing, and a difference between two rows is the skills at that commit, not the task.

## What is pinned

| | Pin | Checked by `run.sh` |
|---|---|---|
| Target | [space-city](https://github.com/matasarei/space-city) at `ec643a3` — TypeScript, vitest, 34 tests, a locked `package-lock.json` | fresh clone, remote removed |
| Task | [`plan.md`](plan.md) — 3 steps: a cost table, funds charged on placement, half refunded on clearing | copied in as `.tasks/funds.md` |
| Score | [`acceptance/`](acceptance) — 26 hidden tests, one file per step | copied in after the run, removed again |
| Model | `lmstudio/prism-ml/bonsai-27b`, loaded at a 131072 window | `lms ps` |
| Pi side | Pi 1.5.0 with this checkout; the commit is recorded per row | `pi --version`, `pi list` |
| Idle timeout | Pi's `httpIdleTimeoutMs` at 20 minutes or more, in `~/.pi/agent/settings.json`; `meta.env` records it as `http_idle_ms` | [`idle-check.mjs`](idle-check.mjs) |

Not pinned, so recorded instead: the `node:lts-alpine` image the profile runs tests in (its
digest goes in `runs/<run>/meta.env`), LM Studio's own version, and the model's `maxTokens`
in `~/.pi/agent/models.json` (`max_tokens` in `meta.env`). A runaway tool call runs to that limit,
so it changes what a row costs. Rows up to `pi@289fbc9` in `results.md` ran at 16384.

The reference solution passes 26/26 hidden tests and all 34 existing ones; the untouched target
passes none of the hidden ones. Both were checked when the benchmark was written.

## Run it

```bash
~/.lmstudio/bin/lms server start
~/.lmstudio/bin/lms load prism-ml/bonsai-27b --context-length 131072 -y

bash bench/space-city/run.sh pi

~/.lmstudio/bin/lms unload --all && ~/.lmstudio/bin/lms server stop
```

`--steps 1` (or `1-2`, `2-3`) runs part of the plan. Each step times out after 30 minutes
(`BENCH_STEP_TIMEOUT`, in seconds), which counts as a step not done. Logs land in
`bench/space-city/runs/` (git-ignored); the scored row is appended to [`results.md`](results.md).
Re-score a finished run with `BENCH_RESULTS=/dev/null bash bench/space-city/score.sh <target-dir> <logs-dir>`
(without it, the row is appended to `results.md` again).

The run is headless: a skill that stops to ask ends its session, and the step counts as not done.
A start the harness gates itself (a refused branch: `step-start.sh`'s `STOP`) never reaches the
model; `meta.env` records that step's exit as 3.

A step that ends unticked gets one more session with `--continue`, the README's recovery
for a stuck run, with its own timeout and its log in `step-<n>-retry1.jsonl`. It doesn't get one
when the start was gated, when Pi itself failed, or when an earlier step is the unticked one.
`meta.env` records `step<n>_resumes`, and `step<n>_seconds` covers every attempt, so a run can
take up to twice as long. `BENCH_RESUMES` sets the number; rows up to `pi@d028952` in
`results.md` had none, and `BENCH_RESUMES=0` reproduces them.

## Replay one reply

A run takes an hour or more to reach a long reply. [`replay.mjs`](replay.mjs) resends one reply's
exact request to the model, so a question about that reply takes minutes:

```bash
node bench/space-city/replay.mjs bench/space-city/runs/<run>/step-2-retry1.jsonl       # list the replies
node bench/space-city/replay.mjs bench/space-city/runs/<run>/step-2-retry1.jsonl 28    # replay reply 28
node bench/space-city/replay.mjs <log> 28 --set '{"temperature":0.2}' --limit 900      # change a field; stop after 900 s
```

It needs the model loaded as above, and it prints one JSON line:

| Field | What it says |
|---|---|
| `finish` | `stop`, `tool_calls`, `length`, or `limit` (exit 2), `dropped` or `error` (exit 1) |
| `seconds`, `firstByteSeconds` | the whole reply, and until its first chunk |
| `longestSilenceSeconds` | the longest gap after the first chunk: how long Pi's idle timeout would have waited |
| `tokens`, `tool`, `textChars`, `argsChars` | how much it wrote, and which tools it called |
| `argsValidJson` | whether every call's arguments parse; `null` with no call |
| `lines`, `distinctLines` | few distinct lines out of many means a reply repeating itself |
| `sameStartAsLog` | whether it starts as the logged reply did; `null` if that had no text |
| `dir` | where the rest is: `request.json`, `text.txt`, `args.txt`, and `stream.log` with each chunk's time. It's under `runs/`, so git-ignored |

**What it can't show:**
- **A replay is one sample, not a verdict.** The same request has run away to the 16,384-token limit on one attempt and finished in 26 s on another.
- **The output limit can differ near a full window.** It sends the model's `maxTokens`, and Pi lowers that when a context is within about 20k tokens of the window, which the log doesn't record.
- **After a cut-off, the log isn't what the model saw.** During a `/dev-*` run, `pi/cut-off.js` changes the request, and the log keeps Pi's text. A faithful replay of a later reply has to `--set` the new text, `max_completion_tokens: 4096` and `temperature: 0.3`.
- **Some replies can't be replayed.** It refuses a context with images or thinking, one holding an error Pi didn't retry, and a reply the log has no end for, such as one a run's time limit cut off. It sends only to a plain `http://` server, with no API key.
- **It checks what the model says, not whether that works.** To test a returned edit, apply `args.txt` to a copy of the tree and run the project's checks by hand.

`evals/bench/replay.sh` compares its requests with what real Pi sends, against a mock.

### What runs when

| | Uses | Run it |
|---|---|---|
| `evals/run-all.sh` | Scripts and extensions; real Pi against a mock where Pi is installed | Every change, and in CI |
| `replay.mjs` | The real model, on one logged reply | By hand, for a question about one reply |
| `run.sh` | The real model, on the whole task | By hand, for a change meant to alter what the model does |

## What a row says

Read from the tree and the logs, never from what the model reported. The tests run in a copy of
the target with the pinned lock file and a fresh install in the container, so a model that broke
`node_modules` still has its code scored. What it changed, the lock file included, is read from
the original tree:

- **Ticked** — steps marked `[x]` in the task file. A step can tick with a test it added left open (`lib/test-open.sh`), so this doesn't mean its tests pass. Rows up to `pi@8277145` had no such option.
- **Step 1 / 2 / 3** — hidden tests passing, per step. A file that does not load scores 0.
- **Other failing** — tests outside the hidden ones that fail, the 34 existing ones and the model's own.
- **tsc** — `npx tsc --noEmit`.
- **Outside the plan** — files changed that no step's `Create:` or `Modify:` names.
- **Commits / step branches**, **guard refusals**, **`TEST PASS` lines** — from git and the session logs.
- **Seconds**, **tokens in/out** — wall time of all steps, and Pi's own token count.
