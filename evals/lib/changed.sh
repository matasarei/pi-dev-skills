#!/usr/bin/env bash
# Cases for lib/changed.sh — run them from anywhere:
#
#   bash evals/lib/changed.sh
#
# The queue's order is the decision a small model must not make, so the ranks
# are asserted one by one against a fixture branch, along with the two refusals
# (on the base branch, nothing changed), that uncommitted work is in the queue,
# that a rename yields the destination path rather than "old -> new", and that a
# new directory of untracked files arrives as its files and never as a directory,
# and that a non-ASCII path is never C-quoted into something that is not a path.
#
# Exits 0 when every case matches, 1 otherwise, naming each mismatch.

set -u

# Pi sets DEV_SKILLS_CONTEXT for every command it runs (pi/commands.js), so a
# suite run from inside Pi would inherit the session's window and fail every
# case that asserts the default. Each case that wants a window sets its own.
unset DEV_SKILLS_CONTEXT DEV_SKILLS_QUEUE_CAP

root="$(cd "$(dirname "$0")/../.." && pwd)"
changed="$root/lib/changed.sh"
[ -f "$changed" ] || { printf 'no changed.sh at %s\n' "$changed" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM
# The repository sits one level down, so stderr captures in $work are not untracked files in it.
repo="$work/repo"; mkdir -p "$repo"

fails=0
note() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
g() { git -C "$repo" -c user.email=t@e -c user.name=t "$@"; }
rank_of() { printf '%s\n' "$out" | awk -v f="$1" '$3 == f {print $1}'; }
status_of() { printf '%s\n' "$out" | awk -v f="$1" '$3 == f {print $2}'; }
want_rank() { [ "$(rank_of "$1")" = "$2" ] || note "$1: rank '$(rank_of "$1")', want $2"; }

# The base: a few files that already exist, so "modified" and "added" differ.
g init -q -b main .
mkdir -p "$repo/src" "$repo/db" "$repo/tests" "$repo/vendor"
printf '<?php\n// app\n' > "$repo/src/app.php"
printf '<?php\n// old\n' > "$repo/src/old.php"
printf 'x\n' > "$repo/README.md"
g add -A && g commit -qm base

# Refusal 1: on the base branch there is nothing to compare against.
( cd "$repo" && bash "$changed" main >/dev/null 2>"$work/err" ); rc=$?
[ "$rc" -eq 2 ] || note "on the base branch: exit $rc, want 2"
grep -q "you are on 'main'" "$work/err" || note 'on the base branch: the message should name the branch'

# Refusal 2: a branch with no changes.
g switch -qc feature
( cd "$repo" && bash "$changed" main >/dev/null 2>"$work/err" ); rc=$?
[ "$rc" -eq 3 ] || note "no changes: exit $rc, want 3"

# One file of each rank, committed on the branch.
printf '<?php\n// schema\n' > "$repo/db/upgrade.php"                       # 1: schema
printf '<?php\n// app changed\n' > "$repo/src/app.php"                     # 2: existing code modified
printf '<?php\nforeach ($a as $b) {}\n' > "$repo/src/loop.php"             # 3: new code with a loop
printf '<?php\n// plain\n' > "$repo/src/plain.php"                         # 4: new code, nothing risky
printf '<?php\n// plain\n' > "$repo/src/简历.php"                           # 4: a non-ASCII path, committed
printf '<?php\n// test\n' > "$repo/tests/PlainTest.php"                    # 5: a test
printf '{}\n' > "$repo/composer.lock"                                      # 6: a lock file
printf 'y\n' > "$repo/README.md"                                           # 7: docs
printf '<?php\n' > "$repo/vendor/lib.php"                                  # 9: vendored
g mv src/old.php src/renamed.php                                        # a pure rename
g add -A && g commit -qm change

# And one uncommitted, untracked file: it must be in the queue too.
printf '<?php\n// wip\n' > "$repo/src/wip.php"

# And a whole new directory of untracked files. Porcelain collapses these to a
# single "?? assets/js/" entry unless -uall is passed, and then neither file is
# ever linted or reviewed.
mkdir -p "$repo/assets/js"
printf 'export const a = 1\n' > "$repo/assets/js/widget.js"
printf 'export const b = 2\n' > "$repo/assets/js/helper.js"
printf 'export const c = 3\n' > "$repo/assets/js/咖啡.js"

out="$(cd "$repo" && bash "$changed" main 2>&1)"

want_rank db/upgrade.php 1
want_rank src/app.php 2
want_rank src/loop.php 3
want_rank src/plain.php 4
want_rank tests/PlainTest.php 5
want_rank composer.lock 6
want_rank README.md 7
want_rank vendor/lib.php 9
want_rank src/wip.php 4
[ "$(status_of src/wip.php)" = "??" ] || note "an untracked file should carry status ??, got '$(status_of src/wip.php)'"

# The new directory: both of its files are in the queue, and the directory
# itself is never a queue entry — a path ending in "/" is not a path.
want_rank assets/js/widget.js 4
want_rank assets/js/helper.js 4
printf '%s\n' "$out" | grep -qE ' [^ ]+/$' && note 'a directory reached the queue; the status call needs -uall'

# Non-ASCII paths, both sides: git C-quotes them unless core.quotePath=false, and
# a quoted, escaped path is not a path. The committed one comes through git diff,
# the untracked one through git status.
want_rank "src/简历.php" 4
want_rank "assets/js/咖啡.js" 4
printf '%s\n' "$out" | grep -q '\\[0-9]' && note 'a path reached the queue C-escaped; both git calls need core.quotePath=false'
printf '%s\n' "$out" | grep -q ' "' && note 'a path reached the queue wrapped in quotes'

# Risk does not stop at PHP. Existing code modified in any language is rank 2,
# a dependency manifest or a CI workflow is rank 3 rather than documentation,
# and a non-PHP request idiom reaches rank 3 like $_GET does.
g switch -q main
mkdir -p "$repo/svc" "$repo/.github/workflows"
printf 'package main\nfunc main(){}\n' > "$repo/svc/main.go"
printf 'fn main(){}\n' > "$repo/svc/main.rs"
printf 'class A {}\n' > "$repo/svc/A.java"
printf 'export const x = 1\n' > "$repo/svc/w.tsx"
printf 'module x\n' > "$repo/go.mod"
printf 'on: push\n' > "$repo/.github/workflows/ci.yml"
g add -A && g commit -qm langs
g switch -q feature && g merge -q main -m merge
printf 'package main\nfunc main(){ _ = 1 }\n' > "$repo/svc/main.go"
printf 'fn main(){ let _ = 1; }\n' > "$repo/svc/main.rs"
printf 'class A { int x; }\n' > "$repo/svc/A.java"
printf 'export const x = 2\n' > "$repo/svc/w.tsx"
printf 'module x\nrequire y v1\n' > "$repo/go.mod"
printf 'on: [push]\n' > "$repo/.github/workflows/ci.yml"
printf 'package h\nfunc H(r *http.Request){ r.URL.Query().Get("id") }\n' > "$repo/svc/handler.go"
g add -A && g commit -qm polyglot
out="$(cd "$repo" && bash "$changed" main 2>&1)"

want_rank svc/main.go 2
want_rank svc/main.rs 2
want_rank svc/A.java 2
want_rank svc/w.tsx 2
want_rank go.mod 3
want_rank .github/workflows/ci.yml 3
want_rank svc/handler.go 3

# The rename: destination path, status R, and no "->" anywhere in the queue.
[ -n "$(rank_of src/renamed.php)" ] || note 'a renamed file is missing from the queue under its new path'
printf '%s\n' "$out" | grep -q -- '->' && note 'a rename leaked through as "old -> new"'
printf '%s\n' "$out" | grep -q 'src/old.php' && note 'the old path of a rename is still in the queue'

# Sorted by rank: the first line is rank 1, the last is rank 9.
[ "$(printf '%s\n' "$out" | head -1 | cut -d' ' -f1)" = 1 ] || note 'the queue does not start at rank 1'
[ "$(printf '%s\n' "$out" | tail -1 | cut -d' ' -f1)" = 9 ] || note 'the queue does not end at rank 9'

# Build output is rank 9, and a pile of it is counted rather than listed. The
# queue is read into a prompt: 300 generated files there is 300 lines a model
# reads instead of the instructions above them.
g switch -q main
mkdir -p "$repo/build/assets" "$repo/dist"
printf 'x\n' > "$repo/build/assets/app.js"
printf 'x\n' > "$repo/dist/app.css"
g add -A && g commit -qm built
g switch -q feature && g merge -q main -m merge2
printf 'y\n' > "$repo/build/assets/app.js"
printf 'y\n' > "$repo/dist/app.css"
g add -A && g commit -qm rebuilt
out="$(cd "$repo" && bash "$changed" main 2>&1)"
want_rank build/assets/app.js 9
want_rank dist/app.css 9

# Five or fewer stay listed; more than five collapse to a count.
for i in 1 2 3 4 5 6 7 8; do printf 'x\n' > "$repo/build/assets/g$i.js"; done
out="$(cd "$repo" && bash "$changed" main 2>&1)"
printf '%s\n' "$out" | grep -q 'build/assets/g1.js' && note 'a pile of build output was listed file by file'
printf '%s\n' "$out" | grep -qE '^\[[0-9]+ vendored or build file\(s\) not listed' \
  || note "collapsed build output is not announced: '$(printf '%s\n' "$out" | tail -1)'"
# The real change is still there, which is the whole point of collapsing.
[ -n "$(rank_of src/app.php)" ] || note 'the source file was lost among the build output'

# The cap truncates the tail and says so, and never drops a higher-risk file.
out="$(cd "$repo" && DEV_SKILLS_QUEUE_CAP=2 bash "$changed" main 2>&1)"
[ "$(printf '%s\n' "$out" | head -1 | cut -d' ' -f1)" = 1 ] || note 'the cap dropped the highest-risk file'
printf '%s\n' "$out" | grep -q '^\[TRUNCATED:' || note 'the cap truncated without announcing it'

# .devskills/ is never part of the change.
mkdir -p "$repo/.devskills"; printf '{}\n' > "$repo/.devskills/profile.json"
out="$(cd "$repo" && bash "$changed" main 2>&1)"
printf '%s\n' "$out" | grep -q '\.devskills' && note '.devskills/ files were listed as changes'

# A base that does not exist is refused, not treated as empty.
( cd "$repo" && bash "$changed" nope >/dev/null 2>&1 ); rc=$?
[ "$rc" -eq 1 ] || note "a missing base exited $rc, want 1"

# The scratch file. It used to be /tmp/devskills-changed.$$ — a directory the
# environment could not move, and a name derived from the PID — while every
# newer script in lib/ uses mktemp. Two things are asserted: nothing is left
# behind, and TMPDIR actually decides where it goes.
tmp="$work/tmp"; mkdir -p "$tmp"
( cd "$repo" && TMPDIR="$tmp" bash "$changed" main >/dev/null 2>&1 )
[ -z "$(ls -A "$tmp" 2>/dev/null)" ] || note "a scratch file was left behind in TMPDIR: $(ls -A "$tmp")"

# The discriminating half: an unwritable TMPDIR has to stop the run, because a
# script that quietly writes to /tmp instead was never honouring it. Skipped as
# root, where the mode bits do not apply.
if [ "$(id -u)" != 0 ]; then
  ro="$work/ro"; mkdir -p "$ro"; chmod 500 "$ro"
  ( cd "$repo" && TMPDIR="$ro" bash "$changed" main >/dev/null 2>"$work/err" ); rc=$?
  [ "$rc" -eq 73 ] || note "an unwritable TMPDIR exited $rc, want 73 — and never 1, which means the base branch is missing"
  grep -qi 'scratch' "$work/err" \
    || note "unwritable TMPDIR: the error should name the scratch file, got '$(head -1 "$work/err")'"
  chmod 700 "$ro"
else
  # Named, not silent: this is the only case here that tells the fix from the
  # code it replaced, so a run that skips it has proved nothing about TMPDIR.
  printf 'changed: running as root, the unwritable TMPDIR case was skipped\n' >&2
fi

# The queue cap follows the context window too, but at its own rate: a queue
# entry is one short line where a diff line is a line of source, so 6 per 1k --
# diff.sh's rate -- would treble this queue rather than scale it. 2 per 1k keeps
# the 200 this script has always used at the 100k fallback, exactly as diff.sh
# keeps its 600, and gives 262/131/65 at 128k/64k/32k.
g switch -q feature
mkdir -p "$repo/src/gen"
i=1; while [ "$i" -le 300 ]; do printf '<?php\n// %s\n' "$i" > "$repo/src/gen/f$i.php"; i=$((i + 1)); done
g add -A && g commit -qm 'a wide change'

shown_of() { printf '%s\n' "$1" | grep -cv '^\['; }
want_queue() { # want_queue <env context> <expected cap> <label>
  o="$(cd "$repo" && DEV_SKILLS_CONTEXT="$1" bash "$changed" main 2>&1)"
  [ "$(shown_of "$o")" = "$2" ] || note "queue cap at $3: showed $(shown_of "$o"), want $2"
  printf '%s\n' "$o" | grep -q '^\[TRUNCATED:' || note "queue cap at $3: truncation was not announced"
}
want_queue 131072 262 '128k'
want_queue 65536  131 '64k'
want_queue 32768   65 '32k'

# Nothing declares a window: the 200 this script has always used.
o="$(cd "$repo" && bash "$changed" main 2>&1)"
[ "$(shown_of "$o")" = 200 ] || note "queue cap with no window declared: showed $(shown_of "$o"), want the unchanged 200"

# DEV_SKILLS_QUEUE_CAP still wins over the derived default.
o="$(cd "$repo" && DEV_SKILLS_CONTEXT=131072 DEV_SKILLS_QUEUE_CAP=7 bash "$changed" main 2>&1)"
[ "$(shown_of "$o")" = 7 ] || note "DEV_SKILLS_QUEUE_CAP no longer wins: showed $(shown_of "$o"), want 7"

# An override set to nothing is not a cap of nothing: it derives, exactly as an
# unset one does. Every other derived cap here reads empty as absent.
o="$(cd "$repo" && DEV_SKILLS_CONTEXT=131072 DEV_SKILLS_QUEUE_CAP='' bash "$changed" main 2>&1)"
[ "$(shown_of "$o")" = 262 ] || note "an empty DEV_SKILLS_QUEUE_CAP: showed $(shown_of "$o"), want the derived 262"

if [ "$fails" -eq 0 ]; then
  printf 'changed: every rank follows its fixture, renames and untracked files included\n'
else
  printf 'changed: %s case(s) failed\n' "$fails" >&2
fi
exit $((fails > 0))
