#!/bin/sh
# platform.sh — что за OpenWrt под нами: версия, пакетный менеджер, архитектура,
# и как эта архитектура называется в сборках движка и Go-модулей.
#
# Только функции, без побочных эффектов при подключении. POSIX sh / busybox ash.
# Все внешние файлы переопределяются переменными — так их подменяют тесты:
#   Z2K_OW_RELEASE_FILE   (/etc/openwrt_release)
#   Z2K_OW_APK_BIN        (/usr/bin/apk)
#   Z2K_OW_OPKG_BIN       (/bin/opkg)
#   Z2K_OW_FW4_BIN        (/sbin/fw4)

# --- /etc/openwrt_release -------------------------------------------------
#
# Файл — shell-присваивания вида DISTRIB_ARCH='mipsel_24kc'. Не исполняем его
# (`.`), а читаем нужный ключ: подключение чужого файла в наш процесс — лишняя
# поверхность, а значения нам нужны только как строки.
ow_release_get() {
	local key="$1" file="${Z2K_OW_RELEASE_FILE:-/etc/openwrt_release}"
	[ -r "$file" ] || return 1
	sed -n "s/^${key}=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}[[:space:]]*\$/\1/p" "$file" | head -n 1
}

ow_is_openwrt() { [ -r "${Z2K_OW_RELEASE_FILE:-/etc/openwrt_release}" ]; }

# 23.05.5 / 24.10.0 / 25.12.0-rc1 / SNAPSHOT
ow_release() { ow_release_get DISTRIB_RELEASE; }

# Серия релиза: "23.05", "24.10", "25.12", "snapshot". Пусто — не OpenWrt.
ow_series() {
	local r
	r=$(ow_release) || return 1
	case "$r" in
		SNAPSHOT|snapshot|*-SNAPSHOT) echo snapshot ;;
		[0-9]*.[0-9]*) echo "$r" | sed 's/^\([0-9]*\.[0-9]*\).*/\1/' ;;
		*) return 1 ;;
	esac
}

# Поддерживается ли серия портом: 23.05+ (fw4/nftables). 22.03 формально
# тоже fw4, но в план не входит; 21.02 и старше — iptables (fw3), нет.
ow_series_supported() {
	local s major minor
	s=$(ow_series) || return 1
	[ "$s" = snapshot ] && return 0
	major=${s%%.*}; minor=${s#*.}
	[ "$major" -gt 23 ] || { [ "$major" -eq 23 ] && [ "$minor" -ge 5 ]; }
}

# --- пакетный менеджер ----------------------------------------------------
#
# 25.x перешла на apk, 23.05/24.10 — opkg. Решаем по наличию бинарника, а не
# по номеру версии: снапшоты переехали на apk раньше релизов.
ow_pkg_manager() {
	if [ -x "${Z2K_OW_APK_BIN:-/usr/bin/apk}" ]; then echo apk
	elif [ -x "${Z2K_OW_OPKG_BIN:-/bin/opkg}" ]; then echo opkg
	else return 1
	fi
}

ow_pkg_update() {
	case "$(ow_pkg_manager)" in
		apk)  "${Z2K_OW_APK_BIN:-/usr/bin/apk}" update ;;
		opkg) "${Z2K_OW_OPKG_BIN:-/bin/opkg}" update ;;
		*) return 1 ;;
	esac
}

# ow_pkg_install pkg...
ow_pkg_install() {
	case "$(ow_pkg_manager)" in
		apk)  "${Z2K_OW_APK_BIN:-/usr/bin/apk}" add "$@" ;;
		opkg) "${Z2K_OW_OPKG_BIN:-/bin/opkg}" install "$@" ;;
		*) return 1 ;;
	esac
}

# ow_pkg_installed pkg — 0, если пакет стоит.
ow_pkg_installed() {
	case "$(ow_pkg_manager)" in
		apk)  "${Z2K_OW_APK_BIN:-/usr/bin/apk}" info -e "$1" >/dev/null 2>&1 ;;
		opkg) "${Z2K_OW_OPKG_BIN:-/bin/opkg}" status "$1" 2>/dev/null | grep -q '^Status:.* installed' ;;
		*) return 1 ;;
	esac
}

# --- межсетевой экран -------------------------------------------------------
ow_has_fw4() { [ -x "${Z2K_OW_FW4_BIN:-/sbin/fw4}" ]; }

