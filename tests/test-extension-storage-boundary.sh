#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy="${repo_root}/policy/sneat-backend.yaml"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

write_module() {
	local directory="$1"
	local module="$2"
	local import_path="$3"
	mkdir -p "${directory}"
	printf 'module %s\n\ngo 1.26\n' "${module}" > "${directory}/go.mod"
	printf 'package example\nimport _ "%s"\n' "${import_path}" > "${directory}/example.go"
}

assert_extension_rejects() {
	local name="$1"
	local import_path="$2"
	local directory="${test_root}/${name}"
	write_module "${directory}" "github.com/sneat-co/example/backend" "${import_path}"
	if wb deps policy check "${directory}" --policy "${policy}" --type extension-implementation >/dev/null 2>&1; then
		echo "extension policy unexpectedly allowed ${import_path}" >&2
		exit 1
	fi
}

assert_extension_rejects firestore cloud.google.com/go/firestore
assert_extension_rejects firebase firebase.google.com/go/v4
assert_extension_rejects dalgo2firestore github.com/dal-go/dalgo2firestore

host_dir="${test_root}/host"
write_module "${host_dir}" github.com/sneat-co/sneat-go cloud.google.com/go/firestore
wb deps policy check "${host_dir}" --policy "${policy}" --type host >/dev/null

extension_dir="${test_root}/memory"
mkdir -p "${extension_dir}"
printf 'module github.com/sneat-co/example/backend\n\ngo 1.26\n' > "${extension_dir}/go.mod"
printf 'package example\nimport _ "github.com/dal-go/dalgo/adapters/dalgo2memory"\n' > "${extension_dir}/example_test.go"
wb deps policy check "${extension_dir}" --policy "${policy}" --type extension-implementation >/dev/null

echo 'extension storage boundary policy tests passed'
