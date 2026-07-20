#!/usr/bin/env bash
set -euo pipefail

workspace="${GITHUB_WORKSPACE:-$PWD}"
working_dir="${E2E_WORKING_DIRECTORY:-frontend}"
cases="${E2E_CASES:?E2E_CASES is required}"
project="${E2E_PROJECT:-chromium}"
action_path="${E2E_ACTION_PATH:?E2E_ACTION_PATH is required}"
root="$workspace/$working_dir"
port=4200
failures=0

while IFS= read -r test_case || [[ -n "$test_case" ]]; do
  test_case="${test_case%$'\r'}"
  [[ -z "$test_case" ]] && continue
  if [[ "$test_case" != *"|"* ]]; then
    echo "invalid E2E case (expected e2e-directory|static-directory): $test_case" >&2
    exit 1
  fi
  e2e_dir="${test_case%%|*}"
  static_dir="${test_case#*|}"
  for path in "$e2e_dir" "$static_dir"; do
    if [[ "$path" == /* || "$path" =~ (^|/)\.\.(/|$) ]]; then
      echo "E2E paths must stay inside the working directory: $path" >&2
      exit 1
    fi
  done
  config_path=""
  for candidate in playwright.config.ts playwright.config.mts playwright.config.mjs playwright.config.js; do
    if [[ -f "$root/$e2e_dir/$candidate" ]]; then
      config_path="$e2e_dir/$candidate"
      break
    fi
  done
  if [[ -z "$config_path" ]]; then
    echo "Playwright config not found under: $e2e_dir" >&2
    exit 1
  fi
  test -f "$root/$static_dir/index.html"

  node "$action_path/spa-server.mjs" "$root/$static_dir" "$port" &
  server_pid=$!
  cleanup_server() {
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  }
  trap cleanup_server EXIT
  for _ in {1..30}; do
    if curl --fail --silent "http://127.0.0.1:${port}/" >/dev/null; then
      break
    fi
    sleep 1
  done
  curl --fail --silent "http://127.0.0.1:${port}/" >/dev/null

  echo "Running $e2e_dir against validated output $static_dir on port $port"
  if ! (
    cd "$root"
    BASE_URL="http://127.0.0.1:${port}" E2E_SKIP_WEBSERVER=1 \
      pnpm exec playwright test \
        --config="$config_path" \
        --project="$project"
  ); then
    failures=$((failures + 1))
  fi

  cleanup_server
  trap - EXIT
  port=$((port + 1))
done <<< "$cases"

if [[ "$failures" -ne 0 ]]; then
  echo "$failures Playwright suite(s) failed" >&2
  exit 1
fi
