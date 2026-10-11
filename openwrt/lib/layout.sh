#!/bin/sh
# layout.sh — куда на роутере ложится каждый файл репозитория.
#
# Единственный источник раскладки: им пользуется установщик (сейчас) и
# сборщик манифеста форка (install_map в UPDATES.json, фаза 3). Аналог
# z2k_install_paths апстрима (lib/release_map.sh), но под OpenWrt.
#
# ow_layout_targets <путь в репозитории> — печатает абсолютные пути
# назначения через пробел; пусто = файл на роутер не едет.
# Первый путь — основной (по нему обновлятор сверяет sha).
#
# Что едет, решает openwrt/compat-map.tsv (portable/patched + наш рантайм);
# здесь — только куда. Модули фаз 5–6 (Go-сборки, панель, туннели, WARP)
# добавятся сюда по мере портирования.

OW_ZD="${OW_ZD:-/opt/zapret2}"

ow_layout_targets()
{
	local p="$1" zd="$OW_ZD"
	case "$p" in
		# --- наш рантайм ---
		openwrt/init.d/z2k)          echo "/etc/init.d/z2k" ;;
		openwrt/init.d/*)            echo "/etc/init.d/${p#openwrt/init.d/}" ;;
		openwrt/lib/tg-redirect.sh)  echo "$zd/z2k-tg-redirect.sh" ;;
		openwrt/hotplug/90-z2k)      echo "/etc/hotplug.d/iface/90-z2k" ;;
		openwrt/lib/*.sh)            echo "$zd/$p" ;;
		openwrt/bin/*)               echo "$zd/$p" ;;
		openwrt/engine.pin)          echo "$zd/openwrt/engine.pin" ;;
		openwrt/install.sh|openwrt/uninstall.sh) echo "$zd/$p" ;;
		openwrt/etc/*)               echo "$zd/etc/${p#openwrt/etc/}" ;;

		# --- движок z2k: S99 + платформенный слой ---
		files/S99zapret2.new)        echo "$zd/init.d/z2k-engine" ;;

		# --- данные nfqws2 ---
		files/lua/*.lua)             echo "$zd/lua/${p#files/lua/}" ;;
		files/fake/*)                echo "$zd/files/fake/${p#files/fake/}" ;;
		files/lists/extra_strats/*)  echo "$zd/files/lists/${p#files/lists/}" ;;
		# Поставляемые списки — и снимок (files/lists), и живая копия (lists),
		# как у апстрима (release_map.sh).
		files/lists/*)               echo "$zd/files/lists/${p#files/lists/} $zd/lists/${p#files/lists/}" ;;
		files/etc/z2k-roots.pem)     echo "$zd/etc/z2k-roots.pem" ;;
		strats_new2.txt|quic_strats.ini) echo "$zd/$p" ;;
		extras/*)                    echo "$zd/$p" ;;

		# --- бинарники модулей (ставятся по выбору, под арку роутера: modules.sh) ---
		mtproxy-client/builds/tg-mtproxy-client-linux-*) echo "/opt/sbin/tg-mtproxy-client" ;;
		mtproxy-client/builds/z2k-rt-proxy-linux-*)      echo "/opt/sbin/z2k-rt-proxy" ;;
		openwrt/builds/z2k-detect-linux-*)               echo "/opt/sbin/z2k-detect" ;;
		openwrt/builds/z2k-warpd-linux-*)                echo "/opt/sbin/z2k-warpd" ;;

		# --- модуль tg ---
		files/z2k-tg-watchdog.sh)    echo "$zd/tg-tunnel-watchdog.sh" ;;

		# --- модуль warp ---
		files/z2k-warp.sh)           echo "$zd/z2k-warp.sh" ;;

		# --- закрепление адресов Instagram (dnsmasq вместо ndmc ip host) ---
		files/z2k-insta-ip-refresh.sh) echo "$zd/z2k-insta-ip-refresh.sh" ;;
		openwrt/fw4/*.nft)           echo "/usr/share/nftables.d/chain-pre/forward/${p#openwrt/fw4/}" ;;

		# --- библиотеки z2k (генераторы, утилиты) ---
		lib/install.sh|lib/release_map.sh|lib/auto_update.sh) ;;
		lib/*.sh)                    echo "$zd/$p" ;;

		# --- рантайм-скрипты z2k ---
		files/z2k-geosite.sh|files/z2k-config-validator.sh|files/z2k-blocked-monitor.sh|\
		files/z2k-dns-check.sh|files/z2k-update-lists.sh|files/z2k-tcp16-probe.sh|\
		files/z2k-diag.sh|files/z2k-warp-list-filter.awk)
		                             echo "$zd/${p#files/}" ;;
		*) ;;
	esac
}

# ow_layout_is_build <путь> — сборка модуля (ставится через modules.sh).
ow_layout_is_build() { case "$1" in */builds/*) return 0 ;; esac; return 1; }

# ow_layout_files <корень репозитория> — все файлы репозитория, которые едут
# на роутер (путь относительно корня), по одному в строке. Сборки модулей
# сюда не входят — их ставит ow_module_install под арку роутера.
ow_layout_files()
{
	local root="$1" f
	( cd "$root" && find openwrt files lib strats_new2.txt quic_strats.ini extras -type f 2>/dev/null ) |
	while IFS= read -r f; do
		ow_layout_is_build "$f" && continue
		[ -n "$(ow_layout_targets "$f")" ] && echo "$f"
	done
}
