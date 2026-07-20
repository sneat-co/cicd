#!/usr/bin/env bash
set -euo pipefail

coverage_path="${COVERAGE_PATH:?COVERAGE_PATH is required}"
minimum="${COVERAGE_MINIMUM_PERCENT:?COVERAGE_MINIMUM_PERCENT is required}"

if [[ ! -e "$coverage_path" ]]; then
  echo "coverage path not found: $coverage_path" >&2
  exit 1
fi
if ! awk -v value="$minimum" 'BEGIN { exit !(value >= 0 && value <= 100) }'; then
  echo "minimum coverage must be between 0 and 100: $minimum" >&2
  exit 1
fi

coverage_files=()
if [[ -f "$coverage_path" ]]; then
  coverage_files+=("$coverage_path")
else
  while IFS= read -r -d '' file; do
    coverage_files+=("$file")
  done < <(find "$coverage_path" -type f -name lcov.info -print0 | sort -z)
fi
if [[ ${#coverage_files[@]} -eq 0 ]]; then
  echo "no lcov.info files found under: $coverage_path" >&2
  exit 1
fi

read -r covered found < <(
  awk -F: '
    $1 == "LH" { covered += $2 }
    $1 == "LF" { found += $2 }
    END { print covered + 0, found + 0 }
  ' "${coverage_files[@]}"
)
if [[ "$found" -eq 0 ]]; then
  echo "coverage reports contain no instrumented lines: $coverage_path" >&2
  exit 1
fi

percent="$(awk -v covered="$covered" -v found="$found" 'BEGIN { printf "%.2f", covered * 100 / found }')"
echo "Line coverage: ${percent}% (${covered}/${found}) across ${#coverage_files[@]} report(s); required: ${minimum}%"
if ! awk -v actual="$percent" -v required="$minimum" 'BEGIN { exit !(actual >= required) }'; then
  echo "::error::Line coverage ${percent}% is below required ${minimum}%"
  exit 1
fi
