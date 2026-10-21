#!/usr/bin/env bash
# Ask Copilot coding agent to fix Renovate pull requests whose CI failed.
#
# Copilot starts when a user with a Copilot seat mentions @copilot on the pull
# request, so the request comment is posted with COPILOT_TRIGGER_TOKEN (that
# user's token); every read uses the workflow's GH_TOKEN. Without the secret the
# script only reports what it would request.
#
# Each request carries a marker naming the head commit it was made for, so a
# commit is asked about at most once, and a pull request gets at most
# MAX_ATTEMPTS requests in total: a fix that still fails cannot loop. A pull
# request over the limit is labelled renovate-needs-human instead.
#
# Modes (all read REPO, GH_TOKEN, COPILOT_TRIGGER_TOKEN, MAX_ATTEMPTS, CHECK_HINT):
#   workflow_run: RUN_ID, HEAD_BRANCH, HEAD_SHA of the failed pull_request run
#   one PR:       INPUT_PR=<number> (acts on the failing run of its head commit)
#   sweep:        neither (every open Renovate PR with a failing run)
# A head commit is failing when the newest pull_request run of any workflow
# (this fixer's own workflow, GITHUB_WORKFLOW, excluded) concluded in failure.
# Nothing here checks out or runs pull request code.
set -euo pipefail

: "${REPO:?}" "${GH_TOKEN:?}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-2}"
[[ "$MAX_ATTEMPTS" =~ ^[0-9]+$ ]] || { printf 'MAX_ATTEMPTS must be a number, got %s\n' "$MAX_ATTEMPTS" >&2; exit 1; }
# Keep in step with the check-hint default in action.yml (the test compares them).
DEFAULT_CHECK_HINT="the repository's own build and test commands"
CHECK_HINT="${CHECK_HINT:-$DEFAULT_CHECK_HINT}"
RENOVATE_LOGIN='renovate[bot]'
NEEDS_HUMAN_LABEL='renovate-needs-human'
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

note() { printf '%s\n' "$*" | tee -a "$SUMMARY" >&2; }

