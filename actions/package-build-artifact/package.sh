#!/usr/bin/env bash
set -euo pipefail

name="${ARTIFACT_NAME:?ARTIFACT_NAME is required}"
paths="${ARTIFACT_PATHS:?ARTIFACT_PATHS is required}"
source_sha="${ARTIFACT_SOURCE_SHA:?ARTIFACT_SOURCE_SHA is required}"
workspace="${GITHUB_WORKSPACE:-$PWD}"
runner_temp="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
output_dir="${runner_temp%/}/sneat-build-artifact-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${name}"
paths_file="${output_dir}.paths"

if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "artifact name may contain only letters, numbers, dots, underscores and hyphens" >&2
  exit 1
fi
if [[ ! "$source_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "source SHA must be a full 40-character Git commit SHA" >&2
  exit 1
fi

mkdir -p "$output_dir"
: > "$paths_file"
while IFS= read -r path || [[ -n "$path" ]]; do
  path="${path%$'\r'}"
  [[ -z "$path" ]] && continue
  if [[ "$path" == /* || "$path" =~ (^|/)\.\.(/|$) ]]; then
    echo "artifact path must stay inside the repository: $path" >&2
    exit 1
  fi
  if [[ ! -e "$workspace/$path" ]]; then
    echo "artifact path does not exist: $path" >&2
    exit 1
  fi
  printf '%s\n' "$path" >> "$paths_file"
done <<< "$paths"

if [[ ! -s "$paths_file" ]]; then
  echo "at least one artifact path is required" >&2
  exit 1
fi

(
  cd "$workspace"
  if tar --version 2>/dev/null | grep -q 'GNU tar'; then
    tar --create \
      --sort=name \
      --mtime='UTC 1970-01-01' \
      --owner=0 \
      --group=0 \
      --numeric-owner \
      --verbatim-files-from \
      --files-from="$paths_file" \
      | gzip --no-name > "$output_dir/payload.tar.gz"
  else
    # Portable fallback for local macOS validation. GitHub's Ubuntu runners use
    # the deterministic GNU tar branch above.
    tar --create --file=- --files-from="$paths_file" \
      | gzip --no-name > "$output_dir/payload.tar.gz"
  fi
)

(
  cd "$output_dir"
  sha256sum payload.tar.gz > payload.tar.gz.sha256
)
printf '%s\n' "$source_sha" > "$output_dir/source-sha"
jq -n \
  --arg artifact "$name" \
  --arg source_sha "$source_sha" \
  --arg repository "${GITHUB_REPOSITORY:-local}" \
  --arg run_id "${GITHUB_RUN_ID:-local}" \
  '{schema_version: 1, artifact: $artifact, source_sha: $source_sha, repository: $repository, run_id: $run_id}' \
  > "$output_dir/manifest.json"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  printf 'directory=%s\n' "$output_dir" >> "$GITHUB_OUTPUT"
fi
echo "Packaged $name from $(wc -l < "$paths_file" | tr -d ' ') path(s) at source $source_sha"
