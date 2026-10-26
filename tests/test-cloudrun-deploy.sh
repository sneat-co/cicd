#!/usr/bin/env bash
# Tests for .github/workflows/cloudrun-deploy.yml.
#
# Each step's `run:` script is extracted with yq and executed under GitHub's
# default `bash -e` against a fake gcloud (and curl), so the real script text is
# what is tested. Needs: bash, yq (mikefarah v4), jq.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
workflow="$repo_root/.github/workflows/cloudrun-deploy.yml"
fixtures="$repo_root/tests/fixtures/sneat-go-deploy"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fakebin="$work/bin"
fake="$work/fake"
rt="$work/runner-temp"
sandbox="$work/sandbox"
mkdir -p "$fakebin" "$sandbox"

SHA=0123456789abcdef0123456789abcdef01234567
OUT=""
CODE=0
checks=0

fail() {
  echo "FAIL: $1" >&2
  echo "--- last output (exit ${CODE}) ---" >&2
  echo "${OUT:-<none>}" >&2
  if [ -f "$fake/calls.log" ]; then
    echo "--- gcloud calls ---" >&2
    cat "$fake/calls.log" >&2
  fi
  exit 1
}

# --- fakes -------------------------------------------------------------------

cat > "$fakebin/gcloud" <<'FAKE'
#!/usr/bin/env bash
d="${FAKE_DIR:?}"
echo "gcloud $*" >> "$d/calls.log"
[ -z "${ALL_SECRETS_JSON:-}" ] || echo "gcloud $*" >> "$d/env-leak.log"
case "$1 $2 $3" in
  "secrets describe "*) [ -f "$d/secrets/$3" ] || exit 1 ;;
  "secrets create "*)
    [ -z "${FAKE_FAIL_CREATE:-}" ] || exit 1
    : > "$d/secrets/$3" ;;
  "secrets add-iam-policy-binding "*)
    [ -z "${FAKE_FAIL_IAM:-}" ] || exit 1 ;;
  "secrets versions access")
    name=""
    for a in "$@"; do case "$a" in --secret=*) name="${a#--secret=}" ;; esac; done
    cat "$d/secrets/$name" ;;
  "secrets versions describe")
    name=""
    version="$4"
    for a in "$@"; do case "$a" in --secret=*) name="${a#--secret=}" ;; esac; done
    [ -f "$d/secrets/$name" ] || exit 1
    [ -z "${FAKE_FAIL_VERSION:-}" ] || exit 1
    if [ "$version" = latest ]; then echo "${FAKE_LATEST_STATE:-ENABLED}"; else echo "${FAKE_VERSION_STATE:-ENABLED}"; fi ;;
  "secrets versions add")
    [ -z "${FAKE_FAIL_ADD:-}" ] || exit 1
    cat > "$d/secrets/$4" ;;
  "secrets get-iam-policy "*)
    [ -z "${FAKE_POLICY_UNREADABLE:-}" ] || exit 1
    if [ -f "$d/policy/$3.json" ]; then cat "$d/policy/$3.json"; else echo '{"bindings":[]}'; fi ;;
  "projects describe "*) echo "123456789" ;;
  "projects get-iam-policy "*)
    [ -f "$d/project-policy.json" ] || exit 1
    cat "$d/project-policy.json" ;;
  "run services describe")
    case "$*" in
      *latestReadyRevisionName*) echo "rev-00001" ;;
      *) [ -f "$d/service_url" ] || exit 1; cat "$d/service_url" ;;
    esac ;;
  "run deploy "*)
    [ -f "$d/service_url" ] || echo "https://svc-abc-ew.a.run.app" > "$d/service_url" ;;
  "run services add-iam-policy-binding")
    [ -z "${FAKE_FAIL_INVOKER:-}" ] || exit 1 ;;
  "scheduler jobs describe") [ -f "$d/scheduler/$4" ] || exit 1 ;;
  "scheduler jobs create") : > "$d/scheduler/$5" ;;
  "scheduler jobs pause") [ -z "${FAKE_FAIL_PAUSE:-}" ] || exit 1 ;;
  "scheduler jobs update")
    case "$*" in
      *--remove-headers=*)
        # The installed gcloud SDK serializes removed header values as null;
        # the provider retains the key, so OIDC transitions must clear headers.
        exit 2
        ;;
    esac
    case "$*" in *--clear-headers*|*--update-headers=*|*--oidc-service-account-email=*) [ -z "${FAKE_FAIL_HEADER:-}" ] || exit 1 ;; esac ;;
  "scheduler jobs delete")
    [ -z "${FAKE_FAIL_DELETE:-}" ] || exit 1
    rm -f "$d/scheduler/$4" ;;
esac
exit 0
FAKE
cat > "$fakebin/curl" <<'FAKE'
#!/usr/bin/env bash
out=""
prev=""
for a in "$@"; do
  [ "$prev" = "-o" ] && out="$a"
  prev="$a"
done
[ -z "$out" ] || printf '%s' "${FAKE_CURL_BODY:-}" > "$out"
printf '%s' "${FAKE_CURL_CODE:-200}"
FAKE
printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/sleep"
chmod +x "$fakebin/gcloud" "$fakebin/curl" "$fakebin/sleep"

reset() {
  rm -rf "$fake" "$rt" "$work/gh_output" "$work/summary"
  mkdir -p "$fake/secrets" "$fake/policy" "$fake/scheduler" "$rt"
  : > "$work/gh_output"
  : > "$work/summary"
  : > "$fake/calls.log"
  OUT=""
  CODE=0
}

# run_step "<step name>" [VAR=value ...] runs the step's script; sets OUT and CODE.
run_step() {
  local name="$1"
  shift
  local script="$work/step.sh"
  yq -r ".jobs.deploy.steps[] | select(.name == \"$name\") | .run" "$workflow" > "$script"
  [ -s "$script" ] && [ "$(cat "$script")" != "null" ] || { echo "no such step: $name" >&2; exit 1; }
  set +e
  OUT="$(cd "$sandbox" && env -i PATH="$fakebin:$PATH" HOME="$work" FAKE_DIR="$fake" \
    RUNNER_TEMP="$rt" GITHUB_OUTPUT="$work/gh_output" GITHUB_STEP_SUMMARY="$work/summary" \
    GITHUB_REPOSITORY=sneat-co/fixture GITHUB_ENV="$work/gh_env" \
    GCLOUD_PROJECT_ID=test-proj GCLOUD_REGION=europe-west3 SERVICE_NAME=svc DEPLOY_SHA="$SHA" \
    DRY_RUN=false SECRET_PREFIX= OWNED_SECRETS= SHARED_SECRETS= REQUIRED_SECRETS= \
    ENV_FROM_SECRETS= SECRET_BINDINGS= ENV_VARS_INPUT= RUNTIME_SA= SCHEDULER_JOB= \
    SCHEDULER_OIDC_SERVICE_ACCOUNT= SCHEDULER_OIDC_AUDIENCE= \
    "$@" bash -e "$script" 2>&1)"
  CODE=$?
  set -e
  checks=$((checks + 1))
}

ok() { [ "$CODE" -eq 0 ] || fail "$1 (expected success)"; }
bad() { [ "$CODE" -ne 0 ] || fail "$1 (expected failure)"; }
has() { grep -Fq -- "$2" <<< "$1" || fail "expected to find: $2"; }
hasnt() { if grep -Fq -- "$2" <<< "$1"; then fail "did not expect to find: $2"; fi; }
calls() { cat "$fake/calls.log"; }
line_with() { grep -F -- "$1" "$fake/calls.log" | head -1; }
count_calls() { grep -Fc -- "$1" "$fake/calls.log" || true; }
put_secret() { printf '%s' "$2" > "$fake/secrets/$1"; }

# --- step conditions are what the equivalence relies on -----------------------

cond() { yq -r ".jobs.deploy.steps[] | select(.name == \"$1\") | .if" "$workflow"; }
[ "$(cond 'Configure Cloud Scheduler job')" = "inputs.scheduler_job != ''" ] || fail "scheduler step must run only when scheduler_job is set"
[ "$(cond 'Configure Firestore expiry policies')" = "inputs.firestore_ttls != ''" ] || fail "ttl step must run only when firestore_ttls is set"
[ "$(cond 'Build binary from source')" = "inputs.ci_run_id == '' && inputs.go_build_cmd != '' && !inputs.dry_run" ] || fail "source build condition"
[ "$(cond 'Mint private Go dependency token')" = "inputs.private_go_dependencies && !inputs.dry_run" ] || fail "private Go dependency condition"

