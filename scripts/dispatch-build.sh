#!/usr/bin/env bash
#
# Dispatch the firmware build against a commit you have actually pushed.
#
# WHY THIS EXISTS
#
#   `gh workflow run --ref <branch>` resolves the branch on GitHub's side at
#   dispatch time, and that resolution can race the `git push` that just
#   finished locally.  In this repository that produced two runs against the
#   previous commit - a fix was pushed, a build was dispatched to test it, and
#   the build ran the OLD code.  The failure looked identical to the one the
#   fix addressed, so it read as "the fix did not work" rather than "the fix
#   never ran".
#
#   `--ref <sha>` is not a way out: the dispatches API only accepts a branch or
#   tag name and answers `HTTP 422: No ref found for: <sha>` for an object id.
#
#   So the check has to happen on both sides of the dispatch:
#     before - wait until the remote branch really points at our commit;
#     after  - read back the run's headSha and, if it is the wrong commit,
#              cancel that run and try again rather than waiting 10 minutes
#              for a result about code nobody changed.
#
# USAGE
#
#   scripts/dispatch-build.sh [-f key=value]...
#
#   Any -f pairs are passed through to the workflow, so the caller keeps
#   spelling the build the same way it always has.  Set REPO / BRANCH /
#   WORKFLOW in the environment to retarget it.
#
set -Eeuo pipefail

REPO="${REPO:-skyyzc/H5000M-Openwrt-Build}"
BRANCH="${BRANCH:-higoros-qmodem}"
WORKFLOW="${WORKFLOW:-build.yml}"
ATTEMPTS="${ATTEMPTS:-3}"

log()  { printf '\033[34;1m[dispatch]\033[0m %s\n' "$*"; }
warn() { printf '\033[33;1m[dispatch]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31;1m[dispatch]\033[0m %s\n' "$*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "gh is not on PATH"
command -v git >/dev/null 2>&1 || die "git is not on PATH"

want="$(git rev-parse HEAD)"
[ -n "$want" ] || die "cannot resolve HEAD"

log "target commit: ${want:0:8}"

# ---- before: the remote branch must point at our commit ---------------------
#
# A push that has returned does not mean GitHub's ref store is already serving
# the new value to every API.  Wait for the read to agree instead of assuming.
have=""
for _ in $(seq 1 30); do
	have="$(git ls-remote origin "refs/heads/${BRANCH}" 2>/dev/null | cut -f1)"
	[ "$have" = "$want" ] && break
	sleep 2
done
[ "$have" = "$want" ] ||
	die "origin/${BRANCH} is ${have:0:8}, not ${want:0:8} - push first, or wait for it to land"
log "origin/${BRANCH} agrees"

# ---- dispatch, then verify what it actually dispatched ----------------------
newest_id() {
	gh run list -R "$REPO" --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true
}

attempt=1
while :; do
	before_id="$(newest_id)"

	gh workflow run "$WORKFLOW" -R "$REPO" --ref "$BRANCH" "$@" ||
		die "could not create the workflow dispatch event"

	# gh has no "show me the run I just created", so wait for a new id to
	# appear at the head of the list.
	run_id=""
	for _ in $(seq 1 30); do
		run_id="$(newest_id)"
		[ -n "$run_id" ] && [ "$run_id" != "$before_id" ] && break
		run_id=""
		sleep 2
	done
	[ -n "$run_id" ] || die "no run appeared after the dispatch"

	run_sha="$(gh run view "$run_id" -R "$REPO" --json headSha --jq '.headSha' 2>/dev/null || true)"

	if [ "$run_sha" = "$want" ]; then
		log "run ${run_id} is building ${want:0:8} - correct"
		log "https://github.com/${REPO}/actions/runs/${run_id}"
		exit 0
	fi

	# Wrong commit: the dispatch raced the push.  Cancel it rather than pay
	# ten minutes for a verdict about the previous revision.
	warn "run ${run_id} resolved to ${run_sha:0:8}, wanted ${want:0:8} - the dispatch raced the push"
	gh run cancel "$run_id" -R "$REPO" >/dev/null 2>&1 ||
		warn "could not cancel run ${run_id}; cancel it by hand"

	attempt=$((attempt + 1))
	[ "$attempt" -le "$ATTEMPTS" ] ||
		die "gave up after ${ATTEMPTS} dispatches; the branch ref is not settling"
	warn "retrying (attempt ${attempt}/${ATTEMPTS})"
	sleep 5
done
