#!/usr/bin/env bash
#
# local-build.sh — build mainline OpenWrt for the Hiveton H5000M.
#
# This is the migrated successor of existyay/Auto-H5000M-BIN's local-build.sh.
# The pipeline, the CLI, the ENABLE_* switch names and the artifact layout are
# kept deliberately familiar; what changed is the upstream (ImmortalWrt ->
# openwrt/openwrt) and the H5000M feature stack (QModem/ModemManager ->
# ddimension/wwand, luci-app-Airpifanctrl -> luci-app-h5000m-fancontrol).
#
# Usage: see `scripts/local-build.sh --help`.
#
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Upstream baseline (repo, branch, pinned revision, target triple).
# shellcheck source=../configs/upstream.env
. "${ROOT_DIR}/configs/upstream.env"

# ---------------------------------------------------------------- knobs ------
REPO_URL="${REPO_URL:-${OPENWRT_REPO_URL}}"
REPO_BRANCH="${REPO_BRANCH:-${OPENWRT_REPO_BRANCH}}"
SOURCE_DIR="${SOURCE_DIR:-openwrt}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-artifacts}"
THREADS="${THREADS:-$(nproc 2>/dev/null || echo 2)}"
HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-300}"

TARGET_BOARD="${OPENWRT_TARGET}"
TARGET_SUBTARGET="${OPENWRT_SUBTARGET}"
TARGET_PROFILE="${OPENWRT_PROFILE}"
TARGET_ARCH="${OPENWRT_ARCH}"
IMAGE_PREFIX="${OPENWRT_IMAGE_PREFIX}"

# Upstream tracking: `latest` follows the branch head (the point of a scheduled
# auto-build); `pinned` builds the revision this harness was validated against.
OPENWRT_TRACK="${OPENWRT_TRACK:-latest}"

GIT_TIMEOUT="${GIT_TIMEOUT:-1800}"
FEEDS_TIMEOUT="${FEEDS_TIMEOUT:-3600}"
CONFIG_TIMEOUT="${CONFIG_TIMEOUT:-1800}"
DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-7200}"
TOOLCHAIN_TIMEOUT="${TOOLCHAIN_TIMEOUT:-7200}"
COMPILE_TIMEOUT="${COMPILE_TIMEOUT:-28800}"

# Download accelerators — the same defaults the previous harness used; they are
# harmless outside mainland China and can be overridden to the empty string.
GOPROXY="${GOPROXY:-https://goproxy.cn,https://proxy.golang.org,direct}"
GOSUMDB="${GOSUMDB:-sum.golang.google.cn}"
DOWNLOAD_MIRROR="${DOWNLOAD_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/openwrt/sources;https://mirrors.ustc.edu.cn/openwrt/sources;https://mirrors.bfsu.edu.cn/openwrt/sources}"
export GOPROXY GOSUMDB DOWNLOAD_MIRROR
export MAKEFLAGS="-j${THREADS}"

# ----------------------------------------------------------- H5000M stack ----
# Fan control — luci-app-h5000m-fancontrol (userspace PWM policy; the tree
# patch in patches/ removes the three kernel cooling maps that would race it).
ENABLE_FANCONTROL="${ENABLE_FANCONTROL:-true}"

# Egress priority — luci-app-h5000m-netmode arbitrates wired WAN vs cellular.
ENABLE_NETMODE="${ENABLE_NETMODE:-true}"

# WWAN dialer — ddimension/wwand.  The H5000M's built-in TD Tech MT5700M
# (3466:3301, cdc_ncm) is dialled by wwand-ncm; the other backends cover QMI,
# MBIM and PCIe/MHI modules in the USB and M.2 slots.
#
# Default OFF, matching the workflow input.  The units actually in circulation
# carry a Quectel RG520N-CN and are dialled by QModem, which is mutually
# exclusive with wwand on the data path — so a `true` default here could only
# ever produce a build that defconfig rejects.  It also drags in the ddimension
# feed, whose libubus-lua-async declares CONFLICTS:=libubus-lua and turns that
# into a Kconfig dependency loop.
ENABLE_WWAND="${ENABLE_WWAND:-false}"

# luci-app-mt5700m — FAN789's panel + NCM/DHCP dialer for the same module.
# MUTUALLY EXCLUSIVE with wwand on the data path: both would drive the MT5700M's
# cdc_ncm data interface and both want to own network.MT5700M.  Enabling it
# turns wwand off (see resolve_modem_stack).  It is also the only source of the
# modem temperature cache luci-app-h5000m-fancontrol reads, so a box that wants
# module temperature in the fan curve should pick this and give up wwand.
ENABLE_MT5700M="${ENABLE_MT5700M:-false}"

# QModem — FUjr/QModem 5G modem stack.  The H5000M units actually seen in the
# wild carry a Quectel RG520N-CN (USB 2c7c:0801, QMI), not the TD Tech
# MT5700M the wwand stack was written for; QModem dials it over the mainline
# qmi_wwan driver and its LuCI panels manage signal/SMS/bands.  Mutually
# exclusive with wwand / luci-app-mt5700m (see resolve_modem_stack).
ENABLE_QMODEM="${ENABLE_QMODEM:-false}"
QMODEM_REPO_URL="${QMODEM_REPO_URL:-https://github.com/FUjr/QModem.git}"
QMODEM_REPO_BRANCH="${QMODEM_REPO_BRANCH:-main}"

# The ddimension WWAN dialer feed (wwand, wwand-qmi/mbim/ncm/mhi/esim,
# luci-app-wwand, luci-proto-wwand).  Installed only when ENABLE_WWAND=true;
# see write_feeds_conf() for why the feed is conditional rather than always on.
WWAND_REPO_URL="${WWAND_REPO_URL:-https://github.com/ddimension/openwrt-repo.git}"
WWAND_REPO_BRANCH="${WWAND_REPO_BRANCH:-main}"

# OpenAppFilter — destan19/OpenAppFilter (appfilter userspace + kmod-oaf +
# luci-app-oaf).  Not in any official feed; pulled in as its own feed.
ENABLE_OAF="${ENABLE_OAF:-false}"
OAF_REPO_URL="${OAF_REPO_URL:-https://github.com/destan19/OpenAppFilter.git}"
OAF_REPO_BRANCH="${OAF_REPO_BRANCH:-master}"

# openwrt-passwall — the passwall and passwall2 front-ends plus the core
# packages they depend on.  Not in any official feed, and this is the main
# reason this project publishes its own apk repository (see the ENABLE_PASSWALL
# block further down for the full rationale).
#
# THREE repositories, verified 2026-09-30 rather than assumed — the naming is
# genuinely confusing:
#
#   Openwrt-Passwall/openwrt-passwall           luci-app-passwall only
#   Openwrt-Passwall/openwrt-passwall2          luci-app-passwall2 only
#   Openwrt-Passwall/openwrt-passwall-packages  the cores both depend on
#                                              (sing-box, xray-core, geoview,
#                                              hysteria, chinadns-ng, ...)
#
# There is no single "passwall" feed that carries all three; the packages repo
# says so itself ("luci-app-passwall(2) depends packages").
#
# These are cloned into package/ by install_proxy_repos() and are NOT feeds
# (see the note in write_feeds_conf).  The repositories are named above for the
# reader; the URLs live in install_proxy_repos(), which is the single place
# that fetches them, so there is no second copy of a URL here to drift.

# HigoOS preservation — stage higoros-overlay/ (the vendor higorosd backend,
# its Vue web UI, the userspace fan controller and the MT7992 EEPROM data)
# into the build tree's files/ directory so the vendor panel keeps working on
# mainline.  The overlay files ship verbatim; the config block below only
# carries what the panel needs from the package world.
ENABLE_HIGOROS="${ENABLE_HIGOROS:-false}"

# ------------------------------------------------------- optional services ---
ENABLE_UPNP="${ENABLE_UPNP:-true}"
# Not built in by default.  Adblock and HomeProxy are both useful and both
# available from this project's apk repository, so they ship as =m and the owner
# decides — the image stays smaller and nothing is installed that was not asked
# for.  Turn either on with ENABLE_ADBLOCK=true / ENABLE_HOMEPROXY=true.
ENABLE_ADBLOCK="${ENABLE_ADBLOCK:-false}"
ENABLE_DOCKERMAN="${ENABLE_DOCKERMAN:-false}"
# Nikki-RS (clash-rs), replacing the old mihomo-based Nikki.  See
# install_external_packages().
ENABLE_NIKKI="${ENABLE_NIKKI:-false}"
ENABLE_OPENCLASH="${ENABLE_OPENCLASH:-false}"

# Passwall / Passwall2 — the reason this project publishes its own apk
# repository at all.
#
# These are the packages a Chinese user most often wants and least often can
# get: they are not in the official OpenWrt feeds, and the usual route is a
# third-party feed or a hand-built .ipk.  Here they are compiled into the
# project's OWN repository, together with the kmods that only this build can
# provide — the official snapshot's kmods carry a different vermagic and the
# kernel on the device refuses them outright.
#
# Repository only by default (=m): both front-ends plus their cores are tens of
# megabytes, and baking every proxy stack into the image would bloat the
# sysupgrade payload for a feature most owners install one of.  The install is
# then a single `apk add luci-app-passwall` on the device, from the LuCI package
# manager or the shell — see H5000M_APK_REPO_URL.
#
# The dependency wiring the front-ends need (`+xray-core`, `+sing-box`) and the
# core-presence assertions are already in .github/workflows/build.yml; these
# switches are what select the packages the repository is assembled from.
ENABLE_PASSWALL="${ENABLE_PASSWALL:-true}"
ENABLE_PASSWALL2="${ENABLE_PASSWALL2:-true}"

# eBPF proxy kernel support.  Nikki-RS's eBPF fast path attaches TC (clsact)
# programs to the LAN/WAN interfaces and, when cgroup v2 is mounted, cgroup
# programs for host/process matching.  The TC half needs only the BPF syscall
# and the cls_bpf/act_bpf modules, which the kernel already has / the
# kmod-sched-* packages already carry.  The host half needs CONFIG_CGROUPS and
# CONFIG_CGROUP_BPF, which mainline OpenWrt leaves off, so this switch turns
# them on.
#
# Default true: the whole point of shipping Nikki-RS is the eBPF fast path, and
# a firmware that ships the app but not the kernel support would make the page's
# eBPF switch a no-op.  Turn it off only for a deliberately minimal build.
ENABLE_EBPF_PROXY_KERNEL="${ENABLE_EBPF_PROXY_KERNEL:-true}"
# Built into the image by default, matching the workflow.  A default that
# differs between a local build and CI produces two different firmwares from the
# same commit, which is worse than either choice on its own.
ENABLE_MOSDNS="${ENABLE_MOSDNS:-true}"
# Repository only, like the other proxy front-ends: built into the apk
# repository as =m, not installed into the image.  It is in the list a user sees
# after `apk update`, and `apk add luci-app-homeproxy` pulls its core.
ENABLE_HOMEPROXY="${ENABLE_HOMEPROXY:-false}"

# Mesh.  lean's luci-app-easymesh is not the OpenWrt easymesh daemon — mainline
# dropped that package.  Its LUCI_DEPENDS are kmod-cfg80211, batctl-default,
# kmod-batman-adv and dawn, i.e. a DAWN + batman-adv mesh, all of which ARE in
# the official feeds.  So this is a front-end to software mainline already has,
# not a port of something removed.
ENABLE_EASYMESH="${ENABLE_EASYMESH:-true}"
ENABLE_ADGUARDHOME="${ENABLE_ADGUARDHOME:-false}"

# Build the service packages into the apk repository even when they are not
# installed into the image.  On by default: the whole point is that a user can
# `apk add luci-app-dockerman` on the running router instead of having every
# option baked into the firmware.  Turn it off for a fast iteration build — it
# costs real time, because the Docker and proxy stacks are large Go programs.
ENABLE_REPO_PACKAGES="${ENABLE_REPO_PACKAGES:-true}"

# Clone and build the third-party proxy frontends (PassWall, PassWall2, Momo,
# fcshark, NeKoBox, luci-xray, Daed, HiJpass) alongside the ones already handled.
# They are built into the apk repository as =m, never installed into the image.
# Turn off together with ENABLE_REPO_PACKAGES for a fast iteration build — these
# pull in a lot of Go compilation.
ENABLE_PROXY_REPOS="${ENABLE_PROXY_REPOS:-true}"

# Every third-party tree clone_external() puts into package/.  Filled in as the
# clones happen; fix_mirror_hashes() consumes it.  Declared here rather than in
# main() so that it exists before the first clone under `set -u`.
CLONED_PACKAGE_DIRS=()

# Every CONFIG_PACKAGE_* name emit_service writes, recorded as it is written.
# verify_config() checks each against the build system's own package list,
# because `make defconfig` drops an unknown CONFIG_PACKAGE_x line with exit 0
# and NO diagnostic — so an upstream rename would otherwise shrink the
# repository while every other gate stayed green.  Measured: three names in
# these emit lists (shadowsocksr-libev, simple-obfs, shadowsocks-libev) were
# bare names no package ever had, and every build dropped all three silently.
EMITTED_PACKAGES=()

# ------------------------------------------------- first-boot product setup ---
# Applied once by /usr/sbin/h5000m-firstboot (uci-defaults + ieee80211 hotplug)
# and written into the image as /etc/h5000m-defaults.conf.
#
# WiFi: a freshly flashed OpenWrt leaves every radio disabled until someone logs
# in and picks a country, which reads as "WiFi does not work" on a 5G CPE.  The
# defaults below turn both radios on with one shared SSID.  CHANGE THE KEY
# before flashing anything you care about.
H5000M_WIFI_SSID="${H5000M_WIFI_SSID:-openwrt}"
# No password by default.  Encryption is `none` and there is no key, so the
# first boot brings up an open network: a fresh device is reachable without
# anyone having to know a credential that is printed nowhere.  Owners are
# expected to set their own; the first-boot script never overwrites an SSID that
# has already been changed.
H5000M_WIFI_KEY="${H5000M_WIFI_KEY:-}"
H5000M_WIFI_COUNTRY="${H5000M_WIFI_COUNTRY:-CN}"
H5000M_WIFI_ENCRYPTION="${H5000M_WIFI_ENCRYPTION:-none}"
H5000M_WIFI_HTMODE_2G="${H5000M_WIFI_HTMODE_2G:-EHT40}"
H5000M_WIFI_HTMODE_5G="${H5000M_WIFI_HTMODE_5G:-EHT160}"

# Hardware acceleration.  On mainline this is the netfilter flowtable offload
# driving the MTK PPE — the same hardware the vendor's TurboACC/hnat panel
# controls, reached through a different interface.  fw4 defaults both options to
# "0" and the stock firewall config sets neither, so nothing happens until they
# are turned on.  flow_offloading is software, flow_offloading_hw is the PPE.
H5000M_FLOW_OFFLOAD="${H5000M_FLOW_OFFLOAD:-1}"
H5000M_FLOW_OFFLOAD_HW="${H5000M_FLOW_OFFLOAD_HW:-1}"

# Base URL of this project's own apk repository, published as the apk-repo/
# build artifact.  It is baked into the firmware as
# /etc/apk/repositories.d/50-h5000m.list so the service packages (built as =m,
# not installed) and every kmod can be installed on the running router.
#
# Empty by default, and that default is deliberate.  An earlier revision derived
# a GitHub Pages URL from the repository name and baked it in unconditionally;
# the repository did not exist, so every device shipped with a source entry that
# 404'd and `apk update` reported "wget: exited with error 8" against it.  A
# source that cannot be reached is worse than no source at all: it makes the
# package manager look broken and hides the entries that do work.
#
# scripts/serve-apk-repo.sh serves artifacts/apk-repo/ over HTTP and prints the
# exact value to build with, which is the quickest way to a working setup.
H5000M_APK_REPO_URL="${H5000M_APK_REPO_URL:-}"

# --------------------------------------------------------------------- UI ----
# Argon is the theme the H5000M builds in the wild use, and it is not in any
# mainline feed, so it has to be cloned in.  Installing it is sufficient to make
# it the active theme: the package ships
# root/etc/uci-defaults/30_luci-theme-argon, which sets luci.main.mediaurlbase.
# luci-app-argon-config is its settings page and is useless without the theme.
ENABLE_THEME_ARGON="${ENABLE_THEME_ARGON:-true}"
ARGON_THEME_REPO_URL="${ARGON_THEME_REPO_URL:-https://github.com/jerrykuku/luci-theme-argon.git}"
ARGON_THEME_REPO_BRANCH="${ARGON_THEME_REPO_BRANCH:-master}"
ARGON_CONFIG_REPO_URL="${ARGON_CONFIG_REPO_URL:-https://github.com/jerrykuku/luci-app-argon-config.git}"
ARGON_CONFIG_REPO_BRANCH="${ARGON_CONFIG_REPO_BRANCH:-master}"

# ------------------------------------------------------------- run modes -----
INSTALL_DEPS=false
PREPARE_ONLY="${PREPARE_ONLY:-false}"
CONFIG_ONLY="${CONFIG_ONLY:-false}"
SKIP_TOOLCHAIN="${SKIP_TOOLCHAIN:-false}"
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-false}"
SKIP_FEEDS_UPDATE="${SKIP_FEEDS_UPDATE:-false}"
FORCE_PINNED=false

SRC="${ROOT_DIR}/${SOURCE_DIR}"
ART="${ROOT_DIR}/${ARTIFACTS_DIR}"
LOG_FILE="${ROOT_DIR}/build.log"

# Per-package build logs, enabled by passing BUILD_LOG=1 to make below.
#
# OpenWrt already has this machinery — include/subdir.mk tees each package's
# build output into $(BUILD_LOG_DIR)/<package>/<step>.txt and writes the name of
# a failing target into that directory's error.txt — but it is gated on a config
# symbol that our build could never set:
#
#   config BUILD_LOG
#           bool "Enable log files during build process" if DEVEL
#
# `if DEVEL` makes the symbol invisible unless CONFIG_DEVEL=y, and defconfig
# then drops `CONFIG_BUILD_LOG=y` from the seed without a word.  The result was
# that every build so far kept no per-package output at all, which is why a
# failure could only ever be reported as "ERROR: package/X failed to build."
# with the reason nowhere.  Measured: with the flag the seed set, the generated
# .config contains CONFIG_BUILD_LOG_DIR="" and no CONFIG_BUILD_LOG.
#
# Passing the variables to make directly sidesteps the Kconfig visibility rule
# entirely.  Besides being the only way to get the reason for a failure, it also
# keeps the CI console readable: the same measurement showed the console output
# for one package drop from 1.9 MB to 3.9 KB while the full 277 KB landed in the
# per-package file.
BUILD_LOG_DIR="${ROOT_DIR}/logs"

usage() {
	cat <<'EOF'
Usage: scripts/local-build.sh [options]

Builds mainline OpenWrt (openwrt/openwrt, branch `main`) for the
Hiveton H5000M (mediatek/filogic, profile hiveton_h5000m).

Options:
  --install-deps        Install build dependencies (apt-get, or pacman on Arch).
  --prepare-only        Clone/update source, feeds, patches and local packages, then stop.
  --config-only         Additionally run defconfig and verify the package set, then stop.
  --pinned              Build OPENWRT_PINNED_REVISION instead of the branch head.
  --skip-toolchain      Skip the explicit `make toolchain/install` prebuild step.
  --skip-download       Skip `make download` prefetch.
  --skip-feeds-update   Reuse the existing feeds checkout (no ./scripts/feeds update).
  -h, --help            Show this help.

Feature switches are environment variables, e.g.

  ENABLE_MT5700M=true ENABLE_WWAND=false THREADS=8 scripts/local-build.sh
  ENABLE_NIKKI=true ENABLE_ADBLOCK=false scripts/local-build.sh

Diagnostics:
  PREBUILD_PACKAGES="package/luci-app-ssr-plus/shadowsocks-libev ..."
      Build these packages (and their dependencies) before `make world`, which
      otherwise only reaches package/luci-app-* some 160 minutes in.  A failure
      there then costs a whole three-hour run to discover.  Only the order
      changes — world would have built them anyway.  The kernel is built first,
      because a package compile needs its .config.

Board stack (defaults):
  ENABLE_FANCONTROL=true   luci-app-h5000m-fancontrol + userspace fan DTS patch
  ENABLE_NETMODE=true      luci-app-h5000m-netmode (wired WAN / 5G priority)
  ENABLE_WWAND=true        ddimension/wwand dialer (QMI/MBIM/NCM/MHI)
  ENABLE_MT5700M=false     luci-app-mt5700m instead of wwand (mutually exclusive)

Optional services (defaults):
  ENABLE_UPNP=true ENABLE_ADBLOCK=false
  ENABLE_DOCKERMAN=false
  ENABLE_NIKKI=false ENABLE_OPENCLASH=false ENABLE_MOSDNS=true
  ENABLE_HOMEPROXY=false ENABLE_ADGUARDHOME=false

Acceleration (defaults):
  ENABLE_EBPF_PROXY_KERNEL=true
      Kernel support for the Nikki-RS eBPF proxy: writes CONFIG_KERNEL_CGROUPS
      and CONFIG_KERNEL_CGROUP_BPF (the TC half comes from kmod-sched-*).
      Changing it changes the kernel ABI and forces a full kernel rebuild.
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--install-deps) INSTALL_DEPS=true ;;
		--prepare-only) PREPARE_ONLY=true ;;
		--config-only) CONFIG_ONLY=true ;;
		--pinned)
			FORCE_PINNED=true
			OPENWRT_TRACK=pinned
			;;
		--skip-toolchain) SKIP_TOOLCHAIN=true ;;
		--skip-download) SKIP_DOWNLOAD=true ;;
		--skip-feeds-update) SKIP_FEEDS_UPDATE=true ;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			echo "Unknown argument: $1" >&2
			usage
			exit 2
			;;
	esac
	shift
done

# ------------------------------------------------------------- logging -------
log() { printf '\033[1;34m[h5000m]\033[0m %s\n' "$*" | tee -a "$LOG_FILE"; }
warn() { printf '\033[1;33m[h5000m:warn]\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&2; }
die() {
	printf '\033[1;31m[h5000m:error]\033[0m %s\n' "$*" | tee -a "$LOG_FILE" >&2
	exit 1
}

is_true() {
	case "${1,,}" in
		1 | true | yes | y | on) return 0 ;;
		*) return 1 ;;
	esac
}

run_with_timeout() {
	local timeout_s="$1"
	shift
	if command -v timeout >/dev/null 2>&1; then
		timeout --foreground -k 30 "$timeout_s" "$@"
	else
		"$@"
	fi
}

# --------------------------------------------------------------- network -----
github_url_candidates() {
	local url="$1" prefix
	printf '%s\n' "$url"
	for prefix in ${GITHUB_PROXY_PREFIXES:-}; do
		printf '%s%s\n' "$prefix" "$url"
	done
}

git_clone_retry() {
	local url="$1" branch="$2" dest="$3" candidate

	for candidate in $(github_url_candidates "$url"); do
		if run_with_timeout "$GIT_TIMEOUT" \
			git clone --depth 1 --branch "$branch" "$candidate" "$dest"; then
			return 0
		fi
		warn "clone failed, trying next mirror: $candidate"
		rm -rf "$dest"
	done

	return 1
}

# --------------------------------------------------------- dependencies ------
install_deps() {
	if command -v apt-get >/dev/null 2>&1; then
		log "Installing build dependencies with apt-get"

		# Non-interactive, or apt hangs.  `-y` answers apt's own questions but
		# not debconf's, so a package that wants an answer (tzdata's zone, a
		# service restart, a config-file conflict) blocks for ever on a runner
		# with no terminal.  Observed exactly that in CI: the install step sat
		# in_progress for over thirty minutes on an install that normally takes
		# five.  The dpkg options then make the remaining decisions instead of
		# asking: keep existing config files, and do not use a pty.
		export DEBIAN_FRONTEND=noninteractive
		export DEBCONF_NONINTERACTIVE_SEEN=true
		# The timeouts matter as much as the non-interactive flags.  Without
		# them a stalled connection — most often an IPv6 route that accepts the
		# SYN and then goes nowhere — makes apt wait indefinitely rather than
		# fail, which is what turned a five-minute install into a 30+ minute
		# hang in CI.  ForceIPv4 removes the cause; the timeouts bound it if it
		# happens anyway.
		local apt_opts=(
			-o Dpkg::Options::=--force-confold
			-o Dpkg::Options::=--force-confdef
			-o Dpkg::Use-Pty=0
			-o Acquire::Retries=3
			-o Acquire::ForceIPv4=true
			-o Acquire::http::Timeout=30
			-o Acquire::https::Timeout=30
		)
		sudo -E apt-get "${apt_opts[@]}" update
		# Installed in groups, with a line printed before each.  When the CI
		# install hung, the only thing the log could say was "still running" —
		# there was no way to tell which package was responsible.  Now the last
		# line printed before a timeout names the group, and a group can be
		# bisected further without another blind 20-minute run.
		local apt_groups=(
			"build-essential ccache python3 python3-pyelftools"
			"libncurses-dev libssl-dev libgmp3-dev libmbedtls-dev zlib1g-dev libelf-dev"
			"autoconf automake libtool patch gawk gettext"
			"unzip file wget curl rsync zstd git"
			"bison flex gperf haveged"
			"libltdl-dev libmpc-dev libmpfr-dev libreadline-dev"
			"ninja-build p7zip pkgconf python3-ply python3-setuptools"
			"lld llvm clang re2c scons squashfs-tools"
			"qemu-utils subversion swig texinfo uglifyjs upx-ucl"
			"vim xmlto xxd device-tree-compiler fastjar time"
		)
		local group
		for group in "${apt_groups[@]}"; do
			log "apt: installing ${group}"
			# shellcheck disable=SC2086
			sudo -E apt-get "${apt_opts[@]}" install -y --no-install-recommends $group ||
				die "apt-get failed for: ${group}"
		done
		return 0
	fi

	if command -v pacman >/dev/null 2>&1; then
		log "Installing build dependencies with pacman"
		# Only packages that live in the official Arch repositories.  `fastjar`
		# and `uglify-js` are AUR-only and `qemu-utils` is a Debian name — the
		# Arch equivalent for the image tools is qemu-img.  The AUR extras are
		# reported below rather than silently skipped.
		sudo pacman -S --needed --noconfirm \
			base-devel ccache python python-pyelftools ncurses openssl gmp mbedtls zlib \
			autoconf automake libtool patch gawk gettext unzip file wget curl rsync zstd \
			git bison flex gperf haveged libelf dtc time qemu-img re2c scons \
			squashfs-tools subversion swig texinfo upx ninja p7zip pkgconf \
			python-ply python-setuptools vim xmlto llvm lld clang cpio

		local aur_missing=()
		for cmd in fastjar uglifyjs; do
			command -v "$cmd" >/dev/null 2>&1 || aur_missing+=("$cmd")
		done
		if [ "${#aur_missing[@]}" -gt 0 ]; then
			warn "Still missing (AUR-only on Arch): ${aur_missing[*]}"
			warn "Install them with your AUR helper if a package you enabled needs them, e.g. 'yay -S fastjar uglify-js'."
		fi
		return 0
	fi

	die "No supported package manager found (apt-get / pacman). Install the OpenWrt build deps manually."
}

