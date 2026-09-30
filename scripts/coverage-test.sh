#!/usr/bin/env bash
#
# coverage-test.sh — run several ENABLE_* profiles through --config-only to
# catch configuration regressions without paying for a full firmware build.
#
# This is the migrated equivalent of Auto-H5000M-BIN's coverage-test.sh: the
# point is that every switch combination the workflow offers still produces a
# .config that satisfies verify_config(), not that the firmware boots.
#
# Usage:
#   scripts/coverage-test.sh quick     # default + the two modem stacks
#   scripts/coverage-test.sh full      # everything below
#
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_SET="${1:-quick}"
SOURCE_DIR="${SOURCE_DIR:-openwrt}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts-coverage}"

export SOURCE_DIR ARTIFACTS_DIR

pass=0
fail=0
failed_profiles=()

run_profile() {
	local name="$1"
	shift
	local log="${ROOT_DIR}/coverage-${name}.log"

	printf '\n\033[1;36m== profile: %s ==\033[0m\n' "$name"

	# Feeds are identical across profiles — only the first run pays for them.
	if PREPARE_ONLY=false SKIP_FEEDS_UPDATE="${SKIP_FEEDS_UPDATE:-false}" \
		THREADS="${THREADS:-$(nproc)}" "$@" \
		bash "${ROOT_DIR}/scripts/local-build.sh" --config-only >"$log" 2>&1; then
		printf '   \033[1;32mPASS\033[0m (%s)\n' "$log"
		pass=$((pass + 1))
	else
		printf '   \033[1;31mFAIL\033[0m — tail of %s:\n' "$log"
		tail -25 "$log" | sed 's/^/     /'
		fail=$((fail + 1))
		failed_profiles+=("$name")
	fi

	# Every later profile reuses the feed checkout.
	export SKIP_FEEDS_UPDATE=true
}

# quick: the three board-stack permutations the README documents, plus a profile
# that turns every optional switch on at once.
#
# `all-optional` is in the quick set on purpose.  Every ENABLE_* switch is a
# separate code path — its own clone URL, its own config symbols — and a switch
# that is never exercised in CI is a switch nobody has run.  That is not
# hypothetical: ENABLE_ADGUARDHOME pointed at a repository that does not exist,
# and because the failing clone ran under `set -e` it aborted the whole run.
# The `services` and `proxy-stack` profiles below would have caught it, but they
# live in `full`, which is not what CI runs on push.  One combined profile is
# cheap (all switches on once) and covers every switch individually.
run_profile default env
run_profile mt5700m env ENABLE_WWAND=false ENABLE_MT5700M=true
run_profile minimal env ENABLE_UPNP=false ENABLE_ADBLOCK=false ENABLE_FANCONTROL=false ENABLE_NETMODE=false
run_profile all-optional env ENABLE_DOCKERMAN=true ENABLE_NIKKI=true ENABLE_EBPF_PROXY_KERNEL=true ENABLE_OPENCLASH=true ENABLE_MOSDNS=true ENABLE_HOMEPROXY=true ENABLE_ADGUARDHOME=true ENABLE_ADBLOCK=true
# Passwall off.  Both switches default to true, so the `default` profile only
# ever exercises the ON path — and OFF is the branch that can fail silently:
# a bare `is_true "$X" && emit_service ...` is a failing command when the test
# is false, which aborts the whole build under `set -e`.  This profile is what
# would catch a regression to that shape.  It is cheap: the front-end trees are
# still cloned, only the emit and INCLUDE_* config change.
run_profile no-passwall env ENABLE_PASSWALL=false ENABLE_PASSWALL2=false

if [ "$PROFILE_SET" = "full" ]; then
	run_profile services env ENABLE_DOCKERMAN=true ENABLE_ADGUARDHOME=true
	# adblock and adblock-fast share the DNS backends (dnsmasq-full + ipset) the
	# default profiles already carry; this exercises the ENABLE_ADBLOCK image path
	# and its classic-adblock dependency set.
	run_profile adblock env ENABLE_ADBLOCK=true
	run_profile proxy-stack env ENABLE_NIKKI=true ENABLE_OPENCLASH=true ENABLE_MOSDNS=true ENABLE_HOMEPROXY=true ENABLE_ADGUARDHOME=true
	# The eBPF kernel options are a separate code path (the CONFIG_KERNEL_*
	# writes and verify_config's live check), so the off case is exercised too.
	run_profile no-ebpf-kernel env ENABLE_EBPF_PROXY_KERNEL=false
	run_profile no-dialer env ENABLE_WWAND=false ENABLE_MT5700M=false
	run_profile no-argon env ENABLE_THEME_ARGON=false
fi

printf '\n\033[1m== coverage summary ==\033[0m\n'
printf '  passed: %s\n  failed: %s\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
	printf '  failing profiles: %s\n' "${failed_profiles[*]}"
	exit 1
fi

echo "  all profiles produced a valid configuration"
