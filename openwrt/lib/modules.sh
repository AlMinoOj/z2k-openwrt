#!/bin/sh
# modules.sh — необязательные модули z2k-openwrt с Go-бинарниками.
#
# Бинарники тяжёлые (5–9 МБ каждый), а флеш на роутерах OpenWrt маленький,
# поэтому модуль ставится по выбору: бинарник только своей архитектуры и
# только включённого модуля. Скрипты модулей (init, правила) маленькие и
# ставятся всегда — init без бинарника ничего не запускает.
#
#   модуль   сборка (каталог/префикс)                 цель                      служба
#   tg       mtproxy-client/builds/tg-mtproxy-client  /opt/sbin/tg-mtproxy-client z2k-tg
#   rtproxy  mtproxy-client/builds/z2k-rt-proxy       /opt/sbin/z2k-rt-proxy      z2k-rtproxy
#   detect   openwrt/builds/z2k-detect                /opt/sbin/z2k-detect        —
#   warp     openwrt/builds/z2k-warpd                 /opt/sbin/z2k-warpd         z2k-warp
#
# detect и warp — наши сборки (Go-код пропатчен под nftables), лежат отдельно
# от апстримных builds/, чтобы бинарники не конфликтовали при merge.
#
# Требует platform.sh (ow_bin_path, ow_bin_suffixes).

OW_ALL_MODULES="tg rtproxy detect warp"

ow_module_info() { # <модуль> -> "каталог префикс цель служба"
	case "$1" in
		tg)      echo "mtproxy-client/builds tg-mtproxy-client /opt/sbin/tg-mtproxy-client z2k-tg" ;;
		rtproxy) echo "mtproxy-client/builds z2k-rt-proxy /opt/sbin/z2k-rt-proxy z2k-rtproxy" ;;
		detect)  echo "openwrt/builds z2k-detect /opt/sbin/z2k-detect -" ;;
		warp)    echo "openwrt/builds z2k-warpd /opt/sbin/z2k-warpd z2k-warp" ;;
		*) return 1 ;;
	esac
}
ow_module_field() { # <модуль> <1..4>
	ow_module_info "$1" | awk -v n="$2" '{ print $n }'
}

# Модуль по пути сборки в репозитории (пусто — не сборка модуля).
ow_module_of_path() {
	case "$1" in
		mtproxy-client/builds/tg-mtproxy-client-linux-*) echo tg ;;
		mtproxy-client/builds/z2k-rt-proxy-linux-*)      echo rtproxy ;;
		openwrt/builds/z2k-detect-linux-*)               echo detect ;;
		openwrt/builds/z2k-warpd-linux-*)                echo warp ;;
	esac
}

# --- какие модули включены ---------------------------------------------------
ow_modules_file() { echo "${OW_MODULES_FILE:-${OW_ZD:-/opt/zapret2}/.z2k-modules}"; }
ow_modules_enabled() { cat "$(ow_modules_file)" 2>/dev/null | tr ' ' '\n' | grep -v '^$' | sort -u; }
ow_module_enabled() { ow_modules_enabled | grep -qx "$1"; }
ow_module_set() { # <модуль> <1|0>
	local f; f=$(ow_modules_file)
	{ ow_modules_enabled | grep -vx "$1"; [ "$2" = 1 ] && echo "$1"; } | sort -u > "$f.tmp" && mv -f "$f.tmp" "$f"
}

# ow_module_build_for_arch <модуль> <список-доступных-путей> [пакетная арка]
# Путь сборки модуля для этой архитектуры среди доступных (из манифеста или
# дерева). Код 2 — архитектура не поддерживается сборкой (GOARM=7 на ARMv5/6).
ow_module_build_for_arch() {
	local m="$1" avail="$2" pa="${3:-}" dir prefix
	dir=$(ow_module_field "$m" 1); prefix=$(ow_module_field "$m" 2)
	(
		ow_bin_exists() { printf '%s\n' "$avail" | grep -qxF "$1"; }
		ow_bin_path "$dir" "$prefix" $pa
	)
}

# ow_mf_file_applies <путь> <манифест> — 0, если файл манифеста нужен ЭТОМУ
# роутеру: не сборка вовсе, либо сборка включённого модуля под его арку.
ow_mf_file_applies() {
	local m want
	m=$(ow_module_of_path "$1")
	[ -n "$m" ] || return 0
	ow_module_enabled "$m" || return 1
	want=$(ow_module_build_for_arch "$m" "$(awk -F '\t' '$1 == "file" { print $4 }' "$2")") || return 1
	[ "$want" = "$1" ]
}