# Tools the configuration stage needs.  Kept deliberately small: configuring a
# tree (feeds + defconfig) must not demand the full cross-build toolchain, or
# nobody could lint a config change without provisioning a build host.
CONFIG_TOOLS=(git make gcc g++ python3 patch gawk find tar zstd)

# Tools the download/compile stage additionally needs.
BUILD_TOOLS=(unzip rsync flex bison gperf dtc fastjar)

check_environment() {
	local tools=("${CONFIG_TOOLS[@]}") missing=() cmd

	if ! is_true "$CONFIG_ONLY" && ! is_true "$PREPARE_ONLY"; then
		tools+=("${BUILD_TOOLS[@]}")
	fi

	for cmd in "${tools[@]}"; do
		command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
	done

	command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1 || missing+=("wget|curl")

	if [ "${#missing[@]}" -gt 0 ]; then
		if is_true "$CONFIG_ONLY" || is_true "$PREPARE_ONLY"; then
			die "Missing tools for the configuration stage: ${missing[*]}. Re-run with --install-deps."
		fi
		die "Missing build tools: ${missing[*]}. Re-run with --install-deps."
	fi

	if ! command -v rsync >/dev/null 2>&1; then
		warn "rsync not found; falling back to cp for package staging"
	fi

	if is_true "$CONFIG_ONLY" || is_true "$PREPARE_ONLY"; then
		log "Build host: $(uname -srm), ${THREADS} jobs (configuration stage — full build tools not checked)"
	else
		log "Build host: $(uname -srm), ${THREADS} jobs"
	fi
}

show_features() {
	log "Upstream      : ${REPO_URL} (${REPO_BRANCH}, track=${OPENWRT_TRACK})"
	log "Target        : ${TARGET_BOARD}/${TARGET_SUBTARGET} profile=${TARGET_PROFILE}"
	log "Board stack   : fancontrol=${ENABLE_FANCONTROL} netmode=${ENABLE_NETMODE} wwand=${ENABLE_WWAND} mt5700m=${ENABLE_MT5700M} qmodem=${ENABLE_QMODEM} oaf=${ENABLE_OAF} higoros=${ENABLE_HIGOROS}"
	log "UI            : argon=${ENABLE_THEME_ARGON}"
	# Say plainly whether the default network is open — "encryption=none" is
	# easy to miss in a build log and this is a security-relevant default.
	if [ "${H5000M_WIFI_ENCRYPTION}" = 'none' ]; then
		log "First boot    : wifi=${H5000M_WIFI_SSID}/${H5000M_WIFI_COUNTRY} OPEN NETWORK (no password) offload=sw:${H5000M_FLOW_OFFLOAD}/hw:${H5000M_FLOW_OFFLOAD_HW}"
	else
		log "First boot    : wifi=${H5000M_WIFI_SSID}/${H5000M_WIFI_COUNTRY} ${H5000M_WIFI_ENCRYPTION} offload=sw:${H5000M_FLOW_OFFLOAD}/hw:${H5000M_FLOW_OFFLOAD_HW}"
	fi
	log "apk source    : ${H5000M_APK_REPO_URL:-(none)}"
	log "Optional      : upnp=${ENABLE_UPNP} adblock=${ENABLE_ADBLOCK} dockerman=${ENABLE_DOCKERMAN}"
	log "Repo extras   : build=${ENABLE_REPO_PACKAGES} (services are =m unless their switch is on)"
	log "Proxy/DNS     : nikki-rs=${ENABLE_NIKKI} openclash=${ENABLE_OPENCLASH} mosdns=${ENABLE_MOSDNS} homeproxy=${ENABLE_HOMEPROXY} adguardhome=${ENABLE_ADGUARDHOME}"
	log "eBPF kernel   : ${ENABLE_EBPF_PROXY_KERNEL} (CGROUPS + CGROUP_BPF for Nikki-RS)"
}

resolve_modem_stack() {
	# wwand and luci-app-mt5700m both dial the same MT5700M cdc_ncm interface
	# and both want to own network.MT5700M.  The previous harness enforced the
	# same rule for QModem vs luci-app-modem; keep the loud, automatic
	# resolution so a mis-set environment never produces a box with two
	# dialers racing for one modem.
	if is_true "$ENABLE_WWAND" && is_true "$ENABLE_MT5700M"; then
		warn "ENABLE_WWAND and ENABLE_MT5700M are mutually exclusive (one cdc_ncm data path, one network.MT5700M)."
		warn "Keeping wwand (the WWAN dialer) and DISABLING luci-app-mt5700m."
		ENABLE_MT5700M=false
	fi

	if is_true "$ENABLE_QMODEM"; then
		if is_true "$ENABLE_WWAND" || is_true "$ENABLE_MT5700M"; then
			warn "ENABLE_QMODEM is mutually exclusive with wwand / luci-app-mt5700m"
			warn "(all three want to own the cellular data path)."
			warn "Keeping QModem and DISABLING the other dialer(s)."
		fi
		ENABLE_WWAND=false
		ENABLE_MT5700M=false
	fi

	# The vendor HigoOS panel has its own fan page (driving /usr/bin/fancontrol
	# from the overlay) and its own network management.  FAN789's fan app and
	# netmode would each put a second manager on the same job.
	if is_true "$ENABLE_HIGOROS"; then
		if is_true "$ENABLE_FANCONTROL" || is_true "$ENABLE_NETMODE"; then
			warn "ENABLE_HIGOROS ships the vendor panel with its own fan/network pages."
			warn "DISABLING luci-app-h5000m-fancontrol and luci-app-h5000m-netmode to avoid two managers."
		fi
		ENABLE_FANCONTROL=false
		ENABLE_NETMODE=false
	fi

	if ! is_true "$ENABLE_WWAND" && ! is_true "$ENABLE_MT5700M" && ! is_true "$ENABLE_QMODEM"; then
		warn "Neither ENABLE_WWAND nor ENABLE_MT5700M nor ENABLE_QMODEM is set: the image will have no cellular dialer,"
		warn "and luci-app-h5000m-netmode will have no modem interface to arbitrate."
	fi
}

# ---------------------------------------------------------------- source -----
prepare_source() {
	local rev staging

	if [ ! -d "${SRC}/.git" ]; then
		log "Cloning ${REPO_URL} (${REPO_BRANCH})"

		# Clone beside the target and merge, rather than cloning into it.  CI
		# restores its caches before this runs, and two of them live inside the
		# source tree — openwrt/dl and openwrt/.ccache — so $SRC already exists
		# and is not empty.  `git clone` refuses that destination outright:
		#
		#   fatal: destination path '.../openwrt' already exists and is not an
		#   empty directory.
		#
		# which is why the very first CI build worked and every later one failed:
		# only the first had no cache to restore.  Merging keeps the caches.
		staging="${SRC}.clone.$$"
		rm -rf "$staging"
		git_clone_retry "$REPO_URL" "$REPO_BRANCH" "$staging" ||
			die "Unable to clone ${REPO_URL}"

		mkdir -p "$SRC"
		(cd "$staging" && tar -cf - .) | (cd "$SRC" && tar -xf -) ||
			die "Could not move the fresh checkout into ${SRC}"
		rm -rf "$staging"
	fi

	if [ "${OPENWRT_TRACK}" = "pinned" ]; then
		rev="${OPENWRT_PINNED_REVISION}"
		log "Fetching pinned revision ${rev}"
		run_with_timeout "$GIT_TIMEOUT" git -C "$SRC" fetch --depth 1 origin "$rev" ||
			die "Cannot fetch pinned revision ${rev}"
		git -C "$SRC" checkout -f FETCH_HEAD
	else
		log "Updating ${REPO_BRANCH} to the current upstream head"
		run_with_timeout "$GIT_TIMEOUT" git -C "$SRC" fetch --depth 1 origin "$REPO_BRANCH" ||
			die "Cannot fetch ${REPO_BRANCH}"
		git -C "$SRC" checkout -f FETCH_HEAD
	fi

	# A previous run may have applied tree patches; restore tracked files so
	# patch application stays deterministic.  Deliberately NOT `git clean`:
	# feeds/, package/, dl/, build_dir/, staging_dir/ and bin/ must survive to
	# keep incremental builds and ccache useful.
	git -C "$SRC" reset --hard HEAD >/dev/null 2>&1 || true

	local head
	head="$(git -C "$SRC" rev-parse HEAD)"
	log "Source at $(git -C "$SRC" log --oneline -1)"
	printf '%s\n' "$head" >"${ROOT_DIR}/.upstream-revision"

	local desc
	desc="$(git -C "$SRC" describe --tags --always 2>/dev/null || echo "$head")"
	printf '%s\n' "$desc" >"${ROOT_DIR}/.upstream-describe"
}

write_feeds_conf() {
	# The base feeds are always present.  Every third-party feed is conditional,
	# and each is appended only when a package from it is actually going to be
	# built:
	#
	#   packages / luci / routing / telephony
	#          - the official feeds this image is actually built from, all four
	#            defined in feeds.conf.default.
	#   wwand  - the ddimension WWAN dialer itself (wwand, luci-app-wwand, ...).
	#            Appended for ENABLE_WWAND only.  This feed must NOT be installed
	#            on a QModem or mt5700m build: it carries libubus-lua-async,
	#            which declares PROVIDES:=libubus-lua together with
	#            CONFLICTS:=libubus-lua, and package-metadata.pl turns that pair
	#            into a Kconfig loop that makes defconfig drop the whole qmodem
	#            dependency chain.  The long note in feeds.conf.default has the
	#            full chain.
	#   qmodem - luci-app-mt5700m hard-depends on ubus-at-daemon and sms-tool_q,
	#            which exist only there; ENABLE_QMODEM needs the same feed for
	#            the modem stack itself (qmodem, quectel-CM-5G-M,
	#            luci-app-qmodem-next).
	#   oaf    - its own third-party feed, needed only when the app filter is
	#            wanted.
	#
	# ALSO here, and deliberately, as of the qmodem experiment: the official
	# `video` feed.  It is listed as an active line in feeds.conf.default, where
	# the full rationale lives.  The short version is that removing it makes
	# defconfig drop PACKAGE_qmodem - reproducible on the same upstream revision
	# - while keeping it does not, so the ~140 extra recursive-dependency
	# complaints it brings are noise worth tolerating.  Do not "clean up" the
	# feed list to lower the cycle count; the count does not decide the outcome.
	# See the MEASURED FACTS block over prune_display_stack() for the data.
	# wwand is NOT appended here any more.  feeds.conf.default carries it as an
	# unconditional line on purpose: on a QModem build the feed must still be
	# *installed* even though ENABLE_WWAND is forced off, because installing it
	# is what keeps defconfig from dropping the qmodem closure.  The reasoning,
	# the three-run evidence table and the one experiment that has NOT been run
	# are all in the feeds.conf.default note above that line.  Appending a
	# second copy here when ENABLE_WWAND is on would be harmless (scripts/feeds
	# would update the same feed twice) but pointless.
	{
		cat "${ROOT_DIR}/feeds.conf.default"
		if is_true "$ENABLE_MT5700M"; then
			printf '\n# Added because ENABLE_MT5700M=true. luci-app-mt5700m hard-depends on\n'
			printf '# ubus-at-daemon and sms-tool_q, which are only packaged here.\n'
			printf 'src-git qmodem %s;%s\n' "$QMODEM_REPO_URL" "$QMODEM_REPO_BRANCH"
		elif is_true "$ENABLE_QMODEM"; then
			printf '\n# Added because ENABLE_QMODEM=true. The QModem modem stack lives only\n'
			printf '# in this feed; mainline OpenWrt does not package it.\n'
			printf 'src-git qmodem %s;%s\n' "$QMODEM_REPO_URL" "$QMODEM_REPO_BRANCH"
		fi
		if is_true "$ENABLE_OAF"; then
			printf '\n# Added because ENABLE_OAF=true. OpenAppFilter is not in any official feed.\n'
			printf 'src-git oaf %s;%s\n' "$OAF_REPO_URL" "$OAF_REPO_BRANCH"
		fi
		# NOTE: passwall / passwall2 / passwall-packages deliberately do NOT get
		# feed entries here.  They are cloned straight into package/ by
		# install_proxy_repos() (see clone_and_prune) and that is the only place
		# they may come from: a src-git entry for the same three repositories
		# would land in feeds/passwall*/ and `feeds install` would symlink a
		# SECOND definition of luci-app-passwall into package/feeds/, which does
		# not build.  The ENABLE_PASSWALL* switches below control the emit and
		# include config, not the clone — install_proxy_repos already clones
		# them under ENABLE_REPO_PACKAGES, which is always true here.
	} >"$SRC/feeds.conf.default"

	# The header of feeds.conf.default warns about this, and it is easy to trip:
	# scripts/feeds strips comments with `s/#.*$//` and only THEN skips blank
	# lines, so a lone `#` with nothing after it is not blank after stripping —
	# it reaches the split, its first field is empty, and the parser dies with
	#   Syntax error in feeds.conf.default, line N
	# which aborts `feeds update` and therefore the whole build.  A comment block
	# is exactly where that happens, so assert it instead of trusting the prose.
	# Comparing the source comment line count to the generated one catches it at
	# the point of generation, with the line number, instead of seven minutes
	# into a CI run.
	local bad
	bad="$(grep -nE '^[[:space:]]*#[[:space:]]*$' "$SRC/feeds.conf.default" || true)"
	if [ -n "$bad" ]; then
		die "feeds.conf.default has comment-only '#' line(s) that scripts/feeds cannot parse: ${bad//$'\n'/, }. Every comment line needs text after the hash (see the file header)."
	fi
}

# `feeds install` symlinks packages into package/feeds/<feed>/ but never removes
# links for a feed that is no longer configured, so a tree that once built the
# mt5700m stack would keep offering all of QModem on a later wwand build.  Drop
# those links so the configured feed set is the only thing in the tree.  Only
# symlinks live under package/feeds, so this cannot delete a checkout.
prune_stale_feeds() {
	local dir name entry fname configured

	[ -d "${SRC}/package/feeds" ] || return 0

	shopt -s nullglob
	for dir in "${SRC}/package/feeds"/*/; do
		name="$(basename "$dir")"
		configured=false
		while read -r entry fname _; do
			case "$entry" in
				src-git | src-link | src-svn | src-hg)
					[ "$fname" = "$name" ] && configured=true
					;;
			esac
		done <"$SRC/feeds.conf.default"

		if [ "$configured" = false ]; then
			log "Removing package links for the now-unconfigured feed ${name}"
			rm -rf "$dir"
		fi
	done
	shopt -u nullglob
}

# ------------------------------------------------------- qmodem survival -----
# WHY THIS IS A GUARD AND NOT A PRUNE ANY MORE
#
# The symptom is always the same and always late: qmodem, luci-app-qmodem-next
# and luci-app-qmodem-generic vanish from .config, and verify_config() refuses
# to ship.  What follows is the set of things that were tried, and what each
# one actually did, so the next person does not repeat them.
#
# MEASURED FACTS
#   1. Upstream removed the AUDIO_SUPPORT / DISPLAY_SUPPORT build-feature gate:
#        da6323e5 build: remove the AUDIO_SUPPORT and DISPLAY_SUPPORT symbols
#        de2f69bf treewide: drop the audio and display target features
#        c375123b kernel: drop the audio and display feature gates
#      ~140 display/audio packages stopped being filtered out of the Kconfig
#      graph and recursive dependencies went 26 -> 166.
#   2. Removing the `video` feed takes the count from 166 down to 10.
#   3. The count does not decide the outcome.  The revision that last built
#      green had 26 cycles and kept qmodem; the build with 10 cycles dropped it.
#   4. Removing the video feed CHANGED which symbol Kconfig drops.  With the
#      feed present, qmodem survives; with it absent qmodem is dropped.  Both
#      were reproduced on the same upstream revision, so this is our doing, not
#      upstream's.
#   5. Pruning feeds/packages/multimedia and feeds/packages/sound to "reduce
#      cycles" made things worse.  Deleting a dependency does not delete the
#      packages that depend on it: baresip, freeswitch, asterisk, gnunet and
#      bmx7-dnsupdate stayed in the tree declaring `depends on libgstreamer1`,
#      `depends on mpg123`, `depends on pulseaudio` for symbols that no longer
#      existed.  Hundreds of unsatisfiable `depends on` clauses is exactly the
#      input that makes Kconfig start dropping symbols.
#
# CONCLUSION
#   Kconfig's cycle resolution is not something to be steered by counting
#   cycles or by deleting packages near the cycle.  The dependency graph has to
#   be pruned from the DEPENDENTS down, or via config, never by removing a
#   dependency out from under its users.  The video feed is therefore KEPT (see
#   feeds.conf.default - it was restored after this experiment), because keeping
#   it is what resolves qmodem on the revisions this project builds.
#
# What remains here is the assertion that actually earns its place: qmodem must
# survive defconfig.  That check already exists further down
# ("emitted package ... did not survive defconfig") and is the one that caught
# every instance of this.  The functions below only exist to give that failure
# a useful preamble.
#
# The php8 Config.in cycle (PHP8_INTL <-> PACKAGE_php8) is left alone on purpose:
# it exists in the healthy tree too, and luci-app-nekobox needs php8 when that
# switch is on.  A package-metadata.pl round-trip, not a removal, is the right
# fix there — out of scope for a build recipe.
prune_display_stack() {
	# Nothing is pruned.  The name is kept because prepare_feeds() and the
	# commit history refer to it, and because a stale feeds/video checkout from
	# a build predating the restore is still worth clearing - it would be
	# reinstalled by `feeds update` anyway, but leaving it avoids a confusing
	# intermediate state.
	#
	# Deliberately NOT done here:
	#   * enabling/disabling the video feed - that is feeds.conf.default's job
	#   * pruning multimedia/ or sound/ - see fact 5 above
	local _video="${SRC}/feeds/video"

	if [ -d "$_video" ] && ! grep -qE '^[[:space:]]*src-(git|link|svn|hg)[[:space:]]+video[[:space:]]' \
		"$SRC/feeds.conf.default"; then
		log "Removing feeds/video (feed is unconfigured; leftover from an earlier build)"
		rm -rf "$_video"
	fi

	return 0
}

# The proxy cycles, and why none of them gets to drop qmodem.
#
# These were first enumerated while the video feed was removed, and they are
# unchanged now that it is back — the two sets do not overlap:
#
#   luci-app-hijpass <-> sing-box-tiny <-> sing-box
#   luci-app-homeproxy <-> luci-app-homeproxy          (self)
#   php8 <-> PHP8_INTL <-> luci-app-nekobox
#   luci-app-momo <-> luci-app-momo                    (self)
#   momo <-> momo                                      (self)
#
# All five are third-party proxy front-ends.  Three of them - hijpass, nekobox
# and momo - are packages this image ASKS for, so they cannot simply be
# deleted; the rest are self-cycles on symbols nothing selects, which Kconfig
# resolves by dropping the symbol and no one notices.
#
# The reason none of them takes qmodem down is that a Kconfig drop is
# LOCAL to the cycle: it can only affect symbols reachable from the dropped
# one.  The qmodem dependency closure (qmodem, luci-app-qmodem-next,
# luci-app-qmodem-generic, qmodem-smsd, sms-forwarder-next, quectel-CM-5G-M,
# kmod-usb-net-qmi-wwan...) does not touch sing-box, momo, homeproxy or php8.
# Contrast wwand's libubus-lua-async loop, which DID kill qmodem: that symbol
# sits in the same Provides/Conflicts neighbourhood and defconfig dragged the
# dependents through.  Different closure, different outcome.
#
# An earlier revision of this file carried a prune_proxy_cycles() guard here.
# It asserted that no display/audio symbol (qt5, sdl, gstreamer1, gst1-*, gtk,
# wpewebkit, mesa, vulkan) had reappeared in the generated Kconfig graph, on
# the theory that those symbols were the precondition for the drop.  Fact 4
# above is what retired it: the experiment that removed the video feed - and
# with it those symbols - is precisely the one that DROPPED qmodem.  The guard
# would now fail on the healthy configuration, so it is gone rather than
# inverted.  The real check is the "did not survive defconfig" assertion below,
# which is config-based and therefore cannot be fooled by a proxy signal.
#
# A feed named in feeds.conf.default but absent from feeds/ means the feed set
# changed since the last update (e.g. qmodem was just switched on).  Skipping the
# update then would make `feeds install` fail with a confusing error.
feed_tree_is_complete() {
	local entry name
	while read -r entry name _; do
		case "$entry" in
			src-git | src-link | src-svn | src-hg)
				[ -d "${SRC}/feeds/${name}" ] || return 1
				;;
		esac
	done <"$SRC/feeds.conf.default"
	return 0
}

prepare_feeds() {
	cd "$SRC"

	write_feeds_conf
	prune_stale_feeds

	if is_true "$SKIP_FEEDS_UPDATE" && feed_tree_is_complete; then
		log "Skipping feeds update (--skip-feeds-update)"
	else
		if is_true "$SKIP_FEEDS_UPDATE"; then
			warn "--skip-feeds-update was requested, but a configured feed has no local checkout; updating anyway"
		else
			log "Updating feeds"
		fi
		run_with_timeout "$FEEDS_TIMEOUT" ./scripts/feeds update -a ||
			die "feeds update failed — refusing to build a firmware with missing packages"
	fi

	# Runs AFTER `feeds update` (a stale feeds/video checkout only exists once
	# something has fetched it) and BEFORE `feeds install`.  It no longer prunes
	# anything - see the note over the function - but the ordering still matters
	# if a future revision of it does.
	prune_display_stack

	log "Installing feeds"
	run_with_timeout "$FEEDS_TIMEOUT" ./scripts/feeds install -a ||
		die "feeds install failed"

	verify_wwand_feed
	fix_qmodem_feed
	verify_qmodem_feed
	verify_oaf_feed
}

# Two known upstream defects, both observed in LianXia233's CI (which builds
# this exact stack every day) and both fixed by patching the feed checkout:
#
#   1. version.mk ships QMODEM_VERSION like "3.4.0-rc.3"; apk rejects dashes in
#      versions, so rewrite to the apk-legal "3.4.0_rc3".
#   2. sms-forwarder-next gained "+qmodem-sipd" in DEPENDS, forming a chain
#      that ends in the qmodem-voip libwebsockets variant and makes the apk
#      staging fail with "unable to select packages".  The SIP channel is not
#      wanted here, so drop the dependency.
fix_qmodem_feed() {
	local feed="${SRC}/feeds/qmodem" ver sf

	[ -d "$feed" ] || return 0

	ver="${feed}/version.mk"
	if [ -f "$ver" ] && grep -qE '^QMODEM_VERSION:=[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$' "$ver"; then
		sed -i -E 's/^(QMODEM_VERSION:=)([0-9]+\.[0-9]+\.[0-9]+)-rc\.([0-9]+)$/\1\2_rc\3/' "$ver"
		log "qmodem: QMODEM_VERSION sanitized for apk ($(grep -E '^QMODEM_VERSION:=' "$ver"))"
	fi

	sf="${feed}/application/sms_forwarder_next/Makefile"
	if [ -f "$sf" ] && grep -q '+qmodem-sipd' "$sf"; then
		sed -i 's/ +qmodem-sipd//' "$sf"
		log "qmodem: removed +qmodem-sipd from sms-forwarder-next DEPENDS (apk staging conflict)"
	fi

	return 0
}

verify_qmodem_feed() {
	local feed="${SRC}/feeds/qmodem" d

	if [ ! -d "$feed" ]; then
		is_true "$ENABLE_QMODEM" &&
			warn "qmodem feed is not present — ENABLE_QMODEM will fail its package check"
		return 0
	fi

	for d in application/qmodem application/quectel_CM_5G_M luci/luci-app-qmodem-next; do
		[ -d "${feed}/${d}" ] || warn "qmodem feed is missing ${d}"
	done

	return 0
}

verify_oaf_feed() {
	if is_true "$ENABLE_OAF" && [ ! -d "${SRC}/feeds/oaf" ]; then
		warn "oaf feed is not present — ENABLE_OAF will fail its package check"
	fi
	return 0
}

# The ddimension feed is not one directory per package: `wwand/Makefile` alone
# defines wwand plus its qmi/mbim/ncm/mhi/esim/datapath subpackages.  So check
# the package *definitions* where they actually live, and only look for a
# directory for the two LuCI packages that really are separate.
verify_wwand_feed() {
	local feed="${SRC}/feeds/wwand" mk pkg

	# The feed is only installed when ENABLE_WWAND=true, so its absence on any
	# other build is the expected state, not a problem to report.
	if [ ! -d "$feed" ]; then
		is_true "$ENABLE_WWAND" &&
			warn "wwand feed is not present — ENABLE_WWAND will fail its package check"
		return 0
	fi

	mk="${feed}/wwand/Makefile"
	if [ ! -f "$mk" ]; then
		warn "wwand feed has no wwand/Makefile"
		return 0
	fi

	for pkg in wwand wwand-qmi wwand-ncm wwand-mbim wwand-mhi; do
		grep -q "^define Package/${pkg}\$" "$mk" ||
			warn "wwand feed no longer defines the ${pkg} package"
	done

	for pkg in luci-app-wwand luci-proto-wwand; do
		[ -d "${feed}/${pkg}" ] || warn "wwand feed is missing ${pkg}"
	done

	return 0
}

# Give every source file an mtime derived from its own content.
#
# OpenWrt decides whether a package needs rebuilding from a hash of each source
# file's PATH AND MTIME — include/depends.mk:14 is
#
#   find_md5 = find ... -printf "%p%T@\n" | sort | $(MKHASH) md5
#
# and that hash ends up in the stamp FILENAME:
#
#   build_dir/target-*/acl-2.3.2/.prepared_207a5f72c3f1e3ec911e99787f4e10bd_6664...
#
# A fresh `git clone` stamps every file with the checkout time, so an identical
# tree hashes differently on every clone, no cached stamp name ever matches, and
# `make` rebuilds all 475 packages.  Measured directly: touching a package
# directory moved its hash from 713e06ce... to 8f65ac22..., and no stamp with the
# new name existed.  This is why caching the build tree has never helped —
# including the toolchain cache, which was 996 MB of dead weight.
#
# Deriving the mtime from the content fixes both directions: identical content
# gives an identical mtime so the cached stamp is found, and changed content
# gives a different mtime so the package rebuilds.  Verified on a throwaway
# package: stable across re-clones, different when a byte changes, and the
# original hash returns when the byte is changed back.
#
# The timestamp is mapped into 2000-2019 so it stays behind the stamps the build
# writes, rather than landing in the future where it would look newer than
# everything.
#
# The hash is converted with pure POSIX arithmetic and the subprocess is BASH,
# not sh, and both of those are load-bearing.
#
# `$((16#$h))` is a bash-ism that dash rejects — `arithmetic expression:
# expecting EOF: " 946684800 + 16#cc85f855 % 630720000 "` — and it fails once
# per file, so the whole normalisation silently did nothing.  Debian/Ubuntu's
# /bin/sh is dash, so this never reproduced on a machine whose sh is bash, but
# every CI run printed it and every source file kept its checkout mtime.  Since
# OpenWrt's package stamp is a hash of path AND mtime, that alone was enough to
# make the restored build cache useless even when its bytes were intact.
#
# THE WHOLE POINT of this function is that the mtime is a pure function of the
# content, so it must not depend on a shell whose arithmetic syntax varies.
normalize_source_mtimes() {
	[ -d "$SRC" ] || return 0

	local scope=(
		-not -path '*/.git/*'
		-not -path "${SRC}/build_dir/*"
		-not -path "${SRC}/staging_dir/*"
		-not -path "${SRC}/bin/*"
		-not -path "${SRC}/tmp/*"
		-not -path "${SRC}/dl/*"
	)

	local count
	count="$(find "$SRC" -type f "${scope[@]}" 2>/dev/null | wc -l)"
	[ "$count" -gt 0 ] || return 0

	log "Normalizing mtimes of ${count} source files (content-derived, for cache reuse)"
	find "$SRC" -type f "${scope[@]}" -print0 2>/dev/null |
		xargs -0 -r -P "$(nproc 2>/dev/null || echo 4)" -n 64 bash -c '
			for f do
				h=$(sha1sum "$f" 2>/dev/null | cut -c1-8) || continue
				[ -n "$h" ] || continue
				# 8 hex digits as an unsigned value: 16# is bash-only, so fold
				# the nibbles explicitly.
				n=0
				i=0
				while [ "$i" -lt 8 ]; do
					c=${h:$i:1}
					case "$c" in
						[0-9]) d=$c ;;
						a|A) d=10 ;; b|B) d=11 ;; c|C) d=12 ;; d|D) d=13 ;;
						e|E) d=14 ;; f|F) d=15 ;;
						*) n=""; break ;;
					esac
					n=$(( n * 16 + d ))
					i=$(( i + 1 ))
				done
				[ -n "$n" ] || continue
				# 2000-01-01 + (hash mod 20 years), always in the past.
				touch -d "@$(( 946684800 + n % 630720000 ))" "$f" 2>/dev/null || true
			done
		' _ || warn "Some source mtimes could not be normalized"

	return 0
}

