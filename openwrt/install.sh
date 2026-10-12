#!/bin/sh
# z2k-openwrt — установка на OpenWrt 23.05+ (fw4/nftables).
#
# Сейчас (фаза 2) ставит из локальной копии репозитория или бандла
# (openwrt/maint/make-bundle.sh): sh openwrt/install.sh
# Сетевая установка одной командой по подписанному манифесту — фаза 3.
#
# Переменные:
#   Z2K_OW_SKIP_DEPS=1    не ставить пакеты (уже стоят / нет сети до репозиториев)
#   Z2K_OW_ENGINE_TGZ=…   взять архив движка из файла (проверяется по sha пина)
#   Z2K_OW_NO_START=1     не запускать службу после установки

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ZD=/opt/zapret2
OW_ZD="$ZD"

. "$ROOT/openwrt/lib/platform.sh"
. "$ROOT/openwrt/lib/channel.sh"
. "$ROOT/openwrt/lib/engine.sh"
. "$ROOT/openwrt/lib/layout.sh"
. "$ROOT/openwrt/lib/manifest.sh"
. "$ROOT/openwrt/lib/postinstall.sh"
. "$ROOT/openwrt/lib/modules.sh"

say()  { echo "[z2k] $*"; }
warn() { echo "[z2k] ВНИМАНИЕ: $*" >&2; }
die()  { echo "[z2k] ОШИБКА: $*" >&2; exit 1; }

# --- 0. проверки ----------------------------------------------------------------
[ "$(id -u)" = 0 ] || die "нужен root"
ow_is_openwrt || die "это не OpenWrt (нет /etc/openwrt_release)"
ow_series_supported || die "OpenWrt $(ow_release) не поддерживается (нужен 23.05 или новее)"
ow_has_fw4 || die "нет fw4 (nftables) — нужен OpenWrt 23.05+ с firewall4"
PM=$(ow_pkg_manager) || die "не найден пакетный менеджер (opkg/apk)"
ARCH=$(ow_pkg_arch)
ow_engine_arch >/dev/null || die "под архитектуру $ARCH нет сборки движка zapret2"
say "OpenWrt $(ow_release), $ARCH, пакеты: $PM"

# --- 1. зависимости ------------------------------------------------------------------
# kmod-nft-queue тянет nfnetlink_queue; nft, fw4, kmod-nft-nat — в базе 23.05+.
DEPS="curl ca-bundle kmod-nft-queue"
if [ -z "${Z2K_OW_SKIP_DEPS:-}" ]; then
	missing=""
	for p in $DEPS; do ow_pkg_installed "$p" || missing="$missing $p"; done
	if [ -n "$missing" ]; then
		say "ставлю пакеты:$missing"
		ow_pkg_update >/dev/null 2>&1 || warn "обновление списка пакетов не удалось"
		# shellcheck disable=SC2086
		ow_pkg_install $missing || die "не установились пакеты:$missing"
	fi
fi

# --- 2. остановить прежнюю установку ------------------------------------------------
[ -x /etc/init.d/z2k ] && /etc/init.d/z2k stop >/dev/null 2>&1

# --- 3. движок ------------------------------------------------------------------------------
PIN="$ROOT/openwrt/engine.pin"
TGZ="${Z2K_OW_ENGINE_TGZ:-/tmp/z2k-engine.tar.gz}"
if [ -n "${Z2K_OW_ENGINE_TGZ:-}" ]; then
	[ "$(ow_sha256 "$TGZ")" = "$(ow_pin_get ENGINE_SHA256 "$PIN")" ] || die "архив движка $TGZ не совпадает с пином"
else
	say "качаю движок $(ow_pin_get ENGINE_VERSION "$PIN")"
	ow_engine_fetch "$PIN" "$TGZ" || die "движок не скачался"
fi
ow_engine_install "$TGZ" "$PIN" "$ZD" || die "движок не установился"
[ -n "${Z2K_OW_ENGINE_TGZ:-}" ] || rm -f "$TGZ"
say "движок: $(cat "$ZD/.z2k-engine-version") ($(ow_engine_arch))"

