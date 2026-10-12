# panel-openwrt.sh — платформенный слой OpenWrt для вебпанели z2k
# (webpanel/cgi/api.sh, auth.sh, actions.sh).
#
# Подключается одной строкой-хуком (`# OPENWRT:`) в api.sh перед проверками
# запроса — после того, как auth.sh, actions.sh и сам api.sh объявили свои
# функции, поэтому здесь можно переопределить любую из них. Маршруты, JSON и
# фронтенд — апстримные; меняется только то, что на OpenWrt устроено иначе:
#
#   * вход: пароль проверяет rpcd (`ubus call session login`, учётка LuCI)
#     вместо NDM /auth Keenetic; фронтенд узнаёт режим по realm "rpcd";
#   * устройства для WARP: аренды DHCP + таблица соседей вместо ndmc hotspot;
#   * исключения адресатов: элементы nft-сетов nozapret/nozapret6;
#   * обновления: свой канал (z2k-update), манифест отдаётся панели в формате
#     UPDATES.json апстрима, «Обновить» запускает наш обновлятор;
#   * удаление: openwrt/uninstall.sh;
#   * PPE, маршрутный кэш, политики доступа Keenetic — недоступны (скрыты
#     во фронтенде через www/platform.json, а ручки отвечают ошибкой).

[ -r /etc/openwrt_release ] || [ -n "${Z2K_OW_PANEL_TEST:-}" ] || return 0

# --- вход через rpcd ---------------------------------------------------------------
# В подоболочке с set +u: api.sh работает под `set -u`, а jshn.sh OpenWrt
# обращается к незаданным переменным — CGI обрывался с 500.
_ow_rpcd_login() ( # <логин> <пароль> -> 0 верно, 1 неверно, 2 rpcd недоступен
	set +u
	local json out sid
	command -v ubus >/dev/null 2>&1 || return 2
	. /usr/share/libubox/jshn.sh
	json_init; json_add_string username "$1"; json_add_string password "$2"; json_add_int timeout 60
	json=$(json_dump)
	out=$(ubus call session login "$json" 2>/dev/null) || return 1
	sid=$(printf '%s' "$out" | jsonfilter -e '@.ubus_rpc_session' 2>/dev/null)
	[ -n "$sid" ] || return 1
	# Сессия rpcd нам не нужна — у панели своя; сразу закрываем.
	ubus call session destroy "{\"ubus_rpc_session\":\"$sid\"}" >/dev/null 2>&1
	return 0
)

# Контракт апстрима: stdout «realm<TAB>challenge<TAB>host», код 0/1.
panel_ndm_challenge() { printf 'rpcd\t%s\tlocal\n' "$(_panel_random_hex)"; }

# Контракт апстрима: <логин> <ответ> <host> <jar> -> 0 ок, 1 неверно, 2 недоступно.
# В режиме rpcd «ответ» — сам пароль (см. www/js/core/auth.js, OPENWRT).
panel_verify_ndm_response() { _ow_rpcd_login "$1" "$2"; }
panel_verify_router_password() { _ow_rpcd_login "$1" "$2"; }

# Пускает ли rpcd этого пользователя — уже проверено входом.
panel_user_has_http_tag() { return 0; }
_panel_ndm_port() { echo 80; }
_panel_ndm_candidates() { return 0; }

