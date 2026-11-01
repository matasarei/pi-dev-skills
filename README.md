# opencode-skills

<p>
  <a href="https://opencode.ai"><img src="https://img.shields.io/badge/OpenCode-1B1B1B?style=for-the-badge" alt="OpenCode" /></a>
  <img src="https://img.shields.io/badge/Local_models-6E56CF?style=for-the-badge&logo=ollama&logoColor=white" alt="Local models" />
  <img src="https://img.shields.io/badge/Docker-2496ED?style=for-the-badge&logo=docker&logoColor=white" alt="Docker" />
  <a href="https://github.com/matasarei/opencode-skills/actions/workflows/checks.yml"><img src="https://img.shields.io/github/actions/workflow/status/matasarei/opencode-skills/checks.yml?style=for-the-badge&label=Checks" alt="Checks" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-3DA639?style=for-the-badge" alt="License: MIT" /></a>
</p>

Development skills for [OpenCode](https://opencode.ai) engineered specifically for **local ~30B models** (such as **Qwen3 Coder 30B**, **Prism Bonsai 27B**, and **Qwen3.8 27B**).

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
git clone https://github.com/matasarei/opencode-skills.git
cd opencode-skills

# Install globally (to ~/.config/opencode)
./install.sh

# Or install for current project only (to ./.opencode)
./install.sh --project
```

### Requirements
* **OpenCode** with skills support.
* **Git** and **Bash** (macOS, Linux, or WSL on Windows. Native Windows Git Bash is unsupported).
* **GitHub CLI (`gh`)** for pull request skills (`gh auth login`).
* **Docker** (recommended — skills run tests inside project containers by default).

> **Invoking Skills**: In OpenCode, skills installed in `skills/` are accessed via the **`/skills`** picker (type `/skills` in the prompt or use the TUI picker), or loaded as agent tools. They do not autocomplete directly on the root `/` slash (which OpenCode reserves for custom commands).

---

## Configuration

A complete, recommended configuration is provided in [**`opencode.jsonc`**](opencode.jsonc). Copy it to `~/.config/opencode/opencode.jsonc` or your project's `.opencode/opencode.jsonc`.

### 1. Model Configuration

Local models perform best in agentic loops when **reasoning is turned OFF by default** and the **output ceiling is capped at 16k tokens**:

```jsonc
"models": {
  "prism-ml/bonsai-27b": {
    "name": "Prism Bonsai 27B",
    "attachment": true,
    "reasoning": true,
    "tool_call": true,
    "limit": {
      "context": 131072,  // 128k context window
      "output": 16384     // 16k output ceiling
    },
    "options": {
      "reasoning_effort": "none"  // Disables thinking tokens by default
    },
    "variants": {
      "low": { "disabled": true },
      "medium": { "disabled": true },
      "high": { "disabled": true },
      "off": { "reasoning_effort": "none" },
      "on":  { "reasoning_effort": "medium" }
    }
  }
}
```

* **Capabilities (`attachment`, `reasoning`, `tool_call`)**: Declares model capabilities to OpenCode. Prism Bonsai 27B is natively multimodal (vision) and reasoning-capable. Setting `"reasoning": true` allows OpenCode to parse reasoning tokens and support variants.
* **Why 16k output?** In local inference, thinking tokens share the output budget. 16k gives ample headroom for large diffs, database migrations, and plans without truncation (`finish_reason: length`), while preventing runaway infinite loops (on lower-end 8–12 GB VRAM hardware running 9B models, an 8k output ceiling and 32k context is configured in `opencode.jsonc`).
* **Why reasoning OFF by default?** While the model is reasoning-capable, in agent loops local models spend 30–90 seconds generating `<think>` tokens before *every single tool call*, often simulating imaginary tool output instead of calling the tool. Setting `"reasoning_effort": "none"` in `options` defaults thinking off, reducing latency to 1–3 seconds so real tool output grounds the model.
* **On-the-Fly Toggle**: Because `reasoning: true` is enabled, the `variants` block lets you toggle reasoning `on` whenever you need deep architectural planning (switch via `/variant` or `Ctrl+M` / `Cmd+M` in the OpenCode TUI). Built-in `low`, `medium`, and `high` variants are disabled (`"disabled": true`) to keep the picker clean (`Default`, `off`, `on`).

### 2. Permissions & Agent Configuration

```jsonc
"permission": {
  "external_directory": {
    "/tmp/**": "allow",
    "/private/tmp/**": "allow"
  }
},
"agent": {
  "build": {
    "temperature": 0
  },
  "plan": {
    "temperature": 0,
    "permission": {
      "edit": {
        "*.md": "allow",
        "**/*.md": "allow",
        ".tasks/**": "allow",
        "plans/**": "allow"
      }
    }
  }
}
```

* **Scratch Permissions (`/tmp`)**: OpenCode defaults `external_directory` to `ask`. Allowing `/tmp/**` and `/private/tmp/**` lets models write temporary scripts, diffs, and test outputs without stalling autonomous runs, while keeping sensitive paths outside the workspace protected.
* **`temperature: 0`**: OpenCode defaults Qwen models to `0.55`. Zero temperature is required for deterministic code reviews and consistent tool use.
* **Plan Mode Permissions**: OpenCode's native `plan` agent blocks file edits by default. Adding permissions for `.tasks/**` and `*.md` allows `/dev-plan` to write and update actionable task files.

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
2. **Plan**: `/dev-plan` resolves input via `plan-input.sh`, validates referenced paths with `plan-check.sh`, and sizes each step using `step-budget.sh` against `contextTokens`, read from your `opencode.jsonc` and overridable with `DEV_SKILLS_CONTEXT`. Shared parsing is handled by `steps.awk`. For targeted bug fixes, `/dev-fix <issue>` investigates root cause and produces a verified plan in `.tasks/fix-<slug>.md`.
3. **Or plan it for yourself**: `/dev-plan-manual` writes the same task file marked `**Mode:** manual`, then one step's walkthrough at a time as you reach it — anchors, the pattern in this repository to copy the shape of, and why, but never a body you could paste. It is for a repository that does not accept generated code, and for learning a codebase by changing it. `/dev-implement` refuses a plan carrying that marker, `/dev-review` reads hand-written code unchanged and hands its findings back to you rather than to `/dev-fix`, and `branch.sh` refuses the next step until you have committed the last one yourself.
4. **Build**: `/dev-implement` injects exactly one step via `task-step.sh` onto a stacked branch named `step/<slug>-<n>`.
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

`profile.sh` reads the window from your `opencode.jsonc` — the selected model's `limit.context` —
and `step-budget.sh` sizes every step against it, so a plan written on a 128k machine is sized
for 128k. `DEV_SKILLS_CONTEXT` overrides it when your server is configured differently from your
config file. **A step sized for a window you do not have still runs — it just degrades**, which
is why the number is detected rather than assumed.

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

* **The Guard (`pi/guard.js`)**: A Pi extension on the `tool_call` event that blocks dangerous actions before they run: force pushes, amended commits, skipped git hooks, pushes to `main`/`master`, commits on the base branch, and unauthorized `gh pr merge`. It also repairs the argument mistakes local models make most (an unescaped backslash in a grep pattern, a file passed to `find` as its directory, a bash timeout in milliseconds where Pi wants seconds, line endings that differ from the file) and breaks loops of identical tool calls. Verified by the case table in `evals/guard/cases.sh`.
* **Mechanical Evidence Verification**: `lib/findings-check.sh` validates quoted code against current files on disk, discarding hallucinated findings.
* **Cross-Stack Route Verification**: `lib/http-check.sh` verifies HTTP routes and responses across tech stacks (validating connection status, HTTP codes, auth drops to login routes/inputs, empty responses / white screens of death, English framework error screens, required domain content assertions, and crash/traceback signatures across PHP, Python, Node, Java, Go, Ruby, and SQL engines).
* **One Verdict Line for the Suite**: `lib/test.sh` picks `test` or `testScoped` from the profile, wraps it in `timeoutTool`, runs it, and prints a single line carrying the runner's own summary — `TEST PASS | OK (43 tests, 118 assertions)`, `TEST FAIL | …`, `TEST MISSING — …`, `TEST TIMEOUT — …`. Those four decisions used to be prose in three separate skills, and a model that dropped any one of them reported "tests pass" with nothing behind it. A null `timeoutTool` is declared in the verdict rather than dropped silently.
* **Red First**: `lib/test.sh --red <name>` runs a step's scoped test before its code exists and says whether it failed as a test — `RED PROVEN | …` when at least one test ran and failed, `RED NOT PROVEN — …` when it passed, `RED UNCLEAR | …` for a parse, collection or build error or an unrecognised runner, and `RED UNCLEAR — no testScoped …` for a profile with no `testScoped` carrying `{name}`. A test written after the code can pass either way, so a green line alone never proved it meant anything. Every step in a plan carries a `Red:` line — the test that must fail first, or `none — <reason>` — and `plan-check.sh` refuses one without it. `/dev-implement` writes that test before any production line; the verdict is recorded in `.devskills/red-result`, apart from the green record, and `/dev-review` (C11) and `/dev-pr` read it rather than taking the model's word. A red record counts only on the branch it was recorded on, with its commit at or behind HEAD — so run red after the step branch is cut, and do not rename the branch afterwards: a record from another branch, an earlier step or a renamed branch reads as stale.
* **Ticking a Step**: `lib/tick.sh <task-file> <n> "<what landed>"` rewrites `N. [ ] title` as `N. [x] title — what landed`. It is the smallest edit in the cycle and the one that fails silently: a step left unticked is a step the next run builds again. It refuses a step written in any other shape rather than guessing, and a second tick is a no-op.
* **Stacked Step Branches**: `lib/branch.sh <task-file> <n>` cuts `step/<slug>-<n>` from the previous step's branch when it exists and from the base branch otherwise, which is what makes the pull requests stack. Getting that base wrong points a step's PR at `main` and shows every earlier step's diff inside it. An existing branch is switched to, never re-cut, and a switch is refused while the tree is dirty so half of one step cannot follow into another step's PR.
* **A Capped Queue**: `lib/changed.sh` collapses build and vendor output to a count and caps the queue at 200 entries (`DEV_SKILLS_QUEUE_CAP`), announcing the truncation the way `lib/diff.sh` does. The queue is read into a prompt, and an un-ignored `build/` directory took it from three lines to three hundred — three hundred lines a model reads instead of the instructions above them. Because the queue is ordered by risk, the tail is what gets cut.
* **The Clean-Clone Check**: `lib/verify-clean.sh` clones HEAD somewhere empty and runs the profile's test command there, so a suite cannot pass because of an uncommitted file, a stale install or a cached artefact. It is what a repository with no CI is missing, and only that — no network, no forge, no remote required. Slower than `test.sh` by a clone, so it is deliberate rather than automatic: run it before a pull request, or whenever the profile says `verification: local-only`.
* **Size Cap**: Each `SKILL.md` is strictly capped at 90 lines and `5,000 bytes` (enforced by `evals/skills/size.sh`) to prevent context bloat.
* **Testing & Evals**: The entire toolkit is covered by fixture suites. Run `bash evals/run-all.sh` to execute every suite — it prints how many ran and exits non-zero if any failed — or scope to individual tests (`bash evals/lib/<script>.sh`). Lint with `shellcheck --severity=warning lib/*.sh install.sh evals/*.sh evals/*/*.sh`. Run `./install.sh` to sync local changes into `~/.config/opencode/`, then verify skills load in OpenCode via `opencode debug skill` (or `opencode debug skill --print-logs`).

---

## Troubleshooting

* **Skills not showing up on `/`**: In OpenCode, skills are accessed via the **`/skills`** picker, not root `/` command autocomplete. Type `/skills` in OpenCode to select a skill. If `/skills` is empty, check `ls ~/.config/opencode/skills/` and verify each directory has a valid `SKILL.md`.
* **Tool calls truncate or loop**: Server context window is below 64k. Increase context length in LM Studio or set `OLLAMA_CONTEXT_LENGTH=65536`.
* **Model stuck in a retry loop or context bloated**: Repeated failed tool calls (e.g. failing edits or syntax errors) can fill the context with identical failure traces, trapping `temperature: 0` models in repetitive retry loops:
  * **Fresh Session (`--continue`)**: Exit OpenCode and start a fresh session, then run `/dev-implement .tasks/<task>.md --continue`. Progress is tracked on disk in `.tasks/` and git branch commits, instantly clearing out thousands of poisoned context tokens.
  * **`/compact`**: If staying in the active session, run `/compact` to prune verbose tool error outputs while retaining high-level instructions and decisions, then resume with `/dev-implement .tasks/<task>.md --continue`.
* **Plan mode refuses to write to `.tasks/`**: Ensure `agent.plan.permission.edit` allows `.tasks/**` in `opencode.jsonc`.
* **Guard blocked a command**: The guard refused a destructive git command (force-push, commit amend, or base branch push). Commit changes normally and use `/dev-pr`.
* **Findings dropped as unverifiable**: The model quoted code that did not exist in the file. Ensure `temperature: 0`.

---

## License

[MIT](LICENSE)
