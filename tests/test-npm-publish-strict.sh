#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
strict_workflow="$repo_root/.github/workflows/npm-publish-strict.yml"
legacy_workflow="$repo_root/.github/workflows/npm-publish.yml"
auditor="$repo_root/actions/check-npm-publish-identity/audit.mjs"
checker="$repo_root/actions/check-npm-publish-identity/check.mjs"
packer="$repo_root/actions/check-npm-publish-identity/pack-package.mjs"
fixture="$(mktemp -d)"
cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT

fail() {
  echo "strict npm publisher test failed: $*" >&2
  exit 1
}

expect_failure() {
  local expected="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    fail "expected failure containing $expected, but command passed: $*"
  fi
  if ! grep -Fq -- "$expected" <<<"$output"; then
    printf '%s\n' "$output" >&2
    fail "expected failure containing $expected"
  fi
}

write_package() {
  local path="$1"
  local name="$2"
  local extra="${3:-}"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
{
  "name": "$name",
  "version": "1.2.3",
  "repository": "https://github.com/sneat-co/assetus"$extra
}
EOF
}

write_workflow() {
  local root="$1"
  local name="$2"
  local body="$3"
  mkdir -p "$root/.github/workflows"
  printf '%s\n' "$body" > "$root/.github/workflows/$name.yml"
}

make_repository() {
  local root="$1"
  git -C "$root" init -q
  git -C "$root" remote add origin https://github.com/sneat-co/assetus.git
}

# A strict provider workflow must exist independently of the legacy reusable
# workflow, declare one package directory/name, and never accept caller shell
# under npm credentials.
[[ -f "$strict_workflow" ]] || fail "missing strict provider workflow"
if rg -q 'publish-command|NPM_TOKEN:.*inputs\.|NODE_AUTH_TOKEN:.*inputs\.' "$strict_workflow"; then
  fail "strict provider must not accept caller-controlled publish commands or token values"
fi
for required in 'package-directory:' 'package-name:' 'npm publish' '--ignore-scripts' 'uses: $/actions/check-npm-publish-identity'; do
  rg -Fq -- "$required" "$strict_workflow" || fail "strict provider lacks $required"
done
if ! rg -q 'publish-command' "$legacy_workflow"; then
  fail "legacy contract unexpectedly disappeared before consumer cutover"
fi

# The post-build pack verifier binds the package manifest and resulting tarball
# before the workflow can publish it.
[[ -f "$packer" ]] || fail "missing provider-owned pack verifier"
rg -Fq 'npm pack' "$packer" || fail "provider-owned pack verifier does not invoke npm pack"
artifact_root="$fixture/artifact"
mkdir -p "$artifact_root/package"
write_package "$artifact_root/package/package.json" '@sneat/extension-assetus'
node "$packer" --repository sneat-co/assetus --directory "$artifact_root/package" \
  --package '@sneat/extension-assetus' --artifact-directory "$artifact_root/out"
[[ -f "$artifact_root/out/sneat-extension-assetus-1.2.3.tgz" ]] || fail "provider pack verifier did not create the expected artifact"

# The audit must structurally resolve aliases, bracketed secrets, workspace
# publishing syntax, local scripts/actions, and local reusable workflow calls.
adversarial="$fixture/adversarial"
mkdir -p "$adversarial/frontend" "$adversarial/scripts" "$adversarial/.github/actions/publish"
write_package "$adversarial/frontend/package.json" '@sneat/extension-assetus'
make_repository "$adversarial"
printf '%s\n' 'npm --workspace contract publish' > "$adversarial/scripts/release.sh"
chmod +x "$adversarial/scripts/release.sh"
cat > "$adversarial/.github/actions/publish/action.yml" <<'EOF'
name: publish
runs:
  using: composite
  steps:
    - run: npm publish
      env:
        NPM_TOKEN: ${{ secrets['NPM_TOKEN'] }}
EOF
write_workflow "$adversarial" release $'on: workflow_call\njobs:\n  nested:\n    runs-on: ubuntu-latest\n    defaults:\n      run:\n        working-directory: frontend\n    steps:\n      - run: ./scripts/release.sh\n      - uses: ./.github/actions/publish'
write_workflow "$adversarial" publish $'shared-secrets: &publisher_secrets\n  NPM_TOKEN: ${{ secrets[\'NPM_TOKEN\'] }}\non: &automatic [push]\njobs:\n  shared:\n    uses: sneat-co/cicd/.github/workflows/npm-publish-strict.yml@main\n    with:\n      package-directory: frontend\n      package-name: "@sneat/extension-assetus"\n  bypass:\n    uses: ./.github/workflows/release.yml\n    secrets: *publisher_secrets'
expect_failure 'DUPLICATE_ARMED_PUBLISHER' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$adversarial" --require-no-direct-publisher

# Unknown YAML is evidence of an unverified publisher, never a silent unarmed
# result. The secret sentinel must be redacted from every receipt/error.
malformed="$fixture/malformed"
mkdir -p "$malformed"
write_package "$malformed/package.json" '@sneat/extension-assetus' ',\n  "repository": "raw-secret-sentinel"'
redaction_output="$(node "$checker" --repository sneat-co/assetus --directory "$malformed" 2>&1 || true)"
if grep -Fq 'raw-secret-sentinel' <<<"$redaction_output"; then
  fail "identity output leaked a raw manifest value"
fi
write_workflow "$adversarial" malformed $'on: [push]\njobs:\n  bad: [unterminated'
expect_failure 'UNPARSEABLE_WORKFLOW' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$adversarial" --require-no-direct-publisher

# Authoritative audits never fall back to an ambient repository token. Detailed
# classic-token entitlement cases are exercised by test-npm-publish-authority.sh.
expect_failure 'SNEAT_ORGANIZATION_AUDIT_TOKEN' \
  env -u SNEAT_ORGANIZATION_AUDIT_TOKEN \
  node "$auditor" --organization-root "$adversarial" --github-api --require-authoritative

echo "strict npm publisher tests passed"
