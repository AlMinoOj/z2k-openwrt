# diag-openwrt.sh — платформенный слой OpenWrt для диагностики z2k
# (files/z2k-diag.sh).
#
# Подключается хуком (`# OPENWRT:`) в z2k-diag.sh после объявления всех его
# функций, перед диспетчером. Разделы, вердикт «что не так», формат отчёта —
# апстримные; здесь только то, что на OpenWrt устроено иначе, иначе сводка
# врёт человеку прямо в первой строке:
#
#   * правила — nftables (таблицы zapret2, z2k_tg, z2k_warp, z2k_warpd и
#     include fw4), а не iptables/ipset: считаем их там, где они есть;
#   * /opt — каталог на корневой ФС, а не флешка Entware;
#   * компоненты Keenetic (bitmap:port, модули Netfilter, хук NDM) —
#     заменены проверками OpenWrt (kmod, fw4, flow offload, hotplug);
#   * закрепы Instagram — записи dnsmasq (функция ndmc из ndmc-dnsmasq.sh).
#
# Функции ipset/iptables/mount здесь — только для чтения и только для тех
# вопросов, что задаёт диагностика; наружу z2k-diag.sh ничего не меняет.

[ -r /etc/openwrt_release ] || [ -n "${Z2K_OW_DIAG_TEST:-}" ] || return 0

_OW_D_LIB="${ZAPRET2_DIR:-/opt/zapret2}/openwrt/lib"
[ -r "$_OW_D_LIB/ndmc-dnsmasq.sh" ] && . "$_OW_D_LIB/ndmc-dnsmasq.sh"

_ow_d_nft() { nft "$@" 2>/dev/null; }

# Элементы сета по одному в строке (интервалы — как есть, «a/b» или «a-b»).
_ow_d_set_elems() { # <таблица> <сет>
	_ow_d_nft list set inet "$1" "$2" | awk '
		/elements = \{/ { on = 1; sub(/.*elements = \{/, "") }
		on {
			end = sub(/\}.*/, "")
			n = split($0, a, ",")
			for (i = 1; i <= n; i++) { gsub(/^[ \t]+|[ \t]+$/, "", a[i]); if (a[i] != "") print a[i] }
			if (end) on = 0
		}'
}

# Правила цепочек таблицы: «<цепочка>\t<правило>».
_ow_d_rules() { # <таблица>
	_ow_d_nft list table inet "$1" | awk '
		/^[ \t]*chain [^ ]+ \{/ { c = $2; next }
		/^[ \t]*\}/ { c = ""; next }
		c != "" && !/^[ \t]*type / && NF { sub(/^[ \t]+/, ""); print c "\t" $0 }'
}

# --- то, что диагностика спрашивает у Keenetic ------------------------------------

ipset() {
	[ "${1:-}" = list ] || return 1
	shift
	[ "${1:-}" = -n ] && shift
	local t
	for t in z2k_tg z2k_warp zapret2; do
		_ow_d_nft list set inet "$t" "${1:-}" >/dev/null || continue
		printf 'Name: %s\nMembers:\n' "$1"
		_ow_d_set_elems "$t" "$1"
		return 0
	done
	return 1
}

# Только вопросы раздела WARP (метка, NAT, форвард) — в форме `iptables -S`,
# чтобы счёт апстрима (`grep -c`) остался прежним.
iptables() {
	case "$*" in
		*"-t mangle -S PREROUTING"*)
			_ow_d_rules z2k_warp | awk -F'\t' '$1 == "prerouting" && /jump warp_policy/ { print "-A PREROUTING -j z2k_warp" }' ;;
		*"-t nat -S POSTROUTING"*)
			_ow_d_rules z2k_warpd | awk -F'\t' '/masquerade/ { print "-A POSTROUTING " $2 }' ;;
		*"-t filter -S FORWARD"*)
			local ifs
			ifs=$(ls /sys/class/net 2>/dev/null | grep '^z2ktun' | tr '\n' ' ')
			_ow_d_rules fw4 | awk -F'\t' -v ifs="$ifs" '$1 == "forward" && /z2k-warp/ { r = $2; gsub(/z2ktun\*/, ifs, r); print "-A FORWARD " r }' ;;
		*) return 1 ;;
	esac
}
ip6tables() { return 1; }

