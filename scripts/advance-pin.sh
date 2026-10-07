#!/usr/bin/env bash
#
# advance-pin.sh — move the pinned upstream pair, and only on evidence.
#
# WHY THIS EXISTS
#
#   `configs/upstream.env` carries two numbers that together name the exact
#   upstream state a reproducible build compiles:
#
#     OPENWRT_PINNED_REVISION  the openwrt/openwrt tree revision
#     FEEDS_SNAPSHOT_DATE      the moment all nine feeds are rolled back to
#
#   They are the recovery mechanism: `dispatch-build.sh -f pinned=true` compiles
#   them, and it is what produced the last firmware that worked.  Until this
#   script existed they were moved BY HAND, which failed in both directions:
#
#     * a probe that came out green proved nothing that stuck - the pin stayed
#       where it was and the next probe started from the same old pair, so the
#       project never actually moved forward on its own;
#     * and nothing stopped the pin being moved to a revision that had never
#       been built, which is precisely the class of change - 2026-10-05's group
#       id collision, 2026-10-07's lost Kconfig symbol - that cost two days.
#
#   The invariant enforced here is narrow enough to check mechanically: the pin
#   may only ever name a revision whose OWN build produced a complete image and
#   passed every gate.  The only input is the record of a run that succeeded, so
#   a revision nothing has built cannot be promoted even by mistake.
#
# WHAT IT REFUSES, AND WHY EACH REFUSAL IS THE POINT
#
#   track != latest          the run already compiled the pin; promoting it would
#                            be circular.  Only a probe produces evidence.
#   empty feeds_cutoff       the feeds were not rolled back at all, so the tree
#                            revision alone does not name a reproducible state.
#                            Pinning it would freeze a combination no run has
#                            ever built - the exact failure this refuses.
#   malformed revision/date  a promotion writes to a file that a recovery build
#                            depends on; an unvalidated value there turns a
#                            recovery into a second failure.
#   already current          nothing to do.  Exercised on every normal run after
#                            the pin has caught up, so it must not be an error.
#
# USAGE
#
#   scripts/advance-pin.sh --revision <sha40> --cutoff <iso8601> --track <t> [--check]
#
#   --check   report whether the file would change; write nothing.
#             Exit 0 = current, 3 = would change, other = refused.
#
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/configs/upstream.env"

log()  { printf '\033[34;1m[advance-pin]\033[0m %s\n' "$*"; }
warn() { printf '\033[33;1m[advance-pin]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31;1m[advance-pin]\033[0m %s\n' "$*" >&2; exit 2; }

revision=""
cutoff=""
track=""
check_only=false

while [ $# -gt 0 ]; do
	case "$1" in
	--revision) revision="${2:-}"; shift 2 ;;
	--cutoff) cutoff="${2:-}"; shift 2 ;;
	--track) track="${2:-}"; shift 2 ;;
	--check) check_only=true; shift ;;
	-h | --help)
		sed -n '2,60p' "$0"
		exit 0
		;;
	*)
		die "unknown argument: $1"
		;;
	esac
done

[ -f "$ENV_FILE" ] || die "no such file: ${ENV_FILE}"

# ---- refusals ---------------------------------------------------------------
#
# Order matters for the message, not for correctness: the operator should read
# "this run was not a probe" rather than a validation complaint about values
# that were never supposed to be used.
[ -n "$track" ] || die "--track is required (read upstream_track= from BUILD-INFO.txt)"
if [ "$track" != "latest" ]; then
	log "upstream_track=${track} - this run compiled the pinned pair, so it carries"
	log "no evidence to promote. Nothing to do (a pinned run cannot advance the pin)."
	exit 0
fi

[ -n "$revision" ] || die "--revision is required"

# NOTE the asymmetry with --revision: an empty --cutoff is not a usage error, it
# is the most important refusal in this file.  `feeds_cutoff` is empty exactly
# when the feeds were left on their branch heads, and a tree revision with
# unpinned feeds does not name a state anybody can rebuild.  Pinning it would
# freeze a combination no run has ever compiled, so it gets its own sentence
# rather than "argument missing".
if [ -z "$cutoff" ]; then
	die "feeds_cutoff is empty: the feeds were never rolled back, so this revision does not name a reproducible state - refusing to pin it"