# --- Exact source-build repository credentials (synthetic keys only) -----------
E="Validate exact source repository configuration"
C="Configure exact source repository credentials"
R="Remove exact source repository credentials"
[ "$(cond "$E")" = "inputs.ci_run_id == '' && inputs.go_build_cmd != ''" ] || fail "exact validation must include keyless source dry-run and skip artifacts"
[ "$(cond "$C")" = "inputs.ci_run_id == '' && inputs.go_build_cmd != '' && !inputs.dry_run && steps.exact_go.outputs.configured == 'true'" ] || fail "exact secret resolution must be real source only"
[ "$(cond "$R")" = 'always()' ] || fail "exact credential cleanup must run after build failures"
[ "$(yq -r '.jobs.deploy.steps[] | select(.name == "Configure exact source repository credentials") | .env.PRIVATE_GO_DEPENDENCIES' "$workflow")" = '${{ inputs.private_go_dependencies }}' ] || fail "exact reset must use declared built-in legacy mode"
[ "$(yq -r '.jobs.deploy.steps[] | select(.name == "Configure exact source repository credentials") | .env.EXACT_REPOSITORY_TOKEN' "$workflow")" = '${{ secrets[inputs.goprivate_git_repository_token_secret] }}' ] || fail "dedicated inherited secret binding"

reset; run_step "$E"; ok "legacy-only exact configuration absent"
reset; run_step "$E" PRIVATE_GIT_REPOSITORIES=github.com/new-owner/private-module; bad "exact list without secret name"
reset; run_step "$E" PRIVATE_GIT_REPOSITORY_SECRET=READ_MODULE; bad "secret name without exact list"
reset; run_step "$E" PRIVATE_GIT_REPOSITORIES=github.com/new-owner/private-module PRIVATE_GIT_REPOSITORY_SECRET='not/a/name'; bad "invalid inherited secret name"
for repository in github.com github.com/owner https://github.com/owner/repo github.com:443/owner/repo github.com/owner/repo/child github.com/owner/repo.git github.com/owner/repo.GIT github.com/../repo github.com/owner/repo?query github.com/owner/repo/; do
  reset; run_step "$E" PRIVATE_GIT_REPOSITORIES="$repository" PRIVATE_GIT_REPOSITORY_SECRET=READ_MODULE; bad "invalid exact repository $repository"
done
for repository in github.com/SNEAT-CO/private-module github.com/sneat-dev/private-module github.com/DATATUG/BACKEND github.com/datatug/backend.git/child github.com/datatug/datatug-core; do
  reset; run_step "$E" PRIVATE_GIT_REPOSITORIES="$repository" PRIVATE_GIT_REPOSITORY_SECRET=READ_MODULE PRIVATE_GO_DEPENDENCIES=true; bad "overlapping legacy or App route $repository"
done
reset; run_step "$E" PRIVATE_GIT_REPOSITORIES=github.com/new-owner/private-module PRIVATE_GIT_REPOSITORY_SECRET=READ_MODULE PRIVATE_GO_DEPENDENCIES=true DRY_RUN=true; ok "keyless dry-run validates syntax"
has "$OUT" "access are not proved"
[ ! -e "$rt/exact-go-dependencies/token" ] || fail "dry validation created a credential"
reset; run_step "$C" EXACT_REPOSITORIES=github.com/new-owner/private-module EXACT_REPOSITORY_TOKEN= SNEAT_DEPENDENCY_TOKEN=LEGACY_SYNTHETIC; bad "actual source missing dedicated credential cannot borrow legacy"

# Parse the real process-only GITHUB_ENV protocol without evaluating its values.
load_git_env() {
  local line key end value
  while IFS= read -r line; do
    if [[ "$line" == *'<<'* ]]; then
      key="${line%%<<*}"; end="${line#*<<}"; value=""
      while IFS= read -r line && [ "$line" != "$end" ]; do value+="$line"$'\n'; done
      value="${value%$'\n'}"
      export "$key=$value"
    else export "$line"; fi
  done < "$work/gh_env"
}
credential_output() (
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 RUNNER_TEMP="$rt"
  load_git_env
  printf 'protocol=%s\nhost=%s\npath=%s\n\n' "$1" "$2" "$3" | git credential fill 2>/dev/null || true
)
reset; : > "$work/gh_env"
run_step 'Configure private Go dependency credentials' BACKEND_DEPENDENCY_TOKEN=DATATUG_SYNTHETIC SNEAT_DEPENDENCY_TOKEN=SNEAT_SYNTHETIC; ok "existing legacy helper configuration"
run_step "$C" EXACT_REPOSITORIES='github.com/new-owner/private-module,ghe.example.com/team/module' EXACT_REPOSITORY_TOKEN=EXACT_SYNTHETIC GIT_CONFIG_COUNT=3 PRIVATE_GO_DEPENDENCIES=true; ok "append exact helper without overwriting existing routes"
hasnt "$(cat "$work/gh_env")" EXACT_SYNTHETIC
for path in new-owner/private-module new-owner/private-module.git; do
  has "$(credential_output https github.com "$path")" 'password=EXACT_SYNTHETIC'
done
has "$(credential_output https ghe.example.com team/module.git)" 'password=EXACT_SYNTHETIC'
has "$(credential_output https github.com sneat-co/existing)" 'password=SNEAT_SYNTHETIC'
has "$(credential_output https github.com sneat-dev/existing)" 'password=SNEAT_SYNTHETIC'
has "$(credential_output https github.com datatug/backend)" 'password=DATATUG_SYNTHETIC'
has "$(credential_output https github.com datatug/datatug-core.git)" 'password=DATATUG_SYNTHETIC'
for path in new-owner/private-module/child new-owner/private-module.git/child new-owner/private-module-suffix new-owner/private-module.git.evil new-owner/sibling NEW-OWNER/private-module new-owner/private-module/../sibling; do
  [ -z "$(credential_output https github.com "$path")" ] || fail "foreign exact recipient $path got credentials"
done
[ -z "$(credential_output http github.com new-owner/private-module)" ] || fail "HTTP obtained credential"
[ -z "$(credential_output https github.com.evil new-owner/private-module)" ] || fail "foreign host obtained credential"
python3 - "$rt/exact-go-dependencies" <<'PY_PERMISSIONS'
import os,sys
for name in ('token','repositories','base-count'):
    assert os.stat(os.path.join(sys.argv[1],name)).st_mode & 0o777 == 0o600
assert os.stat(os.path.join(sys.argv[1],'helper')).st_mode & 0o777 == 0o700
PY_PERMISSIONS
run_step "$R"; ok "always cleanup restores prior process helper count"
[ ! -e "$rt/exact-go-dependencies" ] || fail "dedicated credential files retained"
[ -z "$(credential_output https github.com new-owner/private-module)" ] || fail "exact credential survived cleanup"
has "$(credential_output https github.com sneat-co/existing)" 'password=SNEAT_SYNTHETIC'
# Exact-only mode clears ambient helpers and still never borrows a legacy token.
reset; : > "$work/gh_env"
run_step "$C" EXACT_REPOSITORIES=github.com/new-owner/private-module EXACT_REPOSITORY_TOKEN=EXACT_SYNTHETIC; ok "exact-only setup"
has "$(credential_output https github.com new-owner/private-module)" 'password=EXACT_SYNTHETIC'
[ -z "$(credential_output https github.com unrelated/repository)" ] || fail "exact-only helper became host-wide"
run_step "$R"; ok "exact-only cleanup"

# Nonzero process config is not proof that the reviewed legacy mode is enabled.
reset
cat > "$work/gh_env" <<'AMBIENT_ENV'
GIT_CONFIG_COUNT=2
GIT_CONFIG_KEY_0=core.quotePath
GIT_CONFIG_VALUE_0=false
GIT_CONFIG_KEY_1=credential.helper
GIT_CONFIG_VALUE_1<<AMBIENT_HELPER
!f() { printf 'username=synthetic\npassword=AMBIENT_SYNTHETIC\n'; }; f
AMBIENT_HELPER
AMBIENT_ENV
run_step "$C" EXACT_REPOSITORIES=github.com/new-owner/private-module EXACT_REPOSITORY_TOKEN=EXACT_SYNTHETIC GIT_CONFIG_COUNT=2 PRIVATE_GO_DEPENDENCIES=false; ok "exact-only setup with ambient process helper"
has "$(credential_output https github.com new-owner/private-module)" 'password=EXACT_SYNTHETIC'
[ -z "$(credential_output https github.com new-owner/private-module/child)" ] || fail "exact-only retained ambient helper for child"
[ "$(export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null; load_git_env; git config --get core.quotePath)" = false ] || fail "exact-only overwrote unrelated process config"
run_step "$R"; ok "exact-only cleanup restores nonzero original config"
has "$(credential_output https github.com new-owner/private-module/child)" 'password=AMBIENT_SYNTHETIC'
[ "$(export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null; load_git_env; git config --get core.quotePath)" = false ] || fail "cleanup overwrote unrelated process config"

# --- Validate deploy inputs ---------------------------------------------------

V="Validate deploy inputs"
valid_env=(SCHEDULER_PATH=/v0/cron/sweep 'SCHEDULER_CRON=*/5 * * * *' SCHEDULER_CREATE_PAUSED=false
  ALLOW_UNPREFIXED_SECRETS=false FIRESTORE_TTLS= MIN_INSTANCES=0 MAX_INSTANCES=2 VALIDATE_PATH=/cicd/validate
  CI_RUN_ID= CI_ARTIFACT_NAME= BINARY_NAME= WIF_PROVIDER=projects/1/locations/global/workloadIdentityPools/p/providers/q
  DEPLOYER_SA=d@test-proj.iam.gserviceaccount.com)