# Install a fixed apk signing key, if one was handed to us.
#
# OpenWrt signs the package index with $(TOPDIR)/private-key.pem and installs the
# matching public key at /etc/apk/keys/public-key.pem in the image.  Left alone,
# every build generates a FRESH pair, and that breaks the published repository:
# the index on GitHub Pages is overwritten by each build and signed with that
# build's key, so a device flashed from an earlier build sees
#
#   WARNING: updating <url>: UNTRUSTED signature
#
# with the packages then unavailable.  Reproduced against the live Pages index
# with the firmware's own apk.
#
# Given one key for every build, the public key ships in every image and matches
# the index, so any device trusts any build's repository.
install_signing_key() {
	local src="${H5000M_SIGNING_KEY_FILE:-}"

	[ -n "$src" ] || return 0
	[ -f "$src" ] || {
		warn "H5000M_SIGNING_KEY_FILE=${src} does not exist; signing with a per-build key"
		return 0
	}

	cp -f "$src" "${SRC}/private-key.pem"
	chmod 0600 "${SRC}/private-key.pem"
	# `pkey`, not `ec`: the stored secret's type is never assumed — pkey handles
	# EC, RSA and Ed25519 alike — so replacing the key material with a different
	# type cannot silently degrade into "Could not derive the public key", where
	# the index is signed but no device ever gets the matching public key.
	if openssl pkey -in "${SRC}/private-key.pem" -pubout -out "${SRC}/public-key.pem" 2>/dev/null; then
		log "Installed the fixed apk signing key (public key derived and shipped in the image)"
	else
		warn "Could not derive the public key; the image would not trust the index"
	fi
	return 0
}

# Restore the cached build tree, if the CI fetched one from GitHub Packages.
#
# This is the part that actually saves hours: build_dir/target-* holds one build
# directory per package along with the .built stamps, so packages whose sources
# did not change are simply not rebuilt.  It only works because
# normalize_source_mtimes runs too — see the note there.
seed_cached_build_state() {
	local archive="${BUILD_CACHE_ARCHIVE:-}"

	[ -n "$archive" ] || return 0

	# If the exact path is missing, look around before giving up.  A cache that
	# is downloaded and then silently unused is the worst outcome: it costs the
	# transfer and saves nothing.  This is how the oras title bug above went
	# unnoticed for a whole run.
	if [ ! -f "$archive" ]; then
		local found
		found="$(find "$(dirname "$archive")" "$(dirname "$(dirname "$archive")")" \
			-name "$(basename "$archive")" -type f 2>/dev/null | head -1)"
		if [ -n "$found" ]; then
			warn "Build cache was not at ${archive}; using ${found}"
			archive="$found"
		else
			log "No cached build state at ${archive}"
			return 0
		fi
	fi

	log "Seeding build state from cache ($(du -h "$archive" | cut -f1))"

	# Test the compressed stream before spending minutes unpacking it into the
	# tree.  A truncated archive fails with "premature end" part-way through,
	# which leaves a half-populated build_dir behind and makes the real cause
	# hard to see.  The caller (CI) now removes a cache that fails this test, but
	# keep the check here too: this script is also run by hand.
	if command -v zstd >/dev/null 2>&1; then
		if ! zstd -t "$archive" >/dev/null 2>&1; then
			warn "Cached build state at ${archive} is truncated or corrupt (zstd -t failed); ignoring it"
			return 0
		fi
	fi

	mkdir -p "${SRC}"
	if tar -I zstd -xf "$archive" -C "${SRC}"; then
		log "Build cache applied; unchanged packages should be skipped"
	else
		warn "Could not unpack the cached build state; everything will rebuild"
	fi
	return 0
}

# Restore a previously cached toolchain, if one was handed to us.
#
# The CI caches the toolchain because building it is the longest single phase.
# It arrives as an archive rather than as openwrt/staging_dir directly: caching
# that directory makes the cache restore create openwrt/ before anything else
# runs, and prepare_source's `git clone` then fails with "destination path
# already exists and is not an empty directory".  Extracting after the clone
# avoids that, and the archive is keyed on the upstream revision so a stale
# toolchain is never used.
seed_cached_toolchain() {
	local archive="${TOOLCHAIN_CACHE_ARCHIVE:-}"

	[ -n "$archive" ] || return 0
	[ -f "$archive" ] || {
		log "No cached toolchain at ${archive}"
		return 0
	}

	log "Seeding toolchain from cache ($(du -h "$archive" | cut -f1))"
	# Unpacked at the source root: the archive holds build_dir/toolchain-* as
	# well as staging_dir/*, and both are needed.  The stamps that make `make`
	# skip the toolchain live in build_dir, not in staging_dir.
	mkdir -p "${SRC}"
	if tar -I zstd -xf "$archive" -C "${SRC}" 2>/dev/null ||
		tar -xf "$archive" -C "${SRC}"; then
		log "Toolchain cache applied; the toolchain build should be skipped"
	else
		warn "Could not unpack the cached toolchain; building it from scratch"
	fi
	return 0
}

# --------------------------------------------------------------- patches -----
apply_patches() {
	local patch_file name paths applied=0

	shopt -s nullglob
	for patch_file in "${ROOT_DIR}"/patches/*.patch; do
		name="$(basename "$patch_file")"

		# A patch that only INSERTS lines is not idempotent under `git apply`:
		# the surrounding context still matches afterwards, so a second run
		# inserts a second copy of the block.  0001-h5000m-userspace-fan-control
		# has exactly that shape — applying it twice yields two
		# /delete-node/ blocks in the DTS, which dtc then rejects.
		#
		# The `--reverse --check` test below cannot catch this, so the real
		# protection is prepare_source's `git reset --hard`.  Rather than trust
		# that implicitly, assert it: refuse to apply a patch on top of a tree
		# where the files it touches are already modified.  feeds.conf.default
		# is deliberately excluded by scoping the test to the patch's own
		# paths, because prepare_feeds legitimately rewrites it before this
		# point.
		paths="$(git -C "$SRC" apply --numstat "$patch_file" 2>/dev/null | cut -f3-)"
		if [ -n "$paths" ] &&
			[ -n "$(git -C "$SRC" status --porcelain --untracked-files=no -- $paths)" ]; then
			die "${name} targets files that are already modified in ${SRC} — the tree was not reset; applying it would duplicate inserted blocks"
		fi

		if git -C "$SRC" apply --check "$patch_file" >/dev/null 2>&1; then
			git -C "$SRC" apply "$patch_file" || die "Failed to apply ${name}"
			log "Applied patch ${name}"
			applied=$((applied + 1))
		elif git -C "$SRC" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
			log "Patch ${name} already applied"
		else
			die "Patch ${name} does not apply to $(git -C "$SRC" log --oneline -1) — upstream changed the files it touches; refresh that patch in patches/"
		fi
	done
	shopt -u nullglob

	if [ "$applied" -gt 0 ]; then
		log "Applied ${applied} tree patch(es)"
	fi
	return 0
}

# --------------------------------------------------------- version pins ------
# Pin sing-box to the version the LuCI front-ends can actually drive.
#
# sing-box 1.13.0 removed the legacy inbound fields.  HomeProxy still emits
# them on master and dev, and PassWall2 fails the same way, so the daemon dies
# with:
#
#   FATAL decode config ... inbounds[1]: legacy inbound fields are deprecated
#   in sing-box 1.11.0 and removed in 1.13.0
#
# 1.12.25 is the last release accepting them, and apk resolves dependencies to
# the HIGHEST version across every configured repository — so the pin also has
# to decide what gets installed (the package ships in the image; see the note
# in append_board_stack_config).
#
# This used to be patches/0003, a context patch.  A context patch bakes the
# CURRENT upstream version into its +/- lines, so the next routine upstream
# bump (1.14.0 -> 1.15.0) makes it fail to apply and the scheduled build dies
# at apply_patches — over a change whose entire point is to IGNORE what
# upstream decided.  Rewriting the lines directly cannot go stale that way: it
# pins whatever version is there, verifies the result, and dies loudly (not
# silently) if upstream ever stops packaging sing-box the normal way.
pin_sing_box() {
	local mk="${SRC}/feeds/packages/net/sing-box/Makefile"
	local want_v="1.12.25"
	local want_h="881435f07b5ab8170ccf3cb69e87130759521dc0ed1ae4bfeacbe7772a93a158"

	if [ ! -f "$mk" ]; then
		die "cannot pin sing-box: ${mk} does not exist — the packages feed layout changed; update pin_sing_box in scripts/local-build.sh"
	fi

	# Idempotent: a tree from a previous run (or an already-pinned checkout)
	# carries the pin, and `feeds update` on the next run restores upstream's
	# version, which this then pins again.
	if grep -q "^PKG_VERSION:=${want_v}$" "$mk" &&
		grep -q "^PKG_HASH:=${want_h}$" "$mk"; then
		log "sing-box already pinned to ${want_v}"
		return 0
	fi

	# Refuse to guess: if upstream stopped writing plain PKG_VERSION / PKG_HASH
	# lines (switched to a git proto, renamed the variables), a blind sed would
	# silently pin nothing and the front-ends would break on a device instead of
	# the build failing here.
	if ! grep -q '^PKG_VERSION:=' "$mk" || ! grep -q '^PKG_HASH:=' "$mk"; then
		die "cannot pin sing-box: ${mk} no longer has plain PKG_VERSION/PKG_HASH lines; re-check how upstream packages it and update pin_sing_box"
	fi

	sed -i \
		-e "s|^PKG_VERSION:=.*|PKG_VERSION:=${want_v}|" \
		-e "s|^PKG_HASH:=.*|PKG_HASH:=${want_h}|" \
		"$mk"
	# PKG_RELEASE, when present, is pinned to 1 as well: the repository gates
	# (verify-apk-repo.sh and the build.yml publish gate) assert the exact
	# `sing-box-1.12.25-r1` name, and upstream bumps PKG_RELEASE for packaging
	# changes that have nothing to do with our pin.
	grep -q '^PKG_RELEASE:=' "$mk" && sed -i 's|^PKG_RELEASE:=.*|PKG_RELEASE:=1|' "$mk"

	if ! grep -q "^PKG_VERSION:=${want_v}$" "$mk" ||
		! grep -q "^PKG_HASH:=${want_h}$" "$mk"; then
		die "pinning sing-box in ${mk} did not take; refusing to build an unpinned sing-box"
	fi

	log "sing-box pinned to ${want_v} (the front-ends still emit removed legacy inbound fields)"
	return 0
}

# Pin the clash-rs core to a version that actually understands the config the
# front-end generates.
#
# Why this is needed: OpenWrt-nikki-rs is cloned from `main`, but its
# `clash-rs/Makefile` pins the prebuilt core to `v0.20.0-alpha` — upstream does
# not bump that pin when it adds a config field.  Measured: the feed's
# `mixin.uc` started emitting `ebpf.lan.proxy-src-macs` in commit 424abb38
# (2026-09-26), while the pinned core only learned that field in
# `v0.20.10-alpha`.  The two are version-independent, so a fresh clone of the
# feed generates a key the pinned binary has never heard of.
#
#     $ clash-rs -t -f config.yaml --strict-config
#     test failed: invalid config: unknown field(s) in config:
#         ebpf.?.lan.proxy-src-macs
#
# Note what does NOT happen: `nikki-rs.init` starts the core WITHOUT
# `--strict-config` (measured on the feed's main branch — the procd command is
# `exec $PROG -d $RUN_DIR`), and clash-rs silently ignores unknown fields by
# default.  So this does not crash.  It is worse in a quieter way: the user
# ticks "Proxy Client MACs" on the eBPF page, UCI stores it, a config with the
# key is generated, the core drops the key on the floor, and the MAC whitelist
# silently proxies every client instead of only the listed ones.  A security
# control that reports success while doing nothing is the failure mode this
# whole project treats as its worst.
#
# Fixing it by pinning the core rather than by patching the feed's `mixin.uc`
# is deliberate: the field list grows upstream, and a local patch would have to
# be re-synced on every such commit.  Pinning the core keeps the two halves in
# step by construction.
#
# The rewrite is a plain text substitution with a post-check, following
# pin_sing_box.  It dies loudly rather than silently pinning nothing if upstream
# restructures the Makefile.
pin_clash_rs() {
	local mk="${SRC}/package/OpenWrt-nikki-rs/clash-rs/Makefile"
	local want_v="0.20.10_alpha"
	local want_url="https://github.com/CHKayanami/clash-rs/releases/download/v0.20.10-alpha/"

	# Only when the package is actually part of this build.  Every ENABLE_NIKKI
	# path that pulls the front-end also pulls the core, and
	# ENABLE_REPO_PACKAGES builds it into the repository, so those are exactly
	# the two conditions under which the Makefile exists.
	if ! is_true "$ENABLE_NIKKI" && ! is_true "$ENABLE_REPO_PACKAGES"; then
		return 0
	fi

	if [ ! -f "$mk" ]; then
		# Not fatal on its own: the clone is gated on ENABLE_NIKKI_REPO /
		# ENABLE_NIKKI above, and a `warn` from clone_external already explains
		# a failed clone.  But if the core is required for the image, a missing
		# Makefile is a hard error.
		if is_true "$ENABLE_NIKKI"; then
			die "cannot pin clash-rs: ${mk} does not exist — Nikki-RS was enabled but the core did not clone; see the clone warnings above"
		fi
		warn "clash-rs Makefile not present; skipping the core pin"
		return 0
	fi

	# The upstream Makefile writes the hash as $(CLASH_HASH) and sets
	# PKG_HASH:=$(CLASH_HASH), with one `CLASH_HASH:=` line per architecture
	# inside ifneq blocks.  A blind `sed` on PKG_HASH would rewrite the
	# indirection and pin nothing, so the per-arch lines are what get replaced.
	if ! grep -q '^  CLASH_HASH:=' "$mk"; then
		die "cannot pin clash-rs: ${mk} no longer has per-arch CLASH_HASH lines; re-check how upstream downloads the core and update pin_clash_rs"
	fi

	# The tarball name carries no version (`clash-rs-minimal-<target>.tar.gz`),
	# so a stale copy of the OLD release sits in dl/ under the SAME filename.
	# OpenWrt's check_download_integrity adds a FORCE rule when the cached hash
	# differs from HASH, so the download stage replaces it — but only because
	# PKG_HASH changes here.  That is also why the hash has to be right: a
	# wrong-but-stable hash would keep the old binary and every check would pass.
	local aarch64_h="b6ad0f7014d6fc03a9ab56cd1a61ea61574db9e3e483a637cc04bf022bf6c065"
	local x86_64_h="1ac876892965b3249659931c0c6f7e3dc87673daeab90f4a9744ff2caf5fb139"
	local armv7_h="33321d4b6311714a91992fe0a5f5f78de1e169653e9603d9556deb01813400c9"
	local riscv64_h="bc9d29081f7a665e82135045c30eedb6d37b642013cd20ef056c109f588b35ad"
	local i686_h="834cc83b4d34f0c06126f51d4de0584ce74540c0bcf3e1edc67b342e2fbf4136"

	# Replace the version, the release URL and every architecture hash.  Done
	# with awk rather than sed because the hash lines are indented and identical
	# in form, so a line-oriented rewrite keyed on the neighbouring CLASH_TARGET
	# is the only way to tell them apart.
	awk -v v="$want_v" -v url="$want_url" \
		-v ha="$aarch64_h" -v hx="$x86_64_h" -v hv="$armv7_h" \
		-v hr="$riscv64_h" -v hi="$i686_h" '
		/^PKG_VERSION:=/ { print "PKG_VERSION:=" v; next }
		/^PKG_SOURCE_URL:=/ { print "PKG_SOURCE_URL:=" url; next }
		/^  CLASH_TARGET:=/ { target=$0; sub(/^  CLASH_TARGET:=/, "", target); print; next }
		/^  CLASH_HASH:=/ {
			h = ""
			if (target == "aarch64-unknown-linux-musl") h = ha
			else if (target == "x86_64-unknown-linux-musl") h = hx
			else if (target == "armv7-unknown-linux-musleabihf") h = hv
			else if (target == "riscv64gc-unknown-linux-musl") h = hr
			else if (target == "i686-unknown-linux-musl") h = hi
			if (h == "") {
				print "  CLASH_HASH:=" substr($0, index($0, ":=") + 2)
			} else {
				print "  CLASH_HASH:=" h
			}
			next
		}
		{ print }
	' "$mk" >"${mk}.pinned" && mv "${mk}.pinned" "$mk"

	if ! grep -q "^PKG_VERSION:=${want_v}$" "$mk" ||
		! grep -q "^PKG_SOURCE_URL:=${want_url}$" "$mk"; then
		die "pinning clash-rs in ${mk} did not take; refusing to build an unpinned core"
	fi

	# Verify what was actually rewritten.  The check is deliberately "every
	# known arch that appears in the file now carries the new hash", NOT "all
	# five arches must appear": upstream may drop or add an architecture at any
	# time, and failing the build over an arch this target does not use would
	# be a false alarm.  What must never pass silently is a known arch left
	# holding the OLD hash, because that is a stale core with a green build.
	local arch got want pinned=0 unpinned=""
	for arch in \
		"aarch64-unknown-linux-musl:${aarch64_h}" \
		"x86_64-unknown-linux-musl:${x86_64_h}" \
		"armv7-unknown-linux-musleabihf:${armv7_h}" \
		"riscv64gc-unknown-linux-musl:${riscv64_h}" \
		"i686-unknown-linux-musl:${i686_h}"; do
		want="${arch##*:}"
		got="$(awk -v t="${arch%%:*}" '
			/^  CLASH_TARGET:=/ { cur = $0; sub(/^  CLASH_TARGET:=/, "", cur) }
			/^  CLASH_HASH:=/ && cur == t { sub(/^  CLASH_HASH:=/, ""); print; exit }
		' "$mk")"
		# Absent from the file: upstream does not build it, nothing to check.
		[ -n "$got" ] || continue
		if [ "$got" = "$want" ]; then
			pinned=$((pinned + 1))
		else
			unpinned="${unpinned} ${arch%%:*}"
		fi
	done

	[ -z "$unpinned" ] ||
		die "clash-rs hash was not pinned for:${unpinned} — those blocks kept the old hash, which would silently ship the old core"
	# At least one has to have matched, or the awk rewrite was a no-op and the
	# version/URL assertions above passed for some other reason.
	[ "$pinned" -gt 0 ] ||
		die "clash-rs pin matched no architecture block in ${mk}; the Makefile layout changed and pin_clash_rs needs updating"

	log "clash-rs pinned to ${want_v} (the feed's eBPF page emits proxy-src-macs and quic, which v0.20.0-alpha lacks)"
	return 0
}

# Insert `new` after the first line containing `anchor`, exactly once.  A file
# that already carries `new` is left alone, so a re-run over an already-patched
# tree is not an error.  Dies if the anchor is gone: a rewrite that quietly
# stops matching is the failure this project treats as its worst, because the
# build stays green and ships a default that no longer protects anything.
insert_after_anchor() {
	local file="$1" anchor="$2" new="$3"

	if grep -qF -- "$new" "$file"; then
		return 0
	fi
	grep -qF -- "$anchor" "$file" ||
		die "cannot patch $(basename "$file"): anchor not found: ${anchor}"

	awk -v a="$anchor" -v n="$new" '
		{ print }
		!done && index($0, a) > 0 { print n; done = 1 }
	' "$file" >"${file}.ebpf-patched" ||
		die "cannot patch $(basename "$file"): awk failed"

	mv -f "${file}.ebpf-patched" "$file"

	grep -qF -- "$new" "$file" ||
		die "patching $(basename "$file") did not take effect (wanted: ${new})"
	return 0
}

# The same for the `o.default = [ ... ];` array in the LuCI view, inserting
# BEFORE the anchor.  That file has four `o.default =` assignments and the
# single-line ones close on their own line, so the text has to be scoped to the
# multi-line array: a file-wide insert on `'224.0.0.0/4',` would also hit the
# section-creation list, which already has the entry this is meant to add.
insert_in_default_block() {
	local file="$1" anchor="$2" new="$3" block

	block="$(awk '/o\.default = \[/,/\];/' "$file")"
	printf '%s\n' "$block" | grep -qF -- "$new" && return 0
	printf '%s\n' "$block" | grep -qF -- "$anchor" ||
		die "cannot patch $(basename "$file"): the bypass_dst_ips default block no longer contains ${anchor}"

	awk -v a="$anchor" -v n="$new" '
		/o\.default = \[/,/\];/ {
			if (!done && index($0, a) > 0) { print n; done = 1 }
		}
		{ print }
	' "$file" >"${file}.ebpf-patched" ||
		die "cannot patch $(basename "$file"): awk failed"

	mv -f "${file}.ebpf-patched" "$file"

	block="$(awk '/o\.default = \[/,/\];/' "$file")"
	printf '%s\n' "$block" | grep -qF -- "$new" ||
		die "patching $(basename "$file") did not take effect (wanted: ${new})"
	return 0
}

# The eBPF bypass list has to name the router's own networks, and on the IPv6
# side upstream's default does not.
#
# The list decides one thing: which destinations the kernel hook must NOT take
# over, because they belong to the router itself.  Traffic addressed to the
# router has to be delivered locally — that is the difference between a LAN
# client's DNS query being answered by dnsmasq and being swallowed by the
# datapath.  Upstream ships 192.168.0.0/16 for IPv4 and, for IPv6, only
# ::1/128 (loopback), fe80::/10 (link-local) and ff00::/8 (multicast).
#
# This firmware always has an IPv6 LAN — base-files' config_generate sets
# `ula_prefix 'auto'` and 12_network-generate-ula derives fdXX:XXXX:XXXX::/48
# from it, so odhcpd advertises a ULA as the resolver address — and `fc00::/7`
# is the whole ULA range, which is never a public destination.  With no entry
# covering it, eBPF mode captures every IPv6 packet addressed to the router
# while the IPv4 equivalent is bypassed: IPv6 name resolution fails, IPv4 does
# not.  Reported on a real device as "开启 eBPF 后 IPv6 解析不对".
#
# Three copies of that default exist and all three are patched, so a fresh
# install, a migrated section and the LuCI page agree:
#   nikki-rs/files/nikki-rs.conf             the config a fresh install gets
#   nikki-rs/files/uci-defaults/migrate.sh   the eBPF section created on upgrade
#   luci-app-nikki-rs/.../ebpf.js            the page's own default for the field
#
# The page's copy had also drifted on IPv4: it was missing 192.168.0.0/16, which
# the other two carry.  A user who clears the field and saves would get a list
# without the IPv4 LAN in it, and docs/engineering.md's "连管理页面都进不去" is
# then one save away.
#
# What this does NOT do is pin the LAN's real prefix: that differs per device and
# is derived at boot by local-packages/luci-app-h5000m-accel (see its
# apply_ebpf_bypass_ips).  These are the static defaults that hold before the
# applier has ever run.
patch_nikki_ebpf_bypass_defaults() {
	local dir="${SRC}/package/OpenWrt-nikki-rs"
	local conf="${dir}/nikki-rs/files/nikki-rs.conf"
	local mig="${dir}/nikki-rs/files/uci-defaults/migrate.sh"
	local js="${dir}/luci-app-nikki-rs/htdocs/luci-static/resources/view/nikki-rs/ebpf.js"
	local f

	# Same condition as clone_for_repo_or_image: the tree only exists when the
	# package is cloned into the image or into the repository.
	if ! is_true "$ENABLE_REPO_PACKAGES" && ! is_true "$ENABLE_NIKKI"; then
		return 0
	fi

	for f in "$conf" "$mig" "$js"; do
		[ -f "$f" ] && continue
		if is_true "$ENABLE_NIKKI"; then
			die "cannot patch the eBPF IPv6 bypass defaults: ${f} does not exist — Nikki-RS was enabled but the package did not clone; see the clone warnings above"
		fi
		warn "Nikki-RS file ${f} is missing; skipping the eBPF bypass default patch"
		return 0
	done

	insert_after_anchor "$conf" \
		"list bypass_dst_ips 'fe80::/10'" \
		"	list bypass_dst_ips 'fc00::/7'"
	insert_after_anchor "$mig" \
		"uci add_list nikki-rs.ebpf.bypass_dst_ips='fe80::/10'" \
		"	uci add_list nikki-rs.ebpf.bypass_dst_ips='fc00::/7'"

	insert_in_default_block "$js" "'224.0.0.0/4'," "            '192.168.0.0/16',"
	insert_in_default_block "$js" "'ff00::/8'" "            'fc00::/7',"

	log "eBPF bypass defaults: fc00::/7 added to the shipped config and the migration, 192.168.0.0/16 restored to the page default"
	return 0
}

# --------------------------------------------------------------- staging -----
stage_directory() {
	local from="$1" to="$2"

	mkdir -p "$to"
	if command -v rsync >/dev/null 2>&1; then
		rsync -a --delete-after --exclude '.git' "${from}/" "${to}/"
	else
		rm -rf "$to"
		mkdir -p "$to"
		cp -a "${from}/." "$to/"
		rm -rf "${to}/.git"
	fi
}

install_local_packages() {
	local pkg

	shopt -s nullglob
	for pkg in "${ROOT_DIR}"/local-packages/*/; do
		local name
		name="$(basename "$pkg")"
		log "Staging local package ${name}"
		stage_directory "$pkg" "${SRC}/package/${name}"
	done
	shopt -u nullglob

	write_h5000m_runtime_config
}

