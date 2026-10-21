#!/usr/bin/env bash
# Offline test of renovate-copilot-fix.sh: bash actions/renovate-copilot-fix/renovate-copilot-fix.test.sh
#
# `gh` is a stub that serves JSON fixtures from $FIX and honours `--jq` (through
# the real jq), so the production filters run unchanged. Writes are appended to
# $FIX/posts as "<method> <token> <endpoint> <fields...>" instead of reaching GitHub.
#   pulls/<n>.json, comments_<n>.json, jobs_<run>.json, runs_<sha>.json (pull_request runs of every workflow),
#   open.json (every open pull request), head.json (pulls?head=...)
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
command -v jq >/dev/null || { echo "jq is required"; exit 2; }
mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = api ] || exit 1
shift
method=GET; jqf=.; endpoint=; fields=()
while [ $# -gt 0 ]; do
  case "$1" in
    --method) method="$2"; shift ;;
    --jq) jqf="$2"; shift ;;
    --paginate) ;;
    -f) fields+=("$2"); shift ;;
    *) endpoint="$1" ;;
  esac
  shift
done
[ "$method" = GET ] && echo "$endpoint" >>"$FIX/gets"
if [ "$method" != GET ]; then
  body="${fields[*]}"
  printf '%s %s %s %s\n' "$method" "$GH_TOKEN" "$endpoint" "${body//$'\n'/\\n}" >>"$FIX/posts"
  exit 0
fi
emit() { jq -r "$jqf" <"$FIX/$1"; }
case "$endpoint" in
  */pulls\?state=open\&head=*) emit head.json ;;
  */pulls\?state=open*) emit open.json ;;
  */pulls/*) emit "pulls/${endpoint##*/}.json" ;;
  */issues/*/comments) n="${endpoint%/comments}"; emit "comments_${n##*/}.json" ;;
  */runs/*/jobs) r="${endpoint%/jobs}"; emit "jobs_${r##*/}.json" ;;
  */actions/runs\?head_sha=*) s="${endpoint#*head_sha=}"; emit "runs_${s%%&*}.json" ;;
  *) echo "unexpected endpoint $endpoint" >&2; exit 1 ;;
esac
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" REPO=o/r GH_TOKEN=read-token MAX_ATTEMPTS=2 GITHUB_STEP_SUMMARY=/dev/null GITHUB_WORKFLOW='Renovate Copilot fix'

failures=0
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

