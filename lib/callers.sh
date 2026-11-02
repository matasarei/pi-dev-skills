#!/usr/bin/env bash
# Search for surviving callers of a renamed, moved or removed symbol across the project.
#
#   callers.sh <symbol> [path...]
#
# Exits 0 if no callers found (clean), 1 if surviving callers found, 2 on bad usage.

set -u

SYM="${1:-}"
if [ -z "$SYM" ]; then
  echo "usage: callers.sh <symbol> [path...]" >&2
  exit 2
fi
shift

EXCLUDES=(
  --exclude-dir=vendor
  --exclude-dir=node_modules
  --exclude-dir=.venv
  --exclude-dir=venv
  --exclude-dir=.git
  --exclude-dir=.idea
  --exclude-dir=.vscode
  --exclude-dir=.claude
  --exclude-dir=.claude-plugin
  --exclude-dir=.antigravitycli
  --exclude-dir=.gemini
  --exclude-dir=.gku
  --exclude-dir=.pi
  --exclude-dir=.agents
  --exclude-dir=.devskills
  --exclude-dir=.tasks
  --exclude-dir=.quests
  --exclude-dir=.phpunit.cache
  --exclude-dir=.pytest_cache
  --exclude-dir=.mypy_cache
  --exclude-dir=.mysql
  --exclude-dir=.next
  --exclude-dir=.nuxt
  --exclude-dir=.turbo
  --exclude-dir=data
  --exclude-dir=storage
  --exclude-dir=uploads
  --exclude-dir=media
  --exclude-dir=tmp
  --exclude-dir=temp
  --exclude-dir=var
  --exclude-dir=cache
  --exclude-dir=log
  --exclude-dir=logs
  --exclude-dir=build
  --exclude-dir=dist
  --exclude-dir=coverage
  --exclude="*.lock"
  --exclude="package-lock.json"
  --exclude="pnpm-lock.yaml"
  --exclude="yarn.lock"
  --exclude="*.cache"
  --exclude="*.min.js"
  --exclude="*.min.css"
  --exclude="*.map"
  --exclude="*.sql"
  --exclude="*.dump"
)

if [ "$#" -gt 0 ]; then
  matches="$(grep -rnI "${EXCLUDES[@]}" -F -- "$SYM" "$@" 2>/dev/null || true)"
else
  matches="$(grep -rnI "${EXCLUDES[@]}" -F -- "$SYM" . 2>/dev/null || true)"
fi

if [ -n "$matches" ]; then
  printf '%s\n' "$matches"
  exit 1
fi
exit 0
