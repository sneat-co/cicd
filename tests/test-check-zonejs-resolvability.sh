#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
checker="$repo_root/actions/check-zonejs-resolvability/check.mjs"
action="$repo_root/actions/check-zonejs-resolvability/action.yml"
workflow="$repo_root/.github/workflows/nx-ci.yml"
fixture="$(mktemp -d)"

cleanup() {
  rm -rf "$fixture"
}
trap cleanup EXIT

fail() {
  echo "check-zonejs-resolvability test failed: $*" >&2
  exit 1
}

mkdir -p "$fixture/bin" "$fixture/workspace"
cat > "$fixture/bin/pnpm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" != 'why -r zone.js --json' ]]; then
  echo "unexpected pnpm invocation: $*" >&2
  exit 97
fi

if [[ "${ZONEJS_PNPM_EXIT:-0}" != 0 ]]; then
  echo "${ZONEJS_PNPM_STDERR:-simulated pnpm failure}" >&2
  exit "${ZONEJS_PNPM_EXIT}"
fi

printf '%s' "${ZONEJS_PNPM_OUTPUT-}"
EOF
chmod +x "$fixture/bin/pnpm"

run_guard() {
  local output="$1"
  local exit_code="$2"
  local stderr="${3:-simulated pnpm failure}"
  env PATH="$fixture/bin:$PATH" \
    ZONEJS_PNPM_OUTPUT="$output" \
    ZONEJS_PNPM_EXIT="$exit_code" \
    ZONEJS_PNPM_STDERR="$stderr" \
    node "$checker" "$fixture/workspace"
}

expect_failure() {
  local expected="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    fail "expected failure containing $expected"
  fi
  if ! grep -Fq "$expected" <<<"$output"; then
    printf '%s\n' "$output" >&2
    fail "expected failure containing $expected"
  fi
}

# pnpm returns zero and an empty JSON array when no zone.js package is
# resolvable. That is the only clean result.
if clean_output="$(run_guard '[]' 0 2>&1)"; then
  if ! grep -Fq 'zone.js guard: clean' <<<"$clean_output"; then
    printf '%s\n' "$clean_output" >&2
    fail 'empty pnpm why array must produce the clean receipt'
  fi
else
  printf '%s\n' "$clean_output" >&2
  fail 'empty pnpm why array must pass'
fi

# pnpm also exits zero when it does find a package; the JSON array—not the
# process status—is the authoritative resolvability signal.
expect_failure 'ZONEJS_RESOLVABLE' run_guard '[{"name":"zone.js","version":"0.15.0"}]' 0

# A malformed stream or a valid-but-not-array JSON value is ambiguous evidence
# and must fail closed rather than being coerced by jq-like length semantics.
expect_failure 'PNPM_WHY_INVALID_JSON' run_guard '{not json' 0
expect_failure 'PNPM_WHY_EXPECTED_ARRAY' run_guard '{"name":"zone.js"}' 0

# A failed pnpm invocation cannot establish that the graph is clean.
expect_failure 'PNPM_WHY_COMMAND_FAILED' run_guard '' 73 'simulated pnpm failure sentinel'

# The default-on caller contract remains a post-install provider action, with
# a deliberate false opt-out and no duplicated inline shell implementation.
last_install_line="$(rg -n 'uses: sneat-co/cicd/actions/setup-pnpm-node@main' "$workflow" | tail -1 | cut -d: -f1)"
guard_line="$(rg -n 'uses: sneat-co/cicd/actions/check-zonejs-resolvability@main' "$workflow" | cut -d: -f1)"
zonejs_default="$(awk '
  /^      check-zonejs:/ { inside = 1; next }
  inside && /^      [[:alnum:]-]+:/ { exit }
  inside && /^        default:/ { print $2; exit }
' "$workflow")"
if [[ "$zonejs_default" != true ]] \
  || ! rg -Fq 'if: ${{ inputs.check-zonejs }}' "$workflow" \
  || ! rg -Fq 'uses: sneat-co/cicd/actions/check-zonejs-resolvability@main' "$workflow" \
  || ! rg -Fq 'directory: ${{ inputs.working-directory }}' "$workflow" \
  || rg -Fq 'pnpm why -r zone.js --json' "$workflow" \
  || ! rg -Fq 'node "$GITHUB_ACTION_PATH/check.mjs"' "$action" \
  || [[ -z "$last_install_line" || -z "$guard_line" ]] \
  || (( guard_line <= last_install_line )); then
  fail 'nx-ci must invoke the provider-owned default-on Zone.js action after install'
fi

echo 'check-zonejs-resolvability tests passed'