reset; run_step "$V" "${valid_env[@]}"; ok "defaults validate"
reset; run_step "$V" "${valid_env[@]}" SERVICE_NAME=games-cloud SECRET_PREFIX=GAMES_CLOUD__ \
  OWNED_SECRETS="A_ONE B_TWO" SHARED_SECRETS="C_THREE" REQUIRED_SECRETS="A_ONE" ENV_FROM_SECRETS=PAIR_MATCHING_GAME_SECRET \
  SCHEDULER_JOB=games-cron 'FIRESTORE_TTLS=sso-flows:expiresAt'; ok "full valid set"
reset; run_step "$V" "${valid_env[@]}" 'SECRET_BINDINGS=DATATUG_PERSONAL_CLOUD_LOGS_CLIENT_SECRET=datatug-cloud-logs-oauth-client-secret:1'; ok "explicit secret mapping"
reset; run_step "$V" "${valid_env[@]}" $'SECRET_BINDINGS=MAP_ONE=secret-one:latest\nMAP_TWO=secret-two:2'; ok "multiline explicit mappings"
reset; run_step "$V" "${valid_env[@]}" 'SECRET_BINDINGS=lower_name=secret:1'; bad "mapped lower-case env name"
reset; run_step "$V" "${valid_env[@]}" 'SECRET_BINDINGS=BAD'; bad "malformed mapped entry"
reset; run_step "$V" "${valid_env[@]}" 'SECRET_BINDINGS=MAP=bad/secret:1'; bad "invalid secret manager name"
reset; run_step "$V" "${valid_env[@]}" 'SECRET_BINDINGS=MAP=secret:0'; bad "invalid zero version"
reset; run_step "$V" "${valid_env[@]}" $'SECRET_BINDINGS=MAP=secret:1\nMAP=other:latest'; bad "duplicate mapped env name"
reset; run_step "$V" "${valid_env[@]}" $'SECRET_BINDINGS=MAP=secret:1\nOTHER=secret:1'; bad "duplicate mapped secret reference"
reset; run_step "$V" "${valid_env[@]}" SECRET_BINDINGS=MAP=secret:1 OWNED_SECRETS=MAP SECRET_PREFIX=P__; bad "mapped name collides with owned"
reset; run_step "$V" "${valid_env[@]}" SECRET_BINDINGS=MAP=secret:1 SHARED_SECRETS=MAP; bad "mapped name collides with shared"
reset; run_step "$V" "${valid_env[@]}" SECRET_BINDINGS=MAP=secret:1 'ENV_VARS_INPUT=MAP=plain'; bad "mapped name collides with env vars"
reset; run_step "$V" "${valid_env[@]}" SECRET_BINDINGS=MAP=secret:1 ENV_FROM_SECRETS=MAP; bad "mapped name collides with env_from_secrets"
reset; run_step "$V" "${valid_env[@]}" SECRET_BINDINGS=GOOGLE_CLOUD_PROJECT=secret:1; bad "mapped name collides with generated env"
reset; run_step "$V" "${valid_env[@]}" SECRET_BINDINGS=MAP=secret:1 $'OWNED_SECRETS=A\nMAP' SECRET_PREFIX=P__; bad "mapped name collides with multiline owned secrets"
reset; run_step "$V" "${valid_env[@]}" SECRET_BINDINGS=MAP=secret:1 $'SHARED_SECRETS=A\nMAP'; bad "mapped name collides with multiline shared secrets"
reset; run_step "$V" "${valid_env[@]}" SECRET_BINDINGS=MAP=secret:1 REQUIRED_SECRETS=MAP; ok "required mapped name"
reset; run_step "$V" "${valid_env[@]}" SCHEDULER_JOB=cron SCHEDULER_OIDC_SERVICE_ACCOUNT=worker@other-proj.iam.gserviceaccount.com SCHEDULER_OIDC_AUDIENCE=https://svc.example; bad "OIDC service account other project"
reset; run_step "$V" "${valid_env[@]}" SCHEDULER_JOB=cron SCHEDULER_OIDC_SERVICE_ACCOUNT=worker@test-proj.iam.gserviceaccount.com SCHEDULER_OIDC_AUDIENCE=http://svc.example; bad "OIDC audience HTTPS required"
reset; run_step "$V" "${valid_env[@]}" SCHEDULER_JOB=cron SCHEDULER_OIDC_SERVICE_ACCOUNT=worker@test-proj.iam.gserviceaccount.com; bad "OIDC inputs supplied together"
reset; run_step "$V" "${valid_env[@]}" SERVICE_NAME=Bad_Name; bad "service name"
reset; run_step "$V" "${valid_env[@]}" SECRET_PREFIX='bad prefix'; bad "secret prefix"
reset; run_step "$V" "${valid_env[@]}" OWNED_SECRETS="1BAD" SECRET_PREFIX=P__; bad "secret name"
reset; run_step "$V" "${valid_env[@]}" OWNED_SECRETS="lower_case" SECRET_PREFIX=P__; bad "lower-case owned name"
has "$OUT" "must be an upper-case environment variable name"
reset; run_step "$V" "${valid_env[@]}" SHARED_SECRETS="Mixed_Case"; bad "mixed-case shared name"
reset; run_step "$V" "${valid_env[@]}" REQUIRED_SECRETS="a_b"; bad "lower-case required name"
reset; run_step "$V" "${valid_env[@]}" ENV_FROM_SECRETS="a_b"; bad "lower-case env_from_secrets name"
reset; run_step "$V" "${valid_env[@]}" OWNED_SECRETS="A_ONE"; bad "owned secrets without a prefix"
has "$OUT" "owned_secrets need a secret_prefix"
reset; run_step "$V" "${valid_env[@]}" OWNED_SECRETS="A_ONE" ALLOW_UNPREFIXED_SECRETS=true; ok "unprefixed owned secrets, confirmed"
reset; run_step "$V" "${valid_env[@]}" SHARED_SECRETS="S_ONE"; ok "shared secrets alone need no prefix"
reset; run_step "$V" "${valid_env[@]}" OWNED_SECRETS="A_ONE" SECRET_PREFIX=P__ SHARED_SECRETS="P__A_ONE"; bad "prefixed owned name equals a shared name"
reset; run_step "$V" "${valid_env[@]}" OWNED_SECRETS="A B A" SECRET_PREFIX=P__; bad "duplicate owned"
reset; run_step "$V" "${valid_env[@]}" OWNED_SECRETS="A B" SHARED_SECRETS="B" SECRET_PREFIX=P__; bad "owned and shared overlap"
reset; run_step "$V" "${valid_env[@]}" MIN_INSTANCES=3; bad "min above max"
reset; run_step "$V" "${valid_env[@]}" MAX_INSTANCES=two; bad "non-numeric max"
reset; run_step "$V" "${valid_env[@]}" VALIDATE_PATH=cicd; bad "validate path"
reset; run_step "$V" "${valid_env[@]}" SCHEDULER_JOB=j SCHEDULER_PATH=sweep; bad "scheduler path"
reset; run_step "$V" "${valid_env[@]}" SCHEDULER_CREATE_PAUSED=true; bad "paused without a job"
reset; run_step "$V" "${valid_env[@]}" 'FIRESTORE_TTLS=justonename'; bad "ttl format"
reset; run_step "$V" "${valid_env[@]}" DEPLOY_SHA='bad ref'; bad "ref"
reset; run_step "$V" "${valid_env[@]}" CI_RUN_ID=42 CI_ARTIFACT_NAME=art BINARY_NAME=app; ok "ci artifact inputs"
reset; run_step "$V" "${valid_env[@]}" CI_RUN_ID=42 CI_ARTIFACT_NAME=art BINARY_NAME=app DEPLOY_SHA=abc123; bad "ci artifact needs full sha"
reset; run_step "$V" "${valid_env[@]}" CI_RUN_ID=42 CI_ARTIFACT_NAME= BINARY_NAME=app; bad "ci artifact name missing"
reset; run_step "$V" "${valid_env[@]}" CI_RUN_ID=42 CI_ARTIFACT_NAME=art BINARY_NAME='../app'; bad "binary name"
reset; run_step "$V" "${valid_env[@]}" RUNTIME_SA='not-an-email'; bad "runtime sa"
reset; run_step "$V" "${valid_env[@]}" WIF_PROVIDER=; bad "wif provider required"

# --- Sync tokens ----------------------------------------------------------------

S="Sync tokens from GitHub secrets to Secret Manager"
reset
put_secret B "v-b"
run_step "$S" OWNED_SECRETS="A B C" 'ALL_SECRETS_JSON={"B":"v-b","C":"v-c","UNOWNED":"zzz-unowned"}'
ok "sync runs"
has "$OUT" "· A: no GitHub secret set — leaving Secret Manager untouched"
has "$OUT" "· B: unchanged"
has "$OUT" "· C: created secret"
has "$OUT" "↳ granted secretAccessor to 123456789-compute@developer.gserviceaccount.com"
has "$OUT" "· C: new version added"
hasnt "$OUT" "v-b"; hasnt "$OUT" "v-c"
[ "$(cat "$fake/secrets/C")" = "v-c" ] || fail "C value stored"
hasnt "$(calls)" "UNOWNED"
hasnt "$(calls)" "versions add B"
has "$(calls)" "secrets add-iam-policy-binding C --member=serviceAccount:123456789-compute@developer.gserviceaccount.com --role=roles/secretmanager.secretAccessor --project=test-proj"

