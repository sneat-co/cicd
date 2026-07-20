#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${ARTIFACT_DIRECTORY:?ARTIFACT_DIRECTORY is required}"
expected_name="${ARTIFACT_EXPECTED_NAME:?ARTIFACT_EXPECTED_NAME is required}"
expected_sha="${ARTIFACT_EXPECTED_SOURCE_SHA:?ARTIFACT_EXPECTED_SOURCE_SHA is required}"
workspace="${GITHUB_WORKSPACE:-$PWD}"

test -f "$artifact_dir/payload.tar.gz"
test -f "$artifact_dir/payload.tar.gz.sha256"
test -f "$artifact_dir/source-sha"
test -f "$artifact_dir/manifest.json"

actual_sha="$(tr -d '\r\n' < "$artifact_dir/source-sha")"
manifest_name="$(jq -r '.artifact' "$artifact_dir/manifest.json")"
manifest_sha="$(jq -r '.source_sha' "$artifact_dir/manifest.json")"
if [[ "$actual_sha" != "$expected_sha" || "$manifest_sha" != "$expected_sha" ]]; then
  echo "artifact source SHA mismatch: expected $expected_sha, got $actual_sha / $manifest_sha" >&2
  exit 1
fi
if [[ "$manifest_name" != "$expected_name" ]]; then
  echo "artifact name mismatch: expected $expected_name, got $manifest_name" >&2
  exit 1
fi

(
  cd "$artifact_dir"
  sha256sum --check payload.tar.gz.sha256
)

while IFS= read -r path; do
  if [[ "$path" == /* || "$path" =~ (^|/)\.\.(/|$) ]]; then
    echo "unsafe path in artifact: $path" >&2
    exit 1
  fi
done < <(tar --list --gzip --file "$artifact_dir/payload.tar.gz")

tar --extract --gzip --file "$artifact_dir/payload.tar.gz" --directory "$workspace"
echo "Restored $expected_name built from $expected_sha"
