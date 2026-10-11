#!/bin/sh
# postinstall.sh — то, что установщик z2k (lib/install.sh, на роутер не едет)
# делает с деревом после раскладки файлов и что нужно и после обновления.
#
# Список псевдонимов сверяется с lib/install.sh тестом test_postinstall.sh:
# появится новый псевдоним в апстриме — тест упадёт при синхронизации.

# Короткие имена блобов, на которые ссылаются стратегии и валидатор конфига
# (z2k-config-validator.sh ищет files/fake/<имя>[.bin]).
OW_BLOB_ALIASES="tls_max_ru:tls_clienthello_max_ru.bin
quic1:quic_1.bin
quic4:quic_4.bin
quic5:quic_5.bin
quic6:quic_6.bin
quic_google:quic_initial_www_google_com.bin
quic_rutracker:quic_initial_rutracker_org.bin
quic_dbankcloud:quic_initial_dbankcloud_ru.bin"

ow_blob_aliases()
{
	local fakedir="${1:-/opt/zapret2}/files/fake" pair a f
	[ -d "$fakedir" ] || return 0
	for pair in $OW_BLOB_ALIASES; do
		a=${pair%%:*}; f=${pair#*:}
		[ -f "$fakedir/$f" ] || continue
		[ -e "$fakedir/$a" ] && [ ! -L "$fakedir/$a" ] && continue   # чужой файл не трогаем
		ln -sf "$f" "$fakedir/$a"
	done
	return 0
}

# Код z2k (панель, меню, сторожа, рантайм-скрипты) зовёт службы по путям
# Entware /opt/etc/init.d/S*. На OpenWrt этот каталог больше никто не
# использует — кладём туда ссылки на наши procd-службы (rc.common определяет
# имя службы по цели ссылки).
# S51z2k-warp — на переходник: z2k-warp.sh зовёт службу через `sh`.
OW_COMPAT_INITS="S99zapret2:/etc/init.d/z2k S98tg-tunnel:/etc/init.d/z2k-tg S96z2k-rt-proxy:/etc/init.d/z2k-rtproxy S51z2k-warp:/opt/zapret2/openwrt/bin/z2k-warp-init"

ow_compat_inits()
{
	local pair
	mkdir -p /opt/etc/init.d
	for pair in $OW_COMPAT_INITS; do
		[ -x "${pair#*:}" ] && ln -sf "${pair#*:}" "/opt/etc/init.d/${pair%%:*}"
	done
	return 0
}

# ow_postinstall <ZAPRET_BASE> — всё вместе.
ow_postinstall()
{
	local zd="${1:-/opt/zapret2}"
	ow_blob_aliases "$zd"
	ow_compat_inits
	[ -f "$zd/openwrt/bin/z2k-module" ] && ln -sf "$zd/openwrt/bin/z2k-module" /usr/bin/z2k-module 2>/dev/null
	# CLI обновлений.
	[ -f "$zd/openwrt/bin/z2k-update" ] && ln -sf "$zd/openwrt/bin/z2k-update" /usr/bin/z2k-update 2>/dev/null
	return 0
}
