#!/usr/bin/env bash
set -euo pipefail

module_directory="${1:-}"
policy="${2:-}"

if [[ -z "$module_directory" || -z "$policy" ]]; then
	echo "usage: check-go-storage-driver-boundary.sh <module-directory> <policy>" >&2
	exit 2
fi
if ! command -v wb >/dev/null 2>&1; then
	echo "wb is required" >&2
	exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
	echo "jq is required" >&2
	exit 2
fi

temporary_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
report="$(mktemp "${temporary_root%/}/go-storage-driver-boundary.XXXXXX.json")"
diagnostics="$(mktemp "${temporary_root%/}/go-storage-driver-boundary.XXXXXX.err")"
trap 'rm -f "$report" "$diagnostics"' EXIT

set +e
wb deps policy check "$module_directory" --policy "$policy" --format json >"$report" 2>"$diagnostics"
wb_exit=$?
set -e

if [[ "$wb_exit" -ne 0 && "$wb_exit" -ne 1 ]]; then
	cat "$diagnostics" >&2
	echo "storage-driver boundary could not obtain a policy verdict (wb exit $wb_exit)" >&2
	exit "$wb_exit"
fi

if ! jq -e --argjson wbExit "$wb_exit" '
	type == "object" and
	(.module | type == "string" and length > 0) and
	(.type | type == "string" and length > 0) and
	(.typeDetected | type == "boolean") and
	(.policy | type == "string" and length > 0) and
	(.blocking | type == "number" and . >= 0) and
	(.reported | type == "number" and . >= 0) and
	((.unparseable // []) | type == "array" and all(.[]; type == "string")) and
	(.findings | type == "array") and
	(all(.findings[];
		(.rule == "import" or .rule == "layer" or .rule == "role") and
		(.mode == "enforce" or .mode == "report") and
		(.file | type == "string" and length > 0) and
		(.line | type == "number" and . >= 0) and
		(.scope | type == "string" and length > 0) and
		(.message | type == "string" and length > 0) and
		(if .rule == "import" then
			(.import | type == "string" and length > 0) and
			(.group | type == "string" and length > 0)
		else
			((.group // "") | type == "string")
		end)
	)) and
	(
		($wbExit == 0 and .blocking == 0) or
		($wbExit == 1 and .blocking > 0)
	)
' "$report" >/dev/null; then
	cat "$diagnostics" >&2
	echo "storage-driver boundary received malformed or inconsistent WB policy JSON" >&2
	exit 2
fi

if [[ "$(jq -r '.typeDetected' "$report")" != "false" ]]; then
	echo "storage-driver boundary requires .wb-deps-policy.yaml to declare a non-empty type" >&2
	exit 2
fi

unparseable_count="$(jq '(.unparseable // []) | length' "$report")"
if [[ "$unparseable_count" -ne 0 ]]; then
	echo "storage-driver boundary cannot certify files WB could not parse:" >&2
	jq -r '(.unparseable // [])[] | "  \(.)"' "$report" >&2
	exit 2
fi

storage_count="$(jq '[.findings[] | select(.rule == "import" and .group == "storage-driver" and .mode == "enforce")] | length' "$report")"
other_count="$(jq --argjson storageCount "$storage_count" '.findings | length - $storageCount' "$report")"

if [[ "$other_count" -gt 0 ]]; then
	echo "::notice title=Focused storage-driver boundary::$other_count dependency-policy finding(s) are visible but outside this focused gate; run the full dependency-policy workflow for the complete verdict."
	jq -r '
		[.findings[] | select((.rule == "import" and .group == "storage-driver" and .mode == "enforce") | not)]
		| group_by([.rule, (.group // "-"), .mode])[]
		| "  \(length)x rule=\(.[0].rule) group=\(.[0].group // "-") mode=\(.[0].mode)"
	' "$report"
fi

if [[ "$storage_count" -gt 0 ]]; then
	echo "::error title=Storage driver boundary::$storage_count enforcing storage-driver import finding(s)"
	jq -r '
		.findings[]
		| select(.rule == "import" and .group == "storage-driver" and .mode == "enforce")
		| "  \(.file):\(.line) [\(.scope)] group=\(.group) \(.import)"
	' "$report"
	exit 1
fi

repository_type="$(jq -r '.type' "$report")"
echo "Focused storage-driver boundary passed for declared repository type ${repository_type}."
