---
name: dev-init
description: Write this repository's AGENTS.md — the detected commands plus its family's conventions and security rules. Writes AGENTS.md only and nothing else.
---

# Give this repository an AGENTS.md

`AGENTS.md` is loaded at the start of every session: the build and test commands, and the handful of rules that actually get broken here.

**Content goes in `AGENTS.md` only.** Pi reads `AGENTS.md` directly. If existing rules are in `CLAUDE.md` and none in `AGENTS.md`, **move** them into `AGENTS.md`. Never create or write `CLAUDE.md` stubs.

## Step 1 — Map the family to a template

From `family` in the profile below; `--family <name>` overrides it with a template name. Templates live in `templates/` beside this file.

| Profile family | Template | Note |
|---|---|---|
| `moodle-plugin` | `moodle-plugin` | |
| `cms` | `cms` | |
| `php-app` | `php-app` | |
| `php-library` | `php-app` | skip its request-handling sections |
| `python-app` | `python-app` | |
| `node`, `other` | — | commands section only; say the family block was skipped |

## Step 2 — Read what is there first

No `AGENTS.md` → step 3. Otherwise judge it: are the commands still true against the profile (a stale command will be tried); is anything contradicted by the code (an escaping claim the templates do not back is worse than nothing); is the family block present?

Report one of three, and **do not write without saying which**: **Already fine** — one line, nothing written; **Needs a refresh** — show what would change and ask (`--refresh` is already yes); **Needs attention you should not apply** — a stale command or a claim the code contradicts, listed for the developer. **A hand-written `AGENTS.md` is never overwritten** — show the family block and ask where to insert it.

## Step 3 — Write it

```markdown
# <Repository name>

<One or two sentences: what this is, and the structural thing a newcomer gets wrong.>

## Commands

| What | Command |
|---|---|
| Install | `<profile.install>` |
| Test | `<profile.test>` |
| Lint | `<profile.lint>` |
| Build | `<profile.build>` |
| Run | `<profile.runtime.how>` |

<exec.kind compose or image: these run inside the container, and why. Host fallback: say so, name the version mismatch.>

<the family template, verbatim>

## This project specifically

<step 4>
```

**A `null` command is written as "none" with the reason.** Never invented — the next reader will try it. **Do not pad**: the file is loaded into every session.

## Step 4 — What only this repository knows

Look, then write what you find — never assume: does the template layer escape automatically (read a view and the render path; cannot tell → say so and mark it); is there a CSRF helper — name it or record none; how authorisation is checked — middleware, base controller, per-action; which files hold credentials and whether they are ignored — where, **never their contents**; what is generated and must not be hand-edited; what breaks only in production — a cache, a version bump, a migration.

## Step 5 — Report

Write `AGENTS.md`. Never create `CLAUDE.md` stubs — Pi reads `AGENTS.md` first. Then report: the family and why, the absolute path written, which commands came out `null`, and what step 4 left as a question. `--dry-run` prints and writes nothing.

## Rules

- **Only `AGENTS.md`.** Never write `CLAUDE.md`. No source, no config, no commits. Never invent a command. Never copy a secret into the file.
- **Under ~120 lines** including the family block; the surplus belongs in the repository's own documentation.
- English. A monorepo gets one file at the root, noting which directory each command applies to. Already correct → say so and stop; no reformatting.

---

## This repository

Profile:

!`bash $DEV_SKILLS_LIB/profile.sh`

Existing instruction files:

!`for f in AGENTS.md CLAUDE.md CONTRIBUTING.md; do [ -f "$f" ] && echo "== $f ($(wc -l < "$f" | tr -d ' ') lines)" && head -15 "$f"; done; echo "(end)"`
