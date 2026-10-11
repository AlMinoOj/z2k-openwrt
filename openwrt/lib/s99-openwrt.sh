# s99-openwrt.sh — платформенный слой OpenWrt для движка z2k.
#
# Подключается ОДНОЙ строкой из files/S99zapret2.new (маркер `# OPENWRT:`)
# прямо перед диспетчером `case "$1"` — то есть после того, как S99 объявил
# все свои функции и собрал NFQWS2_OPT_BASE. Всё, что здесь объявлено,
# переопределяет одноимённое в S99. Логика z2k (автохостлист, кэш ротации,
# отладка, исключения, whitelist, Lua-цепочка) остаётся в S99 и приезжает
# с апстримом без ручного переноса.
#
# Что меняем:
#   * межсетевой экран: nftables (fw4) через апстримный nft-путь zapret2
#     (common/nft.sh), платформенные функции — как в init.d/openwrt/functions
#     архива движка; iptables-слои z2k (connmark политики Keenetic, UDP
#     masquerade fix, RST-фильтр, порт-ipset) на nft не включаются;
#   * исключения адресатов (nozapret/nozapret6) — элементы nft-сетов вместо ipset;
#   * модули ядра — штатные kmod OpenWrt, insmod не нужен;
#   * планировщик z2k и «разминирование» стокового lighttpd Keenetic — нет
#     (задачи по расписанию на OpenWrt — cron, см. openwrt/cron).

# Только на OpenWrt: на Keenetic этот файл не устанавливается, но страховка
# дешёвая.
[ -r /etc/openwrt_release ] || return 0

. /lib/functions/network.sh

OPENWRT_LAN=${OPENWRT_LAN:-lan}

# --- WAN/LAN по netifd (из init.d/openwrt/functions движка) -----------------
#
# Все IPv4/IPv6 uplink'и, а не только первый (network_find_wan отдаёт один):
# провайдер, туннельный брокер, VPN — блокировать может любой.
network_find_wan4_all()
{
	if [ -n "$OPENWRT_WAN4" ]; then
		eval $1="\$OPENWRT_WAN4"
	else
		__network_ifstatus "$1" "" "[@.route[@.target='0.0.0.0' && !@.table]].interface" "" 10 2>/dev/null && return
		network_find_wan $1
	fi
}
network_find_wan_all()
{
	network_find_wan4_all "$@"
}
network_find_wan6_all()
{
	if [ -n "$OPENWRT_WAN6" ]; then
		eval $1="\$OPENWRT_WAN6"
	else
		__network_ifstatus "$1" "" "[@.route[@.target='::' && !@.table]].interface" "" 10 2>/dev/null && return
		network_find_wan6 $1
	fi
}
network_find_wanX_devices()
{
	# $1 - 4/6, $2 - переменная для результата
	local ifaces
	network_find_wan${1}_all ifaces
	call_for_multiple_items network_get_device $2 "$ifaces"
}
get_lanif()
{
	call_for_multiple_items network_get_device $1 "$OPENWRT_LAN"
}

# --- nftables: наборы интерфейсов и правила очереди ---------------------------
nft_fill_ifsets_overload()
{
	local ifaces DLAN DWAN DWAN6 PDLAN PDWAN PDWAN6

	call_for_multiple_items network_get_device DLAN "$OPENWRT_LAN"
	call_for_multiple_items network_get_physdev PDLAN "$OPENWRT_LAN"

	network_find_wan4_all ifaces
	call_for_multiple_items network_get_device DWAN "$ifaces"
	call_for_multiple_items network_get_physdev PDWAN "$ifaces"

	network_find_wan6_all ifaces
	call_for_multiple_items network_get_device DWAN6 "$ifaces"
	call_for_multiple_items network_get_physdev PDWAN6 "$ifaces"

	nft_fill_ifsets "$DLAN" "$DWAN" "$DWAN6" "$PDLAN" "$PDWAN" "$PDWAN6"
}
# На OpenWrt правила очереди всегда привязаны к WAN: локальный трафик в
# очередь не попадает даже при пустом наборе исключений.
nft_wanif_filter_present() { return 0; }
nft_wanif6_filter_present() { return 0; }
nft_fw_nfqws_post4() { _nft_fw_nfqws_post4 "$1" $2 always_apply_wan_filter; }
nft_fw_nfqws_post6() { _nft_fw_nfqws_post6 "$1" $2 always_apply_wan_filter; }
nft_fw_nfqws_pre4()  { _nft_fw_nfqws_pre4 "$1" $2 always_apply_wan_filter; }
nft_fw_nfqws_pre6()  { _nft_fw_nfqws_pre6 "$1" $2 always_apply_wan_filter; }

# --- iptables-слои z2k на nftables не включаются -----------------------------
#
# В S99 эта функция печатает «обход работать НЕ БУДЕТ» при FWTYPE≠iptables:
# на Keenetic это правда, здесь — нет (очередь ставит nft-путь движка). Молча
# отвечаем «не iptables», и слои z2k, завязанные на iptables, выходят сразу.
z2k_fw_is_iptables() { [ "$FWTYPE" = "iptables" ]; }