reset
put_secret B "old"
run_step "$S" OWNED_SECRETS="B" 'ALL_SECRETS_JSON={"B":"new"}'
ok "changed value"
has "$OUT" "· B: new version added"
[ "$(cat "$fake/secrets/B")" = "new" ] || fail "changed value stored"

# The secrets context is dropped before any gcloud call, and the owned value still arrives.
reset
run_step "$S" OWNED_SECRETS="A" 'ALL_SECRETS_JSON={"A":"a-val","CI_TOKEN":"ci-token-val"}'
ok "context dropped"
[ ! -s "$fake/env-leak.log" ] || fail "gcloud inherited the secrets context: $(cat "$fake/env-leak.log")"
[ "$(cat "$fake/secrets/A")" = "a-val" ] || fail "owned value written"
has "$OUT" "secrets context: "
hasnt "$OUT" "ci-token-val"
[ -z "$(ls "$rt" | grep -i values)" ] || true

# A value is stored byte-exact, trailing newline included.
reset
put_secret B "x"
run_step "$S" OWNED_SECRETS="B" 'ALL_SECRETS_JSON={"B":"x\n"}'
ok "newline value"
has "$OUT" "· B: new version added"
[ "$(wc -c < "$fake/secrets/B" | tr -d ' ')" = "2" ] || fail "trailing newline kept"

# A multi-line value that ends in a newline (a PEM key) is unchanged when the
# stored latest version holds the same bytes: no version is added.
reset
printf '%s\n' '-----BEGIN KEY-----' 'abc' '-----END KEY-----' > "$fake/secrets/PEM"
run_step "$S" OWNED_SECRETS="PEM" 'ALL_SECRETS_JSON={"PEM":"-----BEGIN KEY-----\nabc\n-----END KEY-----\n"}'
ok "pem value"
has "$OUT" "· PEM: unchanged"
hasnt "$(calls)" "versions add PEM"

# Differing only by the trailing newline is still a change.
reset
printf '%s\n' '-----BEGIN KEY-----' 'abc' '-----END KEY-----' > "$fake/secrets/PEM"
run_step "$S" OWNED_SECRETS="PEM" 'ALL_SECRETS_JSON={"PEM":"-----BEGIN KEY-----\nabc\n-----END KEY-----"}'
ok "pem value without trailing newline"
has "$OUT" "· PEM: new version added"

# With a prefix, only the owned secrets are written, under the prefixed name.
reset
run_step "$S" SECRET_PREFIX=P__ OWNED_SECRETS="A" SHARED_SECRETS="S" 'ALL_SECRETS_JSON={"A":"a-val","S":"s-val"}'
ok "prefixed sync"
has "$OUT" "· A (P__A): created secret"
[ -f "$fake/secrets/P__A" ] || fail "prefixed secret created"
[ ! -f "$fake/secrets/A" ] || fail "unprefixed secret must not be created"
[ ! -f "$fake/secrets/S" ] || fail "shared secret must never be written"
hasnt "$(calls)" " S "
hasnt "$(calls)" "S --"

reset
run_step "$S" OWNED_SECRETS="A" RUNTIME_SA="rt@test-proj.iam.gserviceaccount.com" 'ALL_SECRETS_JSON={"A":"a"}'
ok "explicit runtime sa"
has "$OUT" "↳ granted secretAccessor to rt@test-proj.iam.gserviceaccount.com"
hasnt "$(calls)" "projects describe"

reset
run_step "$S" OWNED_SECRETS="A" FAKE_FAIL_CREATE=1 'ALL_SECRETS_JSON={"A":"a"}'
ok "create failure is not fatal"
has "$OUT" "::warning::A: could not create secret in Secret Manager"
reset
run_step "$S" OWNED_SECRETS="A" FAKE_FAIL_IAM=1 'ALL_SECRETS_JSON={"A":"a"}'
ok "iam failure is not fatal"
has "$OUT" "::warning::A: created but could not grant secretAccessor"
reset
put_secret A "old"
run_step "$S" OWNED_SECRETS="A" FAKE_FAIL_ADD=1 'ALL_SECRETS_JSON={"A":"new"}'
ok "version failure is not fatal"
has "$OUT" "::warning::A: failed to add new version"
reset
run_step "$S" OWNED_SECRETS="" 'ALL_SECRETS_JSON={"A":"a"}'
ok "no owned secrets"
hasnt "$(calls)" "secrets create"
reset
run_step "$S" OWNED_SECRETS="A" DRY_RUN=true 'ALL_SECRETS_JSON={"A":"a"}'
ok "dry-run sync"
has "$OUT" "· A: [dry-run] would create it if missing, compare with the latest version and add one only if it differs"
hasnt "$OUT" "new version added"
hasnt "$(calls)" "versions"
reset
run_step "$S" OWNED_SECRETS="A" 'ALL_SECRETS_JSON='
ok "empty secrets context"
has "$OUT" "· A: no GitHub secret set"

# --- Plain environment values ------------------------------------------------------

