#!/bin/sh
# Тесты openwrt/lib/platform.sh на фикстурах /etc/openwrt_release и
# поддельных бинарниках пакетных менеджеров.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$ROOT/openwrt/lib/platform.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0; n=0

eq() { # eq <описание> <ожидаемое> <фактическое>
	n=$((n + 1))
	if [ "$2" = "$3" ]; then :; else echo "FAIL: $1: ждали '$2', получили '$3'"; fail=$((fail + 1)); fi
}
rc() { # rc <описание> <ожидаемый код> <команда...>
	local d="$1" want="$2" got; shift 2
	"$@" >/dev/null 2>&1; got=$?
	eq "$d (код)" "$want" "$got"
}

release() { # release <DISTRIB_RELEASE> <DISTRIB_ARCH>
	cat >"$T/openwrt_release" <<EOF
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='$1'
DISTRIB_REVISION='r00000-test'
DISTRIB_TARGET='test/generic'
DISTRIB_ARCH='$2'
DISTRIB_DESCRIPTION='OpenWrt $1 r00000-test'
EOF
	Z2K_OW_RELEASE_FILE="$T/openwrt_release"
}

# --- версия и серия ---
release 23.05.5 mipsel_24kc
eq "release" 23.05.5 "$(ow_release)"
eq "series 23.05" 23.05 "$(ow_series)"
rc "23.05 поддерживается" 0 ow_series_supported
release 24.10.0 aarch64_cortex-a53
eq "series 24.10" 24.10 "$(ow_series)"
rc "24.10 поддерживается" 0 ow_series_supported
release 25.12.0-rc1 x86_64
eq "series 25.12" 25.12 "$(ow_series)"
rc "25.12 поддерживается" 0 ow_series_supported
release SNAPSHOT x86_64
eq "series snapshot" snapshot "$(ow_series)"
rc "snapshot поддерживается" 0 ow_series_supported
release 22.03.7 mipsel_24kc
rc "22.03 не поддерживается" 1 ow_series_supported
release 21.02.7 mipsel_24kc
rc "21.02 не поддерживается" 1 ow_series_supported
Z2K_OW_RELEASE_FILE="$T/нет-такого"
rc "не OpenWrt" 1 ow_is_openwrt
rc "нет серии вне OpenWrt" 1 ow_series

# --- кавычки в openwrt_release ---
printf 'DISTRIB_ARCH="mips_24kc"\nDISTRIB_RELEASE=24.10.1\n' >"$T/q"
Z2K_OW_RELEASE_FILE="$T/q"
eq "двойные кавычки" mips_24kc "$(ow_pkg_arch)"
eq "без кавычек" 24.10.1 "$(ow_release)"

# --- архитектуры: пакетная -> GOARCH / ARM / движок ---
check_arch() { # pkgarch goarch engine armlevel
	eq "goarch $1" "$2" "$(ow_goarch "$1")"
	eq "engine $1" "$3" "$(ow_engine_arch "$1")"
	[ -n "$4" ] && eq "arm level $1" "$4" "$(ow_arm_level "$1")"
	return 0
}
check_arch mipsel_24kc               mipsle   linux-mipsel   ""
check_arch mipsel_74kc               mipsle   linux-mipsel   ""
check_arch mips_24kc                 mips     linux-mips     ""
eq "goarch mips64el" mips64le "$(ow_goarch mips64el_mips64r2)"
rc "движка под mips64el нет" 1 ow_engine_arch mips64el_mips64r2
check_arch mips64_octeonplus         mips64   linux-mips64   ""
check_arch aarch64_cortex-a53        arm64    linux-arm64    ""
check_arch aarch64_generic           arm64    linux-arm64    ""
check_arch arm_cortex-a7_neon-vfpv4  arm      linux-arm      7
check_arch arm_cortex-a9_vfpv3-d16   arm      linux-arm      7
check_arch arm_cortex-a15_neon-vfpv4 arm      linux-arm      7
check_arch arm_arm926ej-s            arm      linux-arm      5
check_arch arm_xscale                arm      linux-arm      5
check_arch arm_arm1176jzf-s_vfp      arm      linux-arm      6
check_arch x86_64                    amd64    linux-x86_64   ""
check_arch i386_pentium4             386      linux-x86      ""
check_arch i386_pentium-mmx          386      linux-x86      ""
check_arch riscv64_riscv64           riscv64  linux-riscv64  ""
check_arch powerpc_464fp             ppc      linux-ppc      ""
rc "неизвестная арка" 1 ow_goarch loongarch64_generic

# --- имена Go-сборок (по реальному содержимому builds/ репозитория) ---
Z2K_OW_REPO_ROOT="$ROOT"
eq "mtproxy mipsel" mtproxy-client/builds/tg-mtproxy-client-linux-mipsel \
	"$(ow_bin_path mtproxy-client/builds tg-mtproxy-client mipsel_24kc)"
eq "detect mipsel -> mipsle" z2k-detect/builds/z2k-detect-linux-mipsle \
	"$(ow_bin_path z2k-detect/builds z2k-detect mipsel_24kc)"
eq "verify i386 -> 386" z2k-verify/builds/z2k-verify-linux-386 \
	"$(ow_bin_path z2k-verify/builds z2k-verify i386_pentium4)"
eq "warpd i386 -> x86" z2k-warpd/builds/z2k-warpd-linux-x86 \
	"$(ow_bin_path z2k-warpd/builds z2k-warpd i386_pentium4)"
eq "warpd mips64el" z2k-warpd/builds/z2k-warpd-linux-mips64el \
	"$(ow_bin_path z2k-warpd/builds z2k-warpd mips64el_mips64r2)"
eq "rt-proxy arm64" mtproxy-client/builds/z2k-rt-proxy-linux-arm64 \
	"$(ow_bin_path mtproxy-client/builds z2k-rt-proxy aarch64_cortex-a53)"
eq "verify ARMv5" z2k-verify/builds/z2k-verify-linux-arm \
	"$(ow_bin_path z2k-verify/builds z2k-verify arm_arm926ej-s)"
rc "mtproxy (GOARM=7) на ARMv5 нельзя" 2 ow_bin_path mtproxy-client/builds tg-mtproxy-client arm_arm926ej-s
rc "rt-proxy под riscv64 нет" 1 ow_bin_path mtproxy-client/builds z2k-rt-proxy riscv64_riscv64

# --- пакетный менеджер ---
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "apk $*"\n' >"$T/bin/apk"
printf '#!/bin/sh\necho "opkg $*"\n' >"$T/bin/opkg"
chmod +x "$T/bin/apk" "$T/bin/opkg"
Z2K_OW_APK_BIN="$T/bin/apk"; Z2K_OW_OPKG_BIN="$T/bin/opkg"
eq "apk приоритетнее" apk "$(ow_pkg_manager)"
eq "apk add" "apk add curl kmod-nft-queue" "$(ow_pkg_install curl kmod-nft-queue)"
Z2K_OW_APK_BIN="$T/bin/нет"
eq "opkg без apk" opkg "$(ow_pkg_manager)"
eq "opkg install" "opkg install curl" "$(ow_pkg_install curl)"
Z2K_OW_OPKG_BIN="$T/bin/нет"
rc "нет менеджера" 1 ow_pkg_manager

echo "test_platform: $((n - fail))/$n"
[ "$fail" -eq 0 ]
