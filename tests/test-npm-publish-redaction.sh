#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
checker="$repo_root/actions/check-npm-publish-identity/check.mjs"
auditor="$repo_root/actions/check-npm-publish-identity/audit.mjs"
packer="$repo_root/actions/check-npm-publish-identity/pack-package.mjs"
fixture="$(mktemp -d)"
secret_sentinel='npm_redaction_secret_7e9a3d5c'

cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT

expect_redacted_failure() {
  local expected="$1"
  shift
  local output
  if output="$(NPM_TOKEN="$secret_sentinel" "$@" 2>&1)"; then
    echo "expected failure containing $expected, but command passed: $*" >&2
    exit 1
  fi
  if ! grep -Fq -- "$expected" <<<"$output"; then
    printf '%s\n' "$output" >&2
    echo "expected failure containing $expected" >&2
    exit 1
  fi
  if grep -Fq -- "$secret_sentinel" <<<"$output"; then
    printf '%s\n' "$output" >&2
    echo 'publisher identity output leaked a secret-bearing value' >&2
    exit 1
  fi
}

manifest_root="$fixture/$secret_sentinel-manifest"
mkdir -p "$manifest_root"
cat > "$manifest_root/package.json" <<EOF
{
  "name": "@sneat/extension-assetus",
  "version": "1.2.3",
  "repository": "https://github.com/sneat-co/$secret_sentinel"
}
EOF

expect_redacted_failure 'PACKAGE_REPOSITORY_MISMATCH' \
  node "$checker" --repository sneat-co/assetus --directory "$manifest_root"

expect_redacted_failure 'PACKAGE_REPOSITORY_MISMATCH' \
  node "$packer" --repository sneat-co/assetus --directory "$manifest_root" \
    --package @sneat/extension-assetus --artifact-directory "$fixture/$secret_sentinel-artifacts"

# A provider-policy prefix can legitimately contain a package suffix. Even if a
# malicious suffix resembles a token, the packer must redact it in its receipt
# rather than printing a raw package/artifact value.
packed_root="$fixture/packed-$secret_sentinel"
mkdir -p "$packed_root"
cat > "$packed_root/package.json" <<EOF
{
  "name": "@sneat/extension-splitus-$secret_sentinel",
  "version": "1.2.3",
  "repository": "https://github.com/sneat-co/debtus"
}
EOF
packed_output="$(NPM_TOKEN="$secret_sentinel" npm_config_cache="$fixture/npm-cache" node "$packer" \
  --repository sneat-co/debtus --directory "$packed_root" \
  --package "@sneat/extension-splitus-$secret_sentinel" \
  --artifact-directory "$fixture/packed-artifacts" 2>&1)"
if grep -Fq -- "$secret_sentinel" <<<"$packed_output"; then
  printf '%s\n' "$packed_output" >&2
  echo 'provider pack receipt leaked a token-shaped package or artifact value' >&2
  exit 1
fi

audit_root="$fixture/audit"
mkdir -p "$audit_root/.github/workflows" "$audit_root/frontend"
cp "$manifest_root/package.json" "$audit_root/frontend/package.json"
cat > "$audit_root/.github/workflows/publish.yml" <<'EOF'
on: [push]
jobs:
  publish:
    uses: sneat-co/cicd/.github/workflows/npm-publish.yml@main
    with:
      working-directory: frontend
EOF
expect_redacted_failure 'PACKAGE_REPOSITORY_MISMATCH' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$audit_root" --require-unique-owners

claim_root="$fixture/claim"
mkdir -p "$claim_root/.github/workflows" "$claim_root/frontend"
cat > "$claim_root/frontend/package.json" <<EOF
{"name":"@sneat/extension-$secret_sentinel","version":"1.2.3"}
EOF
cat > "$claim_root/.github/workflows/publish.yml" <<'EOF'
on: [push]
jobs:
  publish:
    uses: sneat-co/cicd/.github/workflows/npm-publish.yml@main
    with:
      working-directory: frontend
EOF
expect_redacted_failure 'UNKNOWN_PACKAGE_IDENTITY' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$claim_root" --require-unique-owners

inventory="$fixture/inventory.json"
printf '{"schema":"npm-publish-organization-inventory/v1","organization":"sneat-co","organization":"%s"}' \
  "$secret_sentinel" > "$inventory"
expect_redacted_failure 'cannot read a valid --inventory' \
  node "$auditor" --organization-root "$fixture" --inventory "$inventory"

echo 'npm publish identity redaction tests passed'