# --- устройства локальной сети для WARP ------------------------------------------------
#
# Формат апстрима (warp_neighbors): mac ip метка сеть активен выбран, через \037,
# активные сверху, затем по метке. Источники: аренды DHCP (имя), таблица
# соседей (активность и устройства со статическим адресом).
warp_neighbors()
{
	local sel="$WARP_LISTS_DIR/devices.txt"
	[ -f "$sel" ] || sel=/dev/null
	{ ip -4 neigh show 2>/dev/null | awk '/lladdr/ { for (i = 1; i <= NF; i++) { if ($i == "lladdr") m = $(i+1); if ($i == "dev") d = $(i+1) }
		print "N", tolower(m), $1, d, $NF }'
	  [ -r "${OW_DHCP_LEASES:-/tmp/dhcp.leases}" ] && awk '{ print "L", tolower($2), $3, $4 }' "${OW_DHCP_LEASES:-/tmp/dhcp.leases}"
	} | awk -v sel="$sel" '
	BEGIN {
		while ((getline l < sel) > 0) {
			gsub(/\r/, "", l); gsub(/^[ \t]+|[ \t]+$/, "", l); l = tolower(l); gsub(/-/, ":", l)
			if (l ~ /^([0-9a-f][0-9a-f]:)+[0-9a-f][0-9a-f]$/) on[l] = 1
		}
	}
	$1 == "N" { if ($5 == "FAILED" || $5 == "INCOMPLETE" || $4 !~ /^br/) next   # только мосты LAN
		seen[$2] = 1; ip[$2] = $3; net[$2] = $4; act[$2] = ($5 == "REACHABLE" || $5 == "DELAY" || $5 == "PROBE") }
	$1 == "L" { seen[$2] = 1; if (!($2 in ip)) ip[$2] = $3; if ($4 != "*") host[$2] = $4 }
	END {
		for (m in seen) {
			label = (m in host) ? host[m] : m; gsub(/"/, "", label)
			printf "%s\037%s\037%s\037%s\037%d\037%d\n", m, ip[m], label, net[m], act[m], (m in on)
		}
	}' | sort -t "$(printf '\037')" -k5,5r -k3,3f
}

# --- исключения адресатов: nft-сеты движка ---------------------------------------------
_exclude_ipset_apply()
{
	local op="$1" entry="$2" set=nozapret verb=add
	case "$entry" in *:*) set=nozapret6 ;; esac
	case "$op" in del) verb=delete ;; esac
	nft "$verb" element inet "${ZAPRET_NFT_TABLE:-zapret2}" "$set" "{ $entry }" >/dev/null 2>&1 || true
	return 0
}

# --- обновления: канал z2k-openwrt ---------------------------------------------------
AU_SCRIPT="$ZAPRET2_DIR/openwrt/lib/update.sh"     # update_apply_async: `sh $AU_SCRIPT apply`

update_installed_tag()
{
	local v
	v=$(awk '$1 == "version" { print $2; exit }' "$ZAPRET2_DIR/.z2k-installed" 2>/dev/null)
	printf '%s' "${v:-unknown}"
}

# Манифест канала (проверенный по подписи) в формате UPDATES.json апстрима —
# дальше апстримные update_manifest_current / update_behind_count /
# update_pending_entries / update_history_entries работают как есть.
_update_fetch_manifest()
{
	local dest="$2" flag="$2.done.$$" pid rc waited=0
	printf 'z2k-openwrt\n' > "$AU_MANIFEST_SOURCE_FILE" 2>/dev/null
	( sh "$ZAPRET2_DIR/openwrt/lib/update.sh" json > "$dest" 2>/dev/null; printf '%s' "$?" > "$flag" ) \
		</dev/null >/dev/null 2>&1 &
	pid=$!
	while [ ! -f "$flag" ] && [ "$waited" -lt "$AU_MANIFEST_FETCH_TIMEOUT" ]; do sleep 1; waited=$((waited + 1)); done
	if [ -f "$flag" ]; then rc=$(cat "$flag"); case "$rc" in ''|*[!0-9]*) rc=1 ;; esac
	else _kill_tree "$pid"; rc=1; fi
	wait "$pid" 2>/dev/null
	rm -f "$flag"
	return "$rc"
}

# --- удаление ---------------------------------------------------------------------
Z2K_SH="$ZAPRET2_DIR/openwrt/uninstall.sh"          # uninstall_async: `sh $Z2K_SH uninstall`

# --- то, чего на OpenWrt нет ---------------------------------------------------------
toggle_ppe() { echo "PPE — аппаратное ускорение Keenetic, на OpenWrt его нет"; return 1; }
toggle_fastroute() { echo "Маршрутный кэш Keenetic на OpenWrt недоступен (flow offloading настраивает установщик)"; return 1; }
policy_exists() { return 1; }
policy_save() { echo "Политики доступа Keenetic на OpenWrt нет"; return 1; }