# Two files the firmware needs at runtime, generated from build inputs rather
# than committed as constants:
#
#   /etc/h5000m-defaults.conf       the first-boot SSID/key/country and the
#                                   hardware-offload switches
#   /etc/apk/repositories.d/50-h5000m.list
#                                   this project's own apk repository, so the
#                                   service packages (=m) and every kmod can be
#                                   installed on the running router
#
# They are written into the staged package's files/ tree, which is what the
# OpenWrt build copies into the image.  Doing it here keeps the package itself
# free of machine-specific values and keeps a stale file from a previous build
# out of the image — the tree is re-staged from local-packages/ on every run.
write_h5000m_runtime_config() {
	local pkg_dir="${SRC}/package/h5000m-integration"
	local repo_dir="${pkg_dir}/files/etc/apk/repositories.d"
	local conf="${pkg_dir}/files/etc/h5000m-defaults.conf"

	[ -d "$pkg_dir" ] || return 0

	mkdir -p "$repo_dir"

	# The values below land inside single quotes in a shell file that
	# h5000m-firstboot sources on the device.  A value containing a single
	# quote or a newline would produce a syntactically broken file — and dash
	# exits when a sourced file has a syntax error, which would kill the
	# first-boot script and leave the radios unconfigured on every boot, with
	# nothing in the logs but a one-line parse error.  Refuse to build instead.
	local var val
	for var in H5000M_WIFI_SSID H5000M_WIFI_KEY H5000M_WIFI_COUNTRY \
		H5000M_WIFI_ENCRYPTION H5000M_WIFI_HTMODE_2G H5000M_WIFI_HTMODE_5G \
		H5000M_FLOW_OFFLOAD H5000M_FLOW_OFFLOAD_HW; do
		val="${!var}"
		case "$val" in
			*"'"*) die "${var} contains a single quote — /etc/h5000m-defaults.conf would not be valid shell. Change the value and rebuild." ;;
		esac
		if [[ "$val" == *$'\n'* ]]; then
			die "${var} contains a newline — /etc/h5000m-defaults.conf would not be valid shell. Change the value and rebuild."
		fi
	done

	cat >"$conf" <<EOF
# Generated by scripts/local-build.sh — do not edit; edit the build instead.
H5000M_WIFI_SSID='${H5000M_WIFI_SSID}'
H5000M_WIFI_KEY='${H5000M_WIFI_KEY}'
H5000M_WIFI_COUNTRY='${H5000M_WIFI_COUNTRY}'
H5000M_WIFI_ENCRYPTION='${H5000M_WIFI_ENCRYPTION}'
H5000M_WIFI_HTMODE_2G='${H5000M_WIFI_HTMODE_2G}'
H5000M_WIFI_HTMODE_5G='${H5000M_WIFI_HTMODE_5G}'
H5000M_FLOW_OFFLOAD='${H5000M_FLOW_OFFLOAD}'
H5000M_FLOW_OFFLOAD_HW='${H5000M_FLOW_OFFLOAD_HW}'
EOF

	# Root-only: this file carries the WiFi key in clear text, and the package
	# install copies modes verbatim.
	chmod 0600 "$conf"

	# The stock distfeeds.list points every entry at downloads.openwrt.org, and
	# those kmods carry a DIFFERENT vermagic from this image, so `apk add` of
	# anything with a kmod dependency fails there.  customfeeds.list is the
	# file OpenWrt reserves for additions and explicitly survives sysupgrade.
	if [ -n "${H5000M_APK_REPO_URL:-}" ]; then
		{
			printf '# This project'"'"'s own apk repository: every package from the same\n'
			printf '# build as this firmware, so the kmods match this kernel ABI.\n'
			printf '# The repository is the apk-repo/ artifact; serve that directory\n'
			printf '# over HTTP(S) and point H5000M_APK_REPO_URL at it.\n'
			printf '%s/packages.adb\n' "${H5000M_APK_REPO_URL%/}"
		} >"${repo_dir}/50-h5000m.list"
		log "Firmware apk source: ${H5000M_APK_REPO_URL%/}/packages.adb"
	else
		# No URL configured.  Remove any file a previous run left behind rather
		# than ship entries pointing at a host that does not exist.
		rm -f "${repo_dir}/50-h5000m.list"
		log "Firmware apk source: none configured (set H5000M_APK_REPO_URL to add one)"
	fi

	return 0
}

# HigoOS preservation overlay — copy higoros-overlay/ into the build tree's
# files/ directory.  OpenWrt copies files/ verbatim into the generated rootfs,
# which is exactly how the vendor binaries (higorosd, the Vue UI, the
# userspace fan controller and the MT7992 EEPROM data) ride a mainline image
# without becoming packages.  A marker file records that files/ is ours so a
# later build with the switch off can safely clean it up.
stage_higoros_overlay() {
	local marker="${SRC}/files/.higoros-overlay"

	if is_true "$ENABLE_HIGOROS"; then
		if [ ! -d "${ROOT_DIR}/higoros-overlay" ]; then
			die "ENABLE_HIGOROS=true but higoros-overlay/ is missing from the repo — refusing to build a firmware the panel feature promises but cannot deliver"
		fi
		log "Staging HigoOS overlay into files/"
		stage_directory "${ROOT_DIR}/higoros-overlay" "${SRC}/files"
		touch "$marker"
	elif [ -f "$marker" ]; then
		log "Removing stale HigoOS overlay from files/"
		rm -rf "${SRC}/files"
	fi

	return 0
}

# clone_external <name> <url> <branch> — pull a third-party package tree into
# package/ the same way the previous harness did.  These projects are not in
# the official feeds and are the user's own risk; they are all opt-in.
clone_external() {
	# Split across two statements on purpose: `local a="$1" b="${a}"` expands
	# every argument before assigning any of them, so `b` would see an unbound
	# `a` under `set -u`.
	local name="$1" url="$2" branch="${3:-main}"
	local dest="${SRC}/package/${name}"

	# Every tree in package/ that came from a third party rather than an official
	# feed is recorded here, because that is exactly the set whose
	# PKG_MIRROR_HASH cannot be trusted: those hashes are generated by the other
	# project's own build, which uses a different tar and xz and therefore
	# produces a different tarball.  fix_mirror_hashes reads this list.
	#
	# Recording it at the single clone funnel instead of keeping a hand-written
	# list means a tree added later is covered automatically.  The hand-written
	# version had already drifted: it named only package/luci-app-ssr-plus, and
	# it ran before that directory was cloned at all.
	CLONED_PACKAGE_DIRS+=("$dest")

	if [ -d "${dest}/.git" ]; then
		log "Updating external package ${name}"
		if run_with_timeout "$GIT_TIMEOUT" git -C "$dest" fetch --depth 1 origin "$branch" &&
			git -C "$dest" checkout -f FETCH_HEAD; then
			return 0
		fi
		# A usable checkout already exists; a transient fetch failure should not
		# kill the build.
		warn "Could not update ${name}; keeping the existing checkout"
		return 0
	fi

	log "Cloning external package ${name} (${branch})"
	if ! git_clone_retry "$url" "$branch" "$dest"; then
		warn "Could not clone ${name} from ${url}"
		return 1
	fi
	return 0
}

# The three H5000M board plugins are maintained outside any feed, so they are
# cloned into package/ like the previous harness cloned luci-app-Airpifanctrl
# and luci-app-turboacc-mtk.  They are required packages: if the clone fails the
# build stops rather than shipping an image with no fan control or no egress
# arbitration.
install_board_plugins() {
	local failed=0

	if is_true "$ENABLE_FANCONTROL"; then
		clone_external luci-app-h5000m-fancontrol \
			https://github.com/FAN789/luci-app-h5000m-fancontrol.git main ||
			failed=1
	fi

	if is_true "$ENABLE_NETMODE"; then
		clone_external luci-app-h5000m-netmode \
			https://github.com/FAN789/luci-app-h5000m-netmode.git main ||
			failed=1
	fi

	if is_true "$ENABLE_EASYMESH"; then
		# Only this one directory is wanted out of coolsnowwolf/luci.
		clone_only_paths luci-easymesh \
			https://github.com/coolsnowwolf/luci.git master \
			applications/luci-app-easymesh ||
			failed=1
	fi

	if is_true "$ENABLE_MT5700M"; then
		clone_external luci-app-mt5700m \
			https://github.com/FAN789/luci-app-mt5700m.git main ||
			failed=1
	fi

	if [ "$failed" -ne 0 ]; then
		die "Could not fetch the H5000M board plugins — refusing to build a firmware without them"
	fi

	return 0
}

# QModem parts that live outside the FUjr feed: LianXia233's generic modem UI
# is its own repository (LUCI_DEPENDS +qmodem; it injects the built-in module
# definition library that covers the RG520N-CN).  Cloned into package/ like
# the board plugins, and required when ENABLE_QMODEM is on — a QModem build
# without it is a build with no modem page.
install_qmodem_extras() {
	local failed=0

	if is_true "$ENABLE_QMODEM"; then
		clone_external luci-app-qmodem-generic \
			https://github.com/LianXia233/luci-app-qmodem-generic.git main ||
			failed=1
	fi

	if [ "$failed" -ne 0 ]; then
		die "Could not fetch luci-app-qmodem-generic — refusing to build a QModem firmware without its panel"
	fi

	return 0
}

# Argon lives in two repositories outside every feed, so it is cloned into
# package/ exactly like the board plugins rather than pulled from a feed.
# Both Makefiles include $(TOPDIR)/feeds/luci/luci.mk, so this has to run after
# the feeds are installed.
#
# The clone failure is fatal rather than a warning: the seed lists
# luci-theme-argon and luci-app-argon-config as required packages, so a silent
# fetch failure would resurface much later as an opaque defconfig complaint
# about an unknown package instead of as a network error here.
install_theme() {
	if ! is_true "$ENABLE_THEME_ARGON"; then
		log "Argon theme disabled (ENABLE_THEME_ARGON=false) — keeping the stock theme"
		return 0
	fi

	clone_external luci-theme-argon "$ARGON_THEME_REPO_URL" "$ARGON_THEME_REPO_BRANCH" ||
		die "Could not fetch luci-theme-argon from ${ARGON_THEME_REPO_URL}"
	clone_external luci-app-argon-config "$ARGON_CONFIG_REPO_URL" "$ARGON_CONFIG_REPO_BRANCH" ||
		die "Could not fetch luci-app-argon-config from ${ARGON_CONFIG_REPO_URL}"

	return 0
}

# Clone one optional third-party package on behalf of an ENABLE_* switch.
#
# The switch name is part of the failure message on purpose.  Under `set -e` a
# failing `is_true X && clone_external ...` aborts the whole run, and the only
# thing the user sees is the raw git error ("Repository not found") — which does
# not name the switch to turn off, nor the URL that is wrong.  That is exactly
# how a dead ADGUARDHOME url used to kill `--config-only` with
# ENABLE_ADGUARDHOME=true.
#
# `${switch}` is quoted into the message verbatim, so callers must pass a switch
# that actually exists.  Passing the package name (ENABLE_PASSWALL,
# ENABLE_openwrt-passwall-packages) invented settings no one can turn off, which
# is exactly the guidance this message exists to give; callers without a
# dedicated switch pass the gate that pulled the clone in, or "" for a generic
# message.
install_optional_external() {
	local switch="$1" name="$2" url="$3" branch="$4"
	local hint="${switch:+ (required by ${switch})}"

	clone_external "$name" "$url" "$branch" ||
		die "${name} could not be fetched from ${url}${hint}. Fix the URL or pick another source, or turn off the option that requires it."
	return 0
}

# Clone a third-party package when it is needed in the tree for EITHER reason:
# it is installed into the image (its ENABLE_* switch is on), or it is built into
# the apk repository (ENABLE_REPO_PACKAGES).
#
# The second reason is easy to miss and was a real bug here.  append_optional_config
# emits these packages as `=m` so they land in bin/packages/, but a `=m` symbol
# only exists if the package definition exists.  Gating the clone on the ENABLE_*
# switch alone meant that on a clean checkout — CI, or anyone cloning this repo —
# nothing was cloned, defconfig silently dropped all seven symbols with exit 0, and
# the packages never reached the repository at all.  It stayed hidden locally only
# because earlier runs had left the clones in package/.
clone_for_repo_or_image() {
	local switch_value="$1"
	shift

	if is_true "$ENABLE_REPO_PACKAGES" || is_true "$switch_value"; then
		install_optional_external "ENABLE_$1" "${@:2}"
	fi
	return 0
}

install_external_packages() {
	# Nikki-RS, not Nikki.  This is CHKayanami/OpenWrt-nikki-rs: the same LuCI
	# transparent-proxy front-end reworked around the Rust clash-rs core, with
	# an eBPF fast path.  The repository is a monorepo — clash-rs/, nikki-rs/
	# and luci-app-nikki-rs/ — and OpenWrt's package scanner picks up all three
	# Makefiles from the one checkout, so the whole stack lands in package/.
	clone_for_repo_or_image "$ENABLE_NIKKI" NIKKI OpenWrt-nikki-rs https://github.com/CHKayanami/OpenWrt-nikki-rs.git main
	clone_for_repo_or_image "$ENABLE_OPENCLASH" OPENCLASH OpenClash https://github.com/vernesong/OpenClash.git master
	clone_for_repo_or_image "$ENABLE_MOSDNS" MOSDNS luci-app-mosdns https://github.com/sbwml/luci-app-mosdns.git v5
	clone_for_repo_or_image "$ENABLE_HOMEPROXY" HOMEPROXY homeproxy https://github.com/immortalwrt/homeproxy.git master

	# AdGuardHome deliberately has NO clone here.  Its packages — adguardhome,
	# luci-app-adguardhome and luci-i18n-adguardhome-zh-cn — are all in the
	# official feeds now, so the third-party source the previous harness needed
	# (a prebuilt ipk from sirpdboy/luci-app-adguardhome releases) is obsolete.
	# ENABLE_ADGUARDHOME only selects the config symbols; see append_optional_config.
	return 0
}

# Clone a third-party tree and then drop named subdirectories from it.
#
# openwrt-passwall-packages carries its own xray-core, sing-box and microsocks,
# and the official feeds carry packages with those exact PKG_NAMEs.  Cloning it
# wholesale would introduce duplicate package definitions — this project's tree
# currently has ZERO name collisions across 12757 packages, which is worth
# keeping.  Dropping the duplicates leaves exactly the helpers the official feeds
# lack, and the frontends resolve xray-core/sing-box from the feeds instead.
clone_and_prune() {
	local name="$1" url="$2" branch="$3"
	shift 3
	local dest="${SRC}/package/${name}"
	local drop

	clone_external "$name" "$url" "$branch" ||
		die "${name} could not be fetched from ${url} (required to build the proxy repository). Fix the URL or pick another source, or turn off ENABLE_PROXY_REPOS / ENABLE_REPO_PACKAGES."

	for drop in "$@"; do
		if [ -e "${dest}/${drop}" ]; then
			rm -rf "${dest}/${drop}"
			log "  pruned ${name}/${drop} (official feeds already provide it)"
		fi
	done
	return 0
}

