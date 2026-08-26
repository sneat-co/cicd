#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
checker="$repo_root/actions/check-npm-publish-identity/check.mjs"
auditor="$repo_root/actions/check-npm-publish-identity/audit.mjs"
inventory_checkout="$repo_root/actions/check-npm-publish-identity/checkout-organization-inventory.mjs"
directory_resolver="$repo_root/actions/check-npm-publish-identity/resolve-publish-directory.mjs"
mock_api="$repo_root/tests/fixtures/npm-publish-identity/mock-github-api.mjs"
fixture="$(mktemp -d)"
mock_api_pid=""
mock_api_url=""
cleanup() {
  if [[ -n "$mock_api_pid" ]]; then
    kill "$mock_api_pid" 2>/dev/null || true
    wait "$mock_api_pid" 2>/dev/null || true
  fi
  rm -rf "$fixture"
}
trap cleanup EXIT

write_package() {
  local path="$1"
  local name="$2"
  local private="${3:-false}"
  local template_dependency="${4:-false}"
  local repository="${5:-}"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<EOF
{
  "name": "$name",
  "version": "0.1.0",
  "private": $private,
  "publishConfig": {"access": "public"}$([ "$template_dependency" = true ] && printf ',\n  "dependencies": {"@sneat/extension-template-contract": "^0.1.0"}')$([ -n "$repository" ] && printf ',\n  "repository": "%s"' "$repository")
}
EOF
}

write_workflow() {
  local root="$1"
  local body="$2"
  mkdir -p "$root/.github/workflows"
  printf '%s\n' "$body" > "$root/.github/workflows/publish.yml"
}

make_canonical_repository() {
  local root="$1"
  local repository="$2"
  git -C "$root" init -q
  git -C "$root" remote add origin "https://github.com/$repository.git"
}

