---
name: dev-review
description: Review your own changes before /dev-pr — twelve yes/no checks per file, worst-risk first, every finding verified by a script. Never edits, commits or pushes.
---

# Review your own work

Never edit the code under review, never commit, push or post. What this *does* write is its own workspace: `.devskills/findings.md`, and a report. You list; `/dev-fix` applies.

## How to run this

**First, empty `.devskills/findings.md`** (`: > .devskills/findings.md`) — it is appended to; a leftover reads as this run's.

Then work the queue at the bottom **one file per step** — do not batch, do not skim ahead. For each, in queue order: read it; answer the checks below yes or no, about that file only; every YES appends one line to `.devskills/findings.md`. Read at most the **top 3 files** in full; judge the rest from the diff, and name them as judged-from-diff.

## The checks

Answer yes or no. Do not weigh, rank or reconsider — just answer.

- **C1 SECRET** — does the diff add a password, key, token or credential?
- **C2 SCOPE** — does it write to the database without bounded scope (an explicit id set or range)?
- **C3 DRYRUN** — is it a script that writes in bulk, with no dry-run as the default?
- **C4 RERUN** — would a second run duplicate rows or double-apply the change?
- **C5 CALLER** — does it rename or remove a function, method or class?
- **C6 ESCAPE** — does user input reach SQL, HTML or a spreadsheet cell unescaped?
- **C7 AUTHZ** — does it add, remove or change a permission or capability check?
- **C8 VERSION** — *(moodle-plugin only)* does it touch `classes/`, `db/`, caches or tasks with no `version.php` bump?
- **C9 NULL** — does it use a value that can be null without checking?
- **C10 LOOP** — does it add a loop, cursor or search that may not terminate on empty, duplicate or gapped data?
- **C11 TEST** — does it add logic with no test, a test whose assertion proves nothing (e.g. status 200 without checking content/state), or a test while the red receipt below is `(none)`, `RED NOT PROVEN` or `RED UNCLEAR`?
- **C12 ERROR** — does it add a throw, guard or error return that nothing tests?

**Severity is fixed**: C1–C8 `BLOCKER`, C9–C12 `WARNING`. Do not choose it yourself.

## C5 is grep, not judgement

For every renamed or removed symbol, grep the files the current step names — `bash $DEV_SKILLS_LIB/task-step.sh <task-file> --paths <n>` lists them — then run:

```
bash $DEV_SKILLS_LIB/callers.sh "<oldname>"
```

Any surviving caller in code, tests/ or views/ is a BLOCKER. Do not reason about reachability — report what callers.sh found.

## The output line

One line per finding in `.devskills/findings.md`, exactly this shape:

```
SEVERITY | path:line | one sentence on what breaks | EVIDENCE: <the exact line from the file>
```

**EVIDENCE is copied, character for character.** If you cannot copy a line that proves the finding, do not write it — an unverifiable one is deleted below. One sentence; no diff dumps.

## Finish

1. Lint: `bash $DEV_SKILLS_LIB/lint.sh` — a failure is a BLOCKER, quoted verbatim. `NO LINT COMMAND` → report the review as **unlinted**.
2. Verify: `bash $DEV_SKILLS_LIB/findings-check.sh .devskills/findings.md`
3. **Report only what step 2 printed.**

Lead with one line — `Ready to push` / `N blockers first` / `Ready, with N warnings` — then the findings, blockers first, the files judged from the diff alone, and whether lint ran. A report file only on a blocker or when asked: `.devskills/reports/review-<branch-slug>-<UTC timestamp>.md`, path printed. Then: `Next: /dev-fix .devskills/findings.md` when anything survived; `Next: /dev-pr` when nothing did. **Manual plan below, not `(none)`** → hand-written code: the findings are theirs to fix by hand; `/dev-fix` named once as theirs to run.

## Rules

- Absolute paths. English; quote code in its own language.
- No tests in the repository at all → say it once, never per file, never as "tests pass".

---

## This repository

Profile:

!`bash $DEV_SKILLS_LIB/profile.sh`

Manual plan:

!`b=$(git branch --show-current 2>/dev/null); case "$b" in step/*-[0-9]*) case "${b##*-}" in *[!0-9]*) ;; *) s=${b#step/}; grep -l '^\*\*Mode:\*\* manual' ".tasks/${s%-*}.md" 2>/dev/null ;; esac ;; esac | grep . || echo "(none)"`

Red receipt:

!`set -f; b=$(git branch --show-current 2>/dev/null); set -- $(cat .devskills/red-result 2>/dev/null); [ -n "$b" ] && [ "${2:-}" = "$b" ] && git merge-base --is-ancestor "$1" HEAD 2>/dev/null && shift 2 && echo "$*" || echo "(none)"`

Queue — rank 1 is highest risk, top-down:

!`bash $DEV_SKILLS_LIB/changed.sh`

Diff:

!`bash $DEV_SKILLS_LIB/diff.sh`