# Clone a monorepo and keep only the named paths, which are relative to the
# repository root.
#
# luci-app-ssr-plus lives in fw876/helloworld and luci-app-easymesh only in
# coolsnowwolf/luci; neither is published as a standalone repository, and both
# carry far more than we want.
#
# Paths, not bare directory names: coolsnowwolf/luci keeps its apps under
# applications/, so matching on the top-level name alone deleted applications/
# entirely and left a tree with no package in it at all — which is what the
# first version did, silently, because pruning files is not something it does.
clone_only_paths() {
	local name="$1" url="$2" branch="$3"
	shift 3
	local dest="${SRC}/package/${name}"
	local entry sub keep found

	clone_external "$name" "$url" "$branch" ||
		die "${name} could not be fetched from ${url} (required by this build's options). Fix the URL or pick another source, or turn off the option that requires it — ENABLE_EASYMESH, or the proxy-repository switches ENABLE_PROXY_REPOS / ENABLE_REPO_PACKAGES."

	shopt -s nullglob

	# Level one: which top-level directories survive at all.
	for entry in "${dest}"/*; do
		[ -d "$entry" ] || continue
		found=0
		for keep in "$@"; do
			[ "${keep%%/*}" = "$(basename "$entry")" ] && found=1
		done
		[ "$found" -eq 1 ] || rm -rf "$entry"
	done

	# Level two: inside each survivor, drop the siblings that were not asked for.
	for keep in "$@"; do
		case "$keep" in
			*/*) ;;
			*) continue ;;
		esac
		local parent="${dest}/${keep%%/*}" want="${keep#*/}"
		[ -d "$parent" ] || continue
		for sub in "${parent}"/*; do
			[ -d "$sub" ] || continue
			[ "$(basename "$sub")" = "$want" ] || rm -rf "$sub"
		done
	done

	shopt -u nullglob

	log "  kept in ${name}: $*"
	return 0
}

# Neutralise PKG_MIRROR_HASH across every third-party tree we clone.
#
# Those packages declare PKG_SOURCE_PROTO:=git with a pinned PKG_SOURCE_VERSION,
# so the tarball is generated locally by OpenWrt's rawgit method from that
# commit.  Its hash depends on the git, tar and xz versions, so the hash the
# other project recorded never matches here:
#
#   Hash mismatch for file shadowsocks-libev-3.3.5.tar.xz:
#     expected b3898ad0..., got 9d2293f1...
#
# and the build dies in the download stage — reported only as
#
#   ERROR: package/luci-app-ssr-plus/shadowsocks-libev failed to build.
#
# which reads like a compiler error and is not one.  That single line cost two
# full CI cycles: the parallel build swallows the sub-make output, so nothing in
# the log named the hash.
#
# The source is already pinned to an exact commit, which is what actually
# guarantees integrity; the mirror hash only validates a locally generated
# archive and cannot be reproduced outside the machine that generated it.
# `skip` is the value OpenWrt's download logic explicitly tests for
# (include/download.mk, wrap_mirror).
#
# Two things about this function are corrections of the version that failed:
#
#   * It iterates CLONED_PACKAGE_DIRS, the list clone_external() builds, rather
#     than a hard-coded single directory.  Every third-party tree has this
#     problem, not just helloworld's.
#   * It runs AFTER install_proxy_repos().  It used to run before, so
#     package/luci-app-ssr-plus did not exist yet, the `[ -d ]` guard returned
#     silently, and not one hash was ever rewritten in CI.
fix_mirror_hashes() {
	local dir f rel fixed=0

	for dir in "${CLONED_PACKAGE_DIRS[@]}"; do
		[ -d "$dir" ] || continue
		while IFS= read -r f; do
			[ -f "$f" ] || continue
			grep -q '^PKG_SOURCE_PROTO:=git' "$f" 2>/dev/null || continue
			grep -q '^PKG_MIRROR_HASH:=' "$f" 2>/dev/null || continue
			# Delete the line outright; do NOT set it to `skip`.
			#
			# `skip` looks like the obvious answer and is wrong.  include/
			# download.mk treats any non-empty MIRROR_HASH as "fetch it via
			# scripts/download.pl", and download.pl only trusts a hash whose
			# length is 32 or 64 — `skip` is neither, so hash_cmd() is empty
			# and its "does the file already satisfy us?" branch is skipped
			# entirely.  It then goes to the OpenWrt source mirrors, which do
			# not carry a tarball generated from a third-party git commit:
			#
			#   curl ... https://mirrors.tuna.../shadowsocks-libev-3.3.5.tar.xz
			#   curl: (22) The requested URL returned error: 404
			#   Download failed.
			#
			# and what lands in dl/ is the 404 body.  The shell then sees a
			# file where it expected none, download.pl exits 0, the rawgit
			# fallback never runs, and the build dies much later in
			# Build/Prepare with
			#
			#   xzcat: dl/shadowsocks-libev-3.3.5.tar.xz: File format not recognized
			#
			# Removing the line instead leaves MIRROR_HASH as the default `x`,
			# and wrap_mirror's guard — `$(if $(MIRROR),$(filter-out x,
			# $(MIRROR_HASH)))` — is then false, so it takes the git branch
			# directly: a clone of the pinned PKG_SOURCE_VERSION, packed
			# locally.  No mirror, no download.pl, no 404 body.  `make
			# download` still reports "hash is missing" through check_hash,
			# which is a warning and not a failure.
			sed -i '/^PKG_MIRROR_HASH:=/d' "$f"
			rel="${f#"$dir"/}"
			log "  $(basename "$dir")/${rel%/*}: PKG_MIRROR_HASH removed (source stays pinned by PKG_SOURCE_VERSION)"
			fixed=$((fixed + 1))
		done < <(find "$dir" -mindepth 1 -maxdepth 4 \
			-not -path '*/.git/*' -name Makefile 2>/dev/null | sort)
	done

	[ "$fixed" -gt 0 ] && log "Stripped ${fixed} unreproducible mirror hash(es); those packages now clone from their pinned commit"
	return 0
}

# Make sure the cached archives whose hash we just neutralised are at least
# readable, and drop the ones that are not.
#
# `skip` means "this hash cannot be reproduced on this machine", NOT "do not look
# at the file at all".  Treating it as the latter hid a corrupt download-cache
# entry for three builds: a truncated shadowsocks-libev-3.3.5.tar.xz sailed
# through the checks, and the build failed at extraction with
#
#   xzcat: dl/shadowsocks-libev-3.3.5.tar.xz: File format not recognized
#   tar: This does not look like a tar archive
#
# reported only as "ERROR: package/luci-app-ssr-plus/shadowsocks-libev failed to
# build."  The archive came from the restored dl cache; with no hash check there
# was nothing to notice it was broken.
#
# Deleting it is enough: `make download` runs after this and regenerates the
# tarball from the pinned commit through OpenWrt's rawgit method.  A file that
# does not even list is never worth keeping, so this cannot lose anything.
verify_cached_sources() {
	local dir f name src dropped=0

	shopt -s nullglob
	for dir in "${CLONED_PACKAGE_DIRS[@]}"; do
		[ -d "$dir" ] || continue
		while IFS= read -r f; do
			[ -f "$f" ] || continue
			# Only git packages with no usable hash: OpenWrt cannot verify
			# those, so nothing else will notice a bad file.  Everything else
			# keeps its checksum and is OpenWrt's business.
			#
			# Written as `if`, not `x && continue`: every branch here is taken
			# by most files, and a bare failing test as the last command of a
			# loop body aborts the whole build under `set -e`.  That trap has
			# bitten this script once already.
			if ! grep -q '^PKG_SOURCE_PROTO:=git' "$f" 2>/dev/null; then
				continue
			fi
			if grep -q '^PKG_MIRROR_HASH:=' "$f" 2>/dev/null; then
				continue
			fi
			if grep -qE '^PKG_HASH:=' "$f" 2>/dev/null; then
				continue
			fi

			name="$(sed -n 's/^PKG_NAME:=//p' "$f" | head -1)"
			[ -n "$name" ] || name="$(basename "$dir")"

			# PKG_SOURCE is always built from PKG_NAME, so the archive name
			# starts with it — measured across all eight packages, including
			# the ones written as $(PKG_SOURCE_SUBDIR).tar.xz.
			for src in "$SRC"/dl/"$name"-*; do
				[ -f "$src" ] || continue
				if tar -tf "$src" >/dev/null 2>&1; then
					continue
				fi
				warn "cached source $(basename "$src") is unreadable; deleting it so the download stage regenerates it"
				rm -f "$src"
				dropped=$((dropped + 1))
			done
		done < <(find "$dir" -mindepth 1 -maxdepth 4 \
			-not -path '*/.git/*' -name Makefile 2>/dev/null | sort)
	done
	shopt -u nullglob

	[ "$dropped" -gt 0 ] && log "Dropped ${dropped} unreadable cached source archive(s)"
	return 0
}

# Make luci-app-ssr-plus depend on a core, so installing it produces a working
# router rather than a broken one.
#
# Reported from a real device, right after `apk add luci-app-ssr-plus`:
#
#   Main node:Xray 和 Mihomo 内核均不存在，无法启动。
#   dns2tcp tunnel error.restart!
#
# and then every later `apk add` failed with `wget: exited with error 4`, because
# the app had started without a core and its DNS handling left the box unable to
# resolve anything.
#
# The cause is this project's own configuration.  SSR-Plus pulls its cores
# through the INCLUDE_* options, and those are `select`s:
#
#   config PACKAGE_..._INCLUDE_Xray
#           select PACKAGE_xray-core
#
# Turning them off (which is right — see the note in append_optional_config) also
# removes the cores from LUCI_DEPENDS, because every core there is written as
# `+PACKAGE_..._INCLUDE_Xray:xray-core`.  So the app installs and has nothing to
# run.  Emitting the cores as `=m` in this project's repository is not enough on
# its own: nothing says the app needs them.
#
# The fix is a real dependency.  `+=` after the main assignment and before
# luci.mk is included is enough for luci.mk to see it, and a plain `+dep` from an
# `=m` package keeps the target at `=m` — so the cores stay in the repository and
# out of the image, while `apk add luci-app-ssr-plus` now pulls them.
#
# SSR-Plus is not the only front-end with this shape.  PassWall and PassWall2
# reach their cores through the same kind of switch:
#
#   config PACKAGE_luci-app-passwall_INCLUDE_Xray
#           bool "..."
#           select PACKAGE_xray-core
#
# and measured on a tree configured exactly as this project configures it,
# `apk query --recursive luci-app-passwall` (and ...-passwall2) resolves with NO
# core at all, even though the switches are on in .config: a `select` inside a
# package that is itself only `=m` does not become an install dependency.  A user
# who runs `apk add luci-app-passwall` therefore gets a panel that cannot start a
# node, which is the same failure one package over.  Both are given the cores
# their own default switches ask for.
#
# This is asserted from the built repository by the
# "Verify the built repository can satisfy every frontend on its own" CI step, so
# a front-end that loses its core fails the build instead of reaching a device.
ensure_frontend_cores() {
	local spec mk cores

	# "<directory>/<package>|+deps to add"
	for spec in \
		"luci-app-ssr-plus/luci-app-ssr-plus|+xray-core +mihomo +coreutils-timeout" \
		"openwrt-passwall/luci-app-passwall|+xray-core +sing-box" \
		"openwrt-passwall2/luci-app-passwall2|+xray-core +sing-box"; do
		mk="${SRC}/package/${spec%%|*}/Makefile"
		cores="${spec##*|}"

		[ -f "$mk" ] || continue

		# Idempotent on OUR line: the tree is re-cloned only when it is missing,
		# so this can run against a Makefile that already carries the injection.
		# The test is the cores string itself, not any `LUCI_DEPENDS+=` line —
		# an upstream Makefile that already appends to LUCI_DEPENDS for its own
		# reasons would match a generic test and be skipped silently, leaving
		# the app with no core and the build none the wiser until the publish
		# gate caught it.
		if grep -qF "$cores" "$mk" 2>/dev/null; then
			continue
		fi

		if ! awk -v extra="$cores" '
			/^include .*luci\.mk/ && !done {
				print "LUCI_DEPENDS+=" extra
				print "# Added by AutoBuild-H5000M-Openwrt: the cores this app needs are"
				print "# reached through `select` switches, and a select inside a package"
				print "# that is only =m does not become an install dependency, so the app"
				print "# would install with no core and refuse to start."
				done = 1
			}
			{ print }
			END { exit(done ? 0 : 1) }
		' "$mk" >"${mk}.tmp"; then
			rm -f "${mk}.tmp"
			warn "could not find the luci.mk include in ${spec%%|*}; it would install without a core"
			continue
		fi
		mv "${mk}.tmp" "$mk"
		log "  ${spec%%|*} now depends on: ${cores}"
	done

	# Drop dependencies on packages that no feed in this tree defines.
	#
	# luci-app-ssr-plus declares `+PACKAGE_..._INCLUDE_Kcptun:kcptun-client`,
	# and no feed here has ever packaged kcptun-client, so every build prints
	#
	#   WARNING: Makefile 'package/luci-app-ssr-plus/luci-app-ssr-plus/Makefile'
	#            has a dependency on 'kcptun-client', which does not exist
	#
	# five times and the warning can never be satisfied.  We already force that
	# INCLUDE_* switch off, so the clause is unreachable — but leaving it means a
	# real dangling dependency would hide in the same noise.  Removing the
	# `+PACKAGE_x:name` clause is safe: it only ever resolves to `name` when the
	# switch is on, and we keep the switch off.
	prune_dangling_depends
	return 0
}

# Remove `+PACKAGE_<switch>:<pkg>` clauses whose <pkg> this tree cannot supply.
#
# The check is against what the tree actually defines rather than a hard-coded
# list of bad names, so the rewrite stays correct if upstream renames or adds
# one.  Deleting the whole line is enough and needs no continuation fixup: the
# preceding line already ends in `\`, so make continues straight into the line
# that follows the deleted one.
prune_dangling_depends() {
	local mk="${SRC}/package/luci-app-ssr-plus/luci-app-ssr-plus/Makefile"
	local pkg pruned=0

	[ -f "$mk" ] || return 0

	for pkg in kcptun-client; do
		grep -q ":${pkg}\b" "$mk" 2>/dev/null || continue
		# A real package definition anywhere in the tree means the dependency
		# is satisfiable and must be left alone.
		if grep -rq "define Package/${pkg}\$" "${SRC}/package" "${SRC}/feeds" \
			--include=Makefile 2>/dev/null; then
			continue
		fi
		sed -i "\|:${pkg}|d" "$mk"
		# Invalidate OpenWrt's metadata cache for this package.
		#
		# `prepare-tmpinfo` scans package/*/Makefile INCREMENTALLY: include/
		# scan.mk keeps per-file results under tmp/info/ and only rescans a
		# Makefile it considers stale.  Editing the file is not always enough —
		# the first defconfig of a run can reuse a tmp/.config-package.in built
		# BEFORE this edit, so it still reports
		#
		#   WARNING: Makefile '.../luci-app-ssr-plus/Makefile' has a dependency
		#            on 'kcptun-client', which does not exist
		#
		# Measured on this tree: tmp/.config-package.in was written at 19:03 and
		# still contained the pruned clause when the audit ran at 19:05, which
		# made the audit fail on a dependency that had already been removed.
		# Dropping the stale scan result is what makes the prune authoritative.
		rm -f "${SRC}/tmp/info/.packageinfo-$(basename "$(dirname "$mk")")" \
			"${SRC}/tmp/.config-package.in" 2>/dev/null || true
		log "  pruned the dangling dependency on ${pkg} (no feed in this tree provides it)"
		pruned=$((pruned + 1))
	done

	[ "$pruned" -eq 0 ] || log "Pruned ${pruned} unsatisfiable dependency clause(s)"
	return 0
}