E="Collect plain environment values from secrets"
reset
run_step "$E" ENV_FROM_SECRETS="PAIR_KEY UNSET_KEY" 'ALL_SECRETS_JSON={"PAIR_KEY":"hmac-value"}'
ok "env from secrets"
[ "$(cat "$rt/env-from-secrets.txt")" = "PAIR_KEY=hmac-value
UNSET_KEY=" ] || fail "env-from-secrets file content"
hasnt "$OUT" "hmac-value"
reset
run_step "$E" ENV_FROM_SECRETS="PAIR_KEY" 'ALL_SECRETS_JSON={"PAIR_KEY":"a,b"}'
bad "comma in plain value"
hasnt "$OUT" "a,b"
reset
run_step "$E" ENV_FROM_SECRETS="" 'ALL_SECRETS_JSON={}'
ok "no plain values"
[ ! -s "$rt/env-from-secrets.txt" ] || fail "empty file expected"

# --- Resolve secret bindings --------------------------------------------------------

R="Resolve secret bindings"
reset
put_secret P__A x; put_secret S x
run_step "$R" SECRET_PREFIX=P__ OWNED_SECRETS="A B" SHARED_SECRETS="S T"
ok "bindings resolve"
[ "$(cat "$rt/secret-flags.txt")" = "--set-secrets=A=P__A:latest
--set-secrets=S=S:latest" ] || fail "binding flags: $(cat "$rt/secret-flags.txt")"
[ "$(cat "$rt/bound-secrets.txt")" = "A P__A
S S" ] || fail "bound file"
has "$OUT" "Skipping optional secret B: P__B not found in Secret Manager"
has "$OUT" "Skipping optional secret T: not found in Secret Manager"

reset
put_secret datatug-cloud-logs-oauth-client-secret sentinel-secret-value
run_step "$R" 'SECRET_BINDINGS=DATATUG_PERSONAL_CLOUD_LOGS_CLIENT_SECRET=datatug-cloud-logs-oauth-client-secret:1' REQUIRED_SECRETS=DATATUG_PERSONAL_CLOUD_LOGS_CLIENT_SECRET
ok "explicit read-only binding"
[ "$(cat "$rt/secret-flags.txt")" = "--set-secrets=DATATUG_PERSONAL_CLOUD_LOGS_CLIENT_SECRET=datatug-cloud-logs-oauth-client-secret:1" ] || fail "mapped version flag"
[ "$(cat "$rt/bound-secrets.txt")" = "DATATUG_PERSONAL_CLOUD_LOGS_CLIENT_SECRET datatug-cloud-logs-oauth-client-secret 1" ] || fail "mapped bound secret record"
hasnt "$(calls)" "versions access"
hasnt "$OUT" "sentinel-secret-value"
hasnt "$(calls)" "sentinel-secret-value"

reset
run_step "$R" 'SECRET_BINDINGS=MAP=missing-secret:1'
bad "missing explicit secret fails"
has "$OUT" "MAP references Secret Manager secret missing-secret, which does not exist"

reset
put_secret mapped x
run_step "$R" 'SECRET_BINDINGS=MAP=mapped:9' FAKE_FAIL_VERSION=1
bad "missing explicit version fails"
has "$OUT" "MAP references mapped:9, which is missing or disabled"

reset
put_secret mapped x
run_step "$R" 'SECRET_BINDINGS=MAP=mapped:latest' FAKE_FAIL_VERSION=1
bad "missing enabled latest version fails"
has "$OUT" "MAP references mapped:latest, which is missing or disabled"

reset
put_secret mapped x
run_step "$R" $'SECRET_BINDINGS=OLDER=mapped:1\nMAP=mapped:latest' FAKE_VERSION_STATE=ENABLED FAKE_LATEST_STATE=DISABLED
bad "disabled latest fails when an older version is enabled"
has "$OUT" "MAP references mapped:latest, which is missing or disabled"
has "$(calls)" "secrets versions describe 1 --secret=mapped"
has "$(calls)" "secrets versions describe latest --secret=mapped"
hasnt "$(calls)" "secrets versions list"

reset
put_secret P__A x; put_secret S x
run_step "$R" SECRET_PREFIX=P__ OWNED_SECRETS="A" SHARED_SECRETS="S" REQUIRED_SECRETS="A S"
ok "required present"
reset
put_secret P__A x
run_step "$R" SECRET_PREFIX=P__ OWNED_SECRETS="A B" REQUIRED_SECRETS="A B"
bad "required missing"
has "$OUT" "::error title=Required secret missing::B not found"
reset
run_step "$R" REQUIRED_SECRETS="NOT_LISTED"
bad "required but never bindable"
has "$OUT" "NOT_LISTED"

# --- Runtime service account access --------------------------------------------------

C="Check runtime service account access"
RT="rt@test-proj.iam.gserviceaccount.com"
reset
printf 'A P__A\nS S\n' > "$rt/bound-secrets.txt"
run_step "$C" DRY_RUN=true
ok "dry run skips the check"
hasnt "$(calls)" "get-iam-policy"

reset
printf 'A P__A\nS S\n' > "$rt/bound-secrets.txt"
echo '{"bindings":[{"role":"roles/secretmanager.secretAccessor","members":["serviceAccount:rt@test-proj.iam.gserviceaccount.com"]}]}' > "$fake/project-policy.json"
run_step "$C" RUNTIME_SA="$RT"
ok "project-level grant"
hasnt "$(calls)" "secrets get-iam-policy"

reset
printf 'MAP mapped-secret 7\n' > "$rt/bound-secrets.txt"
echo '{"bindings":[{"role":"roles/secretmanager.secretAccessor","members":["serviceAccount:rt@test-proj.iam.gserviceaccount.com"]}]}' > "$fake/policy/mapped-secret.json"
run_step "$C" RUNTIME_SA="$RT"
ok "explicit mapped secret access check"
has "$(calls)" "secrets get-iam-policy mapped-secret --project=test-proj --format=json"
hasnt "$(calls)" "mapped-secret 7"

reset
printf 'A P__A\nS S\n' > "$rt/bound-secrets.txt"
for sm in P__A S; do
  echo '{"bindings":[{"role":"roles/secretmanager.secretAccessor","members":["user:x@y.z","serviceAccount:rt@test-proj.iam.gserviceaccount.com"]}]}' > "$fake/policy/$sm.json"
done
run_step "$C" RUNTIME_SA="$RT"
ok "secret-level grants"

reset
printf 'A P__A\nS S\n' > "$rt/bound-secrets.txt"
echo '{"bindings":[{"role":"roles/secretmanager.secretAccessor","members":["serviceAccount:rt@test-proj.iam.gserviceaccount.com"]}]}' > "$fake/policy/S.json"
run_step "$C" RUNTIME_SA="$RT"
bad "missing grant fails"
has "$OUT" "gcloud secrets add-iam-policy-binding P__A --member=serviceAccount:$RT --role=roles/secretmanager.secretAccessor --project=test-proj"
hasnt "$OUT" "add-iam-policy-binding S --member"
hasnt "$(calls)" "secrets add-iam-policy-binding"

reset
printf 'A P__A\n' > "$rt/bound-secrets.txt"
run_step "$C" RUNTIME_SA="$RT" FAKE_POLICY_UNREADABLE=1
ok "unreadable policy only warns"
has "$OUT" "::warning::P__A: cannot read its IAM policy"

reset
printf 'A A\n' > "$rt/bound-secrets.txt"
echo '{"bindings":[{"role":"roles/viewer","members":["serviceAccount:123456789-compute@developer.gserviceaccount.com"]}]}' > "$fake/policy/A.json"
run_step "$C"
bad "default compute account is checked"
has "$OUT" "serviceAccount:123456789-compute@developer.gserviceaccount.com"

# --- Deploy ----------------------------------------------------------------------------

D="Deploy to Cloud Run"
IMG="europe-west3-docker.pkg.dev/test-proj/cloud-run/svc"
deploy_env=(CRON_SWEEP_SECRET=cron-secret ENV_VARS_INPUT= IMAGE= MIN_INSTANCES=0 MAX_INSTANCES=2)
prep_deploy() {
  : > "$rt/env-from-secrets.txt"
  printf -- '--set-secrets=A=P__A:latest\n--set-secrets=S=S:latest\n' > "$rt/secret-flags.txt"
}

# First deploy: no URL yet, so the base URL is patched in afterwards.
reset; prep_deploy
run_step "$D" "${deploy_env[@]}" 'ENV_VARS_INPUT=SNEAT_PLATFORM=cloudrun
FOO=bar'
ok "first deploy"
deploy="$(line_with 'run deploy svc')"
has "$deploy" "--image=$IMG:$SHA"
has "$deploy" "--platform=managed --region=europe-west3 --allow-unauthenticated --min-instances=0 --max-instances=2 --memory=512Mi --cpu=1 --timeout=300"
has "$deploy" "--set-env-vars=GOOGLE_CLOUD_PROJECT=test-proj,FIREBASE_PROJECT_ID=test-proj,CLOUD_TASKS_LOCATION=europe-west3,CLOUD_TASKS_INVOKER_SA=cloud-tasks-invoker@test-proj.iam.gserviceaccount.com,SNEAT_PLATFORM=cloudrun,FOO=bar --set-secrets=A=P__A:latest --set-secrets=S=S:latest --project=test-proj"
hasnt "$deploy" "SNEAT_TASKS_BASE_URL"
hasnt "$deploy" "--service-account"
has "$(calls)" "run services update svc --region=europe-west3 --update-env-vars=SNEAT_TASKS_BASE_URL=https://svc-abc-ew.a.run.app,CLOUD_TASKS_OIDC_AUDIENCE=https://svc-abc-ew.a.run.app --project=test-proj"
has "$(calls)" "run services add-iam-policy-binding svc --region=europe-west3 --member=serviceAccount:cloud-tasks-invoker@test-proj.iam.gserviceaccount.com --role=roles/run.invoker --project=test-proj"
has "$OUT" "Existing service URL: <none: first deploy>"

# Steady state: the URL is injected into the single revision, nothing is patched.
reset; prep_deploy
echo "https://svc-abc-ew.a.run.app" > "$fake/service_url"
run_step "$D" "${deploy_env[@]}"
ok "steady-state deploy"
deploy="$(line_with 'run deploy svc')"
has "$deploy" "SNEAT_TASKS_BASE_URL=https://svc-abc-ew.a.run.app,CLOUD_TASKS_OIDC_AUDIENCE=https://svc-abc-ew.a.run.app"
[ "$(count_calls 'run services update')" = "0" ] || fail "no bootstrap patch when the URL exists"
has "$OUT" "Existing service URL: https://svc-abc-ew.a.run.app"

# The caller may override the platform values but never the URL pair; comments and blanks are ignored.
reset; prep_deploy
echo "https://svc-abc-ew.a.run.app" > "$fake/service_url"
run_step "$D" "${deploy_env[@]}" 'ENV_VARS_INPUT=# a comment

  GOOGLE_CLOUD_PROJECT=other
SNEAT_TASKS_BASE_URL=https://evil.example
EMPTY=
WITH_EQ=a=b'
ok "env overrides"
deploy="$(line_with 'run deploy svc')"
has "$deploy" "GOOGLE_CLOUD_PROJECT=other"
hasnt "$deploy" "GOOGLE_CLOUD_PROJECT=test-proj"
hasnt "$deploy" "evil.example"
has "$deploy" ",EMPTY=,WITH_EQ=a=b,"
[ "$(grep -o 'GOOGLE_CLOUD_PROJECT=' <<< "$deploy" | wc -l | tr -d ' ')" = "1" ] || fail "no duplicate keys"

reset; prep_deploy
run_step "$D" "${deploy_env[@]}" 'ENV_VARS_INPUT=A=1,2'; bad "comma in a value"
reset; prep_deploy
run_step "$D" "${deploy_env[@]}" 'ENV_VARS_INPUT=NO_EQUALS'; bad "line without ="
reset; prep_deploy
run_step "$D" "${deploy_env[@]}" 'ENV_VARS_INPUT=1BAD=x'; bad "bad name"
hasnt "$(calls)" "run deploy"

# Plain values from secrets, a dedicated runtime account and the instance limits.
reset; prep_deploy
printf 'PAIR_MATCHING_GAME_SECRET=hmac\n' > "$rt/env-from-secrets.txt"
run_step "$D" "${deploy_env[@]}" RUNTIME_SA=rt@test-proj.iam.gserviceaccount.com MIN_INSTANCES=1 MAX_INSTANCES=5 IMAGE=r.example/x/y
ok "plain secret values, service account, limits"
deploy="$(line_with 'run deploy svc')"
has "$deploy" "PAIR_MATCHING_GAME_SECRET=hmac"
has "$deploy" "--service-account=rt@test-proj.iam.gserviceaccount.com"
has "$deploy" "--min-instances=1 --max-instances=5"
has "$deploy" "--image=r.example/x/y:$SHA"
hasnt "$OUT" "hmac"

# No secret bindings at all still deploys.
reset
: > "$rt/env-from-secrets.txt"; : > "$rt/secret-flags.txt"
run_step "$D" "${deploy_env[@]}"
ok "no bindings"
hasnt "$(line_with 'run deploy svc')" "--set-secrets"

# A scheduler job needs CRON_SWEEP_SECRET before anything is deployed.
reset; prep_deploy
run_step "$D" "${deploy_env[@]}" CRON_SWEEP_SECRET= SCHEDULER_JOB=svc-cron
bad "scheduler needs the cron secret"
has "$OUT" "::error::CRON_SWEEP_SECRET must be configured as a GitHub secret before deployment"
hasnt "$(calls)" "run deploy"
reset; prep_deploy
run_step "$D" "${deploy_env[@]}" CRON_SWEEP_SECRET=
ok "no scheduler, no cron secret needed"
reset; prep_deploy
run_step "$D" "${deploy_env[@]}" CRON_SWEEP_SECRET= SCHEDULER_JOB=svc-cron DRY_RUN=true
ok "a dry run does not need the cron secret"
has "$OUT" "[dry-run] CRON_SWEEP_SECRET is not set; a real deploy would stop here"

# The invoker grant is a warning with the exact command.
reset; prep_deploy
run_step "$D" "${deploy_env[@]}" FAKE_FAIL_INVOKER=1
ok "invoker grant failure is not fatal"
has "$OUT" "::warning::could not grant roles/run.invoker on svc to cloud-tasks-invoker@test-proj.iam.gserviceaccount.com. Someone with IAM rights must run: gcloud run services add-iam-policy-binding svc --region=europe-west3 --member=serviceAccount:cloud-tasks-invoker@test-proj.iam.gserviceaccount.com --role=roles/run.invoker --project=test-proj"

# --- Scheduler ----------------------------------------------------------------------------

J="Configure Cloud Scheduler job"
sched_env=(CRON_SWEEP_SECRET=cron-secret SCHEDULER_JOB=svc-cron SCHEDULER_PATH=/v0/cron/sweep 'SCHEDULER_CRON=*/5 * * * *')
reset; echo "https://svc-abc-ew.a.run.app" > "$fake/service_url"
run_step "$J" "${sched_env[@]}" SCHEDULER_CREATE_PAUSED=false
ok "scheduler create"
create="$(line_with 'scheduler jobs create http svc-cron')"
has "$create" "--location=europe-west3 --project=test-proj --schedule=*/5 * * * * --time-zone=Etc/UTC --uri=https://svc-abc-ew.a.run.app/v0/cron/sweep --http-method=POST --attempt-deadline=300s --headers=X-Cron-Secret=cron-secret"
[ "$(count_calls 'scheduler jobs pause')" = "0" ] || fail "an unpaused job is not paused"

# Created paused: no header until the job is paused, so a tick in the window is rejected.
reset; echo "https://svc-abc-ew.a.run.app" > "$fake/service_url"
run_step "$J" "${sched_env[@]}" SCHEDULER_CREATE_PAUSED=true
ok "scheduler create paused"
sched_calls="$(grep 'scheduler jobs' "$fake/calls.log")"
[ "$(sed -n 1p <<< "$sched_calls")" = "gcloud scheduler jobs describe svc-cron --location=europe-west3 --project=test-proj" ] || fail "call 1 is describe"
create="$(sed -n 2p <<< "$sched_calls")"
has "$create" "scheduler jobs create http svc-cron --location=europe-west3 --project=test-proj --schedule=*/5 * * * * --time-zone=Etc/UTC --uri=https://svc-abc-ew.a.run.app/v0/cron/sweep --http-method=POST --attempt-deadline=300s"
hasnt "$create" "headers"
hasnt "$create" "cron-secret"
[ "$(sed -n 3p <<< "$sched_calls")" = "gcloud scheduler jobs pause svc-cron --location=europe-west3 --project=test-proj" ] || fail "call 3 is pause"
update="$(sed -n 4p <<< "$sched_calls")"
has "$update" "scheduler jobs update http svc-cron --location=europe-west3 --project=test-proj --update-headers=X-Cron-Secret=cron-secret"
[ "$(wc -l <<< "$sched_calls" | tr -d ' ')" = "4" ] || fail "exactly four scheduler calls"
has "$OUT" "Created svc-cron paused"
[ -f "$fake/scheduler/svc-cron" ] || fail "job kept"

# If pausing fails the job is deleted before the step fails, so a re-run recreates it paused.
reset; echo "https://svc-abc-ew.a.run.app" > "$fake/service_url"
run_step "$J" "${sched_env[@]}" SCHEDULER_CREATE_PAUSED=true FAKE_FAIL_PAUSE=1
bad "pause failure fails the step"
has "$OUT" "could not be created paused; deleting it"
sched_calls="$(grep 'scheduler jobs' "$fake/calls.log" | sed -E 's/ --.*//')"
[ "$sched_calls" = "gcloud scheduler jobs describe svc-cron
gcloud scheduler jobs create http svc-cron
gcloud scheduler jobs pause svc-cron
gcloud scheduler jobs delete svc-cron" ] || fail "order on pause failure: $sched_calls"
hasnt "$(calls)" "update-headers"
has "$(calls)" "scheduler jobs delete svc-cron --location=europe-west3 --project=test-proj --quiet"
[ ! -f "$fake/scheduler/svc-cron" ] || fail "job deleted"

# If the header update fails the job is deleted too.
reset; echo "https://svc-abc-ew.a.run.app" > "$fake/service_url"
run_step "$J" "${sched_env[@]}" SCHEDULER_CREATE_PAUSED=true FAKE_FAIL_HEADER=1
bad "header failure fails the step"
sched_calls="$(grep 'scheduler jobs' "$fake/calls.log" | sed -E 's/ --.*//')"
[ "$sched_calls" = "gcloud scheduler jobs describe svc-cron
gcloud scheduler jobs create http svc-cron
gcloud scheduler jobs pause svc-cron
gcloud scheduler jobs update http svc-cron
gcloud scheduler jobs delete svc-cron" ] || fail "order on header failure: $sched_calls"
[ ! -f "$fake/scheduler/svc-cron" ] || fail "job deleted after header failure"

# If the delete fails too, the step still fails and says how to delete by hand.
reset; echo "https://svc-abc-ew.a.run.app" > "$fake/service_url"
run_step "$J" "${sched_env[@]}" SCHEDULER_CREATE_PAUSED=true FAKE_FAIL_PAUSE=1 FAKE_FAIL_DELETE=1
bad "pause and delete failure"
has "$OUT" "::warning::could not delete svc-cron; delete it by hand before re-running: gcloud scheduler jobs delete svc-cron --location=europe-west3 --project=test-proj"

# An update never pauses or resumes, even when create-paused is set.
reset; echo "https://svc-abc-ew.a.run.app" > "$fake/service_url"; printf 'prior OIDC auth\n' > "$fake/scheduler/svc-cron"
run_step "$J" "${sched_env[@]}" SCHEDULER_CREATE_PAUSED=true SCHEDULER_PATH=/other
ok "scheduler update"
update="$(line_with 'scheduler jobs update http svc-cron')"
has "$update" "--uri=https://svc-abc-ew.a.run.app/other"
has "$update" "--clear-auth-token"
has "$update" "--update-headers=X-Cron-Secret=cron-secret"
[ "$(count_calls 'scheduler jobs create')" = "0" ] || fail "existing job is not recreated"
[ "$(count_calls 'scheduler jobs pause')" = "0" ] || fail "update must not pause"
[ "$(count_calls 'scheduler jobs resume')" = "0" ] || fail "update must not resume"

# OIDC jobs use explicit auth settings and remove the legacy cron header.
oidc_env=(SCHEDULER_OIDC_SERVICE_ACCOUNT=worker@test-proj.iam.gserviceaccount.com SCHEDULER_OIDC_AUDIENCE=https://svc.example/cron)
reset; echo "https://svc-abc-ew.a.run.app" > "$fake/service_url"
run_step "$J" "${sched_env[@]}" "${oidc_env[@]}" CRON_SWEEP_SECRET= SCHEDULER_CREATE_PAUSED=false
ok "OIDC scheduler create"
create="$(line_with 'scheduler jobs create http svc-cron')"
has "$create" "--oidc-service-account-email=worker@test-proj.iam.gserviceaccount.com --oidc-token-audience=https://svc.example/cron"
hasnt "$create" "X-Cron-Secret"
hasnt "$create" "cron-secret"

reset; echo "https://svc-abc-ew.a.run.app" > "$fake/service_url"; : > "$fake/scheduler/svc-cron"
run_step "$J" "${sched_env[@]}" "${oidc_env[@]}" SCHEDULER_CREATE_PAUSED=true
ok "OIDC scheduler update"
update="$(line_with 'scheduler jobs update http svc-cron')"
has "$update" "--clear-headers"
has "$update" "--oidc-service-account-email=worker@test-proj.iam.gserviceaccount.com --oidc-token-audience=https://svc.example/cron"
hasnt "$update" "--remove-headers"
hasnt "$(calls)" "cron-secret"
[ "$(count_calls 'scheduler jobs pause')" = "0" ] || fail "OIDC update must preserve state"

reset; echo "https://svc-abc-ew.a.run.app" > "$fake/service_url"
run_step "$J" "${sched_env[@]}" "${oidc_env[@]}" CRON_SWEEP_SECRET= SCHEDULER_CREATE_PAUSED=true
ok "OIDC scheduler create paused"
sched_calls="$(grep 'scheduler jobs' "$fake/calls.log")"
create="$(sed -n 2p <<< "$sched_calls")"
hasnt "$create" "oidc"
hasnt "$create" "headers"
[ "$(sed -n 3p <<< "$sched_calls")" = "gcloud scheduler jobs pause svc-cron --location=europe-west3 --project=test-proj" ] || fail "OIDC pause happens before auth"
update="$(sed -n 4p <<< "$sched_calls")"
has "$update" "--clear-headers"
has "$update" "--oidc-service-account-email=worker@test-proj.iam.gserviceaccount.com --oidc-token-audience=https://svc.example/cron"
hasnt "$update" "--remove-headers"
hasnt "$update" "cron-secret"

reset; echo "https://svc-abc-ew.a.run.app" > "$fake/service_url"
run_step "$J" "${sched_env[@]}" "${oidc_env[@]}" SCHEDULER_CREATE_PAUSED=true FAKE_FAIL_HEADER=1
bad "OIDC attachment failure fails the step"
sched_calls="$(grep 'scheduler jobs' "$fake/calls.log" | sed -E 's/ --.*//')"
has "$sched_calls" "gcloud scheduler jobs pause svc-cron"
has "$sched_calls" "gcloud scheduler jobs update http svc-cron"
has "$sched_calls" "gcloud scheduler jobs delete svc-cron"
[ ! -f "$fake/scheduler/svc-cron" ] || fail "job deleted after OIDC attachment failure"

# --- Firestore TTLs -----------------------------------------------------------------------

T="Configure Firestore expiry policies"
reset
run_step "$T" "FIRESTORE_TTLS=$(cat "$fixtures/firestore-ttls.txt")"
ok "ttls"
[ "$(cat "$fake/calls.log")" = "gcloud firestore fields ttls update expiresAt --collection-group=sso-flows --enable-ttl --async --quiet --project=test-proj
gcloud firestore fields ttls update expiresAt --collection-group=sso-exchanges --enable-ttl --async --quiet --project=test-proj
gcloud firestore fields ttls update expiresAt --collection-group=detectiveQuerySnapshots --enable-ttl --async --quiet --project=test-proj" ] || fail "ttl commands"
reset
run_step "$T" 'FIRESTORE_TTLS=# note

 grp:field '
ok "ttl comments and blanks"
[ "$(count_calls 'ttls update')" = "1" ] || fail "one ttl command"
has "$(calls)" "ttls update field --collection-group=grp"

# --- Service URL and revision -----------------------------------------------------------------

U="Show service URL and revision"
reset; echo "https://svc-abc-ew.a.run.app" > "$fake/service_url"
run_step "$U"
ok "revision line"
has "$OUT" "Service deployed to: https://svc-abc-ew.a.run.app"
has "$OUT" "Deployed revision: service=svc revision=rev-00001 commit=$SHA url=https://svc-abc-ew.a.run.app"
[ "$(cat "$work/gh_output")" = "service_url=https://svc-abc-ew.a.run.app
revision=rev-00001" ] || fail "step outputs"
has "$(cat "$work/summary")" "Deployed revision: service=svc revision=rev-00001"

# --- Health and validation -------------------------------------------------------------------------

H="Verify Cloud Run service and datastore health"
reset
run_step "$H" SERVICE_URL=https://x HEALTH_EXPECT="Firestore write: OK" FAKE_CURL_CODE=200 "FAKE_CURL_BODY=ok. Firestore write: OK"
ok "healthy"
reset
run_step "$H" SERVICE_URL=https://x HEALTH_EXPECT="Firestore write: OK" FAKE_CURL_CODE=200 "FAKE_CURL_BODY=ok"
bad "marker missing"
has "$OUT" "did not contain the expected text: Firestore write: OK"
reset
run_step "$H" SERVICE_URL=https://x HEALTH_EXPECT="" FAKE_CURL_CODE=200 "FAKE_CURL_BODY=anything"
ok "no marker required"
reset
run_step "$H" SERVICE_URL=https://x HEALTH_EXPECT="" FAKE_CURL_CODE=503
bad "unhealthy"
has "$OUT" "health check failed (HTTP 503)"

VAL="Validate deployment"
val_ok='{"status":"ok","checks":[{"status":"ok","name":"getMe","message":"fine"}]}'
reset
run_step "$VAL" SERVICE_URL=https://x VALIDATE_PATH=/cicd/validate CICD_VALIDATE_TOKEN=tok "FAKE_CURL_BODY=$val_ok"
ok "validation ok"
has "$OUT" "Overall validation status: ok"
reset
run_step "$VAL" SERVICE_URL=https://x VALIDATE_PATH=/cicd/validate CICD_VALIDATE_TOKEN=tok \
  'FAKE_CURL_BODY={"status":"warning","checks":[{"status":"warning","name":"w","message":"m"}]}'
ok "validation warning passes"
has "$OUT" "::warning::Deployment validation has warnings"
reset
run_step "$VAL" SERVICE_URL=https://x VALIDATE_PATH=/cicd/validate CICD_VALIDATE_TOKEN=tok \
  'FAKE_CURL_BODY={"status":"error","checks":[{"status":"error","name":"e","message":"m"}]}'
bad "validation error"
has "$OUT" "Deployment validation FAILED (1 error checks)"
reset
run_step "$VAL" SERVICE_URL=https://x VALIDATE_PATH=/cicd/validate CICD_VALIDATE_TOKEN= "FAKE_CURL_BODY=$val_ok"
bad "validation token required"
reset
run_step "$VAL" SERVICE_URL=https://x VALIDATE_PATH=/cicd/validate CICD_VALIDATE_TOKEN=tok FAKE_CURL_CODE=502
bad "validation unreachable"
has "$OUT" "/cicd/validate is unreachable (HTTP 502)"

# --- Validated CI binary --------------------------------------------------------------------------------

VB="Verify validated binary"
make_artifact() { # make_artifact <dir> <sha-in-file>
  mkdir -p "$1"
  printf 'binary-bytes' > "$1/app"
  printf '%s' "$2" > "$1/app.source-sha"
  printf '%s  app\n' "$(shasum -a 256 "$1/app" | cut -d' ' -f1)" > "$1/app.sha256"
}
reset; art="$work/art"; rm -rf "$art" "$sandbox"/app; make_artifact "$art" "$SHA"
run_step "$VB" ARTIFACT_DIR="$art" BINARY_NAME=app
ok "validated binary installs"
[ -x "$sandbox/app" ] || fail "binary installed"
reset; art="$work/art2"; rm -rf "$art" "$sandbox"/app; make_artifact "$art" "ffffffffffffffffffffffffffffffffffffffff"
run_step "$VB" ARTIFACT_DIR="$art" BINARY_NAME=app
bad "source sha mismatch"
[ ! -e "$sandbox/app" ] || fail "nothing installed on mismatch"
reset; art="$work/art3"; rm -rf "$art"; make_artifact "$art" "$SHA"
printf 'tampered' > "$art/app"
run_step "$VB" ARTIFACT_DIR="$art" BINARY_NAME=app
bad "checksum mismatch"
reset; art="$work/art4"; rm -rf "$art"; make_artifact "$art" "$SHA"
printf '%s  other-file\n' "$(shasum -a 256 "$art/app" | cut -d' ' -f1)" > "$art/app.sha256"
run_step "$VB" ARTIFACT_DIR="$art" BINARY_NAME=app
bad "checksum file naming another path"
reset; art="$work/art5"; rm -rf "$art"; make_artifact "$art" "$SHA"
rm "$art/app.sha256"; ln -s /etc/hosts "$art/app.sha256"
run_step "$VB" ARTIFACT_DIR="$art" BINARY_NAME=app
bad "symlinked checksum"

VS="Verify canonical CI artifact source"
git init -q "$sandbox/repo"
git -C "$sandbox/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
head_sha="$(git -C "$sandbox/repo" rev-parse HEAD)"
src_ok=(SOURCE_EVENT=push SOURCE_REPOSITORY=sneat-co/fixture SOURCE_BRANCH=main SOURCE_CONCLUSION=success DEPLOY_SHA="$head_sha")
reset; (cd "$sandbox/repo" && true)
set +e
OUT="$(cd "$sandbox/repo" && env -i PATH="$PATH" GITHUB_REPOSITORY=sneat-co/fixture "${src_ok[@]}" bash -e <(yq -r ".jobs.deploy.steps[] | select(.name == \"$VS\") | .run" "$workflow") 2>&1)"; CODE=$?
set -e
ok "canonical source accepted"
for bad_env in SOURCE_EVENT=pull_request SOURCE_REPOSITORY=fork/fixture SOURCE_BRANCH=dev SOURCE_CONCLUSION=failure DEPLOY_SHA=0123456789abcdef0123456789abcdef01234567; do
  set +e
  OUT="$(cd "$sandbox/repo" && env -i PATH="$PATH" GITHUB_REPOSITORY=sneat-co/fixture "${src_ok[@]}" "$bad_env" bash -e <(yq -r ".jobs.deploy.steps[] | select(.name == \"$VS\") | .run" "$workflow") 2>&1)"; CODE=$?
  set -e
  bad "source check ${bad_env%%=*}"
done

# --- sneat-go equivalence (task-9 depends on this) ---------------------------------------------------------
#
# With an empty prefix, today's sync list as owned secrets and the six
# bound-but-never-synced secrets as shared ones, the set of bindings must equal
# the set deploy-cloudrun.yml binds today (every secret that exists in Secret
# Manager), and every required secret must still block the deploy when missing.

owned="$(tr '\n' ' ' < "$fixtures/owned-secrets.txt")"
shared="$(tr '\n' ' ' < "$fixtures/shared-secrets.txt")"
required="$(tr '\n' ' ' < "$fixtures/required-secrets.txt")"

reset
while IFS= read -r name; do put_secret "$name" "x"; done < "$fixtures/bound-secrets.txt"
run_step "$R" OWNED_SECRETS="$owned" SHARED_SECRETS="$shared" REQUIRED_SECRETS="$required"
ok "sneat-go bindings"
sort "$rt/secret-flags.txt" > "$work/new-flags.txt"
sed 's/.*/--set-secrets=&=&:latest/' "$fixtures/bound-secrets.txt" | sort > "$work/old-flags.txt"
diff "$work/old-flags.txt" "$work/new-flags.txt" || fail "sneat-go binding set differs from today's"
[ "$(wc -l < "$work/new-flags.txt" | tr -d ' ')" = "61" ] || fail "61 bindings expected"

# Optional secrets that do not exist are skipped, as today.
reset
while IFS= read -r name; do put_secret "$name" "x"; done < "$fixtures/required-secrets.txt"
run_step "$R" OWNED_SECRETS="$owned" SHARED_SECRETS="$shared" REQUIRED_SECRETS="$required"
ok "only required secrets exist"
[ "$(wc -l < "$rt/secret-flags.txt" | tr -d ' ')" = "12" ] || fail "12 bindings when only the required exist"

# Each required secret, missing on its own, blocks the deploy.
while IFS= read -r missing; do
  reset
  while IFS= read -r name; do
    [ "$name" = "$missing" ] || put_secret "$name" "x"
  done < "$fixtures/bound-secrets.txt"
  run_step "$R" OWNED_SECRETS="$owned" SHARED_SECRETS="$shared" REQUIRED_SECRETS="$required"
  bad "required $missing missing"
  has "$OUT" "$missing"
done < "$fixtures/required-secrets.txt"

# The sneat-go sync step, with an empty prefix, writes to the same Secret Manager names.
reset
run_step "$S" OWNED_SECRETS="TELEGRAM_BOT_TOKEN_SNEATBOT CRON_SWEEP_SECRET" 'ALL_SECRETS_JSON={"TELEGRAM_BOT_TOKEN_SNEATBOT":"t","CRON_SWEEP_SECRET":"c","POSTHOG_API_KEY":"p"}'
ok "sneat-go sync names"
[ -f "$fake/secrets/TELEGRAM_BOT_TOKEN_SNEATBOT" ] && [ -f "$fake/secrets/CRON_SWEEP_SECRET" ] || fail "unprefixed names"
[ ! -f "$fake/secrets/POSTHOG_API_KEY" ] || fail "a secret outside owned_secrets is never written"

# --- Dry run, end to end -------------------------------------------------------------------------------------------

reset
run_step "Install dry-run shims" GITHUB_PATH="$work/gh_path"
ok "install shims"
shim_dir="$(cat "$work/gh_path")"
[ -x "$shim_dir/gcloud" ] && [ -x "$shim_dir/docker" ] || fail "shims installed"
dry() { # dry "<step>" [VAR=value ...]: runs with the shims first on PATH and no fake gcloud
  local name="$1"; shift
  local script="$work/dry-step.sh"
  yq -r ".jobs.deploy.steps[] | select(.name == \"$name\") | .run" "$workflow" > "$script"
  set +e
  OUT="$(cd "$sandbox" && env -i PATH="$shim_dir:/usr/bin:/bin:/opt/homebrew/bin" HOME="$work" RUNNER_TEMP="$rt" \
    GITHUB_OUTPUT="$work/gh_output" GITHUB_STEP_SUMMARY="$work/summary" \
    GCLOUD_PROJECT_ID=test-proj GCLOUD_REGION=europe-west3 SERVICE_NAME=svc DEPLOY_SHA="$SHA" DRY_RUN=true \
    SECRET_PREFIX=P__ OWNED_SECRETS="A" SHARED_SECRETS="S" REQUIRED_SECRETS= SECRET_BINDINGS= ENV_VARS_INPUT= ENV_FROM_SECRETS=PLAIN RUNTIME_SA= SCHEDULER_JOB=svc-cron \
    SCHEDULER_OIDC_SERVICE_ACCOUNT= SCHEDULER_OIDC_AUDIENCE= \
    "$@" bash -e "$script" 2>&1)"
  CODE=$?
  set -e
  ok "dry-run step $name"
}
dry "Sync tokens from GitHub secrets to Secret Manager" 'ALL_SECRETS_JSON={"A":"super-secret-a"}'
dry "Collect plain environment values from secrets" 'ALL_SECRETS_JSON={"PLAIN":"plain-secret-value"}'
dry "Configure Docker for Artifact Registry"
dry "Build Docker image" IMAGE=
dry "Push Docker image" IMAGE=
dry "Resolve secret bindings" 'SECRET_BINDINGS=MAP=explicit-secret:7'
dry "Check runtime service account access"
dry "Deploy to Cloud Run" CRON_SWEEP_SECRET=cron-secret-value ENV_VARS_INPUT=SNEAT_PLATFORM=cloudrun IMAGE= MIN_INSTANCES=0 MAX_INSTANCES=2
dry "Configure Cloud Scheduler job" CRON_SWEEP_SECRET=cron-secret-value SCHEDULER_PATH=/v0/cron/sweep 'SCHEDULER_CRON=*/5 * * * *' SCHEDULER_CREATE_PAUSED=true
dry "Configure Cloud Scheduler job" CRON_SWEEP_SECRET= SCHEDULER_PATH=/v0/cron/sweep 'SCHEDULER_CRON=*/5 * * * *' SCHEDULER_CREATE_PAUSED=true SCHEDULER_OIDC_SERVICE_ACCOUNT=worker@test-proj.iam.gserviceaccount.com SCHEDULER_OIDC_AUDIENCE=https://svc.example/cron
dry "Configure Firestore expiry policies" 'FIRESTORE_TTLS=grp:field'
dry "Show service URL and revision"
dry "Dry-run plan" SERVICE_URL=https://svc-dry-run.a.run.app VALIDATE_PATH=/cicd/validate
plan="$(cat "$rt/dry-run-plan.log")"
has "$plan" "docker build -t europe-west3-docker.pkg.dev/test-proj/cloud-run/svc:$SHA -t europe-west3-docker.pkg.dev/test-proj/cloud-run/svc:latest ."
has "$plan" "gcloud run deploy svc --image=europe-west3-docker.pkg.dev/test-proj/cloud-run/svc:$SHA"
has "$plan" "--set-secrets=A=P__A:latest --set-secrets=S=S:latest"
has "$plan" "--set-secrets=MAP=explicit-secret:7"
has "$plan" "gcloud scheduler jobs create http svc-cron"
has "$plan" "gcloud scheduler jobs pause svc-cron"
has "$plan" "gcloud firestore fields ttls update field --collection-group=grp"
has "$plan" "--set-env-vars=<GOOGLE_CLOUD_PROJECT,FIREBASE_PROJECT_ID,CLOUD_TASKS_LOCATION,CLOUD_TASKS_INVOKER_SA,SNEAT_PLATFORM,PLAIN,SNEAT_TASKS_BASE_URL,CLOUD_TASKS_OIDC_AUDIENCE>"
has "$plan" "--update-headers=<redacted>"
has "$plan" "--oidc-service-account-email=worker@test-proj.iam.gserviceaccount.com --oidc-token-audience=https://svc.example/cron"
hasnt "$plan" "explicit-secret-value"
hasnt "$(grep 'scheduler jobs create' <<< "$plan")" "headers"
for leaked in super-secret-a plain-secret-value cron-secret-value; do
  hasnt "$plan" "$leaked"
  hasnt "$(cat "$work/summary")" "$leaked"
done

echo "OK: ${checks} cloudrun-deploy step runs passed"