# Подметалки висячих NFQUEUE-правил работают через iptables-save и защиту
# z2k_fw_is_iptables не имеют. На fw4 nft-таблица zapret2 пересоздаётся
# целиком при каждом start_fw, висячим правилам взяться неоткуда.
z2k_sweep_stale_wan_nfqueue() { z2k_fw_is_iptables || return 0; }
z2k_sweep_orphan_nfqueue() { z2k_fw_is_iptables || return 0; }

# --- исключения адресатов: nft-сеты вместо ipset -----------------------------
#
# Сеты nozapret/nozapret6 проверяются в каждом nft-правиле очереди
# (common/nft.sh: `ip daddr != @nozapret`) и в исключениях flow offload.
# Объявляем их сами (add set идемпотентен): создаёт ли их create_ipset,
# зависит от наличия файлов списков.
z2k_ow_nft_ensure_exclude_sets()
{
	[ "$DISABLE_IPV4" = "1" ] || nft add set inet "$ZAPRET_NFT_TABLE" nozapret \
		'{ type ipv4_addr; flags interval; auto-merge; }' 2>/dev/null
	[ "$DISABLE_IPV6" = "1" ] || nft add set inet "$ZAPRET_NFT_TABLE" nozapret6 \
		'{ type ipv6_addr; flags interval; auto-merge; }' 2>/dev/null
	return 0
}

# z2k_ow_nft_add_elements <сет> <адрес/сеть>... — одной транзакцией.
z2k_ow_nft_add_elements()
{
	local set="$1" list="" a
	shift
	for a in "$@"; do list="${list:+$list, }$a"; done
	[ -n "$list" ] || return 0
	nft add element inet "$ZAPRET_NFT_TABLE" "$set" "{ $list }" 2>/dev/null
}

z2k_seed_local_exclusions()
{
	[ "$FWTYPE" = nftables ] || return 0
	z2k_ow_nft_ensure_exclude_sets
	[ "$DISABLE_IPV4" = "1" ] || z2k_ow_nft_add_elements nozapret $Z2K_LOCAL_EXCLUDE4
	[ "$DISABLE_IPV6" = "1" ] || z2k_ow_nft_add_elements nozapret6 $Z2K_LOCAL_EXCLUDE6
	echo "Local address ranges excluded from desync (nozapret)"
	return 0
}

# Та же грамматика файла, что у S99 (z2k_seed_user_exclusions) и панели:
# комментарий после «#» и пробелы срезаются, строка-не-адрес пропускается.
z2k_seed_user_exclusions()
{
	[ "$FWTYPE" = nftables ] || return 0
	local f="${ZAPRET_BASE}/ipset/zapret-hosts-user-exclude.txt"
	local line v4="" v6="" n4=0 n6=0 skipped=0
	[ -f "$f" ] || return 0
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%%#*}"
		line=$(printf '%s' "$line" | tr -d ' \t\r')
		[ -n "$line" ] || continue
		case "$line" in
			*:*) v6="$v6 $line"; n6=$((n6 + 1)) ;;
			*[!0-9./]*) skipped=$((skipped + 1)) ;;
			*[0-9]*) v4="$v4 $line"; n4=$((n4 + 1)) ;;
		esac
	done < "$f"
	z2k_ow_nft_ensure_exclude_sets
	[ "$DISABLE_IPV4" = "1" ] || z2k_ow_nft_add_elements nozapret $v4
	[ "$DISABLE_IPV6" = "1" ] || z2k_ow_nft_add_elements nozapret6 $v6
	[ "$((n4 + n6))" -gt 0 ] && echo "User address exclusions loaded: $n4 IPv4, $n6 IPv6"
	[ "$skipped" -gt 0 ] && echo "User address exclusions: $skipped line(s) skipped, not an address (domains go to lists/whitelist.txt)"
	return 0
}

# --- модули ядра ---------------------------------------------------------------
#
# На OpenWrt модули ставятся пакетами (kmod-nft-queue и др.) и грузятся
# kmodloader'ом. S99 искал .ko по каталогам Keenetic и делал insmod — здесь
# только убеждаемся, что очередь есть, и подсказываем пакет.
load_modules()
{
	[ -e /proc/net/netfilter/nfnetlink_queue ] || modprobe nfnetlink_queue 2>/dev/null
	modprobe nft_queue 2>/dev/null
	[ -e /proc/net/netfilter/nfnetlink_queue ] || {
		echo "Warning: nfnetlink_queue не загружен — установите kmod-nft-queue"
		return 1
	}
	return 0
}

# --- то, чего на OpenWrt нет -------------------------------------------------
_z2k_scheduler_sync() { return 0; }
_z2k_disarm_stock_lighttpd() { return 0; }