# Patch the nftables userspace with fullcone support.
#
# The `fullcone` expression the kernel module registers is invisible to nftables
# unless the userspace parser knows it, so a rule using it cannot even be
# written, let alone take effect.  Upstream nftables has no such support.
#
# The patch is the single commit from fullcone-nat-nftables/
# nftables-1.0.2-with-fullcone rebased onto the 1.1.6 that mainline ships: 200
# lines across seven files, 9 of its 13 hunks applying as-is and 4 needing only
# the surrounding context updated.
#
# It goes into the package's own patches/ directory, not patches/ at the top
# level: nftables' source is downloaded into build_dir at build time, so it is
# not part of the checked-out tree that apply_patches() operates on.
install_nftables_patches() {
	local fwdir="${SRC}/package/network/config/firewall4/patches"
	local libdir="${SRC}/package/libs/libnftnl/patches"
	local dir="${SRC}/package/network/utils/nftables/patches"
	local f

	[ -d "$dir" ] || {
		warn "No nftables patches directory; fullcone will not be available to nft"
		return 0
	}

	# firewall4 last: it is the layer that actually emits the rules.  Without it
	# nft knows the `fullcone` keyword and nothing ever writes one.
	mkdir -p "$fwdir"
	shopt -s nullglob
	for f in "${ROOT_DIR}"/firewall4-patches/*.patch; do
		cp -f "$f" "${fwdir}/$(basename "$f")"
		log "  installed firewall4 patch $(basename "$f")"
	done
	shopt -u nullglob

	# libnftnl first: it is the layer beneath.  nftables' own fullcone code
	# refers to NFTNL_EXPR_FULLCONE_* constants, and without them the nftables
	# build stops with "'NFTNL_EXPR_FULLCONE_FLAGS' undeclared" — which is
	# exactly how the missing layer announced itself.
	# libnftnl ships without a patches/ directory, so create it.  OpenWrt picks
	# up any patches/ directory next to a package Makefile at build time.
	mkdir -p "$libdir"
	if [ -d "$libdir" ]; then
		shopt -s nullglob
		for f in "${ROOT_DIR}"/libnftnl-patches/*.patch; do
			cp -f "$f" "${libdir}/$(basename "$f")"
			log "  installed libnftnl patch $(basename "$f")"
		done
		shopt -u nullglob
	fi

	shopt -s nullglob
	for f in "${ROOT_DIR}"/nftables-patches/*.patch; do
		cp -f "$f" "${dir}/$(basename "$f")"
		log "  installed nftables patch $(basename "$f")"
	done
	shopt -u nullglob

	return 0
}

# Proxy frontends, plus the cores the official feeds do not carry.  Everything is
# emitted as `=m`: built into the apk repository, not installed into the image, so
# a user picks with `apk add` and the frontend pulls its backend and helpers in.
#
# It is not enough to ship the daemon: each entry here also carries its LuCI app
# and, where upstream has one, the `luci-i18n-<app>-zh-cn` translation, because
# `apk add passwall` without `luci-app-passwall` installs something with no UI.
#
# Repository paths verified against upstream.  Several of the ones in circulation
# are dead: xiaorouji/openwrt-passwall and -passwall2 now 404 and live under the
# Openwrt-Passwall org, v2rayA/openwrt is v2rayA/v2raya-openwrt, and
# QiuSimons/openwrt-xray does not exist at all.
#
# v2rayA needs no clone: v2raya and luci-app-v2raya are in the official feeds.
install_proxy_repos() {
	is_true "$ENABLE_REPO_PACKAGES" || is_true "$ENABLE_PROXY_REPOS" || return 0

	# No dedicated per-app switch exists here: these trees are pulled in by the
	# two repository gates, so that is what the failure message names.
	install_optional_external "ENABLE_PROXY_REPOS / ENABLE_REPO_PACKAGES" \
		openwrt-passwall https://github.com/Openwrt-Passwall/openwrt-passwall.git main
	install_optional_external "ENABLE_PROXY_REPOS / ENABLE_REPO_PACKAGES" \
		openwrt-passwall2 https://github.com/Openwrt-Passwall/openwrt-passwall2.git main

	# Cores and helpers PassWall/PassWall2/SSR-Plus/HiJpass need that the
	# official feeds do not have.  The three official-feeds duplicates are pruned.
	clone_and_prune openwrt-passwall-packages \
		https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git main \
		xray-core sing-box microsocks

	install_optional_external "ENABLE_PROXY_REPOS / ENABLE_REPO_PACKAGES" \
		OpenWrt-momo https://github.com/nikkinikki-org/OpenWrt-momo.git main
	install_optional_external "ENABLE_PROXY_REPOS / ENABLE_REPO_PACKAGES" \
		openwrt-fchomo https://github.com/fcshark-org/openwrt-fchomo.git master
	# NeKoBox bundles its own sing-box and mihomo.  sing-box duplicates the
	# official feed; mihomo would duplicate fcshark's.  Keep one of each defined
	# in the tree — fcshark's mihomo, the official sing-box — and let NeKoBox
	# depend on them.
	# SSR-Plus.  It is Lua-based, so mainline LuCI needs luci-compat for the page
	# to appear at all; that is emitted below alongside the app.
	#
	# fw876/helloworld is the canonical source (lean uses it too — there is no
	# luci-app-ssr-plus in coolsnowwolf/lede or coolsnowwolf/luci).  The
	# repository is a monorepo of two dozen cores, several of which the official
	# feeds already provide, so the duplicates are pruned by name.
	# SSR-Plus defaults INCLUDE_Http_Proxy to y on aarch64, and that option
	# does `select PACKAGE_3proxy`.  Mainline has no 3proxy at all, so without
	# it the build stops on a missing dependency.  immortalwrt/packages carries
	# it; only that one directory is taken.
	clone_only_paths luci-ssr-plus-3proxy \
		https://github.com/immortalwrt/packages.git master \
		net/3proxy

	# Prune against openwrt-passwall-packages as well as against the official
	# feeds.  Checking only the feeds left nine names defined twice in the tree —
	# chinadns-ng, dns2socks, ipt2socks, naiveproxy, shadow-tls,
	# shadowsocksr-libev, simple-obfs, tcping, v2ray-plugin and xray-plugin all
	# already come from the PassWall checkout — and a tree with two definitions
	# of the same package does not build.
	clone_and_prune luci-app-ssr-plus \
		https://github.com/fw876/helloworld.git dev \
		dnsproxy microsocks v2ray-core xray-core mihomo mosdns v2raya \
		shadowsocks-rust hysteria sing-box \
		chinadns-ng dns2socks ipt2socks naiveproxy shadow-tls \
		shadowsocksr-libev simple-obfs tcping v2ray-plugin xray-plugin

	clone_and_prune openwrt-nekobox \
		https://github.com/Thaolga/openwrt-nekobox.git main \
		sing-box mihomo
	fix_nekobox_release

	install_optional_external "ENABLE_PROXY_REPOS / ENABLE_REPO_PACKAGES" \
		luci-app-xray https://github.com/yichya/luci-app-xray.git master
	# Daed is deliberately NOT cloned.  Its daemon declares
	# `PKG_BUILD_DEPENDS:=golang/host bpf-headers` and bpf-headers fails to
	# build against this kernel configuration, which does not enable
	# CONFIG_KERNEL_XDP_SOCKETS / DEBUG_INFO_BTF / BPF_EVENTS.  The failure
	# is not survivable and Daed would not run even if it built, so offering
	# it here would only break every build.  See docs/proxy-kmod-audit.md for
	# the kernel options it needs; enabling them is a separate decision because
	# they change the kernel ABI.
	install_optional_external "ENABLE_PROXY_REPOS / ENABLE_REPO_PACKAGES" \
		luci-app-hijpass https://github.com/WROIATE/luci-app-hijpass.git main

	return 0
}

# Upstream packaging bug in Thaolga/openwrt-nekobox, worked around rather than
# waited on.
#
# Its Makefile sets `PKG_RELEASE:=rc14`, but luci.mk composes the package version
# as `$(PKG_VERSION)-r$(PKG_RELEASE)` (feeds/luci/luci.mk:185), which yields
# `2.0.9-rrc14`.  apk rejects that -- `-r` must be followed by a number -- and
# the build stops with the unhelpful
#
#   ERROR: failed to create package: package version is invalid
#
# The first look at this looked like a CSS-minification complaint, because
# luci-theme-spectra logs its own message immediately before it; the real error
# only shows up under `make ... V=s`.  A numeric PKG_RELEASE makes the version
# `2.0.9-r1`, which is valid.  The `rc14` marker is cosmetic and is dropped
# rather than encoded as `2.0.9_rc14`, whose underscore form apk's version parser
# would also have to accept.
fix_nekobox_release() {
	local mk="${SRC}/package/openwrt-nekobox/luci-app-nekobox/Makefile"

	[ -f "$mk" ] || return 0
	grep -q '^PKG_RELEASE:=rc14$' "$mk" || return 0

	sed -i 's/^PKG_RELEASE:=rc14$/PKG_RELEASE:=1/' "$mk"
	log "  fixed luci-app-nekobox PKG_RELEASE (upstream rc14 becomes apk-invalid -rrc14)"
	return 0
}

# --------------------------------------------------------------- config ------
config_set_symbol() {
	local symbol="$1" value="$2"

	if grep -q "^${symbol}=" "$SRC/.config" 2>/dev/null; then
		sed -i "s|^${symbol}=.*|${symbol}=${value}|" "$SRC/.config"
	else
		printf '%s=%s\n' "$symbol" "$value" >>"$SRC/.config"
	fi
}

config_enable() { config_set_symbol "CONFIG_PACKAGE_$1" "y"; }
config_disable() { config_set_symbol "CONFIG_PACKAGE_$1" "n"; }

append_board_stack_config() {
	local out="$1"

	cat >>"$out" <<'EOF'

# --------------------------------------------------- H5000M board stack ------
EOF

	if is_true "$ENABLE_FANCONTROL"; then
		cat >>"$out" <<'EOF'
CONFIG_PACKAGE_luci-app-h5000m-fancontrol=y
CONFIG_PACKAGE_kmod-hwmon-pwmfan=y
CONFIG_PACKAGE_luci-i18n-h5000m-fancontrol-zh-cn=y
EOF
	fi

	if is_true "$ENABLE_NETMODE"; then
		cat >>"$out" <<'EOF'
CONFIG_PACKAGE_luci-app-h5000m-netmode=y
CONFIG_PACKAGE_luci-i18n-h5000m-netmode-zh-cn=y
EOF
	fi

	if is_true "$ENABLE_WWAND"; then
		cat >>"$out" <<'EOF'
CONFIG_PACKAGE_wwand=y
CONFIG_PACKAGE_wwand-qmi=y
CONFIG_PACKAGE_wwand-ncm=y
CONFIG_PACKAGE_wwand-mbim=y
CONFIG_PACKAGE_luci-app-wwand=y
CONFIG_PACKAGE_luci-proto-wwand=y
CONFIG_PACKAGE_kmod-usb-net-cdc-ncm=y
CONFIG_PACKAGE_kmod-usb-net-cdc-mbim=y
CONFIG_PACKAGE_kmod-usb-net-qmi-wwan=y
CONFIG_PACKAGE_kmod-rmnet=y
EOF
	fi

	if is_true "$ENABLE_MT5700M"; then
		cat >>"$out" <<'EOF'
CONFIG_PACKAGE_luci-app-mt5700m=y
CONFIG_PACKAGE_kmod-usb-net-cdc-ncm=y
EOF
	fi

	if is_true "$ENABLE_QMODEM"; then
		cat >>"$out" <<'EOF'

# QModem (FUjr feed) — the RG520N-CN dials over QMI on the mainline driver
# set.  The vendor and NSS QMI drivers are deliberately not selected: they
# register the same kernel module names as qmi_wwan and clash.
CONFIG_PACKAGE_qmodem=y
CONFIG_PACKAGE_quectel-CM-5G-M=y
CONFIG_PACKAGE_luci-app-qmodem-next=y
CONFIG_PACKAGE_luci-app-qmodem-generic=y
CONFIG_PACKAGE_sms-forwarder-next=y
CONFIG_PACKAGE_kmod-usb-net-qmi-wwan=y
CONFIG_PACKAGE_kmod-usb-serial-option=y
EOF
	fi

	if is_true "$ENABLE_OAF"; then
		cat >>"$out" <<'EOF'

# OpenAppFilter (destan19 feed) — app filter userspace + kernel module +
# LuCI app.  Built from source in this tree, so the kmod vermagic matches
# this kernel exactly.
CONFIG_PACKAGE_luci-app-oaf=y
CONFIG_PACKAGE_appfilter=y
CONFIG_PACKAGE_kmod-oaf=y
EOF
	fi

	if is_true "$ENABLE_HIGOROS"; then
		cat >>"$out" <<'EOF'

# HigoOS preservation.  The vendor panel itself ships through files/
# (higoros-overlay/), not as a package; the config only has to provide the
# pwm-fan hwmon driver the overlay's /usr/bin/fancontrol drives.  The
# kernel cooling maps are already removed by patches/0001*, so nothing in
# the kernel races the userspace controller for the PWM channel.
CONFIG_PACKAGE_kmod-hwmon-pwmfan=y

# U-Boot environment access: gives the image `fw_setenv failsafe 1` and the
# vendor panel's env page a working backend.  The package ships the binaries
# only — higoros-overlay/etc/fw_env.config supplies the partition layout
# (/dev/mmcblk0p1 0x0 0x80000), and usr/bin/to-failsafe wraps the one-liner.
CONFIG_PACKAGE_uboot-envtools=y
EOF
	fi

	cat >>"$out" <<'EOF'
CONFIG_PACKAGE_h5000m-integration=y
CONFIG_PACKAGE_luci-app-h5000m-accel=y
CONFIG_PACKAGE_kmod-tcp-bbr=y

# firewall4 is written down explicitly rather than left to the default.
#
# It is the fourth and last layer of fullcone: the kernel module registers the
# expression, libnftnl gives it a constant, nftables gives it a keyword, and
# firewall4 is what actually emits `fullcone` in place of `masquerade`.  It is
# also what `luci-app-firewall` renders and what `luci-app-h5000m-accel` writes
# its fullcone option into.  `make defconfig` drops a symbol it cannot satisfy
# without failing, so naming it here means the acceleration page cannot end up
# writing into a firewall that is not there.
#
# nftables-json, not nftables: `nftables` is only a PROVIDES alias, and
# CONFIG_PACKAGE_nftables is not a symbol defconfig can set — asking for it
# would be dropped silently and then reported as missing by verify_config.
# firewall4 already depends on nftables-json, which is the variant LuCI's
# firewall page needs in order to read the ruleset back.
CONFIG_PACKAGE_firewall4=y
CONFIG_PACKAGE_nftables-json=y

# nftables fullcone expression — all four layers are in this tree now.
#
# =y, not =m: the user asked for fullcone to be actually in effect, and a module
# that is only available from the repository is not in effect on a freshly
# flashed device.  The userspace half is carried as patches against mainline's
# own libnftnl, nftables and firewall4 (libnftnl-patches/, nftables-patches/,
# firewall4-patches/), so nothing here depends on a fork being installed.
#
# The upstream module source is from 2022, written against the pre-rework
# nftables expression API, and needed two signature fixes for 6.18 — dump
# gained `bool reset`, validate lost its `data` argument.
CONFIG_PACKAGE_kmod-nft-fullcone=y

# Transparent-proxy nftables modules.  PassWall2 warns without them:
#   Warning: nftables transparent proxy is missing basic dependency
#   kmod-nft-socket!
# and the redirect/tproxy rules it installs do nothing.  kmod-nft-nat and
# kmod-nft-core are already pulled in by firewall4.
CONFIG_PACKAGE_kmod-nft-socket=y
CONFIG_PACKAGE_kmod-nft-tproxy=y
EOF

	# ------------------------------------------------ adblock DNS backends ---
	# Classic `adblock` and the newer `adblock-fast` both drive a DNS server's
	# blocklist, and both offer a dnsmasq backend that needs more than the base
	# image carries:
	#
	#   dnsmasq-full   the base image ships the plain `dnsmasq` variant, which
	#                  has neither ipset nor nftset support compiled in.  The
	#                  full variant has both and PROVIDES dnsmasq, so it takes
	#                  its place.  nftset additionally needs nftables, which the
	#                  image already has.
	#
	#   ipset          dnsmasq.ipset needs the ipset userspace tool AND the
	#                  ipset netfilter modules.  Without them the LuCI page
	#                  reports "Please note that dnsmasq.ipset is not supported
	#                  on this system." and the option is not offered at all.
	#                  `ipset` pulls kmod-ipt-ipset, libmnl and libipset; the
	#                  kmod is named explicitly because a kernel module may only
	#                  come from this exact kernel build.
	#
	# This is a few tens of KB and it is what makes adblock-fast's recommended
	# dnsmasq.ipset mode work instead of merely warning about it.
	cat >>"$out" <<'EOF'
CONFIG_PACKAGE_dnsmasq-full=y
CONFIG_PACKAGE_ipset=y
CONFIG_PACKAGE_kmod-ipt-ipset=y
EOF

	# eBPF proxy kernel support (Nikki-RS / clash-rs).
	#
	# The TC half of the eBPF datapath attaches cls_bpf/act_bpf programs to a
	# clsact qdisc.  Those come from the kmod-sched-core / kmod-sched-bpf
	# packages emitted further down, so there is no CONFIG_KERNEL_* to add for
	# them: kmod-sched-core's KCONFIG already sets CONFIG_NET_SCH_INGRESS and
	# CONFIG_NET_CLS_ACT, and kmod-sched-bpf sets CONFIG_NET_CLS_BPF /
	# CONFIG_NET_ACT_BPF.
	#
	# The host half — proxy-local and the process lists — is a cgroup BPF hook,
	# and that is the part mainline leaves off: the generic kernel config ships
	# `# CONFIG_CGROUPS is not set`, and CONFIG_CGROUP_BPF sits behind it.  Both
	# are declared OpenWrt symbols (config/Config-kernel.in), so they survive
	# `make defconfig` and the kernel build copies them across.
	#
	# Enabling cgroups adds the default-on controllers (pids, cpuset, cpuacct,
	# memory, ...) to the kernel.  That is a few tens of KB and a kernel ABI
	# change — harmless here, because every kmod in this image is built from the
	# same tree in the same run, which is the only way a kernel module may ever
	# be paired with a kernel.
	if is_true "$ENABLE_EBPF_PROXY_KERNEL"; then
		cat >>"$out" <<'EOF'

# eBPF proxy kernel support (Nikki-RS): cgroup BPF needs cgroups underneath it.
# The TC half rides on kmod-sched-core + kmod-sched-bpf.
CONFIG_KERNEL_CGROUPS=y
CONFIG_KERNEL_CGROUP_BPF=y

# BTF (BPF Type Format) type information.
#
# CONFIG_DEBUG_INFO_BTF has two prerequisites and both have to be satisfied or
# Kconfig silently drops it: `depends on KERNEL_DEBUG_INFO && !KERNEL_DEBUG_INFO_REDUCED`.
# The tree already sets DEBUG_INFO=y, but DEBUG_INFO_REDUCED DEFAULTS TO y, so
# BTF was being dropped without a word and the kernel shipped no BTF.
#
# Turning DEBUG_INFO_REDUCED off is not merely a switch: it makes gcc emit full
# DWARF instead of the reduced structure information, which is what pahole needs
# in order to generate BTF.  That costs real build time and a bigger vmlinux —
# the same trade this project already accepts for the libbpf package.
#
# `select DWARVES` builds the pahole host tool automatically once BTF is on.
CONFIG_KERNEL_DEBUG_INFO_REDUCED=n
CONFIG_KERNEL_DEBUG_INFO_BTF=y
EOF
	fi
}

append_optional_config() {
	local out="$1"

	cat >>"$out" <<'EOF'

# ------------------------------------------------------ optional services ---
EOF

	if is_true "$ENABLE_UPNP"; then
		cat >>"$out" <<'EOF'
CONFIG_PACKAGE_luci-app-upnp=y
CONFIG_PACKAGE_luci-i18n-upnp-zh-cn=y
CONFIG_PACKAGE_miniupnpd-nftables=y
EOF
	fi

	# Argon theme and its settings page, both cloned into package/ above.
	# Installing the theme is what activates it: it ships
	# root/etc/uci-defaults/30_luci-theme-argon, which points
	# luci.main.mediaurlbase at /luci-static/argon on first boot.
	if is_true "$ENABLE_THEME_ARGON"; then
		cat >>"$out" <<'EOF'
CONFIG_PACKAGE_luci-theme-argon=y
CONFIG_PACKAGE_luci-app-argon-config=y
EOF
	fi

	# Adblock is NOT here.  It used to be, as an unconditional =y behind this
	# switch — which meant turning the switch off removed it from the build
	# entirely instead of leaving it in the repository.  It is emitted through
	# emit_service below, which gives =m when the switch is off and =y when it is
	# on, so the package is always built and the owner chooses.

	# ------------------------------------------------ services: image or repo ---
	# These are the "extras" — a Docker stack, a proxy stack, AdGuardHome.  They
	# are NOT baked into the image by default: they are large, most owners want
	# only one of them, and every one of them can be installed afterwards from
	# the apk repository this same build publishes.
	#
	# `=m` is the mechanism.  OpenWrt builds a `=m` package and drops its .apk in
	# bin/packages/ without installing it into the rootfs — verified on this tree:
	# CONFIG_PACKAGE_jq=m survived defconfig, `make .../jq/compile` produced
	# bin/packages/aarch64_cortex-a53/packages/jq-1.8.2-r1.apk, and no module was
	# installed into the image.  Runtime dependencies are emitted as `=m` too, so
	# the repository stays self-contained and `apk add` resolves.
	#
	# Turning the matching ENABLE_* switch on upgrades the group to `=y`, i.e.
	# installed into the firmware, for anyone who does want it baked in.
	service_pkg_mode="m"
	is_true "$ENABLE_REPO_PACKAGES" || service_pkg_mode="n"

	# emit_service <switch-value> <package>...
	emit_service() {
		local on="$1"
		shift
		local mode="$service_pkg_mode"
		local pkg
		is_true "$on" && mode="y"
		for pkg in "$@"; do
			printf 'CONFIG_PACKAGE_%s=%s\n' "$pkg" "$mode" >>"$out"
			EMITTED_PACKAGES+=("$pkg")
		done
	}

	emit_service "$ENABLE_DOCKERMAN" \
		docker dockerd containerd runc docker-compose \
		luci-app-dockerman luci-i18n-dockerman-zh-cn \
		kmod-fs-cifs kmod-nf-nathelper-extra

	emit_service "$ENABLE_NIKKI" nikki-rs clash-rs luci-app-nikki-rs
	emit_service "$ENABLE_OPENCLASH" luci-app-openclash
	emit_service "$ENABLE_MOSDNS" mosdns luci-app-mosdns
	# ucode-mod-math is a HARD requirement that upstream does not declare.
	# luci-app-homeproxy's LUCI_DEPENDS lists ucode-mod-digest but not math, even
	# though root/etc/homeproxy/scripts/generate_client.uc line 11 does
	# `import { isnan } from 'math'`.  Without it the daemon dies on startup:
	#
	#   Syntax error: Unable to resolve path for module 'math'
	#   Error: failed to generate client configuration.
	#
	# Reported from a real device.  ucode-mod-math has no dependencies of its own,
	# so there is nothing to hold it back.
	#
	# ip-full and kmod-tun are what the LuCI page itself asks for before TUN mode
	# can be switched on ("you need to install ip-full and kmod-tun").  ip-full
	# replaces ip-tiny, which the base image selects; ip-tiny is turned off below
	# so the two do not collide.
	# ip-full conflicts with the ip-tiny the base image pulls in.
	printf 'CONFIG_PACKAGE_ip-tiny=n\n' >>"$out"

	# Mesh: the front-end plus the DAWN / batman-adv stack it drives.  DAWN is a
	# decentralised WiFi controller and batman-adv carries the mesh links; both
	# are in the official feeds.  luci-compat is what lets the Lua-era pages
	# (this one and SSR-Plus) render at all under mainline's JS LuCI.
	emit_service "$ENABLE_EASYMESH" \
		luci-app-easymesh dawn batctl-default kmod-batman-adv kmod-cfg80211 \
		luci-compat

	# Repository only, hence the empty switch — see the note on the block above.
	#
	# The shadowsocks-libev tools are back in this list, under their real
	# subpackage names.  The package was first removed two commits ago as an
	# undiagnosable CI blocker — "ERROR: package/luci-app-ssr-plus/
	# shadowsocks-libev failed to build", with no reason in the log.  That
	# failure was never a compile error: it was a PKG_MIRROR_HASH mismatch in
	# the *download* stage, and the compile failed a few seconds later only
	# because there was no source tree.  The real cause is fixed in
	# fix_mirror_hashes, the download and compile stages both pass now, and a
	# workaround kept for a problem that no longer exists is just a missing
	# package.
	#
	# What is emitted are the real subpackages.  The bare `shadowsocks-libev`
	# (and the bare `shadowsocksr-libev`, `simple-obfs`) was never a package —
	# those are helloworld *directory* names — so the CONFIG lines for them were
	# dropped by defconfig on every build without a word, and the old claim
	# "the repository carries the config helpers and the tools" was never
	# actually true.  HiJpass pulls ss-local and ss-server anyway; naming every
	# variant here makes them installable standalone, and the existence check in
	# verify_config keeps the list honest against upstream.
	#
	# SSR-Plus uses `select`, not `depends`, for the cores its INCLUDE_* options
	# cover.  A select forces its target to =y even when the selecting package is
	# only =m, so leaving those options at their aarch64 defaults would install
	# mihomo, 3proxy, chinadns-ng and v2ray-geoip into the image — and
	# dnsmasq-full, which replaces the dnsmasq the base image ships — while the
	# app itself stayed in the repository.  Dependencies in the image and the
	# package that needs them in the repository is the worst of both.
	#
	# They are therefore turned off and the cores are emitted here as =m
	# alongside every other proxy core, so `apk add` finds them all.
	# `gn` is deliberately NOT emitted.  It is a HOST-ONLY build tool
	# (PKG_HOST_ONLY:=1, BUILDONLY:=1 in the helloworld tree): OpenWrt builds it
	# automatically when a package declares `PKG_BUILD_DEPENDS:=gn/host`, and
	# BUILDONLY means kconfig never offers a target symbol for it at all.  Asking
	# for CONFIG_PACKAGE_gn could therefore never take effect — it was silently
	# dropped on every build, which the emitted-package survival check in
	# verify_config now reports by name instead of leaving to a repository that
	# is quietly one package short.
	emit_service "" \
		luci-app-ssr-plus luci-i18n-ssr-plus-zh-cn \
		chinadns-ng dns2socks dns2tcp ipt2socks redsocks2 \
		tcping shadow-tls tuic-client v2ray-plugin xray-plugin \
		lua-neturl naiveproxy \
		shadowsocks-libev-config shadowsocks-libev-ss-local \
		shadowsocks-libev-ss-redir shadowsocks-libev-ss-server \
		shadowsocks-libev-ss-tunnel shadowsocks-libev-ss-rules \
		3proxy v2ray-geoip v2ray-geosite \
		shadowsocksr-libev-ssr-local shadowsocksr-libev-ssr-redir

	# The INCLUDE_* switches themselves.  Off, so the selects above cannot fire.
	printf 'CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Http_Proxy=n\n' >>"$out"
	printf 'CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_ChinaDNS_NG=n\n' >>"$out"
	printf 'CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Mihomo=n\n' >>"$out"
	printf 'CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_ShadowsocksR_Libev_Client=n\n' >>"$out"
	printf 'CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Kcptun=n\n' >>"$out"
	printf 'CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_GeoData=n\n' >>"$out"

	emit_service "$ENABLE_ADBLOCK" \
		adblock luci-app-adblock luci-i18n-adblock-zh-cn

	# ---------------------------------------------------------- passwall ------
	# The front-ends a Chinese user is most likely to want and least likely to be
	# able to install from a domestic mirror.  The trees come from
	# install_proxy_repos() (cloned into package/) and are built into THIS
	# project's apk repository, so the device installs them with a plain
	# `apk add`.
	#
	# `emit_service ""` keeps them at the repository mode ("m") even when
	# ENABLE_REPO_PACKAGES is off, because that switch would otherwise set the
	# mode to "n" and the repository would be missing exactly the packages it
	# exists to carry.  The two ENABLE_PASSWALL* switches are the real control;
	# both default to true.
	#
	# Both the apps and their cores are listed.  The apps declare their cores
	# through `+xray-core` / `+sing-box`, and a `+dep` inside a package that is
	# only =m does not force the dependency to be built — so the cores are named
	# here as well, or `apk add luci-app-passwall` would resolve to an app with
	# nothing to run.  build.yml asserts the same cores exist before publishing.
	#
	# The i18n packages are separate binaries, not translations inside the app:
	# without luci-i18n-passwall-zh-cn the page renders in English.
	#
	# The two kmod-nft-* entries are the tproxy pieces passwall asks for and the
	# base image does not carry; firewall4 and nftables-json are already there
	# (see REQUIRED_PACKAGES).
	#
	# Written as `if`, NOT `is_true "$X" && emit_service ...`.  A bare `&&` list
	# whose left side fails is itself a failing command, and as the last command
	# of the function it would abort the build under `set -e` every time the
	# switch is OFF — i.e. exactly for the configuration most people run.  Same
	# trap as the checksum loop above.
	if is_true "$ENABLE_PASSWALL"; then
		emit_service "" luci-app-passwall luci-i18n-passwall-zh-cn
	fi
	if is_true "$ENABLE_PASSWALL2"; then
		emit_service "" luci-app-passwall2 luci-i18n-passwall2-zh-cn
	fi
	# The cores and the shared helpers are emitted whenever EITHER front-end is
	# wanted: passwall2 can drive xray-core just as passwall can, so a build with
	# only one of them still needs the full core set.
	#
	# ★ The helper list is not decoration, it is the UNION of both front-ends'
	# own LUCI_DEPENDS (verified 2026-09-30 against the upstream Makefiles):
	#
	#   luci-app-passwall (PKG_VERSION 26.9.27):
	#     +coreutils +coreutils-base64 +coreutils-nohup +coreutils-timeout +curl
	#     +chinadns-ng +dns2socks +dnsmasq-full +ip-full
	#     +libuci-lua +lua +luci-compat +luci-lib-jsonc
	#     +microsocks +resolveip +tcping +lyaml
	#
	#   luci-app-passwall2 (PKG_VERSION 26.9.16):
	#     +coreutils +coreutils-base64 +coreutils-nohup +coreutils-timeout +curl
	#     +ip-full +libuci-lua +lua +luci-compat +luci-lib-jsonc +lyaml
	#     +resolveip +tcping
	#     +geoview +v2ray-geoip +v2ray-geosite      <- NOT in passwall's list
	#     +unzip                                    <- NOT in passwall's list
	#
	# Both lists have to be covered, not just passwall's: a build with only
	# ENABLE_PASSWALL2 on would otherwise emit a luci-app-passwall2 whose
	# `apk add` cannot resolve v2ray-geoip / v2ray-geosite / unzip.
	#
	# Every one of those must be in the repository or `apk add luci-app-passwall`
	# resolves against a package set that cannot satisfy it.  Most are already
	# emitted elsewhere in this function (lua, luci-compat, chinadns-ng,
	# dnsmasq-full via REQUIRED_PACKAGES, ip-full, microsocks/tcping/dns2socks
	# from the ssr-plus block); the ones listed again here are named so the
	# passwall block is self-contained and stays correct if that block changes.
	#
	# `luci-compat` deserves a callout: passwall is a Lua-era LuCI app, so
	# without it the page does not render at all under mainline's JS LuCI.
	if is_true "$ENABLE_PASSWALL" || is_true "$ENABLE_PASSWALL2"; then
		emit_service "" \
			xray-core sing-box \
			geoview v2ray-geoip v2ray-geosite \
			chinadns-ng hysteria \
			coreutils coreutils-base64 coreutils-nohup coreutils-timeout \
			curl resolveip lyaml unzip \
			libuci-lua lua luci-compat luci-lib-jsonc \
			microsocks tcping dns2socks \
			nftables ipt2socks \
			kmod-nft-tproxy kmod-nft-socket
	fi

	# ★ The INCLUDE_* switches, pinned OFF — and this is not cosmetic.
	#
	# Both front-ends pull their cores through a Kconfig `select`, exactly like
	# ssr-plus above (see the long note on its INCLUDE_* block): a select forces
	# its target to =y even when the selecting package is only =m.  Left at their
	# aarch64 defaults, `luci-app-passwall` would drag xray-core, sing-box,
	# geoview, hysteria and the rest INTO THE IMAGE while the app itself stayed
	# in the repository — dependencies in the firmware and the package that
	# needs them in the apk repo, which is the worst of both.
	#
	# Pinned off, the cores are built as =m by the emit above and `apk add
	# luci-app-passwall` finds every one of them.
	#
	# The two transparent-proxy switches are left ON: they only choose between
	# the iptables and nftables rule generators, the nftables one is what this
	# firmware uses (firewall4 + nftables-json are in the image), and neither
	# pulls a package the repository does not already carry.
	if is_true "$ENABLE_PASSWALL"; then
		for opt in Geoview Haproxy Hysteria NaiveProxy \
			Shadowsocks_Rust_Client Shadowsocks_Rust_Server \
			ShadowsocksR_Libev_Client ShadowsocksR_Libev_Server \
			Shadow_TLS Simple_Obfs SingBox V2ray_Geodata \
			V2ray_Plugin Xray Xray_Plugin; do
			printf 'CONFIG_PACKAGE_luci-app-passwall_INCLUDE_%s=n\n' "$opt" >>"$out"
		done
		printf 'CONFIG_PACKAGE_luci-app-passwall_Nftables_Transparent_Proxy=y\n' >>"$out"
		printf 'CONFIG_PACKAGE_luci-app-passwall_Iptables_Transparent_Proxy=n\n' >>"$out"
	fi
	if is_true "$ENABLE_PASSWALL2"; then
		for opt in Haproxy Shadowsocks_Rust_Client Shadowsocks_Rust_Server \
			ShadowsocksR_Libev_Client ShadowsocksR_Libev_Server \
			Simple_Obfs V2ray_Plugin; do
			printf 'CONFIG_PACKAGE_luci-app-passwall2_INCLUDE_%s=n\n' "$opt" >>"$out"
		done
		# passwall2 picks its cores with a choice, not INCLUDE_* switches: one
		# of Basic_Core_Xray / Basic_Core_SingBox / Basic_Core_All is always
		# selected.  A choice cannot be turned off, so choose the single-core
		# option rather than All — Xray is emitted as =m above either way, and
		# Basic_Core_All would select both cores and defeat the point.
		printf 'CONFIG_PACKAGE_luci-app-passwall2_Basic_Core_Xray=y\n' >>"$out"
		printf 'CONFIG_PACKAGE_luci-app-passwall2_Basic_Core_SingBox=n\n' >>"$out"
		printf 'CONFIG_PACKAGE_luci-app-passwall2_Basic_Core_All=n\n' >>"$out"
		printf 'CONFIG_PACKAGE_luci-app-passwall2_Nftables_Transparent_Proxy=y\n' >>"$out"
		printf 'CONFIG_PACKAGE_luci-app-passwall2_Iptables_Transparent_Proxy=n\n' >>"$out"
	fi

	# adblock-fast — the modern, ucode-based implementation.  It is built into
	# the repository whether or not ENABLE_ADBLOCK is on: the switch installs the
	# classic adblock into the image, and this one stays installable so the owner
	# can choose.  `luci-app-adblock-fast` pulls adblock-fast and rpcd-mod-ucode.
	#
	# The four tools are adblock-fast's *recommended* packages, not hard
	# dependencies: it probes /usr/sbin/gawk and /usr/libexec/{grep-gnu,
	# sed-gnu,sort-coreutils} and warns when they are absent, even though busybox
	# provides awk/grep/sed/sort.  Putting them in the repository is what makes
	# the `apk add` its warning suggests actually succeed.  gawk and
	# coreutils-sort already arrive as hard dependencies of the classic adblock
	# package; all four are named here so the repository stays complete even if
	# that package is ever dropped.
	emit_service "" \
		adblock-fast luci-app-adblock-fast luci-i18n-adblock-fast-zh-cn \
		gawk grep sed coreutils-sort

	# HomeProxy: the LuCI app stays in the repository, but its *dependencies* are
	# installed into the image.
	#
	# That split is deliberate and comes from a real device.  With the app and
	# every dependency left as `=m`, installing it looked like this:
	#
	#   apk add luci-app-homeproxy
	#   ERROR: wget: exited with error 4
	#   ERROR: kmod-tun-6.18.44-r1: unexpected end of file
	#   ...
	#   To enable Tun support, you need to install ip-full and kmod-tun.
	#
	# Two things went wrong there.  kmod-tun is a KERNEL module, so it has to
	# come from a repository built against this exact kernel; the only other
	# source configured in the image is downloads.openwrt.org/snapshots, whose
	# kmods carry a different vermagic AND whose files disappear as soon as the
	# snapshot moves on — so that download can only fail.  And ip-full is what
	# HomeProxy's own page checks for before it will offer TUN mode at all.
	#
	# Both are small (kmod-tun is ~20 KB, ip-full ~200 KB), and sing-box is the
	# core the app needs: it is also the one package this project PINS
	# (pinned by pin_sing_box, 1.12.25) because 1.14 dropped the legacy inbound fields
	# HomeProxy still writes.  A pin only holds if we control which version gets
	# installed, and apk resolves dependencies to the HIGHEST version across all
	# configured repositories — so leaving sing-box in the repository alone means
	# apk would happily fetch 1.14 from the snapshot mirror and break HomeProxy.
	# Installing it here fixes the version and removes a ~15 MB download from the
	# user's install.
	emit_service "$ENABLE_HOMEPROXY" \
		luci-app-homeproxy luci-i18n-homeproxy-zh-cn
	emit_service true \
		sing-box ucode-mod-math ip-full kmod-tun

	# AdGuardHome and its LuCI app are in the official feeds, so this needs no
	# clone at all.
	emit_service "$ENABLE_ADGUARDHOME" \
		adguardhome luci-app-adguardhome luci-i18n-adguardhome-zh-cn

	# ------------------------------------------- proxy ecosystem kmod support ---
	# PassWall, PassWall2, SSR-Plus, HomeProxy, OpenClash, Nikki-RS, Momo,
	# FullCombo Shark!, luci-xray, NeKoBox, Daed, HiJpass and v2rayA all redirect
	# traffic through the same handful of kernel facilities: nftables
	# tproxy/socket, the legacy iptables equivalents, tun/inet-diag for the
	# userspace tunnels, the NAT helper and traffic-control modules for the
	# rest, and — for Nikki-RS and Daed — the TC eBPF classifier/action.
	#
	# These go INTO THE IMAGE (`=y`), not merely into the repository.
	#
	# They used to be `=m`, on the reasoning that a user who `apk add`s a frontend
	# gets them from our repository.  A real device showed why that is not good
	# enough: a kmod can only come from a repository built against this exact
	# kernel, and the other source configured in the image is
	# downloads.openwrt.org/snapshots — whose kmods carry a different vermagic
	# and whose files vanish as soon as the snapshot moves.  So the install fails:
	#
	#   ERROR: kmod-tun-6.18.44-r1: unexpected end of file
	#
	# Every module here is a few tens of KB, so carrying them always costs
	# well under a megabyte and removes the whole class of failure.  `=y` can
	# only ever promote a symbol, never demote one, so it is also free of the
	# hazard this list used to warn about (writing `=m` for something the base
	# system already builds as `=y` would remove it from the image).
	#
	# `kmod-xdp-sockets-diag` is deliberately NOT here even though the wider
	# module list suggests it: it depends on KERNEL_XDP_SOCKETS, which this
	# kernel does not set, so the symbol is dropped by defconfig regardless.
	# Only Daed wants it, and only in its README rather than its Makefile, so
	# `apk add daed` would not pull it either way.  Turning the kernel option on
	# changes the kernel ABI and forces a full rebuild; see
	# ENABLE_EBPF_PROXY_KERNEL for that decision.  Nikki-RS does not want
	# AF_XDP, so its eBPF support does not require it either.
	#
	# kmod-veth is the eBPF datapath's load-bearing module.  Nikki-RS's eBPF
	# manager builds dae0 <-> dae0peer as a link pair: it prefers the L2 netkit
	# driver and falls back to veth, and this kernel leaves CONFIG_NETKIT off, so
	# veth is the only path.  Without the module `RTM_NEWLINK` fails with
	# EOPNOTSUPP and clash-rs stops at startup with
	#
	#   failed to initialize eBPF inbound: IO error: Not supported (os error 95)
	#
	# so it must be IN the image, not merely built into the repository.
	emit_service true \
		kmod-netlink-diag \
		kmod-nf-nathelper \
		kmod-macvlan \
		kmod-sched-core \
		kmod-ifb \
		kmod-tcp-bbr \
		kmod-tun \
		kmod-inet-diag \
		kmod-dummy \
		kmod-veth

	# Found by auditing the proxy packages' Makefiles rather than by guessing:
	#   kmod-nft-queue            HomeProxy (VIKINGYFY variant) uses nft queue
	#                             rather than tproxy; pulls kmod-nfnetlink-queue
	#   kmod-sched-bpf            Daed traffic shaping AND Nikki-RS's eBPF fast
	#                             path (cls_bpf + act_bpf are the TC hooks the
	#                             eBPF manager attaches); kmod-sched-core brings
	#                             the clsact qdisc (NET_SCH_INGRESS) and
	#                             NET_CLS_ACT those two depend on
	#   kmod-ipt-tproxy           OpenClash's firewall3 path and the fw3 branch
	#   kmod-ipt-conntrack-extra  of ttimasdf's luci-app-xray
	#   kmod-ipt-filter
	#
	# `kmod-lib-crc32c` is NOT in the list, and two independent audits disagreed
	# about it, so here is the settled answer.  Its Kconfig is
	# `depends on LINUX_6_12`, and this target sets CONFIG_LINUX_6_18, so the
	# symbol cannot be selected at all — defconfig drops it no matter what is
	# asked for.  It is also unnecessary: the kernel is built with
	# CONFIG_NET_CRC32C=y and CONFIG_CRYPTO_CRC32C=y, i.e. CRC32C is already
	# there, and the module package only exists for 6.12 where it evidently is
	# not.  `kmod-nft-core`'s `select PACKAGE_kmod-lib-crc32c if LINUX_6_12`
	# therefore does not fire for this build, which is correct rather than a gap.
	#
	# Into the image, for the same reason as the block above.
	emit_service true \
		kmod-nft-queue \
		kmod-nfnetlink-queue \
		kmod-sched-bpf \
		kmod-ipt-tproxy \
		kmod-ipt-conntrack-extra \
		kmod-ipt-filter

	# ------------------------------------------- third-party proxy frontends ---
	# Built into the repository, never installed.  Package names are taken from
	# the build system's own tmp/.packageinfo rather than guessed from the
	# Makefiles: these are LuCI apps whose package name comes from the directory,
	# so grepping for `define Package/` finds nothing.
	#
	# The daemon, its LuCI app AND its Chinese translation are all listed.  A user
	# who runs `apk add luci-app-passwall` and gets a UI with no Chinese is the
	# failure this prevents -- upstream ships the translation as its own package
	# and nothing pulls it in automatically.
	#
	# luci-theme-spectra is deliberately NOT in this list.  Its Makefile declares
	# LUCI_DEPENDS:=+curl +php8 +php8-cgi +php8-mod-curl +php8-mod-zip
	# +php8-mod-mbstring +ffmpeg on a pure CSS/JS theme, and ffmpeg alone measured
	# ~72 minutes of a 211-minute CI build — 34% of the whole run — for a package
	# this project never promises (it is not in the README and nothing selects
	# it).  Leaving it out removes that leg entirely.  luci-app-nekobox is
	# unaffected: its own UI fetches the theme at runtime if a user asks for it.
	emit_service "" \
		luci-app-passwall luci-i18n-passwall-zh-cn \
		luci-app-passwall2 luci-i18n-passwall2-zh-cn \
		luci-app-momo luci-i18n-momo-zh-cn momo \
		luci-app-fchomo luci-i18n-fchomo-zh-cn mihomo \
		luci-app-nekobox \
		luci-app-xray luci-app-xray-geodata luci-app-xray-status \
		luci-app-hijpass luci-i18n-hijpass-zh-cn \
		v2raya luci-app-v2raya

	# php8 must be requested EXPLICITLY, or luci-app-nekobox silently disappears.
	#
	# This is a Kconfig recursive-dependency trap, and it fails in the worst way:
	# no error, no warning naming the package, just a missing symbol.
	#
	# nekobox's Makefile carries `+php8 +php8-cgi +php8-mod-curl
	# +php8-mod-intl`.  The last one pulls the php8 feed's `PHP8_INTL` symbol,
	# which is `depends on PACKAGE_php8` — while nekobox itself `select`s php8.
	# Kconfig reports the loop,
	#
	#   symbol PACKAGE_php8 is selected by PACKAGE_luci-app-nekobox
	#   symbol PACKAGE_luci-app-nekobox depends on PHP8_INTL
	#   symbol PHP8_INTL depends on PACKAGE_php8
	#
	# and resolves it by dropping PACKAGE_php8.  That takes nekobox with it,
	# because by then its own `depends on PACKAGE_php8` cannot be satisfied.
	# Measured on this tree: with only the upstream DEPENDS, `make defconfig`
	# leaves `# CONFIG_PACKAGE_php8 is not set` and NO luci-app-nekobox symbol
	# at all, so the package is never built and the publish gate fails with
	#
	#   FAIL  luci-app-nekobox is not in the built repository
	#
	# The loop is only *reported* once php8 is on; nothing is dropped.  So the
	# fix is to request php8 (and the modules nekobox loads at runtime) from
	# here rather than relying on the package's own select.  Note this trap was
	# latent for a long time: a stale tmp/.config-package.in masked it until
	# prune_dangling_depends began invalidating that cache.
	emit_service "" \
		php8 php8-cgi php8-mod-curl php8-mod-intl

	# Cores and helpers PassWall/PassWall2/HiJpass need that the official feeds do
	# not carry, from the pruned openwrt-passwall-packages checkout.
	emit_service "" \
		chinadns-ng dns2socks geoview hysteria ipt2socks naiveproxy \
		shadow-tls tcping v2ray-plugin xray-plugin \
		shadowsocks-rust-sslocal shadowsocks-rust-ssserver \
		shadowsocksr-libev-ssr-local shadowsocksr-libev-ssr-redir \
		shadowsocksr-libev-ssr-server \
		simple-obfs-client simple-obfs-server

	# Translations for the frontends that were already listed.  Some arrive on
	# their own because luci.mk selects the configured language, but naming them
	# is what turns "the Chinese UI is present" into a checked property.
	emit_service "" \
		luci-i18n-nikki-rs-zh-cn luci-i18n-mosdns-zh-cn luci-i18n-homeproxy-zh-cn

	return 0
}

build_required_packages() {
	REQUIRED_PACKAGES=()
	REPO_PACKAGES=(
		luci
		luci-base
		luci-ssl
		luci-mod-admin-full
		luci-app-firewall
		luci-app-package-manager
		luci-i18n-base-zh-cn
	)
	is_true "$ENABLE_FANCONTROL" && REQUIRED_PACKAGES+=(luci-app-h5000m-fancontrol kmod-hwmon-pwmfan)
	is_true "$ENABLE_NETMODE" && REQUIRED_PACKAGES+=(luci-app-h5000m-netmode)
	is_true "$ENABLE_WWAND" && REQUIRED_PACKAGES+=(wwand wwand-qmi wwand-ncm wwand-mbim luci-app-wwand luci-proto-wwand)
	is_true "$ENABLE_MT5700M" && REQUIRED_PACKAGES+=(luci-app-mt5700m ubus-at-daemon sms-tool_q)
	is_true "$ENABLE_THEME_ARGON" && REQUIRED_PACKAGES+=(luci-theme-argon luci-app-argon-config)
	REQUIRED_PACKAGES+=(h5000m-integration luci-app-h5000m-accel kmod-tcp-bbr
		kmod-nft-socket kmod-nft-tproxy
		# kmod-veth carries the Nikki-RS eBPF datapath's dae0/dae0peer link
		# pair; without it clash-rs fails at startup with EOPNOTSUPP.  Verified
		# like any other in-image kmod so a defconfig that drops it is fatal.
		kmod-veth
		# firewall4 and nftables-json are required, not implied: they are
		# the userspace half of fullcone, and the acceleration page writes
		# its `fullcone` option into firewall4's config.  A defconfig that
		# dropped them would leave a page whose switch changes nothing.
		#
		# The symbol is nftables-json, not nftables — `nftables` is only a
		# PROVIDES alias, so CONFIG_PACKAGE_nftables never exists in .config
		# and listing it here would fail every build.
		firewall4 nftables-json kmod-nft-fullcone)
	# Adblock DNS backends.  dnsmasq-full (ipset + nftset compiled in) plus the
	# ipset tool and its netfilter modules are what make `dnsmasq.ipset` an
	# offered mode in the adblock / adblock-fast LuCI pages instead of a
	# "not supported on this system" note.  They are checked here so a defconfig
	# that silently drops one of them fails the build rather than shipping a
	# feature that is switched off.
	REQUIRED_PACKAGES+=(dnsmasq-full ipset kmod-ipt-ipset)
	is_true "$ENABLE_REPO_PACKAGES" && REPO_PACKAGES+=(luci-app-ssr-plus chinadns-ng
		adblock-fast luci-app-adblock-fast gawk grep sed coreutils-sort)

	# Optional switches are verified too, and for a specific reason: `make
	# defconfig` exits 0 even when a requested package does not exist, it just
	# drops the symbol.  Measured: feeding it the 30 package names the reference
	# harness used but mainline lacks left 20 of them silently absent and
	# produced no diagnostic naming any of them.  Without these entries a typo
	# in a package name, or an upstream package being removed, would ship a
	# firmware that quietly lacks the feature the switch promised.
	is_true "$ENABLE_DOCKERMAN" && REQUIRED_PACKAGES+=(docker dockerd containerd runc luci-app-dockerman)
	is_true "$ENABLE_NIKKI" && REQUIRED_PACKAGES+=(nikki-rs clash-rs luci-app-nikki-rs)
	is_true "$ENABLE_OPENCLASH" && REQUIRED_PACKAGES+=(luci-app-openclash)
	is_true "$ENABLE_MOSDNS" && REQUIRED_PACKAGES+=(mosdns luci-app-mosdns)
	# The ucode module and the two TUN packages are listed here too: a
	# configuration that drops them builds a HomeProxy that cannot start, and
	# `make defconfig` drops requests silently rather than failing.
	is_true "$ENABLE_HOMEPROXY" && REQUIRED_PACKAGES+=(luci-app-homeproxy ucode-mod-math ip-full kmod-tun)
	# Mesh and SSR-Plus.  Both are Lua-era LuCI apps, so luci-compat is not
	# optional: without it the pages do not render under mainline's JS LuCI.
	is_true "$ENABLE_EASYMESH" && REQUIRED_PACKAGES+=(luci-app-easymesh dawn batctl-default kmod-batman-adv luci-compat)
	is_true "$ENABLE_ADGUARDHOME" && REQUIRED_PACKAGES+=(adguardhome luci-app-adguardhome)
	is_true "$ENABLE_UPNP" && REQUIRED_PACKAGES+=(luci-app-upnp miniupnpd-nftables)
	is_true "$ENABLE_ADBLOCK" && REQUIRED_PACKAGES+=(adblock luci-app-adblock)
	is_true "$ENABLE_QMODEM" && REQUIRED_PACKAGES+=(qmodem quectel-CM-5G-M luci-app-qmodem-next luci-app-qmodem-generic sms-forwarder-next kmod-usb-net-qmi-wwan kmod-usb-serial-option)
	# OpenAppFilter.  The two userspace package names are not the directory
	# names: `open-app-filter/` builds PACKAGE_appfilter (PKG_NAME:=appfilter)
	# and `oaf/` is a KernelPackage, so its symbol is the kmod- prefixed
	# PACKAGE_kmod-oaf.  Verified against the Makefiles — `open-app-filter` is
	# not a symbol at all and defconfig drops it silently.
	is_true "$ENABLE_OAF" && REQUIRED_PACKAGES+=(luci-app-oaf appfilter kmod-oaf)
	is_true "$ENABLE_HIGOROS" && REQUIRED_PACKAGES+=(kmod-hwmon-pwmfan uboot-envtools)

	# Required, not cosmetic.  Every line above is `is_true X && ...`, so when
	# the LAST switch is off the final statement returns 1 and — because this
	# function is called as a plain statement under `set -e` — the whole build
	# dies with no message at all.  Before the optional packages were added here
	# the last line was an unconditional `REQUIRED_PACKAGES+=(...)`, which hid
	# the trap.  It surfaced as the `minimal` coverage profile failing right
	# after the second defconfig with a log that simply stopped.
	return 0
}

# Packages that should be there but whose absence is only worth a warning: the
# translation sub-packages generated by luci.mk from a plugin's po/ tree.  Their
# exact name depends on LuCI's language-suffix mapping, so a rename upstream
# must not fail an otherwise good firmware.
build_expected_packages() {
	EXPECTED_PACKAGES=()
	is_true "$ENABLE_FANCONTROL" && EXPECTED_PACKAGES+=(luci-i18n-h5000m-fancontrol-zh-cn)
	is_true "$ENABLE_NETMODE" && EXPECTED_PACKAGES+=(luci-i18n-h5000m-netmode-zh-cn)
	is_true "$ENABLE_QMODEM" && EXPECTED_PACKAGES+=(luci-i18n-qmodem-next-zh-cn luci-i18n-qmodem-generic-zh-cn)
	is_true "$ENABLE_OAF" && EXPECTED_PACKAGES+=(luci-i18n-oaf-zh-cn)
	is_true "$ENABLE_UPNP" && EXPECTED_PACKAGES+=(luci-i18n-upnp-zh-cn)
	is_true "$ENABLE_ADBLOCK" && EXPECTED_PACKAGES+=(luci-i18n-adblock-zh-cn)
	return 0
}

configure_build() {
	cd "$SRC"

	prepare_config_stage

	log "Writing .config"
	cp -f "${ROOT_DIR}/configs/h5000m.config" .config
	printf '\n' >>.config
	append_board_stack_config .config
	append_optional_config .config

	log "Running defconfig"
	# Keep defconfig's stderr: this is where OpenWrt reports
	# "WARNING: Makefile ... has a dependency on X, which does not exist" for
	# every package in the tree, and the audit below needs to see them.
	run_with_timeout "$CONFIG_TIMEOUT" make defconfig 2>&1 | tee -a "$LOG_FILE" ||
		die "make defconfig failed"

	# defconfig silently drops symbols whose dependencies were not satisfied.
	# Re-assert the ones this image is defined by, then fold the result again.
	#
	# The language gate has to be re-asserted with the packages: every
	# luci-i18n-<app>-zh-cn package defaults to LUCI_LANG_zh_Hans, so if a
	# defconfig pass drops the language the translations silently disappear even
	# though each app is still enabled.
	config_set_symbol "CONFIG_LUCI_LANG_zh_Hans" "y"

	# Re-asserted for the same reason as the language: defconfig regenerates the
	# feed symbols, and losing this one puts a URL that does not exist back into
	# the image's apk sources, where it makes every `apk update` on the device
	# fail.  See the note in configs/h5000m.config.
	config_set_symbol "CONFIG_FEED_wwand" "m"

	build_required_packages
	local pkg
	for pkg in "${REQUIRED_PACKAGES[@]}"; do
		config_enable "$pkg"
	done
	run_with_timeout "$CONFIG_TIMEOUT" make defconfig 2>&1 | tee -a "$LOG_FILE" ||
		die "second make defconfig failed"

	# Kernel symbols are read out of .config by the kernel build (see
	# include/kernel-defaults.mk: an `awk` copies every CONFIG_KERNEL_* line
	# across with the prefix stripped), so writing them after the final
	# defconfig is enough — and it is necessary, because defconfig is free to
	# drop a symbol whose parent it did not see in the same pass.  The eBPF
	# kernel options are the Nikki-RS fast path's hard requirement; a firmware
	# that ships the app without them would have an eBPF switch that fails at
	# runtime with no hint as to why.
	if is_true "$ENABLE_EBPF_PROXY_KERNEL"; then
		config_set_symbol "CONFIG_KERNEL_CGROUPS" "y"
		config_set_symbol "CONFIG_KERNEL_CGROUP_BPF" "y"
		# DEBUG_INFO_REDUCED defaults to y, and KERNEL_DEBUG_INFO_BTF is
		# `depends on KERNEL_DEBUG_INFO && !KERNEL_DEBUG_INFO_REDUCED` — so
		# without turning it off first, defconfig drops BTF silently and the
		# kernel ships without type information.  Order matters, and both are
		# re-asserted here for the same reason as the cgroup pair above.
		config_set_symbol "CONFIG_KERNEL_DEBUG_INFO" "y"
		config_set_symbol "CONFIG_KERNEL_DEBUG_INFO_REDUCED" "n"
		config_set_symbol "CONFIG_KERNEL_DEBUG_INFO_BTF" "y"
	fi

	# ccache last, and after defconfig rather than in the seed, because its
	# Kconfig is `bool "Use ccache" if DEVEL` and defconfig drops it whenever
	# DEVEL is unset.  Turning DEVEL on instead would pull in debug information
	# and cost more build time than the cache saves.  rules.mk only tests
	# `ifneq ($(CONFIG_CCACHE),)`, so a value written after defconfig is enough.
	# That is what makes the CI ccache cache actually fill: without it every run
	# restored an empty directory and rebuilt everything.
	config_set_symbol "CONFIG_CCACHE" "y"

	# SSR-Plus is a repository package, like every other proxy front-end, but
	# defconfig promotes it to =y on its own.  A =y app pulls nothing, so the
	# image would grow by an app whose cores are only in the repository — the
	# front-end installed with no backend, which is the one combination that
	# helps nobody.  Forced back to =m after the final defconfig, the same way
	# the feed and ccache symbols above are.
	config_set_symbol "CONFIG_PACKAGE_luci-app-ssr-plus" "m"
}

# OpenWrt gates .config on $(STAGING_DIR_HOST)/.prereq-build, whose recipe runs
# the *full* host prerequisite check — including tools such as unzip and rsync
# that only a compile needs.  Configuring a tree compiles nothing, so for
# --prepare-only / --config-only we satisfy that stamp directly and let a config
# change be linted on a lightweight host.  A real build always goes through the
# real gate, so a genuinely under-provisioned build host still fails early.
prepare_config_stage() {
	local stamp

	if ! is_true "$CONFIG_ONLY" && ! is_true "$PREPARE_ONLY"; then
		return 0
	fi

	stamp="${SRC}/staging_dir/host/.prereq-build"
	mkdir -p "$(dirname "$stamp")"
	touch "$stamp"

	log "Configuration stage: host prerequisite gate satisfied directly (nothing is compiled)"
}

config_symbol_is_set() {
	grep -q "^CONFIG_PACKAGE_$1=y$" "$SRC/.config"
}

# Repository packages are legitimately =m, so the =y test above would report them
# as dropped.  =m proves the symbol survived defconfig just as well; what it does
# not prove is that the package is installed, which is exactly the distinction
# between the two lists.
config_symbol_present() {
	grep -qE "^CONFIG_PACKAGE_$1=[ym]$" "$SRC/.config"
}

# A package emitted as `=m` (repository only) must not come out of defconfig as
# `=y`.  The image would then carry a front-end whose core lives only in the
# repository — the panel installs and cannot start a node, the exact failure
# this project has already shipped once — and for adblock / homeproxy it would
# silently break the documented default that they are NOT built in.  defconfig
# promotes symbols on its own when something selects them (it did exactly that
# to luci-app-ssr-plus), so this is checked rather than assumed.
assert_repo_only() {
	grep -q "^CONFIG_PACKAGE_$1=y$" "$SRC/.config" &&
		die "$1 was promoted to =y by defconfig — the image must not carry repository-only packages. Find the new select that pulls it in and turn it off."
	return 0
}

verify_config() {
	local pkg fe missing=()

	build_required_packages
	for pkg in "${REQUIRED_PACKAGES[@]}"; do
		config_symbol_is_set "$pkg" || missing+=("$pkg")
	done
	for pkg in "${REPO_PACKAGES[@]:-}"; do
		config_symbol_present "$pkg" || missing+=("$pkg")
	done

	if [ "${#missing[@]}" -gt 0 ]; then
		printf '\n' >&2
		for pkg in "${missing[@]}"; do
			warn "required package did not survive defconfig: ${pkg}"
		done
		die "Configuration is missing required packages — refusing to build a firmware without ${missing[*]}"
	fi

	# Board target must be the H5000M, not a generic filogic profile.
	grep -q "^CONFIG_TARGET_${TARGET_BOARD}_${TARGET_SUBTARGET}_DEVICE_${TARGET_PROFILE}=y$" "$SRC/.config" ||
		die "target profile ${TARGET_PROFILE} is not selected in .config"

	# The eBPF proxy's kernel half.  Checked here rather than only written in
	# append_board_stack_config because this is the one part of the eBPF
	# datapath that mainline leaves off, and a silently dropped symbol would
	# turn the Nikki-RS eBPF page into a switch that cannot work.
	if is_true "$ENABLE_EBPF_PROXY_KERNEL"; then
		grep -q '^CONFIG_KERNEL_CGROUPS=y$' "$SRC/.config" ||
			die "CONFIG_KERNEL_CGROUPS was dropped — the eBPF proxy's cgroup half cannot work"
		grep -q '^CONFIG_KERNEL_CGROUP_BPF=y$' "$SRC/.config" ||
			die "CONFIG_KERNEL_CGROUP_BPF was dropped — the eBPF proxy's cgroup half cannot work"
		# BTF rides on these two: KERNEL_DEBUG_INFO_BTF is
		# `depends on KERNEL_DEBUG_INFO && !KERNEL_DEBUG_INFO_REDUCED`, and
		# DEBUG_INFO_REDUCED defaults to y — a defconfig that re-enabled it
		# would drop BTF without any other symptom, so all three are asserted.
		grep -q '^CONFIG_KERNEL_DEBUG_INFO=y$' "$SRC/.config" ||
			die "CONFIG_KERNEL_DEBUG_INFO was dropped — CONFIG_DEBUG_INFO_BTF cannot be generated without full debug info"
		grep -q '^CONFIG_KERNEL_DEBUG_INFO_REDUCED=n$' "$SRC/.config" ||
			die "CONFIG_KERNEL_DEBUG_INFO_REDUCED is not explicitly off — it defaults to y and silently disables CONFIG_DEBUG_INFO_BTF"
		grep -q '^CONFIG_KERNEL_DEBUG_INFO_BTF=y$' "$SRC/.config" ||
			die "CONFIG_KERNEL_DEBUG_INFO_BTF was dropped — the kernel would ship no BTF type information"
		for pkg in kmod-sched-core kmod-sched-bpf; do
			config_symbol_is_set "$pkg" ||
				die "${pkg} is not in the image — the eBPF proxy's TC half cannot work"
		done
	fi

	# Front-ends and services that belong to the repository must still be there
	# after the final defconfig — see assert_repo_only.  The unconditional
	# front-ends first, then each optional service whose switch is off.
	for fe in luci-app-passwall luci-app-passwall2 luci-app-ssr-plus \
		luci-app-momo luci-app-fchomo luci-app-nekobox luci-app-xray \
		luci-app-hijpass luci-app-v2raya luci-app-adblock-fast; do
		assert_repo_only "$fe"
	done
	is_true "$ENABLE_HOMEPROXY" || assert_repo_only luci-app-homeproxy
	is_true "$ENABLE_ADBLOCK" || {
		assert_repo_only adblock
		assert_repo_only luci-app-adblock
	}
	is_true "$ENABLE_OPENCLASH" || assert_repo_only luci-app-openclash
	is_true "$ENABLE_ADGUARDHOME" || {
		assert_repo_only adguardhome
		assert_repo_only luci-app-adguardhome
	}
	is_true "$ENABLE_DOCKERMAN" || {
		assert_repo_only docker
		assert_repo_only luci-app-dockerman
	}
	is_true "$ENABLE_NIKKI" || {
		assert_repo_only nikki-rs
		assert_repo_only clash-rs
	}

	# The display/audio-symbol guard that used to sit here was removed together
	# with prune_proxy_cycles() — see the note above feed_tree_is_complete().
	# The assertion below is the one that actually catches a dropped qmodem.

	# Every name emit_service wrote has to be a real package.  defconfig drops
	# an unknown CONFIG_PACKAGE_x line with exit 0 and no diagnostic, so an
	# upstream rename would otherwise shrink the repository while every check
	# above stayed green.  tmp/.packageinfo is the build system's own package
	# list — the same source the emit lists were taken from.
	if [ -s "${SRC}/tmp/.packageinfo" ]; then
		for pkg in ${EMITTED_PACKAGES[@]+"${EMITTED_PACKAGES[@]}"}; do
			grep -qFx "Package: ${pkg}" "${SRC}/tmp/.packageinfo" ||
				die "emit_service wrote CONFIG_PACKAGE_${pkg}, but no package by that name exists — upstream renamed or removed it; update the emit lists in scripts/local-build.sh"
		done
		log "Verified ${#EMITTED_PACKAGES[@]} emitted package names exist upstream"
	else
		warn "no ${SRC}/tmp/.packageinfo — skipping the emitted-package existence check"
	fi

	# …and every one of them has to SURVIVE defconfig.
	#
	# Existing in .packageinfo only proves the package is DEFINED; it does not
	# prove kconfig kept the symbol.  This is a real and very expensive failure
	# mode: a Kconfig recursive dependency dropped PACKAGE_php8, which made
	# luci-app-nekobox's `depends on PACKAGE_php8` unsatisfiable, so nekobox was
	# dropped as well — silently, with no message naming it.  The only symptom
	# appeared three hours later in the publish gate:
	#
	#   FAIL  luci-app-nekobox is not in the built repository
	#
	# Checking here turns a three-hour discovery into a few-minute one, and
	# names the package instead of leaving it to a downstream symptom.
	for pkg in ${EMITTED_PACKAGES[@]+"${EMITTED_PACKAGES[@]}"}; do
		config_symbol_present "$pkg" ||
			die "emitted package ${pkg} did not survive defconfig, so it would be missing from the published repository. Look for a Kconfig 'recursive dependency' involving it (kconfig resolves such a loop by dropping a symbol) or a dependency nothing satisfies."
	done
	log "Verified all emitted packages survived defconfig"

	log "Verified ${#REQUIRED_PACKAGES[@]} required packages and target profile ${TARGET_PROFILE}"

	build_expected_packages
	for pkg in "${EXPECTED_PACKAGES[@]}"; do
		config_symbol_is_set "$pkg" || warn "expected package is absent: ${pkg}"
	done

	audit_own_warnings
}

# Fail early on a warning that is OUR defect, while ignoring upstream noise.
#
# `make defconfig` prints two kinds of text we cannot fix:
#
#   * upstream feed metadata — luci-app-bmx7/babeld declare bmx7/babeld, which
#     the routing feed does not package.  Informational.
#   * baseline OpenWrt packages warning about OPTIONAL dependencies that are
#     simply not selected (busybox -> libpam, lldpd -> libnetsnmp,
#     kexec-tools -> liblzma).  Perfectly normal.
#
# and one kind we can: a Makefile from a tree THIS project clones in and patches
# carrying a dependency nothing in the tree provides.  luci-app-ssr-plus's
# `+PACKAGE_..._INCLUDE_Kcptun:kcptun-client` was exactly that, printed five
# times per build.  Running the audit here means such a defect stops the build
# in the configuration stage (minutes) rather than after a three-hour compile.
audit_own_warnings() {
	local line mk ours=0 upstream=0 baseline=0 arith=0

	# The arithmetic errors are counted separately: they come from our own
	# mtime normalisation, and any occurrence means it silently did nothing.
	arith="$(grep -ac 'arithmetic expression: expecting EOF' "$LOG_FILE" 2>/dev/null || true)"

	# only the Makefile paths, deduplicated
	while IFS= read -r mk; do
		[ -n "$mk" ] || continue
		case "$mk" in
			package/feeds/*) upstream=$((upstream + 1)) ;;
			package/luci-app-ssr-plus/* | package/openwrt-passwall*/* | package/luci-app-h5000m-*/* | package/h5000m-*/* | package/nft-fullcone/* | package/luci-theme-argon/* | package/luci-app-argon-config/* | package/openwrt-nekobox/* | package/OpenWrt-*/* | package/OpenClash/* | package/homeproxy/* | package/openwrt-fchomo/* | package/luci-app-mosdns/* | package/luci-ssr-plus-3proxy/* | package/luci-easymesh/*)
				ours=$((ours + 1))
				warn "our Makefile has an unsatisfiable dependency: ${mk}"
				;;
			*) baseline=$((baseline + 1)) ;;
		esac
	done < <(sed 's/\x1b\[[0-9;]*m//g' "$LOG_FILE" 2>/dev/null |
		grep -aoE "WARNING: Makefile '[^']+'" |
		sed "s|^.*WARNING: Makefile '||; s|'$||" | sort -u)

	if [ "$ours" -ne 0 ]; then
		die "${ours} Makefile(s) of ours declare dependencies this tree cannot satisfy — see prune_dangling_depends() and the emit lists in this script"
	fi

	log "Warning audit: ${ours} of ours, ${baseline} baseline OpenWrt (unselected optional deps), ${upstream} upstream feed, ${arith} arithmetic error(s)"
	return 0
}

dump_enabled_packages() {
	local out="$ART/enabled-packages.txt" n

	mkdir -p "$ART"

	# This file lists .config SYMBOLS, which is not the same set as the packages
	# in the image.  Two differences bite anyone who diffs it against the
	# manifest and concludes that packages went missing:
	#
	#   * ABI-versioned libraries appear under their symbol alias here and under
	#     their real name in the manifest — libubox vs libubox20260721,
	#     libgcc vs libgcc1, jansson vs jansson4.
	#   * Some symbols are build-time knobs, not installable packages at all:
	#     MAC80211_DEBUGFS, TAR_GZIP, trusted-firmware-a-mt7981-ram-ddr3.
	#
	# The authoritative answer to "what is in the image" is the .manifest, which
	# collect_artifacts() copies next to this file.  Say so in the file itself.
	{
		printf '# .config symbols set to =y for this build.\n'
		printf '# NOT the package list of the image: ABI-versioned libraries show their\n'
		printf '# symbol alias here (libubox, libgcc1 -> libgcc) and some entries are\n'
		printf '# build-time knobs rather than packages (MAC80211_DEBUGFS, TAR_GZIP,\n'
		printf '# trusted-firmware-a-*).  For the installed set see the .manifest.\n'
		grep '^CONFIG_PACKAGE_.*=y$' "$SRC/.config" |
			sed 's/^CONFIG_PACKAGE_//; s/=y$//' | sort
	} >"$out"

	n="$(grep -vc '^#' "$out")"
	log "Wrote ${out} (${n} enabled .config symbols)"
}

# ---------------------------------------------------------------- build ------
prefetch_and_toolchain() {
	cd "$SRC"

	if is_true "$SKIP_DOWNLOAD"; then
		log "Skipping source download (--skip-download)"
	else
		log "Prefetching sources (make download)"
		run_with_timeout "$DOWNLOAD_TIMEOUT" make download -j"${THREADS}" \
			BUILD_LOG=1 BUILD_LOG_DIR="$BUILD_LOG_DIR" ||
			warn "make download reported failures; the compile step will retry them"
	fi

	if is_true "$SKIP_TOOLCHAIN"; then
		log "Skipping explicit toolchain prebuild (--skip-toolchain)"
		return 0
	fi

	log "Building toolchain (this is the long part)"
	run_with_timeout "$TOOLCHAIN_TIMEOUT" make toolchain/install -j"${THREADS}" \
		BUILD_LOG=1 BUILD_LOG_DIR="$BUILD_LOG_DIR" ||
		{
			report_build_failure
			die "Toolchain build failed"
		}
}

compile_firmware() {
	cd "$SRC"

	log "Compiling firmware with ${THREADS} jobs — this takes a while"

	local start make_pid heartbeat_pid
	start="$(date +%s)"

	# Fail fast on packages that have failed late in a build before.
	#
	# `make world` only reaches the packages under package/luci-app-* about 160
	# minutes in, so a failure there costs an entire run — three and a half
	# hours — to discover.  Building the named packages first (with their
	# dependencies, which is what `make <pkg>/compile` does) surfaces the same
	# failure in minutes instead, and `world` then skips them.
	#
	# Nothing is built here that `world` would not have built anyway; only the
	# order changes.  Empty by default, so a normal build is unaffected.
	if [ -n "${PREBUILD_PACKAGES:-}" ]; then
		local targets=() p

		# The kernel has to be built first, and this is not optional.
		#
		# Every package compile pulls in package/libs/toolchain and a kernel
		# module (package/kernel/gpio-button-hotplug), and those need
		# .../linux-<ver>/.config — which is generated by target/linux/compile
		# and is NOT part of the restored build cache.  Pre-building a package
		# without it fails immediately with
		#
		#   No rule to make target '.../linux-6.18.44/.config'
		#
		# which is what the first version of this did: it reported a broken
		# gpio-button-hotplug instead of the package it was asked about.  In a
		# normal `make world` that ordering is implicit; here it has to be said.
		log "Pre-build: preparing the kernel first (packages need its .config)"
		if ! make -j"${THREADS}" \
			BUILD_LOG=1 BUILD_LOG_DIR="$BUILD_LOG_DIR" \
			target/linux/compile > >(tee -a "$LOG_FILE") 2>&1; then
			report_build_failure
			die "Kernel build failed"
		fi

		for p in $PREBUILD_PACKAGES; do targets+=("${p}/compile"); done
		log "Pre-building first: ${targets[*]}"
		if ! make -j"${THREADS}" \
			BUILD_LOG=1 BUILD_LOG_DIR="$BUILD_LOG_DIR" \
			"${targets[@]}" > >(tee -a "$LOG_FILE") 2>&1; then
			report_build_failure
			die "Pre-build of ${targets[*]} failed"
		fi
		log "Pre-build finished"
	fi

	# make's output goes to build.log as well as the console.
	#
	# build.log used to hold only this script's own log() lines.  OpenWrt names a
	# failing package with exactly one line — "ERROR: <path> failed to build." —
	# printed by make, and it swallows the sub-make output, so that line is the
	# only clue there is.  It therefore has to reach the file the diagnose step
	# reads; without it the step reports "no failed to build line found" while
	# the line sits in the console output right above it.  That is exactly what
	# happened on the run this comment was written after.
	#
	# A process substitution rather than a pipe, deliberately: with
	# `make ... | tee` the `$!` below would be tee's PID, so `wait` would return
	# tee's status and a failed build would be reported as a successful one.
	# With `> >(tee ...)` $! stays make's PID and `wait` sees the real status.
	make -j"${THREADS}" \
		BUILD_LOG=1 BUILD_LOG_DIR="$BUILD_LOG_DIR" \
		> >(tee -a "$LOG_FILE") 2>&1 &
	make_pid=$!

	# Heartbeat so CI logs show progress instead of going quiet for hours.
	(
		while kill -0 "$make_pid" 2>/dev/null; do
			sleep "$HEARTBEAT_INTERVAL"
			kill -0 "$make_pid" 2>/dev/null || break
			log "still compiling... $((($(date +%s) - start) / 60)) min elapsed"
		done
	) &
	heartbeat_pid=$!

	if ! wait "$make_pid"; then
		kill "$heartbeat_pid" 2>/dev/null || true
		report_build_failure
		die "Firmware compilation failed"
	fi

	kill "$heartbeat_pid" 2>/dev/null || true
	wait "$heartbeat_pid" 2>/dev/null || true

	log "Compilation finished in $((($(date +%s) - start) / 60)) min"
}

# Say which package failed and why, from the logs make just wrote.
#
# OpenWrt's parallel build prints one line per failure and swallows the sub-make
# output, so "ERROR: package/X failed to build." is all the console ever shows.
# The reason is not lost, it is just somewhere else: with BUILD_LOG set,
# include/subdir.mk writes the failing target into
# $(BUILD_LOG_DIR)/<package>/error.txt and that package's entire build output
# into $(BUILD_LOG_DIR)/<package>/<step>.txt.
#
# This runs before die(), in the same job, so a failure explains itself instead
# of costing another three-hour round trip.  Three earlier failures were
# "failed to build" with nothing else, twice for the same package.
report_build_failure() {
	local err line target dir log found=0

	# Every element must be a real glob: a literal path that does not exist is
	# kept by nullglob (nullglob drops unmatched *patterns*, not missing names),
	# and the loop below would then try to read a file that is not there.
	shopt -s nullglob
	local errors=("$BUILD_LOG_DIR"/*/error.txt "$BUILD_LOG_DIR"/*/*/error.txt
		"$BUILD_LOG_DIR"/*/*/*/error.txt "$BUILD_LOG_DIR"/*/*/*/*/error.txt)
	shopt -u nullglob

	if [ "${#errors[@]}" -eq 0 ]; then
		warn "no error.txt under ${BUILD_LOG_DIR}; make's own output is in ${LOG_FILE}"
		return 0
	fi

	printf '\n\033[1;31m[h5000m:error]\033[0m %s\n' "--- the package(s) that failed ---" >&2

	for err in "${errors[@]}"; do
		# error.txt holds the failing target name, e.g.
		#   ERROR: package/luci-app-ssr-plus/shadowsocks-libev failed to build.
		# Its own location is NOT the package's directory — it sits at the level
		# of whichever subdir make was building, so several failures share one
		# file.  The target therefore has to be read out of the contents.
		while IFS= read -r line; do
			target="$(printf '%s' "$line" |
				sed 's/^[[:space:]]*ERROR:[[:space:]]*//; s/[[:space:]]*failed to build\.\{0,1\}$//')"
			[ -n "$target" ] || continue
			found=1
			printf '  %s\n' "$target" >&2

			# subdir.mk tee'd that step to <BUILD_LOG_DIR>/<target>/<step>.txt;
			# compile is the informative one, so prefer it.
			log=""
			dir="$BUILD_LOG_DIR/$target"
			if [ -f "$dir/compile.txt" ]; then
				log="$dir/compile.txt"
			elif [ -f "$BUILD_LOG_DIR/$target.txt" ]; then
				log="$BUILD_LOG_DIR/$target.txt"
			elif [ -d "$dir" ]; then
				log="$(find "$dir" -maxdepth 1 -type f -name '*.txt' \
					! -name error.txt 2>/dev/null | head -1)"
			fi

			if [ -n "$log" ] && [ -f "$log" ]; then
				printf '\n  --- last 60 lines of %s ---\n' "${log#"$ROOT_DIR"/}" >&2
				tail -60 "$log" >&2
				printf '  --- end ---\n' >&2
			else
				printf '  (no per-package log found for this target)\n' >&2
			fi
		done <"$err"
	done

	if [ "$found" = 0 ]; then
		warn "error.txt exists but named no target; see ${LOG_FILE}"
	fi
	printf '  (full per-package logs: %s)\n\n' "${BUILD_LOG_DIR#"$ROOT_DIR"/}" >&2
	return 0
}

