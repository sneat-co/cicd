#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
auditor="$repo_root/actions/check-npm-publish-identity/audit.mjs"
fixture="$(mktemp -d)"
cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT

fail() {
  echo "structural npm publisher audit test failed: $*" >&2
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
  local root="$1"
  mkdir -p "$root/frontend"
  cat > "$root/frontend/package.json" <<'EOF'
{"name":"@sneat/extension-assetus","version":"1.2.3"}
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

# Anchors and bracketed secrets must resolve structurally; an npm workspace
# publish is still a direct publisher even though `npm publish` is not adjacent.
anchors="$fixture/anchors"
mkdir -p "$anchors"
write_package "$anchors"
make_repository "$anchors"
write_workflow "$anchors" publish $'publisher-secrets: &publisher_secrets\n  NPM_TOKEN: ${{ secrets[\'NPM_TOKEN\'] }}\non: &automatic [push]\njobs:\n  shared:\n    uses: sneat-co/cicd/.github/workflows/npm-publish.yml@main\n    with:\n      working-directory: frontend\n  bypass:\n    runs-on: ubuntu-latest\n    defaults:\n      run:\n        working-directory: frontend\n    steps:\n      - run: npm --workspace contract publish\n        env: *publisher_secrets'
expect_failure 'DUPLICATE_ARMED_PUBLISHER' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$anchors" --require-no-direct-publisher

# Both quoted and inline top-level trigger forms are real YAML, not a textual
# occurrence of a trigger word somewhere else in the document.
inline_trigger="$fixture/inline-trigger"
mkdir -p "$inline_trigger"
write_package "$inline_trigger"
make_repository "$inline_trigger"
write_workflow "$inline_trigger" publish $'"on": {push: {branches: [main]}}\njobs:\n  shared:\n    uses: sneat-co/cicd/.github/workflows/npm-publish.yml@main\n    with:\n      working-directory: frontend\n  bypass:\n    runs-on: ubuntu-latest\n    steps:\n      - run: npm publish'
expect_failure 'DUPLICATE_ARMED_PUBLISHER' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$inline_trigger" --require-no-direct-publisher

# Package-manager directory switches are part of the publishing call. A
# short-form `pnpm -C` must not hide an otherwise direct publisher or make the
# audit attribute its package evidence to an unrelated job directory.
short_directory="$fixture/short-directory"
mkdir -p "$short_directory"
write_package "$short_directory"
make_repository "$short_directory"
write_workflow "$short_directory" publish $'on: [push]\njobs:\n  shared:\n    uses: sneat-co/cicd/.github/workflows/npm-publish.yml@main\n    with:\n      working-directory: frontend\n  bypass:\n    runs-on: ubuntu-latest\n    steps:\n      - run: pnpm -C frontend publish'
expect_failure 'DUPLICATE_ARMED_PUBLISHER' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$short_directory" --require-no-direct-publisher
short_directory_output="$(node "$auditor" --repository sneat-co/assetus --repository-root "$short_directory")"
if [[ "$short_directory_output" != *'"kind":"direct-armed"'*'"working_directories":["frontend"]'* ]]; then
  echo 'short-form package-manager directory must scope direct-publisher evidence to frontend' >&2
  exit 1
fi

# A local reusable workflow is reached from the armed caller trigger and its
# nested local shell script must be included in the publish call graph.
nested="$fixture/nested"
mkdir -p "$nested/frontend/scripts"
write_package "$nested"
make_repository "$nested"
printf '%s\n' 'pnpm --filter @sneat/extension-assetus publish' > "$nested/frontend/scripts/release.sh"
chmod +x "$nested/frontend/scripts/release.sh"
write_workflow "$nested" release $'on: workflow_call\njobs:\n  release:\n    runs-on: ubuntu-latest\n    defaults:\n      run:\n        working-directory: frontend\n    steps:\n      - run: ./scripts/release.sh\n        env:\n          NODE_AUTH_TOKEN: ${{ secrets[\'NPM_TOKEN\'] }}'
write_workflow "$nested" publish $'on: [push]\njobs:\n  shared:\n    uses: sneat-co/cicd/.github/workflows/npm-publish.yml@main\n    with:\n      working-directory: frontend\n  bypass:\n    uses: ./.github/workflows/release.yml\n    secrets: inherit'
expect_failure 'DUPLICATE_ARMED_PUBLISHER' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$nested" --require-no-direct-publisher

# Local composite actions are part of the same call graph. The audit must not
# trust a local action just because its implementation is not in the workflow.
action_chain="$fixture/action-chain"
mkdir -p "$action_chain/.github/actions/release"
write_package "$action_chain"
make_repository "$action_chain"
cat > "$action_chain/.github/actions/release/action.yml" <<'EOF'
name: release
runs:
  using: composite
  steps:
    - run: npm publish
      env:
        NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
EOF
write_workflow "$action_chain" publish $'on: [push]\njobs:\n  shared:\n    uses: sneat-co/cicd/.github/workflows/npm-publish.yml@main\n    with:\n      working-directory: frontend\n  bypass:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: ./.github/actions/release'
expect_failure 'DUPLICATE_ARMED_PUBLISHER' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$action_chain" --require-no-direct-publisher

# Any unsupported syntax is a failed verification, not an unarmed workflow.
malformed="$fixture/malformed"
mkdir -p "$malformed"
write_package "$malformed"
make_repository "$malformed"
write_workflow "$malformed" publish $'on: [push]\njobs:\n  bad: [unterminated'
expect_failure 'UNPARSEABLE_WORKFLOW' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$malformed" --require-no-direct-publisher

# An armed workflow cannot make its publishing behavior disappear behind a
# dynamic expression, a missing local script, or a missing local action.
dynamic_only="$fixture/dynamic-only"
mkdir -p "$dynamic_only"
write_package "$dynamic_only"
make_repository "$dynamic_only"
write_workflow "$dynamic_only" publish $'on: [push]\njobs:\n  bypass:\n    runs-on: ubuntu-latest\n    steps:\n      - run: ${{ inputs.publisher }}'
expect_failure 'DYNAMIC_RUN_COMMAND' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$dynamic_only" --require-no-direct-publisher

# A neutral filename and an otherwise unknown shell command do not prove that
# the expression cannot select `npm publish` or an equivalent publishing sink.
dynamic_shell_neutral="$fixture/dynamic-shell-neutral"
mkdir -p "$dynamic_shell_neutral"
write_package "$dynamic_shell_neutral"
make_repository "$dynamic_shell_neutral"
write_workflow "$dynamic_shell_neutral" ci $'on: [push]\njobs:\n  bypass:\n    runs-on: ubuntu-latest\n    steps:\n      - run: ${{ inputs.command }}'
expect_failure 'DYNAMIC_RUN_COMMAND' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$dynamic_shell_neutral" --require-no-direct-publisher

# A shell variable can move an unknown command across a segment boundary; the
# analyzer must not mistake the static `export` spelling for a safe operation.
dynamic_shell_alias="$fixture/dynamic-shell-alias"
mkdir -p "$dynamic_shell_alias"
write_package "$dynamic_shell_alias"
make_repository "$dynamic_shell_alias"
write_workflow "$dynamic_shell_alias" ci $'on: [push]\njobs:\n  bypass:\n    runs-on: ubuntu-latest\n    steps:\n      - run: export COMMAND=${{ inputs.command }}; $COMMAND'
expect_failure 'DYNAMIC_RUN_COMMAND' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$dynamic_shell_alias" --require-no-direct-publisher

# A neutral workflow filename is not proof that a dynamic npm script selector
# cannot reach publish. Dynamic command, token propagation, and a dynamic
# working directory for a direct sink must all leave the audit inconclusive.
unrelated_chain="$fixture/unrelated-chain"
mkdir -p "$unrelated_chain"
write_package "$unrelated_chain"
make_repository "$unrelated_chain"
write_workflow "$unrelated_chain" ci $'on: [push]\njobs:\n  dynamic-script:\n    runs-on: ubuntu-latest\n    defaults:\n      run:\n        working-directory: frontend\n    steps:\n      - run: npm run ${{ inputs.release_step }}\n  credentialed-dynamic:\n    runs-on: ubuntu-latest\n    steps:\n      - run: ${{ inputs.command }}\n        env:\n          NPM_TOKEN: ${{ secrets[\'NPM_TOKEN\'] }}\n  dynamic-directory:\n    runs-on: ubuntu-latest\n    defaults:\n      run:\n        working-directory: ${{ inputs.directory }}\n    steps:\n      - run: pnpm publish'
expect_failure 'DYNAMIC_RUN_COMMAND' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$unrelated_chain" --require-no-direct-publisher
inconclusive_output="$(node "$auditor" --repository sneat-co/assetus --repository-root "$unrelated_chain" 2>&1 || true)"
if ! grep -Fq '"status":"inconclusive"' <<<"$inconclusive_output"; then
  fail 'a structurally unresolved publish-capable chain must be reported as inconclusive'
fi

inherited_secret="$fixture/inherited-secret"
mkdir -p "$inherited_secret"
write_package "$inherited_secret"
make_repository "$inherited_secret"
write_workflow "$inherited_secret" release $'on: workflow_call\njobs:\n  hidden:\n    runs-on: ubuntu-latest\n    steps:\n      - run: ${{ inputs.command }}'
write_workflow "$inherited_secret" ci $'on: [push]\njobs:\n  handoff:\n    uses: ./.github/workflows/release.yml\n    secrets: inherit'
expect_failure 'DYNAMIC_RUN_COMMAND' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$inherited_secret" --require-no-direct-publisher

# A credential-bearing external action or reusable workflow has a publish-capable
# implementation that this local-only analyzer cannot inspect. A static ref is
# not proof that it cannot spend the credential, even when its workflow file is
# named like ordinary CI.
external_action="$fixture/external-action"
mkdir -p "$external_action"
write_package "$external_action"
make_repository "$external_action"
write_workflow "$external_action" ci $'on: [push]\nenv:\n  NPM_TOKEN: ${{ secrets[\'NPM_TOKEN\'] }}\njobs:\n  release:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: example/publish-action@0123456789abcdef0123456789abcdef01234567'
expect_failure 'UNVERIFIED_EXTERNAL_ACTION' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$external_action" --require-no-direct-publisher

external_action_with="$fixture/external-action-with"
mkdir -p "$external_action_with"
write_package "$external_action_with"
make_repository "$external_action_with"
write_workflow "$external_action_with" ci $'on: [push]\njobs:\n  release:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: example/publish-action@0123456789abcdef0123456789abcdef01234567\n        with:\n          registry-token: ${{ secrets[\'NPM_TOKEN\'] }}'
expect_failure 'UNVERIFIED_EXTERNAL_ACTION' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$external_action_with" --require-no-direct-publisher

external_reusable="$fixture/external-reusable"
mkdir -p "$external_reusable"
write_package "$external_reusable"
make_repository "$external_reusable"
write_workflow "$external_reusable" ci $'on: [push]\njobs:\n  release:\n    uses: example/reusable-publisher/.github/workflows/publish.yml@0123456789abcdef0123456789abcdef01234567\n    secrets: inherit'
expect_failure 'UNVERIFIED_EXTERNAL_WORKFLOW' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$external_reusable" --require-no-direct-publisher

# A non-publishing deployment credential is not an npm-publisher credential.
# Its external workflow is outside this audit's publication sink and must not
# turn unrelated deployment CI into an inconclusive package-owner result.
external_nonpublisher_secret="$fixture/external-nonpublisher-secret"
mkdir -p "$external_nonpublisher_secret"
write_package "$external_nonpublisher_secret"
make_repository "$external_nonpublisher_secret"
write_workflow "$external_nonpublisher_secret" ci $'on: [push]\njobs:\n  deploy:\n    uses: example/deploy/.github/workflows/cloud.yml@0123456789abcdef0123456789abcdef01234567\n    secrets:\n      CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}'
node "$auditor" --repository sneat-co/assetus --repository-root "$external_nonpublisher_secret" --require-no-direct-publisher

dynamic_uses="$fixture/dynamic-uses"
mkdir -p "$dynamic_uses"
write_package "$dynamic_uses"
make_repository "$dynamic_uses"
write_workflow "$dynamic_uses" ci $'on: [push]\njobs:\n  release:\n    uses: ${{ inputs.reusable_workflow }}\n    secrets: inherit'
expect_failure 'UNVERIFIED_WORKFLOW_CALL' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$dynamic_uses" --require-no-direct-publisher

nonpublisher_dynamic="$fixture/nonpublisher-dynamic"
mkdir -p "$nonpublisher_dynamic"
write_package "$nonpublisher_dynamic"
make_repository "$nonpublisher_dynamic"
write_workflow "$nonpublisher_dynamic" ci $'on: [push]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    defaults:\n      run:\n        working-directory: ${{ inputs.test_directory }}\n    steps:\n      - run: echo ${{ github.sha }}'
node "$auditor" --repository sneat-co/assetus --repository-root "$nonpublisher_dynamic" --require-no-direct-publisher

# Dynamic non-publishing install flags and a dynamic test directory are not
# evidence of a publishing sink. They remain diagnostic rather than making an
# otherwise unrelated automatic CI workflow inconclusive.
nonpublisher_package_manager="$fixture/nonpublisher-package-manager"
mkdir -p "$nonpublisher_package_manager"
write_package "$nonpublisher_package_manager"
make_repository "$nonpublisher_package_manager"
write_workflow "$nonpublisher_package_manager" ci $'on: [push]\njobs:\n  test:\n    runs-on: ubuntu-latest\n    defaults:\n      run:\n        working-directory: ${{ inputs.test_directory }}\n    steps:\n      - run: pnpm install --frozen-lockfile ${{ inputs.install_flags }}'
node "$auditor" --repository sneat-co/assetus --repository-root "$nonpublisher_package_manager" --require-no-direct-publisher

missing_script="$fixture/missing-script"
mkdir -p "$missing_script"
write_package "$missing_script"
make_repository "$missing_script"
write_workflow "$missing_script" publish $'on: [push]\njobs:\n  bypass:\n    runs-on: ubuntu-latest\n    defaults:\n      run:\n        working-directory: frontend\n    steps:\n      - run: ./scripts/missing.sh'
expect_failure 'UNRESOLVED_LOCAL_SCRIPT' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$missing_script" --require-no-direct-publisher

missing_action="$fixture/missing-action"
mkdir -p "$missing_action"
write_package "$missing_action"
make_repository "$missing_action"
write_workflow "$missing_action" publish $'on: [push]\njobs:\n  bypass:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: ./.github/actions/missing'
expect_failure 'UNRESOLVED_LOCAL_REFERENCE' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$missing_action" --require-no-direct-publisher

# A neutral workflow filename is not evidence that an unavailable local action
# cannot publish. Without its implementation the analyzer cannot prove the
# path is outside every publication-capable chain, so it must be inconclusive.
missing_action_neutral="$fixture/missing-action-neutral"
mkdir -p "$missing_action_neutral"
write_package "$missing_action_neutral"
make_repository "$missing_action_neutral"
write_workflow "$missing_action_neutral" ci $'on: [push]\njobs:\n  bypass:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: ./.github/actions/missing'
expect_failure 'UNRESOLVED_LOCAL_REFERENCE' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$missing_action_neutral" --require-no-direct-publisher

missing_workflow_neutral="$fixture/missing-workflow-neutral"
mkdir -p "$missing_workflow_neutral"
write_package "$missing_workflow_neutral"
make_repository "$missing_workflow_neutral"
write_workflow "$missing_workflow_neutral" ci $'on: [push]\njobs:\n  bypass:\n    uses: ./.github/workflows/missing.yml'
expect_failure 'UNRESOLVED_LOCAL_REFERENCE' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$missing_workflow_neutral" --require-no-direct-publisher

package_script_cycle="$fixture/package-script-cycle"
mkdir -p "$package_script_cycle/.github/workflows"
cat > "$package_script_cycle/package.json" <<'EOF'
{"name":"@sneat/extension-assetus","version":"1.2.3","scripts":{"release":"npm run release"}}
EOF
make_repository "$package_script_cycle"
write_workflow "$package_script_cycle" publish $'on: [push]\njobs:\n  bypass:\n    runs-on: ubuntu-latest\n    steps:\n      - run: npm run release'
expect_failure 'PACKAGE_SCRIPT_CALL_CYCLE' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$package_script_cycle" --require-no-direct-publisher

# Static local references and working directories must be inside the actual
# checkout, not merely share its lexical path prefix or traverse a symlink.
outside_directory="$fixture/outside-directory"
outside_target="$fixture/outside-directory-evil"
mkdir -p "$outside_directory" "$outside_target"
write_package "$outside_directory"
make_repository "$outside_directory"
write_workflow "$outside_directory" publish $'on: [push]\njobs:\n  shared:\n    uses: sneat-co/cicd/.github/workflows/npm-publish.yml@main\n    with:\n      working-directory: ../outside-directory-evil'
expect_failure 'UNVERIFIED_WORKING_DIRECTORY' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$outside_directory" --require-no-direct-publisher

symlink_directory="$fixture/symlink-directory"
mkdir -p "$symlink_directory" "$fixture/symlink-target"
write_package "$symlink_directory"
make_repository "$symlink_directory"
ln -s "$fixture/symlink-target" "$symlink_directory/frontend-link"
write_workflow "$symlink_directory" publish $'on: [push]\njobs:\n  shared:\n    uses: sneat-co/cicd/.github/workflows/npm-publish.yml@main\n    with:\n      working-directory: frontend-link'
expect_failure 'UNVERIFIED_WORKING_DIRECTORY' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$symlink_directory" --require-no-direct-publisher

symlink_script="$fixture/symlink-script"
mkdir -p "$symlink_script/frontend/scripts" "$fixture/symlink-script-target"
write_package "$symlink_script"
make_repository "$symlink_script"
printf '%s\n' 'pnpm publish' > "$fixture/symlink-script-target/release.sh"
ln -s "$fixture/symlink-script-target/release.sh" "$symlink_script/frontend/scripts/release.sh"
write_workflow "$symlink_script" publish $'on: [push]\njobs:\n  bypass:\n    runs-on: ubuntu-latest\n    defaults:\n      run:\n        working-directory: frontend\n    steps:\n      - run: ./scripts/release.sh'
expect_failure 'UNRESOLVED_LOCAL_SCRIPT' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$symlink_script" --require-no-direct-publisher

symlink_workflow="$fixture/symlink-workflow"
mkdir -p "$symlink_workflow/.github/workflows" "$fixture/symlink-workflow-target"
write_package "$symlink_workflow"
make_repository "$symlink_workflow"
printf '%s\n' 'on: [push]' > "$fixture/symlink-workflow-target/publish.yml"
ln -s "$fixture/symlink-workflow-target/publish.yml" "$symlink_workflow/.github/workflows/publish.yml"
expect_failure 'UNRESOLVED_LOCAL_REFERENCE' \
  node "$auditor" --repository sneat-co/assetus --repository-root "$symlink_workflow" --require-no-direct-publisher

echo "structural npm publisher audit tests passed"