# --- 4. файлы z2k и порта ---------------------------------------------------------------
n=0
for f in $(ow_layout_files "$ROOT"); do
	for t in $(ow_layout_targets "$f"); do
		mkdir -p "$(dirname "$t")" || die "не создаётся $(dirname "$t")"
		cp -f "$ROOT/$f" "$t.z2k-new" && mv -f "$t.z2k-new" "$t" || die "не скопировался $f -> $t"
		case "$t" in
			/etc/init.d/*|/etc/hotplug.d/*|*/init.d/z2k-engine|*/openwrt/bin/*|*.sh) chmod 755 "$t" ;;
		esac
		n=$((n + 1))
	done
done
say "разложено файлов: $n"

# custom.d из архива движка (DISABLE_CUSTOM=1 по умолчанию — включаются в меню/панели).
CUSTOM="$ZD/init.d/keenetic/custom.d"
mkdir -p "$CUSTOM"
for s in 50-stun4all 50-discord-media; do
	[ -f "$ZD/init.d/custom.d.examples.linux/$s" ] && cp -f "$ZD/init.d/custom.d.examples.linux/$s" "$CUSTOM/$s"
done

mkdir -p /opt/etc/zapret2
echo "$Z2K_OW_CHANNEL" > "$ZD/.z2k-branch"

# Include fw4 (форвард LAN -> туннель WARP) подхватывается только перезагрузкой fw4.
ls /usr/share/nftables.d/chain-pre/forward/30-z2k-*.nft >/dev/null 2>&1 && fw4 -q reload
ow_postinstall "$ZD"

# Что установлено. Из релиза (get.sh передаёт проверенный манифест) — версия
# и seq релиза, обновлятор дальше сходится от них. Из локальной копии — dev,
# seq 0: первое же z2k-update apply приведёт установку к релизу канала.
if [ -n "${Z2K_OW_MANIFEST:-}" ] && ow_mf_valid "$Z2K_OW_MANIFEST"; then
	cp -f "$Z2K_OW_MANIFEST" "$ZD/.z2k-manifest"
	{ echo "version $(ow_mf_get "$Z2K_OW_MANIFEST" version)"; echo "seq $(ow_mf_get "$Z2K_OW_MANIFEST" seq)"
	  echo "channel $Z2K_OW_CHANNEL"; echo "upstream_base $(ow_mf_get "$Z2K_OW_MANIFEST" upstream_base)"
	  echo "updated $(date -u +%Y-%m-%dT%H:%M:%SZ)"; } > "$ZD/.z2k-installed"
else
	rm -f "$ZD/.z2k-manifest"
	{ echo "version dev"; echo "seq 0"; echo "channel $Z2K_OW_CHANNEL"
	  echo "upstream_base $(sed -n 's/^upstream_base=//p' "$ROOT/openwrt/UPSTREAM" 2>/dev/null)"
	  echo "updated $(date -u +%Y-%m-%dT%H:%M:%SZ)"; } > "$ZD/.z2k-installed"
fi
[ -s "$ZD/etc/z2k-update.pub" ] || warn "нет ключа канала ($ZD/etc/z2k-update.pub) — z2k-update работать не будет"

# --- 5. flow offloading -------------------------------------------------------------------
# Потоки, ушедшие в offload fw4, мимо очереди nfqws2 — обход ломается. Как и
# апстримный zapret2: offload fw4 выключаем, а движок ставит свою flowtable
# с исключениями для трафика обхода (FLOWOFFLOAD в конфиге).
FLOWOFFLOAD=none
if [ "$(uci -q get firewall.@defaults[0].flow_offloading)" = 1 ]; then
	if [ "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" = 1 ]; then FLOWOFFLOAD=hardware; else FLOWOFFLOAD=software; fi
	say "offload fw4 включён — переношу его в движок (FLOWOFFLOAD=$FLOWOFFLOAD) и выключаю в fw4"
	uci set firewall.@defaults[0].flow_offloading=0
	uci set firewall.@defaults[0].flow_offloading_hw=0
	uci commit firewall
	fw4 -q reload || warn "fw4 reload не удался"
elif [ -f "$ZD/config" ]; then
	FLOWOFFLOAD=$(sed -n 's/^FLOWOFFLOAD=//p' "$ZD/config" | head -n 1)
	[ -n "$FLOWOFFLOAD" ] || FLOWOFFLOAD=none
fi
export FLOWOFFLOAD

# --- 6. стратегии и конфиг -----------------------------------------------------------------
. "$ROOT/openwrt/lib/z2k-config.sh"
say "генерирую стратегии и конфиг"
ow_z2k_generate || die "генерация конфига не удалась"

# --- 7. автозапуск и старт ------------------------------------------------------------------
/etc/init.d/z2k enable
sh "$ZD/openwrt/bin/z2k-cron" install

# --- 7a. модули (Go-бинарники по выбору) --------------------------------------------
# Z2K_OW_MODULES="tg rtproxy" — явно; "none" — без модулей. Иначе — что было
# включено раньше, а на новой установке — по свободному месту.
OW_ZD="$ZD"
MODS="${Z2K_OW_MODULES:-}"
[ -n "$MODS" ] || { [ -f "$ZD/.z2k-modules" ] && MODS=$(ow_modules_enabled | tr '
' ' '); }
[ -n "$MODS" ] || MODS=$(ow_modules_default | tr '
' ' ')
[ "$MODS" = none ] && MODS=""
MVER=""; [ -n "${Z2K_OW_MANIFEST:-}" ] && MVER=$(ow_mf_get "$Z2K_OW_MANIFEST" version)
: > "$ZD/.z2k-modules"
for m in $MODS; do
	if ow_module_pkgs_install "$m" && ow_module_install "$m" "$ROOT" "${Z2K_OW_MANIFEST:-}" "$MVER"; then
		ow_module_set "$m" 1; say "модуль $m установлен"
	else
		warn "модуль $m не установлен (позже: z2k-module enable $m)"
	fi
done
if [ -z "${Z2K_OW_NO_START:-}" ]; then
	say "применяю стратегии и запускаю службу"
	ow_z2k_apply_strategies || warn "применение стратегий вернуло ошибку — смотрите вывод выше"
	for m in $(ow_modules_enabled); do ow_module_service_start "$m"; done
	# Вебпанель: Z2K_OW_PANEL=0 — без неё.
	if [ "${Z2K_OW_PANEL:-1}" = 1 ]; then
		had_lighttpd=0; ow_pkg_installed lighttpd && had_lighttpd=1
		if ow_pkg_installed lighttpd-mod-cgi || { ow_pkg_update >/dev/null 2>&1; ow_pkg_install lighttpd lighttpd-mod-cgi lighttpd-mod-setenv >/dev/null 2>&1; }; then
			# Пакет включает свою службу со стандартным конфигом: после
			# перезагрузки второй lighttpd спорил бы с uhttpd (LuCI) за :80.
			# Панель — своя служба z2k-panel; чужой, заранее стоявший lighttpd не трогаем.
			if [ "$had_lighttpd" = 0 ] && [ -x /etc/init.d/lighttpd ]; then
				/etc/init.d/lighttpd stop >/dev/null 2>&1
				/etc/init.d/lighttpd disable >/dev/null 2>&1
			fi
			/etc/init.d/z2k-panel enable && /etc/init.d/z2k-panel restart
			say "вебпанель: http://$(cat "$ZD/webpanel/bind" 2>/dev/null):$(cat "$ZD/webpanel/port" 2>/dev/null)/"
		else
			warn "lighttpd не установился — вебпанель не запущена"
		fi
	fi
	if /etc/init.d/z2k status >/dev/null 2>&1; then
		say "готово: обход работает (nft list table inet zapret2 — правила)"
	else
		warn "служба не запустилась: /etc/init.d/z2k start — подробности"
		exit 1
	fi
else
	say "установлено, служба не запускалась (Z2K_OW_NO_START)"
fi