# Assemble a single flat apk repository containing every package this build
# produced, with one freshly generated index.
#
# Why flat rather than OpenWrt's <arch>/<feed>/ tree: the firmware has to be
# told where the repository lives, and that list is written into the image
# BEFORE anything is compiled (install_local_packages runs early), so it cannot
# be derived from which feed directories ended up non-empty.  A flat repository
# needs exactly one URL and one index, which removes that ordering problem
# entirely — and removes the empty-feed problem with it, since there are no
# per-feed directories to be empty.
#
# Both package sets must be present for the repository to be useful:
#   bin/packages/<arch>/<feed>/            architecture-generic packages
#   bin/targets/<board>/<subtarget>/packages/   every kmod
# The kmods are the part a user cannot get anywhere else: the official snapshot
# repository's kmods carry a different vermagic and this kernel refuses them.
build_apk_repository() {
	local dest="$1"
	local repo="${dest}/apk-repo"
	local apk_tool=""
	local count

	mkdir -p "$repo"

	# Collect from both locations.  cp -a on the tree would keep the per-feed
	# directories; this flattens deliberately.
	find "${SRC}/bin/packages/${TARGET_ARCH}" -mindepth 2 -maxdepth 2 -name '*.apk' \
		-exec cp -f {} "$repo/" \; 2>/dev/null || true
	find "${SRC}/bin/targets/${TARGET_BOARD}/${TARGET_SUBTARGET}/packages" -maxdepth 1 -name '*.apk' \
		-exec cp -f {} "$repo/" \; 2>/dev/null || true

	count="$(find "$repo" -maxdepth 1 -name '*.apk' | wc -l)"
	if [ "$count" -eq 0 ]; then
		warn "No .apk files found; the apk repository will be empty"
		return 0
	fi

	# Prefer the host apk built by this tree, so the index format matches the
	# apk the firmware ships.
	if [ -x "${SRC}/staging_dir/host/bin/apk" ]; then
		apk_tool="${SRC}/staging_dir/host/bin/apk"
	elif command -v apk >/dev/null 2>&1; then
		apk_tool="$(command -v apk)"
	fi

	if [ -z "$apk_tool" ]; then
		warn "No apk tool available; shipping packages without an index (apk cannot read it)"
		return 0
	fi

	# Sign the index with this build's key.  Every device built from this tree
	# trusts the matching public key, because OpenWrt installs it at
	# /etc/apk/keys/public-key.pem — and that file is byte-identical to
	# ${SRC}/public-key.pem.  Without this, `apk update` on the device prints
	#
	#   WARNING: updating <url>: UNTRUSTED signature
	#
	# Verified both ways against the firmware's own apk: unsigned gives that
	# warning, signed gives "OK: N distinct packages available".
	#
	# --allow-untrusted still applies to the .apk files themselves, which carry
	# no signature this host trusts; the index is what the target verifies.
	sign_args=()
	if [ -f "${SRC}/private-key.pem" ]; then
		sign_args=(--sign-key "${SRC}/private-key.pem")
	else
		warn "No ${SRC}/private-key.pem; the index will be unsigned and devices will warn about an untrusted signature"
	fi

	# shellcheck disable=SC2046
	"$apk_tool" mkndx --allow-untrusted "${sign_args[@]}" -o "${repo}/packages.adb" $(find "$repo" -maxdepth 1 -name '*.apk') ||
		die "apk mkndx failed — the repository would be unreadable"

	if [ "${#sign_args[@]}" -gt 0 ]; then
		log "Signed ${repo}/packages.adb with the build key"
	fi

	# Ship the public key with the repository.  The publish job runs on a fresh
	# runner with only this artifact — it has no openwrt/ tree to look in — so
	# the key has to travel inside the artifact.  Devices flashed before the key
	# was fixed fetch it from the same place as the index.
	if [ -f "${SRC}/public-key.pem" ]; then
		cp -f "${SRC}/public-key.pem" "${repo}/public-key.pem"
		log "Repository public key: ${repo}/public-key.pem"
	fi

	log "Built apk repository: ${count} packages, $(du -sh "$repo" | cut -f1)"
	return 0
}

