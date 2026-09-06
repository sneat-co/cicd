#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
checker="${repo_root}/scripts/check-go-storage-driver-boundary.sh"
policy="${repo_root}/policy/sneat-backend.yaml"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

write_module() {
	local directory="$1" module="$2" repository_type="${3:-extension-implementation}"
	mkdir -p "$directory"
	printf 'module %s\n\ngo 1.26\n' "$module" >"$directory/go.mod"
	printf 'policy: sneat-co/cicd//policy/sneat-backend.yaml\ntype: %s\n' "$repository_type" >"$directory/.wb-deps-policy.yaml"
}

run_boundary() {
	local directory="$1"
	set +e
	LAST_OUTPUT="$("$checker" "$directory" "$policy" 2>&1)"
	LAST_CODE=$?
	set -e
}

expect_code() {
	local expected="$1" description="$2"
	if [[ "$LAST_CODE" -ne "$expected" ]]; then
		echo "$description: got exit $LAST_CODE, want $expected" >&2
		echo "$LAST_OUTPUT" >&2
		exit 1
	fi
}

source_driver="$test_root/source-driver"
write_module "$source_driver" github.com/sneat-co/example/backend
printf 'package example\nimport _ "cloud.google.com/go/firestore"\n' >"$source_driver/example.go"
run_boundary "$source_driver"
expect_code 1 "source storage SDK must be denied"
grep -qF 'group=storage-driver' <<<"$LAST_OUTPUT"
grep -qF 'cloud.google.com/go/firestore' <<<"$LAST_OUTPUT"

test_driver="$test_root/test-driver"
write_module "$test_driver" github.com/sneat-co/example/backend
printf 'package example\nimport _ "firebase.google.com/go/v4"\n' >"$test_driver/example_test.go"
run_boundary "$test_driver"
expect_code 1 "test storage SDK must be denied"
grep -qF 'firebase.google.com/go/v4' <<<"$LAST_OUTPUT"

manifest_driver="$test_root/manifest-driver"
write_module "$manifest_driver" github.com/sneat-co/example/backend
printf '\nrequire github.com/dal-go/dalgo2firestore v0.0.0\n' >>"$manifest_driver/go.mod"
run_boundary "$manifest_driver"
expect_code 1 "direct go.mod storage SDK must be denied"
grep -qF 'go.mod:' <<<"$LAST_OUTPUT"
grep -qF 'github.com/dal-go/dalgo2firestore' <<<"$LAST_OUTPUT"

memory_adapter="$test_root/memory-adapter"
write_module "$memory_adapter" github.com/sneat-co/example/backend
printf 'package example\nimport _ "github.com/dal-go/dalgo/adapters/dalgo2memory"\n' >"$memory_adapter/example_test.go"
run_boundary "$memory_adapter"
expect_code 0 "test-only in-memory adapter must remain allowed"
grep -qF 'Focused storage-driver boundary passed' <<<"$LAST_OUTPUT"

host="$test_root/host"
write_module "$host" github.com/sneat-co/sneat-go host
printf 'package example\nimport _ "cloud.google.com/go/firestore"\n' >"$host/example.go"
run_boundary "$host"
expect_code 0 "declared host must be allowed to wire storage"
grep -qF 'declared repository type host' <<<"$LAST_OUTPUT"

missing_type="$test_root/missing-type"
mkdir -p "$missing_type"
printf 'module github.com/sneat-co/example/backend\n\ngo 1.26\n' >"$missing_type/go.mod"
printf 'policy: sneat-co/cicd//policy/sneat-backend.yaml\n' >"$missing_type/.wb-deps-policy.yaml"
run_boundary "$missing_type"
expect_code 2 "missing declared type must fail closed"
grep -qF 'requires .wb-deps-policy.yaml to declare' <<<"$LAST_OUTPUT"

unknown_type="$test_root/unknown-type"
write_module "$unknown_type" github.com/sneat-co/example/backend unknown-repository-type
run_boundary "$unknown_type"
expect_code 2 "unknown declared type must fail closed"
grep -qF 'is not declared' <<<"$LAST_OUTPUT"

invalid_config="$test_root/invalid-config"
write_module "$invalid_config" github.com/sneat-co/example/backend
printf 'allow: [storage-driver]\n' >>"$invalid_config/.wb-deps-policy.yaml"
run_boundary "$invalid_config"
expect_code 2 "a repository-local policy override must fail closed"
grep -qF 'cannot extend an allow list' <<<"$LAST_OUTPUT"

parse_hole="$test_root/parse-hole"
write_module "$parse_hole" github.com/sneat-co/example/backend
printf 'package example\nimport (\n' >"$parse_hole/broken.go"
run_boundary "$parse_hole"
expect_code 2 "an unparseable Go file must fail closed"
grep -qF 'cannot certify files WB could not parse' <<<"$LAST_OUTPUT"
grep -qF 'broken.go' <<<"$LAST_OUTPUT"

unrelated="$test_root/unrelated"
write_module "$unrelated" github.com/sneat-co/example/backend
printf 'package example\nimport _ "github.com/sneat-co/calendarius/backend/dbo4calendarius"\n' >"$unrelated/example.go"
run_boundary "$unrelated"
expect_code 0 "unrelated dependency-policy findings must remain outside the focused gate"
grep -qF 'outside this focused gate' <<<"$LAST_OUTPUT"
grep -qF 'group=extension-implementation' <<<"$LAST_OUTPUT"
if grep -qF 'full dependency policy passed' <<<"$LAST_OUTPUT"; then
	echo "focused gate must not claim the full dependency policy passed" >&2
	exit 1
fi

fake_bin="$test_root/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/wb" <<'EOF'
#!/usr/bin/env bash
printf '{"unexpected":true}\n'
exit 0
EOF
chmod +x "$fake_bin/wb"
set +e
malformed_output="$(PATH="$fake_bin:$PATH" "$checker" "$unrelated" "$policy" 2>&1)"
malformed_code=$?
set -e
if [[ "$malformed_code" -ne 2 ]] || ! grep -qF 'malformed or inconsistent' <<<"$malformed_output"; then
	echo "malformed WB JSON must fail closed" >&2
	echo "$malformed_output" >&2
	exit 1
fi

echo "focused Go storage-driver boundary tests passed"