expect_failure() {
  local expected="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    echo "expected failure containing $expected, but command passed: $*" >&2
    exit 1
  fi
  if ! grep -Fq -- "$expected" <<<"$output"; then
    echo "expected failure containing $expected, got:" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

start_mock_api() {
  local repositories="$1"
  local port_file="$fixture/mock-github-api.port"
  rm -f "$port_file"
  env MOCK_GITHUB_REPOSITORIES="$repositories" MOCK_GITHUB_SHA="$authority_remote_sha" node "$mock_api" "$port_file" &
  mock_api_pid=$!
  for _ in {1..50}; do
    if [[ -s "$port_file" ]]; then
      mock_api_url="$(cat "$port_file")"
      return
    fi
    sleep 0.1
  done
  echo 'mock GitHub API did not start' >&2
  exit 1
}

stop_mock_api() {
  if [[ -n "$mock_api_pid" ]]; then
    kill "$mock_api_pid" 2>/dev/null || true
    wait "$mock_api_pid" 2>/dev/null || true
    mock_api_pid=""
  fi
}

canonical="$fixture/canonical"
mkdir -p "$canonical/frontend/libs/extensions/assetus/runtime"
write_package "$canonical/frontend/package.json" '@sneat/assetus-frontend' true
write_package "$canonical/frontend/libs/extensions/assetus/runtime/package.json" '@sneat/extension-assetus'
write_package "$canonical/unrelated/package.json" '@sneat/not-assetus'
write_workflow "$canonical" $'on:\n  push:\n    branches: [main]\njobs:\n  publish:\n    uses: sneat-co/cicd/.github/workflows/npm-publish.yml@main\n    with:\n      working-directory: frontend\n  unrelated:\n    runs-on: ubuntu-latest\n    defaults:\n      run:\n        working-directory: unrelated\n    steps:\n      - run: echo unrelated'
node "$checker" --repository sneat-co/assetus --directory "$canonical/frontend"
node "$auditor" --repository sneat-co/assetus --repository-root "$canonical" --require-no-direct-publisher

default_directory="$fixture/default-directory"
write_package "$default_directory/frontend/libs/extensions/assetus/runtime/package.json" '@sneat/extension-assetus'
write_package "$default_directory/unrelated/package.json" '@sneat/not-assetus'
write_workflow "$default_directory" $'on:\n  push:\n    branches: [main]\njobs:\n  publish:\n    uses: sneat-co/cicd/.github/workflows/npm-publish.yml@main'
node "$auditor" --repository sneat-co/assetus --repository-root "$default_directory" --require-no-direct-publisher

wrong_repo="$fixture/wrong-repo"
write_package "$wrong_repo/frontend/libs/extensions/other/contract/package.json" '@sneat/extension-other-contract'
expect_failure 'UNKNOWN_PACKAGE_IDENTITY' \
  node "$checker" --repository sneat-co/ext-right --directory "$wrong_repo/frontend"
expect_failure 'INVALID_REPOSITORY' \
  node "$checker" --repository sneat-co/ext-right/extra --directory "$wrong_repo/frontend"
expect_failure 'ARGUMENT_ERROR --repository is required' \
  node "$auditor" --repository sneat-co/ext-right/extra --repository-root "$wrong_repo"

matching_metadata="$fixture/matching-metadata"
write_package "$matching_metadata/package.json" '@sneat/arbitrary-package' false false 'https://github.com/sneat-co/unrelated'
expect_failure 'UNKNOWN_PACKAGE_IDENTITY' \
  node "$checker" --repository sneat-co/unrelated --directory "$matching_metadata"

malformed_metadata="$fixture/malformed-metadata"
write_package "$malformed_metadata/package.json" '@sneat/extension-assetus' false false 'https://github.com/sneat-co/assetus/issues'
expect_failure 'INVALID_PACKAGE_REPOSITORY' \
  node "$checker" --repository sneat-co/assetus --directory "$malformed_metadata"

unscoped="$fixture/unscoped"
write_package "$unscoped/package.json" 'extension-circleus-contract'
expect_failure 'UNSCOPED_PUBLIC_PACKAGE' \
  node "$checker" --repository sneat-co/ext-circleus --directory "$unscoped"

no_identity="$fixture/no-identity"
write_package "$no_identity/package.json" '@sneat/assetus-frontend' true
expect_failure 'NO_PUBLISHABLE_PACKAGE_IDENTITY' \
  node "$checker" --repository sneat-co/assetus --directory "$no_identity"

workspace="$fixture/workspace"
mkdir -p "$workspace"
write_package "$workspace/package.json" '@sneat/assetus-frontend' true
expect_failure 'PUBLISH_DIRECTORY_OUTSIDE_WORKSPACE' \
  node "$directory_resolver" --workspace "$workspace" --directory ../outside
mkdir -p "$fixture/outside"
ln -s "$fixture/outside" "$workspace/outside-link"
expect_failure 'PUBLISH_DIRECTORY_OUTSIDE_WORKSPACE' \
  node "$directory_resolver" --workspace "$workspace" --directory outside-link

copied_template="$fixture/copied-template"
write_package "$copied_template/frontend/package.json" '@sneat/ext-contract-template-frontend' true true
write_package "$copied_template/frontend/libs/extensions/template/contract/package.json" '@sneat/extension-template-contract'
expect_failure 'TEMPLATE_PACKAGE_REQUIRES_CANONICAL_REPOSITORY' \
  node "$checker" --repository sneat-co/ext-circleus --directory "$copied_template/frontend"
expect_failure 'UNREBRANDED_TEMPLATE_DEPENDENCY' \
  node "$checker" --repository sneat-co/ext-circleus --directory "$copied_template/frontend"

incomplete="$fixture/incomplete-rebrand"
write_package "$incomplete/frontend/libs/extensions/circleus/contract/package.json" '@sneat/extension-circleus-contract'
mkdir -p "$incomplete/frontend/libs/extensions/circleus/contract"
cat > "$incomplete/frontend/libs/extensions/circleus/contract/project.json" <<'EOF'
{"name":"ext-template-contract"}
EOF
expect_failure 'UNREBRANDED_TEMPLATE_PROJECT' \
  node "$checker" --repository sneat-co/ext-circleus --directory "$incomplete/frontend"

template="$fixture/template"
write_package "$template/frontend/package.json" '@sneat/ext-contract-template-frontend' true
write_package "$template/frontend/libs/extensions/template/contract/package.json" '@sneat/extension-template-contract'
node "$checker" --repository sneat-co/sneat-ext-contract-template --directory "$template/frontend"

debtus="$fixture/debtus"
write_package "$debtus/frontend/libs/extensions/debtus/runtime/package.json" '@sneat/extension-debtus'
write_package "$debtus/frontend/libs/extensions/splitus/runtime/package.json" '@sneat/extension-splitus'
node "$checker" --repository sneat-co/debtus --directory "$debtus/frontend"

sneat_libs="$fixture/sneat-libs"
write_package "$sneat_libs/libs/core/package.json" '@sneat/core'
node "$checker" --repository sneat-co/sneat-libs --directory "$sneat_libs"

for identity in \
  'sneat-co/ext-kids-club:@sneat/extension-kidsclub-contract' \
  'sneat-co/ext-rsvp-express:@sneat/extension-rsvpexpress-contract' \
  'sneat-co/ext-sneat-team:@sneat/extension-team-contract'; do
  repository="${identity%%:*}"
  package_name="${identity#*:}"
  mapped="$fixture/${repository##*/}"
  write_package "$mapped/frontend/package.json" "$package_name"
  node "$checker" --repository "$repository" --directory "$mapped/frontend"
done

duplicate="$fixture/duplicate"
write_package "$duplicate/frontend/libs/extensions/assetus/runtime/package.json" '@sneat/extension-assetus'
write_workflow "$duplicate" $'on:\n  push:\n    branches: [main]\njobs:\n  shared:\n    uses: sneat-co/cicd/.github/workflows/npm-publish.yml@main\n  bypass:\n    runs-on: ubuntu-latest\n    steps:\n      - run: pnpm publish\n        env:\n          NPM_TOKEN: ${{ secrets.NPM_TOKEN }}'
expect_failure 'DUPLICATE_ARMED_PUBLISHER' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$duplicate" --require-no-direct-publisher

quoted_trigger="$fixture/quoted-trigger"
write_package "$quoted_trigger/frontend/libs/extensions/assetus/runtime/package.json" '@sneat/extension-assetus'
write_workflow "$quoted_trigger" $'"on": [push]\njobs:\n  shared:\n    uses: sneat-co/cicd/.github/workflows/npm-publish.yml@main\n    with:\n      working-directory: frontend\n  bypass:\n    runs-on: ubuntu-latest\n    steps:\n      - run: pnpm publish\n        env:\n          NPM_TOKEN: ${{ secrets.NPM_TOKEN }}'
expect_failure 'DUPLICATE_ARMED_PUBLISHER' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$quoted_trigger" --require-no-direct-publisher

four_space_jobs="$fixture/four-space-jobs"
write_package "$four_space_jobs/frontend/libs/extensions/assetus/runtime/package.json" '@sneat/extension-assetus'
write_workflow "$four_space_jobs" $'on: [push]\njobs:\n    shared:\n        uses: sneat-co/cicd/.github/workflows/npm-publish.yml@main\n        with:\n            working-directory: frontend\n    bypass:\n        runs-on: ubuntu-latest\n        steps:\n            - run: pnpm publish\n              env:\n                  NPM_TOKEN: ${{ secrets.NPM_TOKEN }}'
expect_failure 'DUPLICATE_ARMED_PUBLISHER' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$four_space_jobs" --require-no-direct-publisher

scoped_direct="$fixture/scoped-direct"
write_package "$scoped_direct/frontend/libs/extensions/assetus/runtime/package.json" '@sneat/extension-assetus'
write_package "$scoped_direct/unrelated/package.json" '@sneat/not-assetus'
write_workflow "$scoped_direct" $'on: [push]\njobs:\n  shared:\n    uses: sneat-co/cicd/.github/workflows/npm-publish.yml@main\n    with:\n      working-directory: frontend\n  bypass:\n    runs-on: ubuntu-latest\n    defaults:\n      run:\n        working-directory: frontend\n    steps:\n      - run: pnpm publish\n        env:\n          NPM_TOKEN: ${{ secrets.NPM_TOKEN }}\n  unrelated:\n    runs-on: ubuntu-latest\n    defaults:\n      run:\n        working-directory: unrelated\n    steps:\n      - run: echo unrelated'
scoped_direct_output="$(node "$auditor" --repository sneat-co/assetus --repository-root "$scoped_direct")"
if grep -Fq 'UNKNOWN_PACKAGE_IDENTITY' <<<"$scoped_direct_output" || ! grep -Fq '"working_directories":["frontend"]' <<<"$scoped_direct_output"; then
  echo 'direct publisher audit must use the publishing job directory, not unrelated jobs' >&2
  exit 1
fi
expect_failure 'DUPLICATE_ARMED_PUBLISHER' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$scoped_direct" --require-no-direct-publisher

unarmed="$fixture/unarmed-template-scaffold"
write_package "$unarmed/frontend/libs/extensions/template/contract/package.json" '@sneat/extension-template-contract'
write_workflow "$unarmed" $'on:\n  workflow_dispatch:\njobs:\n  publish:\n    uses: sneat-co/cicd/.github/workflows/npm-publish.yml@main\n    with:\n      working-directory: frontend\n  release:\n    runs-on: ubuntu-latest\n    steps:\n      - run: pnpm publish\n        env:\n          NPM_TOKEN: ${{ secrets.NPM_TOKEN }}'
node "$auditor" --repository sneat-co/ext-circleus --repository-root "$unarmed" --require-no-direct-publisher
expect_failure 'TEMPLATE_PACKAGE_REQUIRES_CANONICAL_REPOSITORY' \
  node "$auditor" --repository sneat-co/ext-circleus --repository-root "$unarmed" --require-publish-identities
expect_failure 'NON_AUTHORITATIVE_LOCAL_REF' \
  node "$auditor" --repository sneat-co/ext-circleus --repository-root "$unarmed" --require-authoritative

org="$fixture/org"
mkdir -p "$org/sneat-ext-contract-template" "$org/ext-circleus"
write_package "$org/sneat-ext-contract-template/frontend/libs/extensions/template/contract/package.json" '@sneat/extension-template-contract'
write_workflow "$org/sneat-ext-contract-template" $'on:\n  push:\n    branches: [main]\njobs:\n  publish:\n    uses: sneat-co/cicd/.github/workflows/npm-publish.yml@main\n    with:\n      working-directory: frontend'
write_package "$org/ext-circleus/frontend/libs/extensions/template/contract/package.json" '@sneat/extension-template-contract'
write_workflow "$org/ext-circleus" $'on:\n  push:\n    branches: [main]\njobs:\n  publish:\n    uses: sneat-co/cicd/.github/workflows/npm-publish.yml@main\n    with:\n      working-directory: frontend'
make_canonical_repository "$org/sneat-ext-contract-template" sneat-co/sneat-ext-contract-template
make_canonical_repository "$org/ext-circleus" sneat-co/ext-circleus
expect_failure 'DUPLICATE_PACKAGE_OWNER' \
  node "$auditor" --organization-root "$org" --require-unique-owners

authority_origin="$fixture/authority-origin.git"
authority_seed="$fixture/authority-seed"
authority_root="$fixture/authority-root"
authority_inventory="$fixture/authority-inventory.json"
git init --bare -q "$authority_origin"
git init -q -b main "$authority_seed"
git -C "$authority_seed" config user.email ci@example.test
git -C "$authority_seed" config user.name 'CI Test'
write_package "$authority_seed/frontend/libs/extensions/assetus/runtime/package.json" '@sneat/extension-assetus'
write_workflow "$authority_seed" $'on:\n  push:\n    branches: [main]\njobs:\n  publish:\n    uses: sneat-co/cicd/.github/workflows/npm-publish.yml@main\n    with:\n      working-directory: frontend'
git -C "$authority_seed" add .
git -C "$authority_seed" commit -qm 'initial publisher'
git -C "$authority_seed" remote add origin "$authority_origin"
git -C "$authority_seed" push -qu origin main
git -C "$authority_origin" symbolic-ref HEAD refs/heads/main
mkdir -p "$authority_root"
git clone -q "$authority_origin" "$authority_root/assetus"
git -C "$authority_root/assetus" remote set-url origin https://github.com/sneat-co/assetus.git
authority_initial_sha="$(git -C "$authority_root/assetus" rev-parse HEAD)"
printf '%s\n' 'advance' > "$authority_seed/advanced.txt"
git -C "$authority_seed" add advanced.txt
git -C "$authority_seed" commit -qm 'advance remote default branch'
git -C "$authority_seed" push -q origin main
authority_remote_sha="$(git -C "$authority_seed" rev-parse HEAD)"
if [[ "$(git -C "$authority_root/assetus" rev-parse HEAD)" != "$(git -C "$authority_root/assetus" rev-parse origin/main)" ]]; then
  echo 'authority fixture must begin with HEAD equal to its cached origin/main' >&2
  exit 1
fi
printf '{"schema":"npm-publish-organization-inventory/v1","source":"github-api","organization":"sneat-co","archive_policy":"exclude","fetched_at":"%s","filters":["fixture"],"repositories":[{"repository":"sneat-co/assetus","default_branch":"main","default_sha":"%s","archived":false}]}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$authority_remote_sha" > "$authority_inventory"
expect_failure 'not a trusted receipt' \
  node "$auditor" --organization-root "$authority_root" --inventory "$authority_inventory" --require-authoritative

checkout_inventory="$fixture/checkout-inventory.json"
checkout_destination="$fixture/checkout-destination"
fake_bin="$fixture/fake-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" != repo || "$2" != clone ]]; then
  echo "unexpected gh invocation: $*" >&2
  exit 2