# Пакеты OpenWrt, нужные модулю: WARP — TUN-интерфейс и копия DNS-ответов
# демону (nft log group -> nfnetlink_log).
ow_module_pkgs() {
	case "$1" in
		warp) echo "kmod-tun kmod-nfnetlink-log" ;;
	esac
}
ow_module_pkgs_install() {
	local p missing=""
	for p in $(ow_module_pkgs "$1"); do ow_pkg_installed "$p" || missing="$missing $p"; done
	[ -n "$missing" ] || return 0
	ow_pkg_update >/dev/null 2>&1
	# shellcheck disable=SC2086
	ow_pkg_install $missing >/dev/null 2>&1
}

# Свободное место на разделе с /opt (КБ).
ow_free_kb() { df -k "${1:-/overlay}" 2>/dev/null | awk 'NR == 2 { print $4 }'; }

# Модули по умолчанию для новой установки — по свободному месту.
# Как у z2k на Keenetic: Телеграм-туннель и мост к RuTracker включены.
ow_modules_default() {
	local free; free=$(ow_free_kb /overlay); free=${free:-0}
	[ "$free" -ge 20000 ] && echo tg
	[ "$free" -ge 30000 ] && echo rtproxy
	return 0
}

# ow_module_install <модуль> <корень-дерева|""> <манифест|""> <версия|"">
# Положить бинарник модуля под эту арку. Источник: локальное дерево (бандл,
# копия репозитория), иначе канал по версии релиза со сверкой sha манифеста.
# Требует channel.sh (ow_file_url, ow_file_cdn_url) и engine.sh (ow_sha256).
ow_module_install() {
	local m="$1" root="$2" mf="$3" ver="$4" avail path target sha tmp url ok=""
	target=$(ow_module_field "$m" 3) || { echo "модуль: неизвестный модуль $m" >&2; return 1; }
	if [ -n "$root" ] && [ -d "$root/$(ow_module_field "$m" 1)" ]; then
		avail=$(cd "$root" && ls "$(ow_module_field "$m" 1)"/* 2>/dev/null)
	elif [ -n "$mf" ]; then
		avail=$(awk -F '\t' '$1 == "file" { print $4 }' "$mf")
	fi
	path=$(ow_module_build_for_arch "$m" "$avail")
	case $? in
		0) ;;
		2) echo "модуль $m: сборка не поддерживает эту архитектуру ARM (нужен ARMv7+)" >&2; return 2 ;;
		*) echo "модуль $m: нет сборки под $(ow_pkg_arch)" >&2; return 2 ;;
	esac
	tmp="$target.z2k-new"
	mkdir -p "$(dirname "$target")"
	if [ -n "$root" ] && [ -f "$root/$path" ]; then
		cp -f "$root/$path" "$tmp" && ok=1
	elif [ -n "$mf" ] && [ -n "$ver" ]; then
		sha=$(awk -F '\t' -v p="$path" '$1 == "file" && $4 == p { print $2; exit }' "$mf")
		for url in "$(ow_file_url "$ver" "$path")" "$(ow_file_cdn_url "$ver" "$path")"; do
			rm -f "$tmp"
			if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 2 --connect-timeout 15 -o "$tmp" "$url" 2>/dev/null
			else uclient-fetch -q -O "$tmp" "$url" 2>/dev/null; fi
			[ -s "$tmp" ] && [ "$(ow_sha256 "$tmp")" = "$sha" ] && { ok=1; break; }
		done
	fi
	[ -n "$ok" ] || { rm -f "$tmp"; echo "модуль $m: бинарник не получен ($path)" >&2; return 1; }
	chmod 755 "$tmp" && mv -f "$tmp" "$target" || return 1
	return 0
}

# Включить службу модуля и запустить (если она есть).
ow_module_service_start() {
	local svc; svc=$(ow_module_field "$1" 4)
	[ "$svc" != - ] && [ -x "/etc/init.d/$svc" ] || return 0
	"/etc/init.d/$svc" enable >/dev/null 2>&1
	"/etc/init.d/$svc" restart >/dev/null 2>&1
}
ow_module_service_stop() {
	local svc; svc=$(ow_module_field "$1" 4)
	[ "$svc" != - ] && [ -x "/etc/init.d/$svc" ] || return 0
	"/etc/init.d/$svc" stop >/dev/null 2>&1
	"/etc/init.d/$svc" disable >/dev/null 2>&1
}
