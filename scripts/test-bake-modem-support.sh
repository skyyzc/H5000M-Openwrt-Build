#!/usr/bin/env bash
#
# Behavioural test for bake_modem_support() in scripts/local-build.sh.
#
# WHY THIS EXISTS
#
#   On 2026-10-09 the build went red on its own new gate because that function
#   had the extra_modem_support.json location written out by hand:
#
#     package/luci-app-qmodem-generic/root/usr/share/qmodem-generic/...
#
#   The upstream repository nests the package one level further down
#   (package/luci-app-qmodem-generic/luci-app-qmodem-generic/...) and had
#   reorganised its tree once before (221f1a10, "维护：整理仓库结构").  The gate
#   did its job - a red run in 19 minutes instead of a four-hour build that
#   produces an image whose RG520N-CN entries would silently be merged at
#   runtime instead - but the root cause was guessing a path.
#
#   So the location is now discovered with `find`, and this test pins that
#   behaviour: a fixed path would go red here rather than four hours into a
#   compile.  It also pins the two refusal paths, because "finds nothing" and
#   "finds two things" must stop the build rather than pick one.
#
# The function is extracted from local-build.sh verbatim, so this exercises the
# real code rather than a copy that can drift.
#
# USAGE
#
#   ./scripts/test-bake-modem-support.sh
#
# Inputs are synthesised here on purpose: no vendor blob is committed, and a
# fixture we control lets the assertions talk about positions rather than
# about whatever happens to be in the real library this week.

set -u

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_SH="${ROOT_DIR}/scripts/local-build.sh"

[ -f "$SRC_SH" ] || { echo "[!] cannot find ${SRC_SH}"; exit 2; }

T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

# ---------------------------------------------------------------- extract
FN="${T}/bake_modem_support.sh"
awk '/^bake_modem_support\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "${SRC_SH}" >"${FN}"
if ! grep -q 'extra_modem_support.json' "${FN}"; then
	echo "[!] could not extract bake_modem_support from ${SRC_SH}"
	exit 2
fi
echo "[i] extracted $(wc -l <"${FN}") lines of bake_modem_support()"

cat >"${T}/stubs.sh" <<'STUB'
log() { printf '[log]  %s\n' "$*"; }
warn() { printf '[warn] %s\n' "$*" >&2; }
die() { printf '[die]  %s\n' "$*" >&2; exit 1; }
is_true() { [ "$1" = "1" ] || [ "$1" = "true" ] || [ "$1" = "y" ]; }
STUB

# ---------------------------------------------------------------- fixtures
# A library whose usb group already has two models: the merge has to land the
# new model *before* `zzz-existing`, which is the observable part of "insert at
# the first position, and put a comma on what used to be last".
lib_seed() {
	cat <<'JSON'
{
    "modem_support": {
        "usb": {
            "zzz-existing": {
                "manufacturer_id": "dead",
                "manufacturer": "example"
            },
            "yyy-existing": {
                "manufacturer_id": "beef",
                "manufacturer": "example"
            }
        },
        "pcie": {
            "ppp-existing": {
                "manufacturer_id": "cafe",
                "manufacturer": "example"
            }
        },
        "device": {}
    }
}
JSON
}

extra_seed() {
	cat <<'JSON'
{
    "modem_support": {
        "usb": {
            "rg520n-cn": {
                "manufacturer_id": "2c7c",
                "manufacturer": "quectel",
                "data_interface": "usb"
            }
        },
        "pcie": {
            "rg520n-cn-pcie": {
                "manufacturer_id": "2c7c",
                "manufacturer": "quectel",
                "data_interface": "pcie"
            }
        }
    }
}
JSON
}

PASS=0
FAIL=0
FAILED=()

ok() { echo "  [OK  ] $1"; PASS=$((PASS + 1)); }
no() {
	echo "  [FAIL] $1"
	[ -n "${2:-}" ] && echo "         -> $2"
	FAIL=$((FAIL + 1))
	FAILED+=("$1")
}

# run_case <layout nested|flat> <extras present|missing|duplicate>
CASE_LIB=""
run_case() {
	local layout="$1" extras="$2"
	# A fresh directory per case rather than rm -rf of a shared one: some
	# environments wrap rm -rf with a path guard that silently refuses, which
	# would leave the previous case's tree in place and make an "ambiguous
	# candidates" refusal look like a bug in the function.
	local root
	root="$(mktemp -d "${T}/tree.XXXXXX")"

	# the qmodem feed ships the library as a static file inside its package
	mkdir -p "${root}/feeds/qmodem/application/qmodem/files/usr/share/qmodem"
	lib_seed >"${root}/feeds/qmodem/application/qmodem/files/usr/share/qmodem/modem_support.json"
	CASE_LIB="${root}/feeds/qmodem/application/qmodem/files/usr/share/qmodem/modem_support.json"

	# where the panel clone lands; the package itself may be one level deeper
	local panel="${root}/package/luci-app-qmodem-generic"
	local inner="${panel}"
	[ "${layout}" = "nested" ] && inner="${panel}/luci-app-qmodem-generic"

	mkdir -p "${inner}/root/usr/share/qmodem-generic"
	case "${extras}" in
	present) extra_seed >"${inner}/root/usr/share/qmodem-generic/extra_modem_support.json" ;;
	duplicate)
		extra_seed >"${inner}/root/usr/share/qmodem-generic/extra_modem_support.json"
		mkdir -p "${panel}/second-copy/root/usr/share/qmodem-generic"
		extra_seed >"${panel}/second-copy/root/usr/share/qmodem-generic/extra_modem_support.json"
		;;
	missing) : ;;
	esac

	# The panel carries its own copy of the library at the same relative path.
	# The function must never patch that one - it is the merge source, not the
	# destination - so it is planted here as a trap and checked afterwards.
	mkdir -p "${inner}/files/usr/share/qmodem"
	lib_seed >"${inner}/files/usr/share/qmodem/modem_support.json"
	CASE_PANEL_LIB="${inner}/files/usr/share/qmodem/modem_support.json"

	CASE_OUT="$(
		SRC="${root}" ENABLE_QMODEM=1 ROOT_DIR="${ROOT_DIR}" \
			bash -c ". '${T}/stubs.sh'; . '${FN}'; bake_modem_support" 2>&1
	)"
	CASE_RC=$?
}

