#!/usr/bin/env bash
set -euo pipefail

# Creates and pushes idempotent, validated annotated Git tags for one or more
# Go modules living in subdirectories of the current repository, in the
# `<module-dir>/v<version>` shape (https://go.dev/ref/mod#vcs-version).
#
# Two-phase, fail-closed: EVERY pair is validated (and checked for a
# conflicting existing tag) before ANY tag is created or pushed. One bad pair
# in a batch never leaves earlier pairs half-tagged.
#
# Required env:
#   GO_MODULE_TAGS_MODULES  JSON array of {"dir": "...", "version": "..."}
#   GITHUB_REPOSITORY       "<owner>/<repo>", e.g. sneat-co/sneat-ext-contracts
# Optional env:
#   GO_MODULE_TAGS_REF      commit-ish to tag (default: HEAD)
#   GO_MODULE_TAGS_REMOTE   git remote to check/push against (default: origin)
#   GITHUB_STEP_SUMMARY     appended with the tag -> SHA receipt table if set

modules_json="${GO_MODULE_TAGS_MODULES:?GO_MODULE_TAGS_MODULES is required}"
repository="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required (owner/repo)}"
ref="${GO_MODULE_TAGS_REF:-HEAD}"
remote="${GO_MODULE_TAGS_REMOTE:-origin}"

if ! command -v jq >/dev/null 2>&1; then
  echo "::error::jq is required" >&2
  exit 1
fi

if ! jq empty >/dev/null 2>&1 <<<"$modules_json"; then
  echo "::error::modules input is not valid JSON: $modules_json" >&2
  exit 1
fi

if [[ "$(jq -r 'type' <<<"$modules_json")" != "array" ]]; then
  echo "::error::modules input must be a JSON array" >&2
  exit 1
fi

module_count="$(jq 'length' <<<"$modules_json")"
if [[ "$module_count" -eq 0 ]]; then
  echo "::error::modules input must be a non-empty JSON array" >&2
  exit 1
fi

if ! resolved_ref="$(git rev-parse --verify "${ref}^{commit}" 2>/dev/null)"; then
  echo "::error::ref '$ref' does not resolve to a commit in this checkout" >&2
  exit 1
fi

# A safe relative module directory: no leading slash, no '.' segments, no '..'
# traversal. Rejects "." itself -- the <dir>/v<version> tag shape requires a
# real subdirectory name.
dir_pattern='^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$'
# Semver 2.0-ish, deliberately with NO leading "v" -- that prefix belongs to
# the tag, never to the input version.
version_pattern='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'

declare -a dirs=() versions=() tags=()
errors=0

for i in $(seq 0 $((module_count - 1))); do
  entry="$(jq -c ".[$i]" <<<"$modules_json")"
  dir="$(jq -r 'if (.dir? // empty) == "" then "" else .dir end' <<<"$entry")"
  version="$(jq -r 'if (.version? // empty) == "" then "" else .version end' <<<"$entry")"

  if [[ -z "$dir" || -z "$version" ]]; then
    echo "::error::modules[$i] must set both a non-empty dir and version: $entry" >&2
    errors=$((errors + 1))
    continue
  fi

  dir="${dir%/}"
  if [[ "$dir" == "." || "$dir" == *".."* || ! "$dir" =~ $dir_pattern ]]; then
    echo "::error::modules[$i] dir '$dir' is not a safe relative module directory" >&2
    errors=$((errors + 1))
    continue
  fi

  if [[ ! "$version" =~ $version_pattern ]]; then
    echo "::error::modules[$i] version '$version' must be semver WITHOUT a leading v (e.g. 1.2.3, not v1.2.3)" >&2
    errors=$((errors + 1))
    continue
  fi

  gomod="$dir/go.mod"
  if ! git cat-file -e "${resolved_ref}:${gomod}" 2>/dev/null; then
    echo "::error::modules[$i] $gomod not found at $resolved_ref" >&2
    errors=$((errors + 1))
    continue
  fi

  actual_module="$(git show "${resolved_ref}:${gomod}" | awk '$1 == "module" { print $2; exit }')"
  expected_module="github.com/${repository}/${dir}"
  if [[ "$actual_module" != "$expected_module" ]]; then
    echo "::error::modules[$i] $gomod declares module '$actual_module', expected '$expected_module' -- path drift here would poison the Go proxy" >&2
    errors=$((errors + 1))
    continue
  fi

  dirs+=("$dir")
  versions+=("$version")
  tags+=("${dir}/v${version}")
