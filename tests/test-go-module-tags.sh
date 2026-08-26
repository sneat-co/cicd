#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
script="$repo_root/actions/go-module-tags/tag-modules.sh"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

origin="$fixture/origin.git"
work="$fixture/work"
git init --quiet --bare --initial-branch=main "$origin"
git clone --quiet "$origin" "$work"
git -C "$work" config user.email "fixture@example.invalid"
git -C "$work" config user.name "Fixture"

export GITHUB_REPOSITORY="sneat-co/fixture-repo"

resolved_tag_sha() {
  # Prints the commit SHA a tag resolves to on origin, or nothing if absent.
  local tag="$1" listing peeled raw
  listing="$(git -C "$work" ls-remote origin "refs/tags/${tag}" "refs/tags/${tag}^{}" 2>/dev/null || true)"
  [[ -z "$listing" ]] && return 0
  peeled="$(awk -v t="refs/tags/${tag}^{}" '$2 == t { print $1 }' <<<"$listing")"
  raw="$(awk -v t="refs/tags/${tag}" '$2 == t { print $1 }' <<<"$listing")"
  if [[ -n "$peeled" ]]; then printf '%s\n' "$peeled"; else printf '%s\n' "$raw"; fi
}

run_script() {
  # run_script <modules-json> [ref]
  local modules="$1" ref="${2:-HEAD}" code output
  set +e
  output="$(cd "$work" && GO_MODULE_TAGS_MODULES="$modules" GO_MODULE_TAGS_REF="$ref" "$script" 2>&1)"
  code=$?
  set -e
  LAST_OUTPUT="$output"
  LAST_CODE="$code"
}

fail() {
  echo "FAIL: $1" >&2
  echo "--- last script output ---" >&2
  echo "${LAST_OUTPUT:-<none>}" >&2
  exit 1
}

# --- fixture content -------------------------------------------------------

mkdir -p "$work/contactus"
cat >"$work/contactus/go.mod" <<'EOF'
module github.com/sneat-co/fixture-repo/contactus

go 1.26
EOF

mkdir -p "$work/wrongmod"
cat >"$work/wrongmod/go.mod" <<'EOF'
module github.com/sneat-co/some-other-repo/wrongmod

go 1.26
EOF

git -C "$work" add -A
git -C "$work" commit --quiet -m "seed contactus and wrongmod modules"
git -C "$work" push --quiet origin main
seed_sha="$(git -C "$work" rev-parse HEAD)"

# --- 1. first tag: created and pushed at the right commit -------------------

run_script '[{"dir":"contactus","version":"1.0.0"}]'
[[ "$LAST_CODE" -eq 0 ]] || fail "expected first tag creation to succeed"
[[ "$(resolved_tag_sha contactus/v1.0.0)" == "$seed_sha" ]] ||
  fail "expected contactus/v1.0.0 to resolve to $seed_sha"
grep -qF 'contactus/v1.0.0' <<<"$LAST_OUTPUT" || fail "expected tag in summary output"

# --- 2. idempotent re-run: same pair, same commit succeeds with a notice ----

run_script '[{"dir":"contactus","version":"1.0.0"}]'
[[ "$LAST_CODE" -eq 0 ]] || fail "expected idempotent re-run to succeed"
grep -qi 'already points' <<<"$LAST_OUTPUT" || fail "expected an idempotent notice"

# --- 3. tag exists at a DIFFERENT commit: must fail and never move it ------

echo "more" >>"$work/contactus/go.mod"
git -C "$work" commit --quiet -am "advance contactus"
git -C "$work" push --quiet origin main
advanced_sha="$(git -C "$work" rev-parse HEAD)"

run_script '[{"dir":"contactus","version":"1.0.0"}]'
[[ "$LAST_CODE" -ne 0 ]] || fail "expected re-tagging at a different commit to fail"
[[ "$(resolved_tag_sha contactus/v1.0.0)" == "$seed_sha" ]] ||
  fail "tag must not have moved off $seed_sha"
[[ "$(resolved_tag_sha contactus/v1.0.0)" != "$advanced_sha" ]] ||
  fail "tag must not have moved onto $advanced_sha"

# --- 4. module path mismatch: rejected, no tag created ----------------------

run_script '[{"dir":"wrongmod","version":"0.1.0"}]' "$advanced_sha"
[[ "$LAST_CODE" -ne 0 ]] || fail "expected module path mismatch to fail"
grep -qi 'expected' <<<"$LAST_OUTPUT" || fail "expected a module-path mismatch message"
[[ -z "$(resolved_tag_sha wrongmod/v0.1.0)" ]] || fail "wrongmod/v0.1.0 must not exist"

# --- 5. missing go.mod: rejected, no tag created ----------------------------

run_script '[{"dir":"nonexistent","version":"0.1.0"}]' "$advanced_sha"
[[ "$LAST_CODE" -ne 0 ]] || fail "expected a missing go.mod to fail"
[[ -z "$(resolved_tag_sha nonexistent/v0.1.0)" ]] || fail "nonexistent/v0.1.0 must not exist"

# --- 6. version with a leading 'v' is rejected ------------------------------

run_script '[{"dir":"contactus","version":"v1.1.0"}]' "$advanced_sha"
[[ "$LAST_CODE" -ne 0 ]] || fail "expected a v-prefixed version to be rejected"
[[ -z "$(resolved_tag_sha 'contactus/vv1.1.0')" ]] || fail "malformed tag must not exist"

# --- 7. directory traversal is rejected -------------------------------------

run_script '[{"dir":"../evil","version":"1.0.0"}]' "$advanced_sha"
[[ "$LAST_CODE" -ne 0 ]] || fail "expected a traversal dir to be rejected"

# --- 8. batch atomicity: one good + one bad pair -> NEITHER tag lands -------

run_script '[{"dir":"contactus","version":"2.0.0"},{"dir":"wrongmod","version":"0.1.0"}]' "$advanced_sha"
[[ "$LAST_CODE" -ne 0 ]] || fail "expected the mixed batch to fail"
[[ -z "$(resolved_tag_sha contactus/v2.0.0)" ]] ||
  fail "contactus/v2.0.0 must not exist -- one bad pair must block the whole batch"
[[ -z "$(resolved_tag_sha wrongmod/v0.1.0)" ]] || fail "wrongmod/v0.1.0 must not exist"

# --- 9. the good pair alone, at the advanced commit, still succeeds --------

run_script '[{"dir":"contactus","version":"2.0.0"}]' "$advanced_sha"
[[ "$LAST_CODE" -eq 0 ]] || fail "expected contactus/v2.0.0 alone to succeed"
[[ "$(resolved_tag_sha contactus/v2.0.0)" == "$advanced_sha" ]] ||
  fail "expected contactus/v2.0.0 to resolve to $advanced_sha"

echo "go-module-tags tests passed"