expect_die() {
	local title="$1"
	if [ "${CASE_RC}" -ne 0 ] && printf '%s' "${CASE_OUT}" | grep -q '\[die\]'; then
		ok "${title}"
	else
		no "${title}" "expected a refusal, got rc=${CASE_RC}: $(printf '%s' "${CASE_OUT}" | tail -1)"
	fi
}

# ---------------------------------------------------------------- assertions
judge_merge() {
	local where="$1"

	if [ "${CASE_RC}" -ne 0 ]; then
		no "${where}: merge succeeds" "rc=${CASE_RC}: $(printf '%s' "${CASE_OUT}" | tail -1)"
		return
	fi

	if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${CASE_LIB}" 2>/dev/null; then
		no "${where}: result is valid JSON"
		return
	fi

	local n_usb n_pcie
	n_usb="$(grep -c '"rg520n-cn"' "${CASE_LIB}")"
	n_pcie="$(grep -c '"rg520n-cn-pcie"' "${CASE_LIB}")"
	if [ "${n_usb}" != "1" ] || [ "${n_pcie}" != "1" ]; then
		no "${where}: both entries land exactly once" \
			"usb=${n_usb} pcie=${n_pcie}"
		return
	fi

	# Insert position: the merged key must be the model that directly follows
	# the group's opening line.  Asserting on the line number keeps this about
	# position, not about whitespace guessing.
	local l_usb l_pcie next_usb next_pcie
	l_usb="$(grep -n '^        "usb": {$' "${CASE_LIB}" | head -1 | cut -d: -f1)"
	l_pcie="$(grep -n '^        "pcie": {$' "${CASE_LIB}" | head -1 | cut -d: -f1)"
	next_usb="$(sed -n "$((l_usb + 1))p" "${CASE_LIB}")"
	next_pcie="$(sed -n "$((l_pcie + 1))p" "${CASE_LIB}")"
	if ! printf '%s' "${next_usb}" | grep -q '"rg520n-cn": {'; then
		no "${where}: usb entry is the group's first key" "line $((l_usb + 1)) is: ${next_usb}"
		return
	fi
	if ! printf '%s' "${next_pcie}" | grep -q '"rg520n-cn-pcie": {'; then
		no "${where}: pcie entry is the group's first key" "line $((l_pcie + 1)) is: ${next_pcie}"
		return
	fi

	# …and the new block's closing brace carries the comma that separates it
	# from the model it displaced.  That comma is the visible half of "insert at
	# the first position": without it the file stops being valid JSON, which the
	# parse check above would already have caught, so this pins the *shape*
	# (comma on the inserted block, not appended to the displaced entry).
	local l_old prev_old
	l_old="$(grep -n '"zzz-existing"' "${CASE_LIB}" | head -1 | cut -d: -f1)"
	prev_old="$(sed -n "$((l_old - 1))p" "${CASE_LIB}")"
	if ! printf '%s' "${prev_old}" | grep -qE '},?[[:space:]]*,$'; then
		no "${where}: comma lands on the inserted block's closing brace" \
			"line $((l_old - 1)) is: ${prev_old}"
		return
	fi

	# The panel's own copy must be untouched.
	if ! cmp -s "${CASE_PANEL_LIB}" <(lib_seed); then
		no "${where}: panel's own library left alone"
		return
	fi

	ok "${where}: merged, both entries first in their group, panel copy untouched"
}

echo
echo "--- positive: the real (nested) layout ---"
run_case nested present
judge_merge "nested"

echo
echo "--- positive: a flat layout must work too (no fixed depth) ---"
run_case flat present
judge_merge "flat"

echo
echo "--- negative: the build must refuse, not silently no-op ---"
run_case nested missing
expect_die "missing extra_modem_support.json refuses the build"

run_case nested duplicate
expect_die "two candidates refuse the build (no guessing)"

echo
echo "=============================================================="
echo "  passed ${PASS} / failed ${FAIL}"
for t in ${FAILED[@]+"${FAILED[@]}"}; do echo "  [FAIL] ${t}"; done
if [ "${FAIL}" -eq 0 ]; then
	echo "  ok"
else
	echo "  FAILED"
fi
echo "=============================================================="
[ "${FAIL}" -eq 0 ]