collect_artifacts() {
	local bin_dir="${SRC}/bin/targets/${TARGET_BOARD}/${TARGET_SUBTARGET}"
	local dest="${ART}"

	[ -d "$bin_dir" ] || die "No build output at ${bin_dir}"

	mkdir -p "$dest"

	# Wipe last run's package output first.  These directories are copied into,
	# not replaced, so without this a second build leaves the previous build's
	# .apk files behind — observed as both base-files-1~f0d3e33.apk (the pinned
	# revision) and base-files-1~d0d8c40.apk (the next one) sitting in the same
	# directory, i.e. a published repository mixing two kernel ABIs.
	rm -rf "${dest}/packages" "${dest}/apk-repo"

	log "Collecting artifacts from ${bin_dir}"
	# Images + the metadata needed to install a matching plugin later: the
	# kernel ABI is what ties luci-app-h5000m-* packages to this firmware.
	# The rootfs tarballs are included because this config builds them
	# (CONFIG_TARGET_ROOTFS_TARGZ) and they are the artifact used for a
	# container/chroot or a manual sysupgrade.
	find "$bin_dir" -maxdepth 1 -type f \
		\( -name '*.bin' -o -name '*.itb' -o -name '*.tar.gz' -o -name '*.img.gz' \
		-o -name '*.manifest' -o -name 'profiles.json' -o -name 'sha256sums' \
		-o -name 'version.buildinfo' -o -name 'config.buildinfo' -o -name 'feeds.buildinfo' \) \
		-exec cp -f {} "$dest/" \;

	if [ -d "${bin_dir}/packages" ]; then
		mkdir -p "${dest}/packages"
		find "${bin_dir}/packages" -maxdepth 1 -type f -name '*.apk' -exec cp -f {} "${dest}/packages/" \;
	fi

	build_apk_repository "$dest"

	write_build_info "$dest"

	log "Artifacts:"
	ls -la "$dest"
}

write_build_info() {
	local dest="$1" rev desc ver code kver abi
	local profiles="${dest}/profiles.json"

	rev="$(cat "${ROOT_DIR}/.upstream-revision" 2>/dev/null || echo unknown)"
	desc="$(cat "${ROOT_DIR}/.upstream-describe" 2>/dev/null || echo unknown)"

	# The authoritative version/kernel data is the target's profiles.json, which
	# the build writes into bin/targets/<target>/<subtarget>/ and collect_artifacts
	# has already copied here.  version.buildinfo is NOT a key=value file — it is
	# the bare output of scripts/getver.sh — so parsing it for kernel_version
	# silently produced "unknown".
	#
	# linux_kernel.vermagic is the kernel ABI hash: it is what a separately built
	# plugin .apk must match to be installable on this image.
	if [ -f "$profiles" ] && command -v python3 >/dev/null 2>&1; then
		eval "$(
			python3 - "$profiles" <<'PY'
import json, shlex, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
k = d.get("linux_kernel") or {}
for name, val in (
    ("code", d.get("version_code")),
    ("ver", d.get("version_number")),
    ("kver", k.get("version")),
    ("abi", k.get("vermagic")),
):
    if val:
        print(f"{name}={shlex.quote(str(val))}")
PY
		)"
	fi

	# A shallow clone carries no tags, so scripts/getver.sh can only produce
	# `r0-<sha>`: the revision counter is derived from the nearest base tag plus
	# the commit count, and --depth 1 has neither.  When we built exactly the
	# revision this project pins, record the published snapshot id instead of a
	# misleading r0.  Any other revision keeps the tree-derived value, because
	# inventing a snapshot number we did not verify would be worse.
	if [ -n "${OPENWRT_PINNED_SNAPSHOT:-}" ] && [ -n "${OPENWRT_PINNED_REVISION:-}" ] &&
		[ "$rev" = "$OPENWRT_PINNED_REVISION" ]; then
		code="$OPENWRT_PINNED_SNAPSHOT"
	fi

	cat >"${dest}/BUILD-INFO.txt" <<EOF
project=AutoBuild-H5000M-Openwrt
upstream_url=${REPO_URL}
upstream_branch=${REPO_BRANCH}
upstream_track=${OPENWRT_TRACK}
openwrt_revision=${rev}
openwrt_version_code=${code:-unknown}
openwrt_version_number=${ver:-unknown}
openwrt_describe=${desc}
kernel_version=${kver:-unknown}
kernel_abi=${abi:-unknown}
target=${TARGET_BOARD}/${TARGET_SUBTARGET}
profile=${TARGET_PROFILE}
arch=${TARGET_ARCH}
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
enable_fancontrol=${ENABLE_FANCONTROL}
enable_netmode=${ENABLE_NETMODE}
enable_wwand=${ENABLE_WWAND}
enable_mt5700m=${ENABLE_MT5700M}
enable_qmodem=${ENABLE_QMODEM}
enable_oaf=${ENABLE_OAF}
enable_higoros=${ENABLE_HIGOROS}
enable_upnp=${ENABLE_UPNP}
enable_adblock=${ENABLE_ADBLOCK}
enable_dockerman=${ENABLE_DOCKERMAN}
EOF

	log "Wrote ${dest}/BUILD-INFO.txt (kernel ${kver:-?}, abi ${abi:-?})"
}

# ----------------------------------------------------------------- main ------
main() {
	cd "$ROOT_DIR"
	: >"$LOG_FILE"

	if is_true "$INSTALL_DEPS"; then
		install_deps
		check_environment
		log "Build dependencies installed."
		# Stop here.  This used to fall through, so `--install-deps` installed
		# the packages and then carried on into prepare_source, feeds, patches
		# and the whole build — which is why the CI step named "Install build
		# dependencies" was observed running "Building toolchain", and why it
		# took over thirty minutes instead of three.  A flag that says it
		# installs dependencies should do exactly that and return.
		exit 0
	fi
	check_environment
	resolve_modem_stack
	show_features

	prepare_source
	install_signing_key
	seed_cached_toolchain
	seed_cached_build_state
	prepare_feeds
	apply_patches
	# After the feeds exist and before anything reads the Makefile: the pin is a
	# rewrite of feeds/packages/net/sing-box/Makefile (see pin_sing_box).
	pin_sing_box
	install_local_packages
	install_board_plugins
	install_qmodem_extras
	install_theme
	stage_higoros_overlay
	install_external_packages
	# After install_external_packages, which is what clones OpenWrt-nikki-rs —
	# the clash-rs/Makefile this pins lives inside that clone.  It has to be
	# done before the download stage, which is where the pinned core is fetched.
	# (pin_sing_box above rewrites a feeds/ tree, which `feeds update` restores,
	# so that one is re-run every build; this one edits a package/ tree, which
	# no feed command touches.)
	pin_clash_rs
	# Same tree and the same "after the clone, before the build" window: this
	# rewrites the defaults that decide which destinations the datapath leaves
	# alone (see patch_nikki_ebpf_bypass_defaults).
	patch_nikki_ebpf_bypass_defaults
	install_nftables_patches
	install_proxy_repos

	# Both of these must come after install_proxy_repos: it is the step that
	# clones package/luci-app-ssr-plus, package/openwrt-passwall* and the rest.
	#
	# This ordering is the whole reason the last two CI builds failed.  The
	# mirror-hash pass used to run here — one step too early — so the directory
	# it looks at did not exist yet, its guard returned silently, and the
	# stale PKG_MIRROR_HASH survived into the download stage.  The mtime
	# normalisation had the same problem in reverse: it ran before the proxy
	# clones, so those trees kept their checkout mtimes and never hashed the
	# same way twice.
	fix_mirror_hashes
	# Needs the SSR-Plus, PassWall and PassWall2 trees, so it has to run after
	# install_proxy_repos like fix_mirror_hashes does.
	ensure_frontend_cores
	# Right after the hashes are neutralised, and therefore before `make
	# download`: a bad cached archive has to be gone by then for the download
	# stage to regenerate it.
	verify_cached_sources
	normalize_source_mtimes
	configure_build
	verify_config
	dump_enabled_packages

	if is_true "$PREPARE_ONLY"; then
		log "Prepare-only requested; stopping before download/build"
		exit 0
	fi
	if is_true "$CONFIG_ONLY"; then
		log "Config-only requested; stopping before download/build"
		exit 0
	fi

	prefetch_and_toolchain
	compile_firmware
	collect_artifacts

	log "Done."
}

main "$@"