# --- архитектура ----------------------------------------------------------
#
# Пакетная архитектура OpenWrt: mipsel_24kc, mips_24kc, aarch64_cortex-a53,
# arm_cortex-a7_neon-vfpv4, arm_arm926ej-s, x86_64, i386_pentium4,
# riscv64_riscv64, mips64_octeonplus, powerpc_464fp …
# Берём DISTRIB_ARCH; без него — uname -m (+ порядок байт из ELF для mips).
ow_pkg_arch() {
	local a
	a=$(ow_release_get DISTRIB_ARCH 2>/dev/null)
	if [ -n "$a" ]; then echo "$a"; return 0; fi
	a=$(uname -m 2>/dev/null) || return 1
	case "$a" in
		mips|mips64)
			# uname -m не различает порядок байт. EI_DATA (байт 6 ELF): 1=LE, 2=BE.
			case "$(dd if=/bin/busybox bs=1 skip=5 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')" in
				1) echo "${a}el" ;;
				*) echo "$a" ;;
			esac ;;
		*) echo "$a" ;;
	esac
}

# Каноническая архитектура Go (GOARCH) по пакетной архитектуре OpenWrt.
# Порядок веток важен: mips64el раньше mips64, mipsel раньше mips.
ow_goarch() {
	case "${1:-$(ow_pkg_arch)}" in
		aarch64*|arm64*)            echo arm64 ;;
		arm*)                       echo arm ;;
		x86_64*|amd64*)             echo amd64 ;;
		i386*|i486*|i586*|i686*|x86) echo 386 ;;
		mips64el*|mips64le*)        echo mips64le ;;
		mips64*)                    echo mips64 ;;
		mipsel*|mipsle*)            echo mipsle ;;
		mips*)                      echo mips ;;
		riscv64*)                   echo riscv64 ;;
		powerpc64*|ppc64*)          echo ppc64 ;;
		powerpc*|ppc*)              echo ppc ;;
		*) return 1 ;;
	esac
}

# Уровень ARM (5/6/7) — только для GOARCH=arm. Сборки с GOARM=7 на ARMv5/v6
# падают с illegal instruction (см. build-matrix.tsv), их нельзя ставить.
ow_arm_level() {
	case "${1:-$(ow_pkg_arch)}" in
		arm_arm926ej-s*|arm_xscale*|arm_fa526*|armv5*) echo 5 ;;
		arm_arm1176jzf-s*|arm_mpcore*|armv6*)          echo 6 ;;
		arm_*|armv7*|arm)                               echo 7 ;;
		*) return 1 ;;
	esac
}

# Каталог движка в архиве zapret2 openwrt-embedded (binaries/<arch>).
ow_engine_arch() {
	local pa="${1:-$(ow_pkg_arch)}" ga
	ga=$(ow_goarch "$pa") || return 1
	case "$ga" in
		arm64)    echo linux-arm64 ;;
		arm)      echo linux-arm ;;
		amd64)    echo linux-x86_64 ;;
		386)      echo linux-x86 ;;
		# mips64le: в архиве движка сборки нет (только mips64 BE) — не поддерживается.
		mips64)   echo linux-mips64 ;;
		mipsle)   echo linux-mipsel ;;
		mips)     echo linux-mips ;;
		riscv64)  echo linux-riscv64 ;;
		ppc)      echo linux-ppc ;;   # 32-bit BE; под ppc64 сборки движка нет
		*) return 1 ;;
	esac
}

# Суффиксы имени Go-сборки для GOARCH, в порядке предпочтения. Модули
# называют одну цель по-разному (build-matrix.tsv): tg-mtproxy-client и
# z2k-warpd — mipsel/mips64el/x86, z2k-detect и z2k-verify — mipsle/mips64le/386.
ow_bin_suffixes() {
	case "$1" in
		mipsle)   echo "mipsel mipsle" ;;
		mips64le) echo "mips64el mips64le" ;;
		386)      echo "x86 386" ;;
		*)        echo "$1" ;;
	esac
}

# ow_bin_path <каталог builds> <префикс> [пакетная арка]
# Путь сборки модуля в репозитории под эту архитектуру — первый кандидат,
# для которого ow_bin_exists (по умолчанию: файл есть рядом) вернул 0.
# Установщик переопределяет ow_bin_exists проверкой по files_sha256 манифеста.
ow_bin_exists() { [ -f "${Z2K_OW_REPO_ROOT:-.}/$1" ]; }

ow_bin_path() {
	local dir="$1" prefix="$2" pa="${3:-$(ow_pkg_arch)}" ga s p
	ga=$(ow_goarch "$pa") || return 1
	if [ "$ga" = arm ] && [ "$(ow_arm_level "$pa")" -lt 7 ]; then
		# GOARM=7 у tg-mtproxy-client, z2k-rt-proxy и z2k-warpd; GOARM=5 — у
		# z2k-detect и z2k-verify. Ниже ARMv7 допустимы только последние.
		case "$prefix" in z2k-detect|z2k-verify) ;; *) return 2 ;; esac
	fi
	for s in $(ow_bin_suffixes "$ga"); do
		p="$dir/$prefix-linux-$s"
		if ow_bin_exists "$p"; then echo "$p"; return 0; fi
	done
	return 1
}
