#!/usr/bin/env bash
# Invariants every skill directory must hold — run them from anywhere:
#
#   bash evals/skills/frontmatter.sh
#
# pi/commands.js names each command after its skill's directory, and the
# Agent Skills spec the files follow wants that directory to be the
# frontmatter's name, so the two must agree. The README's troubleshooting
# section sends people here first. The rest is what makes the prompts work at
# all on a local model:
# a one-line description, and the injected blocks that hand the model its facts
# (the profile, at least) instead of asking it to work them out.
#
# Exits 0 when every skill holds, 1 otherwise, naming each mismatch.

set -u

root="$(cd "$(dirname "$0")/../.." && pwd)"
skills="$root/skills"
[ -d "$skills" ] || { printf 'no skills at %s\n' "$skills" >&2; exit 1; }

fails=0
checked=0
note() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
# The frontmatter: everything between the opening --- and the closing one.
head_of() { sed -n '2,/^---$/p' "$1"; }

for dir in "$skills"/*/; do
  s="$(basename "$dir")"
  f="$dir/SKILL.md"
  [ -f "$f" ] || { note "$s: no SKILL.md (capitals matter)"; continue; }
  checked=$((checked + 1))

  [ "$(head -1 "$f")" = '---' ] || note "$s: SKILL.md does not open with frontmatter"
  name="$(head_of "$f" | sed -n 's/^name:[[:space:]]*//p' | head -1)"
  [ "$name" = "$s" ] || note "$s: frontmatter name is '$name', must equal the directory name"

  desc_lines="$(head_of "$f" | grep -c '^description:')"
  [ "$desc_lines" -eq 1 ] || note "$s: expected exactly one description: line, found $desc_lines"
  # A description that wraps onto a continuation line is two lines to the loader.
  head_of "$f" | grep -qE '^[[:space:]]+[^[:space:]]' && note "$s: frontmatter has a continuation line — keep every field on one line"

  # The injected facts. Every skill hands the model the profile; a skill with no
  # !`…` block at all is asking the model to run the scripts itself.
  grep -q '^!`' "$f" || note "$s: no injected block (a line starting with !\`)"
  grep -q 'profile.sh' "$f" || note "$s: never injects or names profile.sh"
done

if [ "$checked" -eq 0 ]; then
  printf 'no skills under %s\n' "$skills" >&2
  exit 1
elif [ "$fails" -eq 0 ]; then
  printf 'frontmatter: invariants hold across %s skills\n' "$checked"
else
  printf 'frontmatter: %s problem(s)\n' "$fails" >&2
fi
exit $((fails > 0))
