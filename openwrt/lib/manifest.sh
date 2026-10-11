#!/bin/sh
# manifest.sh — манифест релиза форка: формат и разбор.
#
# Текстовый, строка = запись, поля через TAB. Разбирается awk на busybox,
# подписывается целиком (openwrt/release/manifest.sig, формат usign).
#
#   #z2k-openwrt-manifest 1
#   channel        openwrt-main
#   seq            7                  растёт на 1 с каждым релизом (защита от отката)
#   version        v1.2.0             = git-тег, по нему качаются файлы
#   upstream_base  p-86.19            до какой версии z2k дотянут форк
#   date           2026-10-12
#   reset_state    0|1                сбросить кэш автоподбора стратегий
#   file  <sha256>  <644|755>  <путь в репозитории>  <цель1>[ <цель2>…]
#   release  <версия>  <дата>  <upstream_base>  <описание одной строкой>
#
# release — история (новые сверху), только для показа человеку.

OW_MANIFEST_MAGIC="#z2k-openwrt-manifest 1"

# ow_mf_get <манифест> <ключ> — значение одиночного ключа.
ow_mf_get()
{
	awk -F '\t' -v k="$2" '$1 == k { print $2; exit }' "$1"
}

ow_mf_valid()
{
	[ -s "$1" ] && [ "$(head -n 1 "$1")" = "$OW_MANIFEST_MAGIC" ] &&
		[ -n "$(ow_mf_get "$1" seq)" ] && [ -n "$(ow_mf_get "$1" version)" ]
}

# ow_mf_files <манифест> — "sha<TAB>mode<TAB>путь<TAB>цели" по строке на файл.
ow_mf_files()
{
	awk -F '\t' '$1 == "file" { print $2 "\t" $3 "\t" $4 "\t" $5 }' "$1"
}

# ow_mf_targets <манифест> — все цели всех файлов, по одной в строке.
ow_mf_targets()
{
	awk -F '\t' '$1 == "file" { n = split($5, t, " "); for (i = 1; i <= n; i++) print t[i] }' "$1"
}

# ow_mf_releases <манифест> [N] — история: "версия дата upstream описание".
ow_mf_releases()
{
	awk -F '\t' -v n="${2:-1000}" '$1 == "release" && c < n { c++; print $2 "  " $3 "  (" $4 ")  " $5 }' "$1"
}

# ow_steps_for <путь в репозитории> — шаги, которых требует смена файла.
# Аналог z2k_steps_for апстрима (lib/release_map.sh) под OpenWrt.
ow_steps_for()
{
	case "$1" in
		openwrt/engine.pin)
			echo engine; echo restart-service ;;
		lib/strategies.sh|strats_new2.txt|quic_strats.ini)
			echo regen-strategies; echo regen-config; echo validate-config; echo restart-service ;;
		lib/config_official.sh|openwrt/lib/z2k-config.sh)
			echo regen-config; echo validate-config; echo restart-service ;;
		openwrt/bin/z2k-cron)
			echo cron ;;
		files/lua/*|files/fake/*|files/S99zapret2.new|files/lists/*|files/etc/*|extras/*|\
		openwrt/lib/s99-openwrt.sh|openwrt/init.d/z2k)
			echo restart-service ;;
	esac
}

# Канонический порядок: сколько бы файлов ни поменялось — один перезапуск
# в конце.
ow_step_order()
{
	echo engine
	echo regen-strategies
	echo regen-config
	echo validate-config
	echo reset-state
	echo restart-service
	echo cron
}

# ow_steps_merged — пути на stdin -> уникальные шаги в каноническом порядке.
# Дополнительные шаги (reset-state) — аргументами.
ow_steps_merged()
{
	local all s
	all=$( { while IFS= read -r p; do ow_steps_for "$p"; done; for s in "$@"; do echo "$s"; done; } | sort -u)
	for s in $(ow_step_order); do
		printf '%s\n' "$all" | grep -qx "$s" && echo "$s"
	done
	return 0
}