done

if [[ "$errors" -gt 0 ]]; then
  echo "::error::$errors module pair(s) failed validation; no tags were created or pushed" >&2
  exit 1
fi

# Peel a `git ls-remote` listing to the commit SHA for a given tag: an
# annotated tag's raw ref points at the tag object, so the "^{}" peeled entry
# (present only for annotated tags) is the one that names the commit.
resolve_remote_tag_commit() {
  local tag="$1" listing peeled raw
  listing="$(git ls-remote "$remote" "refs/tags/${tag}" "refs/tags/${tag}^{}" 2>/dev/null || true)"
  [[ -z "$listing" ]] && return 1
  peeled="$(awk -v t="refs/tags/${tag}^{}" '$2 == t { print $1 }' <<<"$listing")"
  raw="$(awk -v t="refs/tags/${tag}" '$2 == t { print $1 }' <<<"$listing")"
  if [[ -n "$peeled" ]]; then
    printf '%s\n' "$peeled"
  else
    printf '%s\n' "$raw"
  fi
}

declare -a to_create_idx=()
for idx in "${!tags[@]}"; do
  tag="${tags[$idx]}"
  if existing_sha="$(resolve_remote_tag_commit "$tag")" && [[ -n "$existing_sha" ]]; then
    if [[ "$existing_sha" == "$resolved_ref" ]]; then
      echo "::notice::tag $tag already points at $resolved_ref -- skipping (idempotent)"
    else
      echo "::error::tag $tag already exists at $existing_sha; refusing to move it to $resolved_ref" >&2
      errors=$((errors + 1))
    fi
  else
    to_create_idx+=("$idx")
  fi
done

if [[ "$errors" -gt 0 ]]; then
  echo "::error::$errors tag(s) already exist at a different commit; no tags were created or pushed" >&2
  exit 1
fi

if [[ "${#to_create_idx[@]}" -gt 0 ]]; then
  declare -a push_refs=()
  for idx in "${to_create_idx[@]}"; do
    dir="${dirs[$idx]}"
    version="${versions[$idx]}"
    tag="${tags[$idx]}"
    git -c user.name="Sneat CI" -c user.email="ci@sneat.co" \
      tag -a "$tag" -m "Release ${dir} v${version}" "$resolved_ref"
    push_refs+=("refs/tags/${tag}")
  done
  git push "$remote" "${push_refs[@]}"
fi

declare -a summary_rows=()
for idx in "${!tags[@]}"; do
  tag="${tags[$idx]}"
  if ! final_sha="$(resolve_remote_tag_commit "$tag")" || [[ -z "$final_sha" ]]; then
    echo "::error::post-push verification failed for $tag: tag not found on $remote" >&2
    exit 1
  fi
  if [[ "$final_sha" != "$resolved_ref" ]]; then
    echo "::error::post-push verification failed for $tag: $remote resolves it to $final_sha, expected $resolved_ref" >&2
    exit 1
  fi
  summary_rows+=("| \`${tag}\` | \`${final_sha}\` |")
done

summary="$(
  {
    echo "### Go module tags"
    echo ""
    echo "| Tag | SHA |"
    echo "|---|---|"
    printf '%s\n' "${summary_rows[@]}"
  }
)"
echo "$summary"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  echo "$summary" >>"$GITHUB_STEP_SUMMARY"
fi