# /opt на OpenWrt — каталог на корневой ФС (overlay), не отдельный раздел:
# «/opt не смонтирован» здесь — ложная тревога.
mount() {
	if [ $# -gt 0 ]; then command mount "$@"; return; fi
	command mount
	command mount | grep -q ' /opt ' || [ ! -d /opt/zapret2 ] ||
		echo "rootfs on /opt type dir (OpenWrt: каталог на корневой ФС)"
}

# bitmap:port — тип ipset; правила z2k на nft его не используют.
bitmap_port_ok() { printf 'n/a'; }

get_entware_arch() {
	local a
	a=$(sed -n "s/^DISTRIB_ARCH='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null)
	printf '%s (пакеты OpenWrt)' "${a:-$(uname -m 2>/dev/null)}"
}

# --- очередь nfqws2 ------------------------------------------------------------------

# Правила очереди в таблице zapret2: «<исходящих> <входящих>».
_ow_d_queue_rules() {
	local q="${QNUM:-200}"
	_ow_d_rules zapret2 | awk -F'\t' -v q="$q" '
		$2 ~ ("queue .*to " q "([^0-9]|$)") {
			if ($1 ~ /^post/) o++
			else if ($1 ~ /^pre/) i++
		}
		END { print o + 0, i + 0 }'
}

# Ответ в шкале апстрима, чтобы его пороги в вердикте остались верными:
# исходящих «2» = очередь и для tcp, и для udp; входящих «4» = то же для
# input и forward (на nft одна цепочка prerouting покрывает обе).
nfqueue_counts() {
	local q="${QNUM:-200}" rules ok=1
	case "$q" in ''|*[!0-9]*) q=200 ;; esac
	# Нет таблицы — это ноль правил (поломка), а не «не прочитать».
	command -v nft >/dev/null 2>&1 || ok=0
	rules=$(_ow_d_rules zapret2)
	printf '%s\n' "$rules" | awk -F'\t' -v q="$q" -v ok="$ok" '
		$2 ~ ("queue .*to " q "([^0-9]|$)") {
			p = ($2 ~ /udp/) ? "udp" : "tcp"
			if ($1 ~ /^post/) out[p] = 1
			else if ($1 ~ /^pre/) inn[p] = 1
		}
		END {
			o = 0; i = 0
			for (p in out) o++
			for (p in inn) i += 2
			print o, i, ok
		}'
}

nfqws_first_packets_state() {
	local c
	c=$(_ow_d_rules zapret2 | grep 'queue' | grep -oE 'ct original packets [0-9]+-' | head -1)
	[ -n "$c" ] || return 1
	case "$c" in *" 0-") printf '0' ;; *) printf '1' ;; esac
}

# --- телеграм ------------------------------------------------------------------------

tg_redirect_counts() {
	_ow_d_rules z2k_tg | awk -F'\t' '
		/redirect to :1443/ { if ($1 == "prerouting") p++; else if ($1 == "output") o++ }
		END { print p + 0, o + 0 }'
}

# --- раздел правил ---------------------------------------------------------------------

