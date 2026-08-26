#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
inventory="$repo_root/actions/check-npm-publish-identity/create-organization-inventory.mjs"
mock_api="$repo_root/tests/fixtures/npm-publish-identity/mock-github-api.mjs"
fixture="$(mktemp -d)"
token_sentinel='audit_token_redaction_9c1d7f'
mock_pid=""
mock_url=""

cleanup() {
  if [[ -n "$mock_pid" ]]; then
    kill "$mock_pid" 2>/dev/null || true
    wait "$mock_pid" 2>/dev/null || true
  fi
  rm -rf "$fixture"
}
trap cleanup EXIT

fail() {
  echo "npm publisher authority test failed: $*" >&2
  exit 1
}

start_mock() {
  local scopes="$1"
  local role="$2"
  local state="$3"
  local sso="$4"
  local port_file="$fixture/mock.port"
  rm -f "$port_file"
  env MOCK_GITHUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    MOCK_GITHUB_REPOSITORIES='["sneat-co/assetus"]' \
    MOCK_GITHUB_SCOPES="$scopes" \
    MOCK_GITHUB_MEMBERSHIP_ROLE="$role" \
    MOCK_GITHUB_MEMBERSHIP_STATE="$state" \
    MOCK_GITHUB_SSO="$sso" \
    node "$mock_api" "$port_file" &
  mock_pid=$!
  for _ in {1..50}; do
    if [[ -s "$port_file" ]]; then
      mock_url="$(cat "$port_file")"
      return
    fi
    sleep 0.1
  done
  fail 'mock GitHub API did not start'
}

stop_mock() {
  if [[ -n "$mock_pid" ]]; then
    kill "$mock_pid" 2>/dev/null || true
    wait "$mock_pid" 2>/dev/null || true
    mock_pid=""
  fi
}

expect_entitlement_failure() {
  local output
  if output="$(env SNEAT_ORGANIZATION_AUDIT_TOKEN="$token_sentinel" GITHUB_API_URL="$mock_url" \
    node "$inventory" --organization sneat-co --output "$fixture/inventory.json" 2>&1)"; then
    fail 'expected organization-audit token entitlement failure'
  fi
  if ! grep -Fq 'AUDIT_TOKEN_ENTITLEMENT_REQUIRED' <<<"$output"; then
    printf '%s\n' "$output" >&2
    fail 'missing deterministic entitlement failure'
  fi
  if grep -Fq "$token_sentinel" <<<"$output"; then
    printf '%s\n' "$output" >&2
    fail 'entitlement error leaked the organization audit token'
  fi
}

start_mock 'repo, workflow' admin active ''
allowed_output="$(env SNEAT_ORGANIZATION_AUDIT_TOKEN="$token_sentinel" GITHUB_API_URL="$mock_url" \
  node "$inventory" --organization sneat-co --archive-policy exclude --output "$fixture/allowed.json")"
if grep -Fq "$token_sentinel" <<<"$allowed_output" \
  || ! grep -Fq '"kind":"classic-user-token"' <<<"$allowed_output" \
  || ! grep -Fq '"repository_visibility":"all"' "$fixture/allowed.json"; then
  fail 'authoritative inventory receipt must prove entitlement without printing the token'
fi
stop_mock

start_mock 'read:org' admin active ''
expect_entitlement_failure
stop_mock

start_mock 'repo' member active ''
expect_entitlement_failure
stop_mock

start_mock 'repo' admin pending ''
expect_entitlement_failure
stop_mock

start_mock 'repo' admin active 'required; url=https://sso.example.test'
expect_entitlement_failure

echo 'npm publish authority tests passed'
