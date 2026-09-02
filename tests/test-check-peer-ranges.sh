#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
script="$repo_root/actions/check-peer-ranges/check.mjs"
fixture="$(mktemp -d)"
clean="$(mktemp -d)"
deps_only="$(mktemp -d)"
trap 'rm -rf "$fixture" "$clean" "$deps_only"' EXIT

# A package we publish with every range/pin shape the check must judge:
#   - bare caret / tilde on 0.0.x                  -> the range trap, must be flagged   [test: bare-0.0.x-caret-tilde-rejected]
#   - exact pin outside 0.0.x (e.g. "0.14.0")       -> the pin trap, must be flagged     [test: exact-non-0.0.x-pin-rejected]
#   - explicit union, interval                       -> always safe, must pass
#   - exact pin ON 0.0.x (e.g. "0.0.7")             -> safe (== ^0.0.x under semver)    [test: exact-0.0.x-pin-allowed]
#   - caret / tilde on a non-0.0.x version           -> safe, an upgradeable range        [test: caret-tilde-non-0.0.x-allowed]
#   - a bare 0.0.x range / exact pin on a THIRD-PARTY package -> not ours to fix, must pass
mkdir -p "$fixture/libs/real-lib"
cat > "$fixture/libs/real-lib/package.json" <<'EOF'
{
  "name": "@sneat/real-lib",
  "peerDependencies": {
    "@sneat/random": "^0.0.4",
    "@sneat-team/example-tilde-trap": "~0.0.9",
    "@sneat/extension-contactus-ui": "0.14.0",
    "@sneat-team/example-exact-major": "2.0.0",
    "@sneat/extension-example-contract": "^0.0.1 || ^0.0.2",
    "@sneat/example-safe-interval": ">=0.0.5 <0.1.0",
    "@sneat/example-exact-pin": "0.0.7",
    "@sneat/example-caret-minor": "^1.4.2",
    "@sneat/example-tilde-minor": "~3.2.1",
    "some-third-party": "^0.0.1",
    "some-other-vendor": "1.2.3"
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

# [test: bad-fixture-exits-nonzero]
if [[ "$code" -eq 0 ]]; then
  echo "expected check-peer-ranges to fail on the fixture, but it exited 0" >&2
  exit 1
fi

# [test: bare-0.0.x-caret-tilde-rejected] + [test: exact-non-0.0.x-pin-rejected]
for expected in '@sneat/random' '@sneat-team/example-tilde-trap' '@sneat/extension-contactus-ui' '@sneat-team/example-exact-major'; do
  if ! grep -qF "$expected" <<< "$output"; then
    echo "expected finding for $expected in output:" >&2
    echo "$output" >&2
    exit 1
  fi
done

# [test: exact-0.0.x-pin-allowed] + [test: caret-tilde-non-0.0.x-allowed] + safe unions/intervals/third-party
for unexpected in 'extension-example-contract' 'example-safe-interval' 'example-exact-pin' \
  'example-caret-minor' 'example-tilde-minor' 'some-third-party' 'some-other-vendor' 'cached-copy'; do
  if grep -qF "$unexpected" <<< "$output"; then
    echo "unexpected finding for $unexpected (false positive) in output:" >&2
    echo "$output" >&2
    exit 1
  fi
done

# [test: finding-count-exactly-four]
finding_count="$(grep -c '^::error file=' <<< "$output")"
if [[ "$finding_count" -ne 4 ]]; then
  echo "expected exactly 4 findings, got $finding_count:" >&2
  echo "$output" >&2
  exit 1
fi

# A clean tree (only safe shapes) must exit 0 and print nothing.
# [test: clean-tree-exits-zero-silent]
mkdir -p "$clean/libs/clean-lib"
cat > "$clean/libs/clean-lib/package.json" <<'EOF'
{
  "name": "@sneat/clean-lib",
  "peerDependencies": {
    "@sneat/extension-example-contract": "^0.0.1 || ^0.0.2",
    "@sneat/core": "^0.22.0",
    "@sneat/pinned-pre-release": "0.0.3"
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

# Decision (documented in check.mjs): only `peerDependencies` is scanned, not
# `dependencies`. An exact non-0.0.x @sneat/* pin in `dependencies` is a
# normal transitive dependency, not a peer-dependency identity contract, so
# it does not force every consumer onto one installed copy the way a peer
# pin does -- it is out of scope for this check.
# [test: dependencies-field-not-scanned]
mkdir -p "$deps_only/libs/deps-only-lib"
cat > "$deps_only/libs/deps-only-lib/package.json" <<'EOF'
{
  "name": "@sneat/deps-only-lib",
  "dependencies": {
    "@sneat/example-dep-exact": "1.2.3"
  }
}
EOF
deps_output="$(node "$script" "$deps_only" 2>&1)"
deps_code=$?
if [[ "$deps_code" -ne 0 ]]; then
  echo "expected dependencies-only tree to exit 0 (dependencies field is out of scope), got $deps_code:" >&2
  echo "$deps_output" >&2
  exit 1
fi
if [[ -n "$deps_output" ]]; then
  echo "expected no output for a dependencies-only tree, got:" >&2
  echo "$deps_output" >&2
  exit 1
fi

echo "check-peer-ranges tests passed"
