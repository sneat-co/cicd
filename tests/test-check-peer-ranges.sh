#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
script="$repo_root/actions/check-peer-ranges/check.mjs"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

# A package we publish with every range shape the check must judge:
#   - bare caret / tilde on 0.0.x -> the trap, must be flagged
#   - explicit union, interval, exact pin -> all safe, must pass
#   - a bare 0.0.x range on a THIRD-PARTY package -> not ours to fix, must pass
mkdir -p "$fixture/libs/real-lib"
cat > "$fixture/libs/real-lib/package.json" <<'EOF'
{
  "name": "@sneat/real-lib",
  "peerDependencies": {
    "@sneat/random": "^0.0.4",
    "@sneat-team/example-tilde-trap": "~0.0.9",
    "@sneat/extension-example-contract": "^0.0.1 || ^0.0.2",
    "@sneat/example-safe-interval": ">=0.0.5 <0.1.0",
    "@sneat/example-exact-pin": "0.0.7",
    "some-third-party": "^0.0.1"
  }
}
EOF

# Simulate an Nx cache directory holding hundreds of stale copies of the same
# offending package.json -- these must never be scanned.
mkdir -p "$fixture/.nx/cache/seed"
cat > "$fixture/.nx/cache/seed/package.json" <<'EOF'
{ "name": "@sneat/cached-copy", "peerDependencies": { "@sneat/random": "^0.0.4" } }
EOF
for i in $(seq 1 50); do
  mkdir -p "$fixture/.nx/cache/run$i"
  cp "$fixture/.nx/cache/seed/package.json" "$fixture/.nx/cache/run$i/package.json"
done

# node_modules, dist, .wb, .claude and .worktrees must also be skipped.
mkdir -p "$fixture/node_modules/@sneat/random" "$fixture/dist/some-app" \
  "$fixture/.wb/worktree-stuff" "$fixture/.claude/agent-stuff" "$fixture/.worktrees/other-branch"
for dir in "node_modules/@sneat/random" "dist/some-app" ".wb/worktree-stuff" ".claude/agent-stuff" ".worktrees/other-branch"; do
  cat > "$fixture/$dir/package.json" <<'EOF'
{ "peerDependencies": { "@sneat/random": "^0.0.4" } }
EOF
done

set +e
output="$(node "$script" "$fixture" 2>&1)"
code=$?
set -e

if [[ "$code" -eq 0 ]]; then
  echo "expected check-peer-ranges to fail on the fixture, but it exited 0" >&2
  exit 1
fi

for expected in '@sneat/random' '@sneat-team/example-tilde-trap'; do
  if ! grep -qF "$expected" <<< "$output"; then
    echo "expected finding for $expected in output:" >&2
    echo "$output" >&2
    exit 1
  fi
done

for unexpected in 'extension-example-contract' 'example-safe-interval' 'example-exact-pin' 'some-third-party' 'cached-copy'; do
  if grep -qF "$unexpected" <<< "$output"; then
    echo "unexpected finding for $unexpected (false positive) in output:" >&2
    echo "$output" >&2
    exit 1
  fi
done

finding_count="$(grep -c '^::error file=' <<< "$output")"
if [[ "$finding_count" -ne 2 ]]; then
  echo "expected exactly 2 findings, got $finding_count:" >&2
  echo "$output" >&2
  exit 1
fi

# A clean tree (only safe shapes) must exit 0 and print nothing.
clean="$(mktemp -d)"
trap 'rm -rf "$fixture" "$clean"' EXIT
mkdir -p "$clean/libs/clean-lib"
cat > "$clean/libs/clean-lib/package.json" <<'EOF'
{
  "name": "@sneat/clean-lib",
  "peerDependencies": {
    "@sneat/extension-example-contract": "^0.0.1 || ^0.0.2",
    "@sneat/core": "^0.22.0"
  }
}
EOF
clean_output="$(node "$script" "$clean" 2>&1)"
clean_code=$?
if [[ "$clean_code" -ne 0 ]]; then
  echo "expected a clean tree to exit 0, got $clean_code" >&2
  exit 1
fi
if [[ -n "$clean_output" ]]; then
  echo "expected no output for a clean tree, got:" >&2
  echo "$clean_output" >&2
  exit 1
fi

echo "check-peer-ranges tests passed"