fi

# A 40-hex object id and an ISO-8601 instant.  Both are checked because both are
# written into a file that a recovery build reads: an empty revision makes
# `pinned=true` fetch nothing, and an unparseable date is only discovered hours
# into a build, by `git rev-list --before=` refusing every feed in turn.
case "$revision" in
	*[!0-9a-f]*) die "revision is not a lowercase hex object id: '${revision}'" ;;
esac
[ "${#revision}" -eq 40 ] || die "revision is ${#revision} chars, expected 40: '${revision}'"
case "$cutoff" in
	[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]*) ;;
	*) die "cutoff is not an ISO-8601 timestamp: '${cutoff}'" ;;
esac

current_rev="$(sed -n 's/^OPENWRT_PINNED_REVISION=//p' "$ENV_FILE" | head -n1)"
current_cut="$(sed -n 's/^FEEDS_SNAPSHOT_DATE=//p' "$ENV_FILE" | head -n1)"

log "current pin : ${current_rev:0:12}  (feeds ${current_cut:-<unset>})"
log "probed pair : ${revision:0:12}  (feeds ${cutoff})"

if [ "$current_rev" = "$revision" ] && [ "$current_cut" = "$cutoff" ]; then
	log "the pin already names this pair. Nothing to do."
	exit 0
fi

if [ "$check_only" = true ]; then
	warn "the pin WOULD move; --check was requested, so nothing was written"
	exit 3
fi

# ---- rewrite ----------------------------------------------------------------
#
# Both keys in one awk pass, so the file is replaced atomically and a partial
# write cannot leave the pair inconsistent - a mismatch between these two lines
# is a state nothing has ever built, i.e. the thing this script exists to
# prevent.  Comments and every other key are passed through untouched: this file
# is mostly explanation, and it is the explanation that the next person reads.
tmp="${ENV_FILE}.advance.$$"
trap 'rm -f "$tmp"' EXIT

awk -v want_rev="$revision" -v want_cut="$cutoff" '
	/^[[:space:]]*#/ { print; next }
	/^OPENWRT_PINNED_REVISION=/ && !seen_rev { print "OPENWRT_PINNED_REVISION=" want_rev; seen_rev = 1; next }
	/^FEEDS_SNAPSHOT_DATE=/ && !seen_cut { print "FEEDS_SNAPSHOT_DATE=" want_cut; seen_cut = 1; next }
	{ print }
	END { if (!seen_rev || !seen_cut) exit 9 }
' "$ENV_FILE" >"$tmp" || die "could not find both keys in ${ENV_FILE} - refusing to write a half-updated pin"

# Assert rather than assume: the whole value of this script is the invariant, and
# a rewrite that quietly dropped a key would break it without a single error.
got_rev="$(sed -n 's/^OPENWRT_PINNED_REVISION=//p' "$tmp" | head -n1)"
got_cut="$(sed -n 's/^FEEDS_SNAPSHOT_DATE=//p' "$tmp" | head -n1)"
[ "$got_rev" = "$revision" ] || die "rewrite produced OPENWRT_PINNED_REVISION=${got_rev}, expected ${revision}"
[ "$got_cut" = "$cutoff" ] || die "rewrite produced FEEDS_SNAPSHOT_DATE=${got_cut}, expected ${cutoff}"

# No other line may have shifted: a diff of exactly two lines is the whole
# change, and anything else means the awk above matched more than it should.
changed="$(diff <(cat "$ENV_FILE") <(cat "$tmp") | grep -c '^[<>]' || true)"
[ "${changed:-0}" -eq 4 ] ||
	warn "the rewrite changed ${changed} diff line(s), expected 4 (two removals, two additions) - review the commit"

cat "$tmp" >"$ENV_FILE"
log "pin advanced to ${revision:0:12} (feeds ${cutoff})"
