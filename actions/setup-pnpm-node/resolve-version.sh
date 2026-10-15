#!/usr/bin/env bash
# Prints the pnpm version to install: the `packageManager` pnpm version from
# ./package.json, else <working-directory>/package.json, else the default.
# Usage: resolve-version.sh <default-version> [working-directory]
set -euo pipefail
version="$1"
wd="${2:-.}"
for f in package.json "$wd/package.json"; do
  [[ -f "$f" ]] || continue
  declared="$(node -p "const p=require(require('path').resolve(process.argv[1])).packageManager || ''; p.startsWith('pnpm@') ? p.slice(5).split('+')[0] : ''" "$f")"
  if [[ -n "$declared" ]]; then
    printf '%s\n' "$declared"
    exit 0
  fi
done
printf '%s\n' "$version"