# reset: fresh fixtures with one failing Renovate PR #7 at head aaa1.
reset() {
  export FIX="$tmp/fix"
  rm -rf "$FIX"; mkdir -p "$FIX/pulls"; : >"$FIX/posts"; : >"$FIX/gets"
  unset RUN_ID HEAD_BRANCH HEAD_SHA INPUT_PR CHECK_HINT
  export COPILOT_TRIGGER_TOKEN=trigger-token
  pr 7 'renovate[bot]' aaa1
  echo '[]' >"$FIX/comments_7.json"
  echo '[{"number":7}]' >"$FIX/head.json"
  echo '{"jobs":[{"name":"build","conclusion":"failure","html_url":"https://x/build"},{"name":"test","conclusion":"success","html_url":"https://x/test"}]}' >"$FIX/jobs_100.json"
}
TITLE='chore(deps): update dependency x to v2'
# pr N AUTHOR SHA [STATE] [TITLE]
pr() { jq -n --arg u "$2" --arg s "$3" --arg st "${4:-open}" --arg t "${5:-$TITLE}" '{state:$st,title:$t,user:{login:$u},head:{sha:$s,repo:{full_name:"o/r"}}}' >"$FIX/pulls/$1.json"; }
ver() { printf '%s' "${1:-$TITLE}" | git hash-object --stdin | cut -c1-12; }
# markers N SHA[@TITLE]... -> earlier requests on #N (TITLE defaults to the current one),
# plus one ordinary comment and one with a null body, which must be ignored.
markers() {
  local n="$1" m; shift
  for m in "$@"; do
    case "$m" in *@*) printf '%s %s\n' "$(ver "${m#*@}")" "${m%%@*}" ;; *) printf '%s %s\n' "$(ver)" "$m" ;; esac
  done | jq -R -s 'split("\n") | map(select(length>0) | split(" ") | {body: ("asked\n<!-- renovate-copilot-fix ver:" + .[0] + " sha:" + .[1] + " -->")})
    + [{body: "LGTM"}, {body: null}]' >"$FIX/comments_$n.json"
}
# runs ID:CONCLUSION[:WORKFLOW_ID[:NUMBER[:NAME[:HEAD_REPO]]]]... -> a runs_<sha>.json body; the workflow id
# defaults to the run id, the run number to the run id, the name to "CI" and the head repository to o/r.
runs() {
  local r
  for r in "$@"; do echo "$r"; done | jq -R -s '{workflow_runs: (split("\n") | map(select(length>0) | split(":")
    | {id: (.[0] | tonumber), conclusion: .[1], workflow_id: ((.[2] // .[0]) | tonumber), run_number: ((.[3] // .[0]) | tonumber), name: (.[4] // "CI"), head_repository: {full_name: (.[5] // "o/r")}}))}'
}
failed_run() { export RUN_ID=100 HEAD_BRANCH=renovate/x HEAD_SHA="${1:-aaa1}"; }
run() { bash "$here/renovate-copilot-fix.sh" >/dev/null 2>"$FIX/err" || fail "$1: exited non-zero: $(cat "$FIX/err")"; }
posts() { grep -c '/comments body=' "$FIX/posts"; }

reset; failed_run; run "first failure"
[ "$(posts)" = 1 ] || fail "first failure: expected 1 post, got $(posts)"
grep -q '^POST trigger-token repos/o/r/issues/7/comments body=@copilot' "$FIX/posts" || fail "first failure: comment not posted with the trigger token"
grep -q "ver:$(ver) sha:aaa1 -->" "$FIX/posts" || fail "first failure: marker missing"
grep -q 'https://x/build' "$FIX/posts" || fail "first failure: failing job link missing"
grep -q 'https://x/test' "$FIX/posts" && fail "first failure: passing job listed"
grep -q 'Attempt 1 of 2' "$FIX/posts" || fail "first failure: attempt count missing"

reset; markers 7 aaa1; failed_run; run "same commit"
[ "$(posts)" = 0 ] || fail "same commit: asked twice"

reset; markers 7 bbb2; failed_run; run "second commit"
grep -q 'Attempt 2 of 2' "$FIX/posts" || fail "second commit: expected attempt 2"

reset; markers 7 bbb2 ccc3; failed_run; run "limit"
[ "$(posts)" = 0 ] || fail "limit: commented past the limit"
grep -q '^POST read-token repos/o/r/issues/7/labels labels\[\]=renovate-needs-human' "$FIX/posts" || fail "limit: not labelled"

reset; markers 7 bbb2@old-title ccc3@old-title; failed_run; run "new version"
grep -q 'Attempt 1 of 2' "$FIX/posts" || fail "new version: attempts were not reset"
grep -q '^DELETE read-token repos/o/r/issues/7/labels/renovate-needs-human' "$FIX/posts" || fail "new version: limit label not removed"

reset; pr 7 'renovate[bot]' aaa1 closed; failed_run; run "closed pull request"
[ "$(posts)" = 0 ] || fail "closed pull request: commented"

reset; failed_run old0; run "stale run"
[ "$(posts)" = 0 ] || fail "stale run: acted on an old commit"

reset; pr 7 someone aaa1; failed_run; run "human pull request"
[ "$(posts)" = 0 ] || fail "human pull request: acted on a non-Renovate pull request"

reset; COPILOT_TRIGGER_TOKEN=; failed_run; run "no secret"
[ "$(posts)" = 0 ] || fail "no secret: posted without the trigger token"

reset; pr 8 'renovate[bot]' ddd4; pr 9 someone eee5
echo '[{"number":7,"user":{"login":"renovate[bot]"}},{"number":8,"user":{"login":"renovate[bot]"}},{"number":9,"user":{"login":"someone"}}]' >"$FIX/open.json"
runs 100:failure >"$FIX/runs_aaa1.json"
runs 101:success >"$FIX/runs_ddd4.json"
run "sweep"
if [ "$(posts)" != 1 ] || ! grep -q 'issues/7/comments' "$FIX/posts"; then fail "sweep: expected exactly one request, for #7"; fi

# #6 cannot be read: the sweep reports it, still serves #7, and exits non-zero.
reset; echo '[{"number":6,"user":{"login":"renovate[bot]"}},{"number":7,"user":{"login":"renovate[bot]"}}]' >"$FIX/open.json"
runs 100:failure >"$FIX/runs_aaa1.json"
bash "$here/renovate-copilot-fix.sh" >/dev/null 2>&1 && fail "broken sweep: exited zero"
[ "$(posts)" = 1 ] || fail "broken sweep: one failing pull request stopped the rest"

reset; export INPUT_PR='7;x'
bash "$here/renovate-copilot-fix.sh" >/dev/null 2>"$FIX/err" && fail "bad input: accepted a non-numeric pull request"
grep -q 'must be a number' "$FIX/err" || fail "bad input: not refused as a non-numeric pull request"
[ "$(posts)" = 0 ] || fail "bad input: posted"

reset; runs 100:failure >"$FIX/runs_aaa1.json"; export INPUT_PR=7; run "one pull request"
[ "$(posts)" = 1 ] || fail "one pull request: expected 1 post, got $(posts)"

reset; runs >"$FIX/runs_aaa1.json"; export INPUT_PR=7; run "no CI run"
[ "$(posts)" = 0 ] || fail "no CI run: acted without a failed run"

# Failing-run lookup (one pull request mode, so the lookup runs): the newest run of each
# workflow counts, every workflow is considered, and this fixer's own workflow is ignored.
reset; runs 100:failure:5:1 101:success:5:2 >"$FIX/runs_aaa1.json"; export INPUT_PR=7; run "rerun passed"
[ "$(posts)" = 0 ] || fail "rerun passed: acted on a failure superseded by a newer green run of the same workflow"

reset; runs 100:success:5:1 101:failure:5:2 >"$FIX/runs_aaa1.json"; echo '{"jobs":[]}' >"$FIX/jobs_101.json"; export INPUT_PR=7; run "newest failed"
[ "$(posts)" = 1 ] || fail "newest failed: expected 1 post, got $(posts)"
grep -q 'actions/runs/101)' "$FIX/posts" || fail "newest failed: not the newest run of the workflow"

reset; runs 100:success:5 101:failure:6:101:Security >"$FIX/runs_aaa1.json"; echo '{"jobs":[{"name":"scan","conclusion":"failure","html_url":"https://x/scan"}]}' >"$FIX/jobs_101.json"
export INPUT_PR=7; run "other workflow failed"
[ "$(posts)" = 1 ] || fail "other workflow failed: a failure in a second workflow was ignored"
if ! grep -q 'actions/runs/101)' "$FIX/posts" || ! grep -q 'https://x/scan' "$FIX/posts"; then fail "other workflow failed: not acting on the failed workflow's run"; fi

reset; runs 100:failure:5 102:failure:6:102:Other 103:failure:6:103:Other >"$FIX/runs_aaa1.json"; echo '{"jobs":[]}' >"$FIX/jobs_103.json"
export INPUT_PR=7; run "two failed workflows"
[ "$(posts)" = 1 ] || fail "two failed workflows: expected one request, got $(posts)"
grep -q 'actions/runs/103)' "$FIX/posts" || fail "two failed workflows: did not pick the newest failed run"

reset; runs 100:success:5 101:cancelled:6:101:Other 102:skipped:7 >"$FIX/runs_aaa1.json"; export INPUT_PR=7; run "no failure"
[ "$(posts)" = 0 ] || fail "no failure: acted without a failed run"

reset; runs 100:success:5 101:failure:6:101:"Renovate Copilot fix" >"$FIX/runs_aaa1.json"; export INPUT_PR=7; run "own workflow"
[ "$(posts)" = 0 ] || fail "own workflow: this fixer's own failure triggered a request"

# Sweep acts per pull request on a failure in any workflow.
reset; pr 8 'renovate[bot]' ddd4
echo '[{"number":7,"user":{"login":"renovate[bot]"}},{"number":8,"user":{"login":"renovate[bot]"}}]' >"$FIX/open.json"
echo '{"jobs":[]}' >"$FIX/jobs_101.json"; runs 100:success:5 101:failure:6:101:Lint >"$FIX/runs_aaa1.json"; runs 102:success:5:102 >"$FIX/runs_ddd4.json"
run "sweep across workflows"
if [ "$(posts)" != 1 ] || ! grep -q 'issues/7/comments' "$FIX/posts"; then fail "sweep across workflows: expected exactly one request, for #7"; fi

# Check hint: a command is quoted as code, the default reads as prose.
reset; failed_run; export CHECK_HINT='go vet ./... && go test ./...'; run "check hint"
grep -q 'where you can: `go vet ./... && go test ./...`\.' "$FIX/posts" || fail "check hint: command not rendered as code"
reset; failed_run; run "default check hint"
grep -q "where you can: the repository's own build and test commands\\." "$FIX/posts" || fail "default check hint: not rendered as prose"
grep -q "default: \"$(sed -n 's/^DEFAULT_CHECK_HINT="\(.*\)"$/\1/p' "$here/renovate-copilot-fix.sh")\"" "$here/action.yml" || fail "action.yml check-hint default differs from DEFAULT_CHECK_HINT"

# A run from a fork, or a PR whose head is in a fork, is not acted on.
reset; runs 100:failure:5:100:CI:other/fork >"$FIX/runs_aaa1.json"; export INPUT_PR=7; run "fork run"
[ "$(posts)" = 0 ] || fail "fork run: acted on a run from another repository"
reset; jq '.head.repo.full_name = "other/fork"' "$FIX/pulls/7.json" >"$FIX/p7" && mv "$FIX/p7" "$FIX/pulls/7.json"; failed_run; run "fork head"
[ "$(posts)" = 0 ] || fail "fork head: acted on a pull request whose head is in a fork"

# The branch is URL-encoded in the pull request lookup.
reset; export RUN_ID=100 HEAD_BRANCH='renovate/a&x' HEAD_SHA=aaa1; run "encoded branch"
grep -q 'head=o%3Arenovate%2Fa%26x' "$FIX/gets" || fail "encoded branch: head not URL-encoded: $(cat "$FIX/gets")"

# Newest failed run across workflows is chosen by id, not by per-workflow run number.
reset; runs 100:failure:5:5000 101:failure:6:30:Other >"$FIX/runs_aaa1.json"; echo '{"jobs":[]}' >"$FIX/jobs_101.json"; export INPUT_PR=7; run "newest by id"
grep -q 'actions/runs/101)' "$FIX/posts" || fail "newest by id: picked the run with the larger per-workflow number"

# Warning without the secret, and no untrusted expression in the run line.
reset; COPILOT_TRIGGER_TOKEN=; failed_run; bash "$here/renovate-copilot-fix.sh" >/dev/null 2>"$FIX/err"
grep -q '^::warning::COPILOT_TRIGGER_TOKEN is empty' "$FIX/err" || fail "no secret: no warning"
grep -E '^ *run:' "$here/action.yml" | grep -q '\${{' && fail "action.yml: the run line interpolates an expression"
grep -A1 'max-attempts:' "$here/action.yml" | grep -q 'default: "2"' || grep -A3 'max-attempts:' "$here/action.yml" | grep -q 'default: "2"' || fail "action.yml: max-attempts default is not 2"

# MAX_ATTEMPTS is arithmetic input: refuse anything but digits.
reset; failed_run; export MAX_ATTEMPTS="1+a[\$(touch $tmp/pwned)]"
bash "$here/renovate-copilot-fix.sh" >/dev/null 2>"$FIX/err" && fail "bad max attempts: accepted"
grep -q 'must be a number' "$FIX/err" || fail "bad max attempts: not refused"
[ "$(posts)" = 0 ] && [ ! -e "$tmp/pwned" ] || fail "bad max attempts: posted or evaluated the value"
export MAX_ATTEMPTS=2

if [ "$failures" = 0 ]; then echo "renovate-copilot-fix: all tests passed"; else echo "renovate-copilot-fix: $failures failure(s)"; exit 1; fi
