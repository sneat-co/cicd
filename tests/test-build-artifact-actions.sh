#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

mkdir -p "$fixture/workspace/dist/app" "$fixture/tmp"
printf 'hello\n' > "$fixture/workspace/dist/app/index.html"
printf 'console.log("ok")\n' > "$fixture/workspace/dist/app/main.js"
: > "$fixture/output"

GITHUB_WORKSPACE="$fixture/workspace" \
RUNNER_TEMP="$fixture/tmp" \
GITHUB_OUTPUT="$fixture/output" \
GITHUB_RUN_ID=123 \
GITHUB_RUN_ATTEMPT=1 \
GITHUB_REPOSITORY=sneat-co/fixture \
ARTIFACT_NAME=frontend-dist \
ARTIFACT_PATHS=dist/app \
ARTIFACT_SOURCE_SHA=0123456789abcdef0123456789abcdef01234567 \
  "$repo_root/actions/package-build-artifact/package.sh"

artifact_dir="$(sed -n 's/^directory=//p' "$fixture/output")"
test -f "$artifact_dir/payload.tar.gz"
test -f "$artifact_dir/manifest.json"

mkdir -p "$fixture/restored"
GITHUB_WORKSPACE="$fixture/restored" \
ARTIFACT_DIRECTORY="$artifact_dir" \
ARTIFACT_EXPECTED_NAME=frontend-dist \
ARTIFACT_EXPECTED_SOURCE_SHA=0123456789abcdef0123456789abcdef01234567 \
  "$repo_root/actions/restore-build-artifact/restore.sh"
cmp "$fixture/workspace/dist/app/index.html" "$fixture/restored/dist/app/index.html"
cmp "$fixture/workspace/dist/app/main.js" "$fixture/restored/dist/app/main.js"

printf 'SF:one.ts\nLF:4\nLH:3\nend_of_record\n' > "$fixture/lcov.info"
COVERAGE_PATH="$fixture/lcov.info" COVERAGE_MINIMUM_PERCENT=75 \
  "$repo_root/actions/check-lcov-coverage/check.sh"
if COVERAGE_PATH="$fixture/lcov.info" COVERAGE_MINIMUM_PERCENT=76 \
  "$repo_root/actions/check-lcov-coverage/check.sh"; then
  echo "coverage check unexpectedly accepted a threshold above actual coverage" >&2
  exit 1
fi

node "$repo_root/actions/playwright-artifact-e2e/spa-server.mjs" \
  "$fixture/workspace/dist/app" 43821 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; rm -rf "$fixture"' EXIT
for _ in {1..20}; do
  if curl --fail --silent http://127.0.0.1:43821/route > "$fixture/served"; then
    break
  fi
  sleep 0.1
done
cmp "$fixture/workspace/dist/app/index.html" "$fixture/served"
kill "$server_pid"
wait "$server_pid" 2>/dev/null || true
trap 'rm -rf "$fixture"' EXIT

echo "build artifact and coverage action tests passed"
