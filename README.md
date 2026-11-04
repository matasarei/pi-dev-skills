# pi-dev-skills

<p>
  <a href="https://pi.dev"><img src="https://img.shields.io/badge/Pi_Coding_Agent-1B1B1B?style=for-the-badge" alt="Pi Coding Agent" /></a>
  <img src="https://img.shields.io/badge/Local_models-6E56CF?style=for-the-badge&logo=ollama&logoColor=white" alt="Local models" />
  <img src="https://img.shields.io/badge/Docker-2496ED?style=for-the-badge&logo=docker&logoColor=white" alt="Docker" />
  <a href="https://github.com/matasarei/pi-dev-skills/actions/workflows/checks.yml"><img src="https://img.shields.io/github/actions/workflow/status/matasarei/pi-dev-skills/checks.yml?style=for-the-badge&label=Checks" alt="Checks" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-3DA639?style=for-the-badge" alt="License: MIT" /></a>
</p>

Development skills for [Pi Coding Agent](https://pi.dev) engineered specifically for **local ~30B models** (such as **Qwen3 Coder 30B**, **Prism Bonsai 27B**, and **Qwen3.8 27B**). It continues [opencode-skills](https://github.com/matasarei/opencode-skills), which stays as the frozen OpenCode baseline.

Instead of relying on fragile multi-variable reasoning and prompt guesswork, these skills compute facts before prompts run, replace subjective scoring with binary yes/no checks, verify code quotes mechanically, and advance work one discrete step at a time.

---

## Recommended Models

These skills are optimized for ~30B parameter local coding models:

1. **[Prism Bonsai 27B](https://lmstudio.ai/models/prism-ml/bonsai-27b)** (`prism-ml/bonsai-27b`) — Strong general coding, reasoning, and instruction-following. Best on Apple Silicon in MLX variant (32–48 GB RAM).
2. **[Qwen3 Coder 30B](https://lmstudio.ai/models/qwen/qwen3-coder-30b)** (`qwen/qwen3-coder-30b`) — Tuned specifically for code generation, diff analysis, and fast tool calling. More capable, but requires more memory.
3. **[Qwen3.8 27B](https://huggingface.co/Qwen/Qwen3.8-27B)** (`Qwen/Qwen3.8-27B`) — Often recommended for local agents as well, worth trying.
4. **[Qwen3.5 9B](https://huggingface.co/Qwen/Qwen3.5-9B)** (`Qwen/Qwen3.5-9B`) — For lower-end hardware (8–12 GB VRAM) at 32k. One skill per session, not the whole cycle — see [What each window buys](#what-each-window-buys).

> **Crucial Server Requirement**: Set your model server's context window (LM Studio, Ollama, or llama.cpp) to **64k or 128k**. Local tool calling degrades or loops if it is left at the default 4k/8k. What each of those windows actually buys you — and what 32k does not — is measured in [What each window buys](#what-each-window-buys).

---

## Installation & Setup

```bash
# Pi 1.5.0, the version this package is tested with
npm install -g --ignore-scripts @earendil-works/pi-coding-agent@1.5.0

git clone https://github.com/matasarei/pi-dev-skills.git
pi install ./pi-dev-skills        # loaded from the checkout, not copied
```

`pi install` with a local directory records its path in `~/.pi/agent/settings.json` and loads the package from there. There is nothing to sync after an edit: a changed `SKILL.md` or `lib/` script applies on the next command, and a changed `pi/*.js` after `/reload`. Add `-l` to install it for one project only (written to `.pi/settings.json`, loaded once the project is trusted).

### Requirements
* **Pi 1.5.0** (Node.js 22.19 or newer).
* **Git** and **Bash** (macOS, Linux, or WSL on Windows. Native Windows Git Bash is unsupported).
* **GitHub CLI (`gh`)** for pull request skills (`gh auth login`).
* **Docker** (recommended — skills run tests inside project containers by default).

> **Invoking Skills**: every skill is a Pi command — type `/dev-plan add a CSV export` or `/dev-implement .tasks/csv-export.md`. They are deliberately not Pi skills: Pi would list each one in the system prompt and leave its `!` lines unrun. `pi/commands.js` registers one command per `skills/*/SKILL.md`, runs those lines with `pi/expand.js` — `$ARGUMENTS` replaced by what you typed, each command run in the project — and sends the result as your message, so the model starts from facts already computed.

---

## Configuration

### 1. Model Configuration

A complete provider for LM Studio is in [**`models.example.json`**](models.example.json). Copy it to `~/.pi/agent/models.json` (or merge its `lmstudio` provider into yours), then start Pi on one of its models:

```bash
pi --model lmstudio/prism-ml/bonsai-27b
```

```json
{
  "id": "prism-ml/bonsai-27b",
  "name": "Prism Bonsai 27B",
  "input": ["text", "image"],
  "contextWindow": 131072,
  "maxTokens": 16384,
  "samplingParams": { "temperature": 0, "reasoning_effort": "none" }
}
```

* **`contextWindow`**: set it to the context length your server is actually configured with. It is what every step is sized against — see [What each window buys](#what-each-window-buys).
* **Why 16k output (`maxTokens`)?** In local inference, thinking tokens share the output budget. 16k gives ample headroom for large diffs, database migrations, and plans without truncation (`finish_reason: length`), while preventing runaway infinite loops. The 9B entry uses 8k output and a 32k window for 8–12 GB VRAM hardware.
* **Why reasoning OFF?** In agent loops local models spend 30–90 seconds generating `<think>` tokens before *every single tool call*, often simulating imaginary tool output instead of calling the tool. `samplingParams` sends `"reasoning_effort": "none"` with every request, and the entries leave Pi's own `reasoning` flag off, so no thinking level switches it back on unseen. Latency drops to 1–3 seconds and real tool output grounds the model.
* **`temperature: 0`**: zero temperature is required for deterministic code reviews and consistent tool use.

Then give Pi an idle timeout that outlasts a long tool call, in `~/.pi/agent/settings.json`:

```json
{ "httpIdleTimeoutMs": 1200000 }
```

* **Why 20 minutes?** LM Studio sends nothing while a model writes a tool call's arguments, so a long `edit` or `write` is minutes of silence, and Pi's 5-minute default drops it as `terminated`. A retry at `temperature: 0` can write the same long call again. A full 16k reply takes about 15 minutes at worst, so 20 minutes clears it and still ends a real hang. `/dev-*` commands warn once a session when a local model runs below it, and the bench refuses to start.

### 2. Nothing else to configure

Pi has no plan mode and no per-tool permission prompts: tools run with your own OS permissions, `/dev-plan` writes `.tasks/` like any other file, and `/tmp` needs no allow-list. The guard below is what stands between a model and a destructive git command.

---

## The Skills & The Step Cycle

| Command | Purpose | Code Modified? |
|---|---|---|
| `/dev-init` | Detects project stack and writes repo conventions to `AGENTS.md` | Yes (`AGENTS.md`) |
| `/dev-plan <request>` | Investigates code, sizes steps against budget, writes `.tasks/*.md` | No |
| `/dev-plan-manual <request>` | Plans work **you** write by hand, one walkthrough at a time as you reach it | No |
| `/dev-implement <task>` | Builds one discrete step from the task file, ticks it off, and stops | Yes |
| `/dev-review` | Runs 12 yes/no checks on changed files with mechanical quote verification | No |
| `/dev-fix [<issue>\|<file>]` | Plans verified bug fixes into `.tasks/`, or applies post-review findings | Yes |
| `/dev-pr` | Pushes the step branch, opens stacked PR with `Depends on #` | No |
| `/dev-verify` | Runs test suites and exercises runtime behaviour inside Docker containers | No |
| `/dev-pr-review <pr>` | Reviews an external PR against a structured checklist | No |

### The Step Cycle

```
   /dev-init ──▶ /dev-plan ──▶ /dev-implement ──▶ /dev-review ──────────────▶ /dev-pr
(once per repo)                       ▲                 │                         │
                                      │        (unfixed findings)                 │
     /dev-fix ────────────────────────┤                 ▼                         │
(bug/issue plan)                      │             /dev-fix                      │
                                      │             (apply)                       │
                                      │                 │                         │
                                      └─────────────────┴── (next: --continue) ───┘
                                                            (pre-step: /compact or /new)

   /dev-plan-manual ──▶ you write the code ──▶ /dev-review ──▶ you fix it by hand
        ▲                 (you commit it)                          │
        └──────────────── (next: --continue) ──────────────────────┘
```

1. **Initialize (once per repo)**: `/dev-init` inspects the project, writes build/test/lint commands and stack conventions to `AGENTS.md`.
2. **Plan**: `/dev-plan` resolves input via `plan-input.sh`, validates referenced paths with `plan-check.sh`, and sizes each step using `step-budget.sh` against `contextTokens` — the active model's `contextWindow`, which `pi/commands.js` passes as `DEV_SKILLS_CONTEXT`. Shared parsing is handled by `steps.awk`. For targeted bug fixes, `/dev-fix <issue>` investigates root cause and produces a verified plan in `.tasks/fix-<slug>.md`.
3. **Or plan it for yourself**: `/dev-plan-manual` writes the same task file marked `**Mode:** manual`, then one step's walkthrough at a time as you reach it — anchors, the pattern in this repository to copy the shape of, and why, but never a body you could paste. It is for a repository that does not accept generated code, and for learning a codebase by changing it. `/dev-implement` refuses a plan carrying that marker, `/dev-review` reads hand-written code unchanged and hands its findings back to you rather than to `/dev-fix`, and `branch.sh` refuses the next step until you have committed the last one yourself.
4. **Build**: `/dev-implement` injects exactly one step via `task-step.sh` onto a stacked branch named `step/<slug>-<n>`. The branch is cut before the model reads anything: `step-start.sh`, the skill's first injection, runs `branch.sh` and `step-budget.sh`, and when the branch is refused it prints a `STOP` line, which `pi/commands.js` shows to you instead of sending the block. Once the step is ticked and committed on a clean tree, `pi/commands.js` refuses every further tool call but the report's `learned.md` line, and the third refusal ends the run; a step script named for another step is refused throughout. One step per run is enforced, not asked for.
5. **Review**: `/dev-review` runs 12 mechanical checks against changed files. If clean, proceed directly to `/dev-pr`. If unfixed blockers or warnings survive, hand off to `/dev-fix` to apply verified findings with one commit per finding.
6. **Push & PR**: `/dev-pr` pushes the branch and opens the PR (annotated with `Depends on #` for stacked dependencies).
7. **Next Step**: Continue to the next step with `/dev-implement <task-file> --continue`. Choose a context management pre-step based on your session: run `/compact` (or stay in the session) to keep conversational context while pruning raw tool outputs, or run `/new` for a fresh session when context has ballooned (>60k–80k tokens) or when starting fresh. Inter-step repository discoveries persist in `.devskills/learned.md`.

---

## What each window buys

One step's whole cycle — `/dev-implement` → `/dev-review` → `/dev-fix` → `/dev-pr` in a single
context — measured on this repository at ~9 tokens per line of source, with the four skills'
prompts and their injected facts summing to ~21k:

| Server window | Step cap | One cycle | Verdict |
|---|---|---|---|
| **128k** | 1,572 lines | ~35k tokens (26%) | Comfortable. The whole cycle, with room for retries. |
| **64k** | 786 lines | ~28k tokens (42%) | Fits, with about half the window free. |
| **32k** | 393 lines | ~24.5k tokens (74%) | **Not the full cycle.** Run one skill per session, clearing between them. |

`pi/commands.js` passes the selected model's `contextWindow` from `models.json` to `profile.sh`
as `DEV_SKILLS_CONTEXT`, and `step-budget.sh` sizes every step against it, so a plan written on a
128k machine is sized for 128k. A cached profile reports the window of the model you run now, so
switching models needs no `--reprofile`. Outside Pi, set `DEV_SKILLS_CONTEXT` yourself. Inside
Pi, a value you export applies only to a model whose entry has no `contextWindow`. With nothing set
the default is 100,000. **A step sized for a window you do not have still runs — it
just degrades**, which is why the number comes from the model rather than being assumed.

The 9B option under [Recommended Models](#recommended-models) is 8–12 GB VRAM at 32k: good for
`/dev-plan`, `/dev-review` and `/dev-pr` one at a time, not for the cycle in one context.

---

## Supported Stacks

Nothing in the cycle asks the model which command to run. `lib/profile.sh` works it out once, caches it in `.devskills/profile.json`, and every skill reads that.

**Order of authority — CI, then the manifest, then the language branch, then `null`.** Whatever a `.github/workflows/*` file actually runs is what gates the project, so it wins; the manifest is the fallback; `null` is a real answer and is never replaced by an invention.

| Detected by | Language | Test | Lint | Build / Install |
|---|---|---|---|---|
| `composer.json` + `phpunit.xml` | PHP | `vendor/bin/phpunit` | `php -l` | `composer install` |
| `pyproject.toml`, `pytest.ini`, `conftest.py` | Python | `pytest` | `ruff check` | `pip install` |
| `package.json` | Node | `npm test` | its `lint` script | `npm run build`, `npm ci` |
| `go.mod` | Go | `go test ./...` | `gofmt -l` | `go build ./...` |
| `Cargo.toml` | Rust | `cargo test` | `cargo fmt --check` | `cargo build` |
| `pom.xml` | Java | `mvn -q test` | — | `mvn -q package` |
| `build.gradle(.kts)` | Java/Kotlin | `gradle test` | — | `gradle build` |
| `Gemfile` | Ruby | `rspec` or `rake test` | — | `bundle install` |
| `mix.exs` | Elixir | `mix test` | — | `mix deps.get` |
| `*.sln`, `*.csproj` | .NET | `dotnet test` | — | `dotnet build` |

A stack not in this table still gets a real `test` command whenever its CI names one — that is the point of putting CI first.

**A value read out of the repository is not a command.** `composer.json`'s `vendor-dir` and a CI run line are both files in the checkout, so they are validated before they reach a command string: anything but a plain relative path, or a capture carrying a shell metacharacter, is refused and recorded in `notes`.

### Adding a stack

1. Add a branch to the manifest block in `lib/profile.sh` — the file that identifies it, then `LANGUAGE`, `TEST`, `TEST_SCOPED`, and `LINT`/`BUILD`/`INSTALL` where the stack has an obvious one. Use `set_if_null` so CI still wins.
2. Add a fixture to `evals/lib/profile.sh` via `manifest_case`, asserting the language and both test commands.
3. If the linter is per-file, add its extensions to the whitelist in `lib/lint.sh`, or the command is detected and never invoked.
4. `family` is for `/dev-init` templates and the Moodle version rules only — command detection does not use it, so a new stack does not need one.

---

## Without CI, or without GitHub

Not every project has CI, and several cannot: a repository on a private GitLab, a self-hosted
forge, or no remote at all. **Seven of the nine skills never need a remote** — `/dev-init`,
`/dev-plan`, `/dev-plan-manual`, `/dev-implement`, `/dev-review`, `/dev-fix` and `/dev-verify`
work in a repository that has never had one. Four of them reach the network only when you point
them at it: `/dev-plan`, `/dev-plan-manual` and `/dev-fix` read an issue you name, `/dev-verify`
checks a URL you pass. The
guarantee was always local: `lib/test.sh` before the commit, `lib/lint.sh` over the changed
files, `lib/findings-check.sh` deleting findings whose evidence is not in the code. CI is a
second opinion, not the first one.

`profile.sh` reports what will actually check a change, so the skills stop implying a second
opinion that is never coming:

| `verification` | Means |
|---|---|
| `ci+container` | CI re-runs it, and locally it runs in the target environment |
| `ci` | CI is the clean-machine check |
| `container` | no CI, but the container is the clean environment |
| `local-only` | **nothing will ever run this anywhere but here** |

CI is detected from GitHub Actions, GitLab CI, CircleCI, Jenkins, Woodpecker, Bitbucket
Pipelines and Azure Pipelines — and where the workflow names a test runner `profile.sh`
recognises, that becomes the `test` command, because it is what actually gates the project. A
bespoke command is not: this repository's own workflow runs `bash evals/run-all.sh`, and its
profile records `test: null`.

**What you lose without CI is one thing: the clean-checkout check.** A local run can pass
because of an uncommitted file, a stale install, or a tool that exists on your machine and
nowhere else — one of this repository's own suites passed on macOS and failed on Ubuntu for
exactly that reason. `lib/verify-clean.sh` is the substitute — **The Clean-Clone Check** below
says how it works. **When `verification` is `local-only`, a container matters more than usual** —
it is the only clean environment you have.

`/dev-pr` follows the remote rather than assuming GitHub. `pr-info.sh` reports `host:`, `forge:`
(`github`, `gitlab`, `bitbucket`, `gitea`, `other`, `none`) and a `compare-url:` built for that
forge, so a GitLab project gets a merge-request URL and an unknown host gets an honest sentence
instead of a GitHub link that cannot work. `gh` only speaks GitHub, so anywhere else `/dev-pr`
writes the body to `.devskills/pr-body.md` and hands you the URL.

---

## Mechanics & Guardrails

* **The Guard (`pi/guard.js`)**: A Pi extension on the `tool_call` event that blocks dangerous actions before they run: force pushes, amended commits, skipped git hooks, pushes to `main`/`master`, commits on the base branch, and unauthorized `gh pr merge`. It refuses deleting `node_modules`, `vendor` or a lock file in any project, and, when the profile runs in a container (`exec.kind` `image` or `compose`), the project's test runner or installer run bare on the host — naming `test.sh`, the profile's `install` or its `exec.prefix` instead. It also repairs the argument mistakes local models make most (an unescaped backslash in a grep pattern, a file passed to `find` as its directory, a bash timeout in milliseconds where Pi wants seconds, line endings that differ from the file) and breaks loops of tool calls: the same call three times in a row, or the last 12 calls being 3 or fewer different calls, each made more than once. Those two refusals tell the model to stop and say what blocks it. It also refuses a `write` of exactly what the file already holds, where Pi would answer `Successfully wrote` and the model would take that for a fix it left out. The third refusal for repeating within 40 calls ends the run, and refusals of a repeated edit or a no-op write count toward it too. A call that fails validation never reaches the guard, because Pi rejects it first, so the guard counts those after the fact, toward the same limit: 5 identical ones in a row, or a short cycle of them with other calls, abort the run and notify you, without the model getting a turn to report. Verified by the case table in `evals/guard/cases.sh`, and through real Pi by `evals/pi/live-loop.sh`, which skips when Pi isn't installed.
* **Runaway replies (`pi/runaway.js`)**: At `temperature: 0` a model sometimes starts repeating itself in text, and would write to the output limit, about 10 minutes, and then end the session. During a `/dev-*` command, `pi/commands.js` stops such a reply as soon as its last 200 characters have appeared 3 times, then asks the model for one tool call. Pi leaves the stopped reply out of the next request, so the repetition can't feed the next reply. The third in a command ends its run. Your own prompts aren't watched, so a request for repeated output is safe. It can't see a runaway inside a tool call's arguments, because the server holds those back until they're complete; Pi answers those at the limit with a tool error.
* **Edit arguments (`pi/edit.js`)**: Pi's own `edit` tool, re-registered with one more repair in front of Pi's argument shim: an `edits` sent as a JSON string with raw newlines in its values — which `JSON.parse` rejects, so Pi refused the call — is parsed. So is one ending in the wrong closers, such as `}]}`, whose end is replaced with the right ones. A repeated key, such as `"newText": "the fix", "newText": ""`, keeps its first value when the later one is empty, `null`, identical or inside the first, because `JSON.parse` would keep the last, delete the text and report success. A repeat with different text is refused, and so is anything else it can't read, such as an unterminated string, with the JSON error. It only sees a string `edits`: a repeat in real JSON arguments is lost before this runs. Verified by `evals/pi/edit.sh`, and through real Pi by `evals/pi/live-loop.sh`.
* **Mechanical Evidence Verification**: `lib/findings-check.sh` validates quoted code against current files on disk, discarding hallucinated findings.
* **Cross-Stack Route Verification**: `lib/http-check.sh` verifies HTTP routes and responses across tech stacks (validating connection status, HTTP codes, auth drops to login routes/inputs, empty responses / white screens of death, English framework error screens, required domain content assertions, and crash/traceback signatures across PHP, Python, Node, Java, Go, Ruby, and SQL engines).
* **One Verdict Line for the Suite**: `lib/test.sh` picks `test` or `testScoped` from the profile, wraps it in `timeoutTool`, runs it, and prints a single line carrying the runner's own summary — `TEST PASS | OK (43 tests, 118 assertions)`, `TEST FAIL | …`, `TEST MISSING — …`, `TEST TIMEOUT — …`. Those four decisions used to be prose in three separate skills, and a model that dropped any one of them reported "tests pass" with nothing behind it. A null `timeoutTool` is declared in the verdict rather than dropped silently.
* **Red First**: `lib/test.sh --red <name>` runs a step's scoped test before its code exists and says whether it failed as a test — `RED PROVEN | …` when at least one test ran and failed, `RED NOT PROVEN — …` when it passed, `RED UNCLEAR | …` for a parse, collection or build error or an unrecognised runner, and `RED UNCLEAR — no testScoped …` for a profile with no `testScoped` carrying `{name}`. A test written after the code can pass either way, so a green line alone never proved it meant anything. Every step in a plan carries a `Red:` line — the test that must fail first, or `none — <reason>` — and `plan-check.sh` refuses one without it. `/dev-implement` writes that test before any production line; the verdict is recorded in `.devskills/red-result`, apart from the green record, and `/dev-review` (C11) and `/dev-pr` read it rather than taking the model's word. A red record counts only on the branch it was recorded on, with its commit at or behind HEAD — so run red after the step branch is cut, and do not rename the branch afterwards: a record from another branch, an earlier step or a renamed branch reads as stale.
* **Ticking a Step**: `lib/tick.sh <task-file> <n> "<what landed>"` rewrites `N. [ ] title` as `N. [x] title — what landed`. It is the smallest edit in the cycle and the one that fails silently: a step left unticked is a step the next run builds again. It refuses a step written in any other shape rather than guessing, and a second tick is a no-op.
* **Stacked Step Branches**: `lib/branch.sh <task-file> <n>` cuts `step/<slug>-<n>` from the previous step's branch when it exists and from the base branch otherwise, which is what makes the pull requests stack. Getting that base wrong points a step's PR at `main` and shows every earlier step's diff inside it. An existing branch is switched to, never re-cut, and a switch is refused while the tree is dirty so half of one step cannot follow into another step's PR.
* **A Capped Queue**: `lib/changed.sh` collapses build and vendor output to a count and caps the queue at 200 entries (`DEV_SKILLS_QUEUE_CAP`), announcing the truncation the way `lib/diff.sh` does. The queue is read into a prompt, and an un-ignored `build/` directory took it from three lines to three hundred — three hundred lines a model reads instead of the instructions above them. Because the queue is ordered by risk, the tail is what gets cut.
* **The Clean-Clone Check**: `lib/verify-clean.sh` clones HEAD somewhere empty and runs the profile's test command there, so a suite cannot pass because of an uncommitted file, a stale install or a cached artefact. It is what a repository with no CI is missing, and only that — no network, no forge, no remote required. Slower than `test.sh` by a clone, so it is deliberate rather than automatic: run it before a pull request, or whenever the profile says `verification: local-only`.
* **Size Cap**: Each `SKILL.md` is strictly capped at 90 lines and `5,000 bytes` (enforced by `evals/skills/size.sh`) to prevent context bloat.
* **Testing & Evals**: The entire toolkit is covered by fixture suites. Run `bash evals/run-all.sh` to execute every suite — it prints how many ran and exits non-zero if any failed — or scope to individual tests (`bash evals/lib/<script>.sh`). Lint with `shellcheck --severity=warning lib/*.sh evals/*.sh evals/*/*.sh`. `pi install` loads the checkout in place, so there is nothing to sync: run `/reload` after editing `pi/*.js`, and `pi --verbose` to see what loaded at startup.

---

## Troubleshooting

* **`/dev-*` commands missing**: `pi list` should show this checkout among the packages. Run `/reload` after a change to `pi/*.js`, and start with `pi --verbose` to see extension errors at startup.
* **`A reply started repeating itself`**: The runaway check stopped a reply, and the run continues with a nudge. `This run stops here.` means it happened 3 times in one command: run `/new`, then `/dev-implement .tasks/<task>.md --continue`.
* **A reply ends with `terminated` after about 5 minutes**: Pi's idle timeout dropped a long tool call while the server was silent. Set `httpIdleTimeoutMs` as in [the model setup](#1-model-configuration) and restart Pi.
* **Tool calls truncate or loop**: Server context window is below 64k. Increase context length in LM Studio or set `OLLAMA_CONTEXT_LENGTH=65536`.
* **Model stuck in a retry loop or context bloated**: Repeated failed tool calls (e.g. failing edits or syntax errors) can fill the context with identical failure traces, trapping `temperature: 0` models in repetitive retry loops. The guard ends such a run with `This run stops here.`, in its last refusal or, for calls that fail validation, in a notification; the step is left unfinished, with its uncommitted work still in the tree, and a later step's `BRANCH refused` names it. Check the tree before you resume:
  * **Fresh Session (`--continue`)**: Run `/new` for a fresh session, then `/dev-implement .tasks/<task>.md --continue`. Progress is tracked on disk in `.tasks/` and git branch commits, instantly clearing out thousands of poisoned context tokens.
  * **`/compact`**: If staying in the active session, run `/compact` to prune verbose tool error outputs while retaining high-level instructions and decisions, then resume with `/dev-implement .tasks/<task>.md --continue`.
* **Guard blocked a command**: The guard refused a destructive git command (force-push, commit amend, or base branch push). Commit changes normally and use `/dev-pr`.
* **Findings dropped as unverifiable**: The model quoted code that did not exist in the file. Ensure `temperature: 0`.

---

## License

[MIT](LICENSE)
