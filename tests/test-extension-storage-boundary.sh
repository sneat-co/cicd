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
	local repository_type="$4"
	mkdir -p "${directory}"
	printf 'module %s\n\ngo 1.26\n' "${module}" > "${directory}/go.mod"
	printf 'package example\nimport _ "%s"\n' "${import_path}" > "${directory}/example.go"
	printf 'policy: sneat-co/cicd//policy/sneat-backend.yaml\ntype: %s\n' "${repository_type}" > "${directory}/.wb-deps-policy.yaml"
}

assert_declared_type() {
	local directory="$1"
	local effective
	effective="$(wb deps policy show "${directory}" --policy "${policy}")"
	if ! grep -Eq '^type[[:space:]]+[^[:space:]]+[[:space:]]+\(declared\)$' <<< "${effective}"; then
		echo "repository type was not read from ${directory}/.wb-deps-policy.yaml" >&2
		exit 1
	fi
}

assert_extension_rejects() {
	local name="$1"
	local import_path="$2"
	local directory="${test_root}/${name}"
	write_module "${directory}" "github.com/sneat-co/example/backend" "${import_path}" extension-implementation
	assert_declared_type "${directory}"
	if wb deps policy check "${directory}" --policy "${policy}" >/dev/null 2>&1; then
		echo "extension policy unexpectedly allowed ${import_path}" >&2
		exit 1
	fi
}

assert_extension_rejects firestore cloud.google.com/go/firestore
assert_extension_rejects firebase firebase.google.com/go/v4
assert_extension_rejects dalgo2firestore github.com/dal-go/dalgo2firestore

host_dir="${test_root}/host"
write_module "${host_dir}" github.com/sneat-co/sneat-go cloud.google.com/go/firestore host
assert_declared_type "${host_dir}"
wb deps policy check "${host_dir}" --policy "${policy}" >/dev/null

extension_dir="${test_root}/memory"
mkdir -p "${extension_dir}"
printf 'module github.com/sneat-co/example/backend\n\ngo 1.26\n' > "${extension_dir}/go.mod"
printf 'package example\nimport _ "github.com/dal-go/dalgo/adapters/dalgo2memory"\n' > "${extension_dir}/example_test.go"
printf 'policy: sneat-co/cicd//policy/sneat-backend.yaml\ntype: extension-implementation\n' > "${extension_dir}/.wb-deps-policy.yaml"
assert_declared_type "${extension_dir}"
wb deps policy check "${extension_dir}" --policy "${policy}" >/dev/null

missing_config_dir="${test_root}/missing-config"
mkdir -p "${missing_config_dir}"
printf 'module github.com/sneat-co/example/backend\n\ngo 1.26\n' > "${missing_config_dir}/go.mod"
detected="$(wb deps policy show "${missing_config_dir}" --policy "${policy}")"
if grep -Eq '^type[[:space:]]+[^[:space:]]+[[:space:]]+\(declared\)$' <<< "${detected}"; then
	echo 'repository without a policy config unexpectedly reported a declared type' >&2
	exit 1
fi

missing_type_dir="${test_root}/missing-type"
mkdir -p "${missing_type_dir}"
printf 'module github.com/sneat-co/example/backend\n\ngo 1.26\n' > "${missing_type_dir}/go.mod"
printf 'policy: sneat-co/cicd//policy/sneat-backend.yaml\n' > "${missing_type_dir}/.wb-deps-policy.yaml"
detected="$(wb deps policy show "${missing_type_dir}" --policy "${policy}")"
if grep -Eq '^type[[:space:]]+[^[:space:]]+[[:space:]]+\(declared\)$' <<< "${detected}"; then
	echo 'repository without a type unexpectedly reported a declared type' >&2
	exit 1
fi

echo 'extension storage boundary policy tests passed'