print_iptables() {
	printf '\n=== nftables ===\n'
	local qr qo qi tg tgp tgo tg4 tg6 r6f r6o nz nz6 _tg_exp
	qr=$(_ow_d_queue_rules); qo=${qr% *}; qi=${qr#* }
	if _ow_d_nft list table inet zapret2 >/dev/null; then
		printf 'table zapret2     : есть\n'
	else
		printf 'table zapret2     : НЕТ — правил обхода нет, трафик идёт мимо nfqws2\n'
	fi
	printf 'NFQUEUE исходящие : %s  (postnat/postrouting: tcp+udp, ipv4+ipv6)\n' "$qo"
	printf 'NFQUEUE входящие  : %s  (prenat/prerouting — без них не работает автоподбор стратегий)\n' "$qi"
	nz=$(_ow_d_set_elems zapret2 nozapret | grep -c . || true)
	nz6=$(_ow_d_set_elems zapret2 nozapret6 | grep -c . || true)
	printf 'nozapret          : %s адресов, v6: %s  (мимо обхода)\n' "${nz:-0}" "${nz6:-0}"

	tg=$(tg_redirect_counts); tgp=${tg% *}; tgo=${tg#* }
	if tg_user_disabled; then
		_tg_exp='туннель выключен вручную — правил и не должно быть'
	else
		_tg_exp='ожидается 1'
	fi
	printf 'TG REDIR PREROUT  : %s  (%s)\n' "$tgp" "$_tg_exp"
	printf 'TG REDIR OUTPUT   : %s  (%s)\n' "$tgo" "$_tg_exp"
	tg4=$(_ow_d_set_elems z2k_tg z2k_tg_dc | grep -c . || true)
	tg6=$(_ow_d_set_elems z2k_tg z2k_tg_dc6 | grep -c . || true)
	printf 'TG set z2k_tg_dc  : %s DC subnets (expected 10)\n' "${tg4:-0}"
	printf 'TG set z2k_tg_dc6 : %s DC subnets (expected 4)\n' "${tg6:-0}"
	r6f=$(_ow_d_rules z2k_tg | awk -F'\t' '$1 == "forward6" && /reject/' | grep -c . || true)
	r6o=$(_ow_d_rules z2k_tg | awk -F'\t' '$1 == "output6" && /reject/' | grep -c . || true)
	printf 'TG v6 REJECT FWD  : %s  (expected 1 — fast-reject dead v6 DCs)\n' "${r6f:-0}"
	printf 'TG v6 REJECT OUT  : %s  (expected 1)\n' "${r6o:-0}"

	# Счётчиков в правилах nft нет; сколько пакетов ушло в userspace, видно по
	# самой очереди: id_sequence — всего пакетов, dropped — потери.
	local qs
	qs=$(awk -v q="${QNUM:-200}" '$1 == q { printf "пакетов всего %s, потеряно ядром %s, потеряно демоном %s", $8, $6, $7 }' \
		/proc/net/netfilter/nfnetlink_queue 2>/dev/null)
	printf 'очередь %-9s : %s\n' "${QNUM:-200}" "${qs:-не открыта (nfqws2 не слушает)}"

	if [ -e /etc/hotplug.d/iface/90-z2k ]; then
		printf 'hotplug iface     : installed\n'
	else
		printf 'hotplug iface     : NOT installed (правила не обновятся при смене WAN)\n'
	fi
}

# --- платформа -----------------------------------------------------------------------

_ow_d_mod() { [ -d "/sys/module/$1" ] && echo да || echo НЕТ; }

print_platform() {
	printf '\n=== platform ===\n'
	local rel rev fw fo hw
	rel=$(sed -n "s/^DISTRIB_RELEASE='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null)
	rev=$(sed -n "s/^DISTRIB_REVISION='\(.*\)'/\1/p" /etc/openwrt_release 2>/dev/null)
	fw=$([ -x /sbin/fw4 ] && echo fw4 || echo 'НЕТ fw4')
	printf 'openwrt           : %s %s, %s, пакеты: %s\n' "${rel:-?}" "${rev:-}" "$fw" \
		"$(command -v apk >/dev/null 2>&1 && echo apk || echo opkg)"

	if command -v df >/dev/null 2>&1; then
		printf 'opt space         : %s\n' \
			"$(df -h /opt 2>/dev/null | awk 'NR==2 {printf "%s свободно из %s (занято %s, %s)", $4, $2, $5, $1}')"
	fi
	if [ -r /proc/meminfo ]; then
		printf 'memory            : %s\n' \
			"$(awk '/^MemAvailable:/{a=$2} /^MemTotal:/{t=$2} /^SwapFree:/{sf=$2} /^SwapTotal:/{st=$2}
				END {printf "%d МБ свободно из %d, swap %d/%d МБ", a/1024, t/1024, (st-sf)/1024, st/1024}' /proc/meminfo 2>/dev/null)"
	fi
	if [ -r /proc/loadavg ]; then
		printf 'loadavg           : %s (ядер: %s)\n' \
			"$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)" \
			"$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo '?')"
	fi

	# Без очереди в ядре nfqws2 не стартует: «nfq_create_queue» в логе демона.
	printf 'kmods             : nft_queue=%s nfnetlink_queue=%s nft_nat=%s\n' \
		"$(_ow_d_mod nft_queue)" "$(_ow_d_mod nfnetlink_queue)" "$(_ow_d_mod nft_nat)"

	# Offload fw4 уводит поток в fastpath после рукопожатия — движок держит свою
	# flowtable с исключениями; здесь — что включено в fw4.
	fo=$(uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null)
	hw=$(uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null)
	printf 'flow offload fw4  : software=%s hardware=%s\n' "${fo:-0}" "${hw:-0}"

	local inc=/usr/share/nftables.d/chain-pre/forward/30-z2k-warp.nft
	[ -e "$inc" ] && printf 'fw4 include       : %s\n' "$inc"
}