# failing_run SHA -> id of the newest failed run among the newest pull_request
# runs of each workflow for SHA (empty when none failed or none exist). The
# fixer's own workflow is ignored (defensive: its runs are never pull_request
# runs) and so are runs from forks. One page of 100 runs covers a single commit.
failing_run() {
  # shellcheck disable=SC2016  # $ENV is jq's, not the shell's
  SELF_WORKFLOW="${GITHUB_WORKFLOW:-}" gh api "repos/$REPO/actions/runs?head_sha=$1&event=pull_request&per_page=100" \
    --jq '[.workflow_runs[] | select(.name != $ENV.SELF_WORKFLOW and .head_repository.full_name == $ENV.REPO)]
          | group_by(.workflow_id) | map(max_by(.run_number))
          | map(select(.conclusion == "failure"))
          | (max_by(.id) // empty) | .id'
}

# request_fix PR SHA RUN_ID: ask Copilot once for SHA, within the attempt limit.
request_fix() {
  local pr="$1" sha="$2" run="$3" info state author head head_repo title
  info="$(gh api "repos/$REPO/pulls/$pr" --jq '[.state, .user.login, .head.sha, .head.repo.full_name // "", .title] | @tsv')"
  IFS=$'\t' read -r state author head head_repo title <<<"$info"
  if [ "$state" != open ] || [ "$author" != "$RENOVATE_LOGIN" ] || [ "$head_repo" != "$REPO" ]; then
    note "#$pr: skipped (state $state, author $author, head repository $head_repo)"
    return 0
  fi
  if [ "$head" != "$sha" ]; then
    note "#$pr: skipped, failed run $run is for ${sha:0:7} but the head is now ${head:0:7}"
    return 0
  fi

  # Renovate reuses one pull request for every later version of a dependency and
  # retitles it, so attempts are counted per title (ver), not per pull request.
  local ver markers attempts
  ver="$(printf '%s' "$title" | git hash-object --stdin | cut -c1-12)"
  markers="$(gh api --paginate "repos/$REPO/issues/$pr/comments" \
    --jq '.[] | (.body // "") | capture("<!-- renovate-copilot-fix ver:(?<ver>[0-9a-f]+) sha:(?<sha>[0-9a-f]+) -->") | "\(.ver) \(.sha)"')"
  if grep -q " $sha\$" <<<"$markers"; then
    note "#$pr: Copilot was already asked about ${sha:0:7}"
    return 0
  fi
  attempts="$(grep -c "^$ver " <<<"$markers" || true)"
  if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
    gh api --method POST "repos/$REPO/issues/$pr/labels" -f "labels[]=$NEEDS_HUMAN_LABEL" >/dev/null
    note "#$pr: still failing after $attempts Copilot attempts; labelled $NEEDS_HUMAN_LABEL"
    return 0
  fi

  local jobs body hint="$CHECK_HINT"
  [ "$hint" = "$DEFAULT_CHECK_HINT" ] || hint="\`$hint\`"
  jobs="$(gh api --paginate "repos/$REPO/actions/runs/$run/jobs" \
    --jq '.jobs[] | select(.conclusion == "failure") | "- [\(.name)](\(.html_url))"')"
  body="$(cat <<EOF
@copilot CI failed on this Renovate dependency update. Please fix this branch so the update works and CI passes.

- Keep the dependency at the version this pull request proposes and adapt our code, configuration, types or tests to it. If that is impossible, explain why in a comment and leave the branch unchanged.
- Keep the change minimal: do not touch unrelated files or other dependencies.
- Before pushing, run the failing checks where you can: $hint.

Failing jobs in [CI run $run](https://github.com/$REPO/actions/runs/$run):
${jobs:-- (no failed job was reported; see the run)}

Attempt $((attempts + 1)) of $MAX_ATTEMPTS.
<!-- renovate-copilot-fix ver:$ver sha:$sha -->
EOF
)"
  if [ -z "${COPILOT_TRIGGER_TOKEN:-}" ]; then
    echo "::warning::COPILOT_TRIGGER_TOKEN is empty: Copilot is not asked to fix Renovate pull requests in $REPO (set the org secret for $REPO's owner and pass it to the action)" >&2
    note "#$pr: would ask Copilot about ${sha:0:7}, but COPILOT_TRIGGER_TOKEN is not set"
    return 0
  fi
  GH_TOKEN="$COPILOT_TRIGGER_TOKEN" gh api --method POST "repos/$REPO/issues/$pr/comments" -f "body=$body" >/dev/null
  # A new version gets fresh attempts, so drop a limit label left by an older one.
  gh api --method DELETE "repos/$REPO/issues/$pr/labels/$NEEDS_HUMAN_LABEL" >/dev/null 2>&1 || true
  note "#$pr: asked Copilot to fix ${sha:0:7} (attempt $((attempts + 1)) of $MAX_ATTEMPTS)"
}

# request_if_failed PR: act on the failing run of the PR's head commit.
request_if_failed() {
  local pr="$1" sha run
  sha="$(gh api "repos/$REPO/pulls/$pr" --jq .head.sha)"
  run="$(failing_run "$sha")"
  if [ -z "$run" ]; then
    note "#$pr: no failing pull_request run for ${sha:0:7}; nothing to fix"
    return 0
  fi
  request_fix "$pr" "$sha" "$run"
}

if [ -n "${RUN_ID:-}" ]; then
  : "${HEAD_BRANCH:?}" "${HEAD_SHA:?}"
  head="$(jq -rn --arg h "${REPO%%/*}:$HEAD_BRANCH" '$h | @uri')"
  prs="$(gh api "repos/$REPO/pulls?state=open&head=$head" --jq '.[].number')"
  [ -n "$prs" ] || note "no open pull request for $HEAD_BRANCH"
  for pr in $prs; do request_fix "$pr" "$HEAD_SHA" "$RUN_ID"; done
elif [ -n "${INPUT_PR:-}" ]; then
  [[ "$INPUT_PR" =~ ^[0-9]+$ ]] || { note "pull request must be a number, got '$INPUT_PR'"; exit 1; }
  request_if_failed "$INPUT_PR"
else
  # Each pull request runs in its own process, so one API failure (which stops
  # that process under set -e) cannot skip the rest of the sweep.
  prs="$(gh api --paginate "repos/$REPO/pulls?state=open&per_page=100" \
    --jq ".[] | select(.user.login == \"$RENOVATE_LOGIN\") | .number")"
  status=0
  for pr in $prs; do
    INPUT_PR="$pr" bash "$0" || { note "#$pr: failed; see the log above"; status=1; }
  done
  exit "$status"
fi
