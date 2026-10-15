#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
script="$repo_root/actions/setup-pnpm-node/resolve-version.sh"
fx="$(mktemp -d)"; trap 'rm -rf "$fx"' EXIT
fail=0
check() { # name expected actual
  if [[ "$2" == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want $2 got $3"; fail=1; fi
}
mkdir -p "$fx/a/frontend" "$fx/b/frontend" "$fx/c/frontend"
echo '{"packageManager":"pnpm@10.1.0+sha512.abc"}' > "$fx/a/package.json"
echo '{"packageManager":"pnpm@9.0.0"}' > "$fx/a/frontend/package.json"
echo '{"packageManager":"pnpm@9.2.0"}' > "$fx/b/frontend/package.json"
echo '{"name":"x"}' > "$fx/c/frontend/package.json"
check "root wins" 10.1.0 "$(cd "$fx/a" && "$script" 11.20.0 frontend)"
check "subdir pin, no root package.json" 9.2.0 "$(cd "$fx/b" && "$script" 11.20.0 frontend)"
check "default when none declared" 11.20.0 "$(cd "$fx/c" && "$script" 11.20.0 frontend)"
check "non-pnpm packageManager ignored" 11.20.0 "$(echo '{"packageManager":"yarn@4.0.0"}' > "$fx/c/frontend/package.json"; cd "$fx/c" && "$script" 11.20.0 frontend)"
exit $fail