fi
git clone --no-checkout "$AUTHORITY_ORIGIN" "$4"
EOF
chmod +x "$fake_bin/gh"
printf '{"schema":"npm-publish-organization-inventory/v1","source":"github-api","organization":"sneat-co","archive_policy":"exclude","fetched_at":"%s","filters":["fixture"],"repositories":[{"repository":"sneat-co/assetus","default_branch":"main","default_sha":"%s","archived":false}]}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$authority_initial_sha" > "$checkout_inventory"
env AUTHORITY_ORIGIN="$authority_origin" PATH="$fake_bin:$PATH" \
  node "$inventory_checkout" --inventory "$checkout_inventory" --directory "$checkout_destination"
if [[ "$(git -C "$checkout_destination/assetus" rev-parse HEAD)" != "$authority_initial_sha" ]] \
  || git -C "$checkout_destination/assetus" symbolic-ref --quiet HEAD >/dev/null; then
  echo 'inventory checkout must detach at the recorded SHA, not the current branch head' >&2
  exit 1
fi
printf '{"schema":"npm-publish-organization-inventory/v1","source":"github-api","organization":"sneat-co","archive_policy":"exclude","repositories":[{"repository":"sneat-co/../escape","default_branch":"main","default_sha":"%s","archived":false}]}' "$authority_initial_sha" > "$checkout_inventory"
expect_failure 'invalid organization inventory repository' \
  node "$inventory_checkout" --inventory "$checkout_inventory" --directory "$fixture/invalid-checkout"

start_mock_api '["sneat-co/assetus"]'
expect_failure 'NON_AUTHORITATIVE_LOCAL_REF' \
  env SNEAT_ORGANIZATION_AUDIT_TOKEN=fixture-token GITHUB_API_URL="$mock_api_url" \
  node "$auditor" --organization-root "$authority_root" --github-api --require-authoritative
git -C "$authority_root/assetus" fetch -q "$authority_origin" main
git -C "$authority_root/assetus" checkout -q FETCH_HEAD
env GITHUB_SHA=1111111111111111111111111111111111111111 SNEAT_ORGANIZATION_AUDIT_TOKEN=fixture-token GITHUB_API_URL="$mock_api_url" \
  node "$auditor" --organization-root "$authority_root" --github-api --require-authoritative
stop_mock_api
start_mock_api '["sneat-co/assetus","sneat-co/missing"]'
expect_failure 'MISSING_INVENTORY_REPOSITORY' \
  env SNEAT_ORGANIZATION_AUDIT_TOKEN=fixture-token GITHUB_API_URL="$mock_api_url" \
  node "$auditor" --organization-root "$authority_root" --github-api --require-authoritative

preflight_line="$(rg -n 'name: Verify package publisher identity' "$repo_root/.github/workflows/npm-publish.yml" | cut -d: -f1)"
install_line="$(rg -n 'name: Install dependencies' "$repo_root/.github/workflows/npm-publish.yml" | cut -d: -f1)"
build_line="$(rg -n 'name: Build packages' "$repo_root/.github/workflows/npm-publish.yml" | cut -d: -f1)"
publish_line="$(rg -n 'name: Publish packages' "$repo_root/.github/workflows/npm-publish.yml" | cut -d: -f1)"
token_line="$(rg -n '^\s+(NPM_TOKEN|NODE_AUTH_TOKEN):' "$repo_root/.github/workflows/npm-publish.yml" | tail -1 | cut -d: -f1)"
if [[ -z "$preflight_line" || -z "$install_line" || -z "$build_line" || -z "$publish_line" || -z "$token_line" ]] \
  || (( preflight_line >= install_line || preflight_line >= build_line || preflight_line >= publish_line || token_line <= publish_line )); then
  echo 'npm publish identity preflight must precede install/build/publish and token exposure must remain in the publish step' >&2
  exit 1
fi
if ! rg -Fq 'uses: $/actions/check-npm-publish-identity' "$repo_root/.github/workflows/npm-publish.yml"; then
  echo 'npm publish identity preflight must resolve from the provider workflow commit' >&2
  exit 1
fi

audit_workflow="$repo_root/.github/workflows/audit-npm-publish-identities.yml"
if ! rg -Fq 'workflow_dispatch:' "$audit_workflow" \
  || ! rg -Fq 'SNEAT_ORGANIZATION_AUDIT_TOKEN' "$audit_workflow" \
  || ! rg -Fq -- '--github-api' "$audit_workflow" \
  || rg -q '^[[:space:]]*schedule:' "$audit_workflow" \
  || rg -qi 'upload-artifact|actions/cache' "$audit_workflow"; then
  echo 'organization audit must stay manual-only, use the explicit organization token, and retain no artifact/cache' >&2
  exit 1
fi

echo "npm publish identity tests passed"
