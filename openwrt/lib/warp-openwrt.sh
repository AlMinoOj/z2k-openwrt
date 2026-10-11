# warp-openwrt.sh — платформенный слой OpenWrt для files/z2k-warp.sh.
#
# Подключается одной строкой-хуком (`# OPENWRT:`) перед диспетчером
# z2k-warp.sh. Логика WARP апстрима (режимы «весь трафик / устройства /
# списки», загрузка списков, регистрация, самовосстановление) остаётся там;
# здесь — только то, что на OpenWrt устроено иначе:
#
#   * ipset   -> функция-замена с тем же интерфейсом поверх nft-сетов в
#                таблице inet z2k_warp (имена сетов те же: z2k_warp,
#                z2k_warp_src). Апстримные загрузка/подсчёт/статус работают
#                без правок;
#   * iptables-правила политики -> переводчик ow_warp_ipt2nft: апстримные
#                warp_policy_rules / warp_all_entries выдают правила в
#                синтаксисе iptables, мы переводим их в nft. Незнакомая форма
#                правила — отказ (тест test_warp_openwrt.sh ловит это при
#                синхронизации с апстримом);
#   * пары «клиент -> адрес» для маршрутизации по доменам — один сет
#                pairs { ipv4_addr . ipv4_addr } (его ведёт z2k-warpd);
#   * копия DNS-ответов демону — nft `log group 189` вместо NFLOG;
#   * разрешение форварда LAN -> туннель — include fw4 (chain-pre/forward),
#                маскарадинг и MSS ставит сам демон (таблица inet z2k_warpd);
#   * бинарник — модуль warp (наша сборка, openwrt/builds), не апстримная;
#   * службу зовут через переходник openwrt/bin/z2k-warp-init (z2k-warp.sh
#     вызывает её как `sh $WARP_INIT …`, а procd-скрипт так не работает).

[ -r /etc/openwrt_release ] || [ -n "${Z2K_OW_WARP_TEST:-}" ] || return 0

OW_WARP_TABLE=z2k_warp
OW_WARP_FW4_INCLUDE=/usr/share/nftables.d/chain-pre/forward/30-z2k-warp.nft
WARP_INIT=/opt/zapret2/openwrt/bin/z2k-warp-init
WARP_NDM_HOOK=/nonexistent   # хуков NDM нет; warp_forward_ensure переопределён ниже

_ow_nft() { nft "$@" 2>/dev/null; }

# --- таблица ------------------------------------------------------------------
ow_warp_table_ensure()
{
	nft -f - 2>/dev/null <<EOF
add table inet $OW_WARP_TABLE
add set inet $OW_WARP_TABLE $WARP_IPSET { type ipv4_addr; flags interval; auto-merge; }
add set inet $OW_WARP_TABLE $WARP_IPSET_SRC { type ipv4_addr; }
add set inet $OW_WARP_TABLE pairs { type ipv4_addr . ipv4_addr; flags timeout; size 65536; }
add chain inet $OW_WARP_TABLE warp_policy
add chain inet $OW_WARP_TABLE prerouting { type filter hook prerouting priority mangle; policy accept; }
add chain inet $OW_WARP_TABLE dnscap_out { type filter hook output priority filter; policy accept; }
add chain inet $OW_WARP_TABLE dnscap_fwd { type filter hook forward priority filter; policy accept; }
EOF
}

# --- ipset поверх nft-сетов -----------------------------------------------------
#
# Поддержано ровно то, что зовёт z2k-warp.sh: create, destroy, list [-n] [имя],
# save имя, restore -exist (строки «add <сет> <адрес> -exist»), swap a b.
_ow_set_exists() { _ow_nft list set inet $OW_WARP_TABLE "$1" >/dev/null; }
_ow_set_elems() { # <сет> -> элементы по одному в строке
	_ow_nft list set inet $OW_WARP_TABLE "$1" | awk '
		/elements = \{/ { f = 1; sub(/.*elements = \{/, "") }
		f { gsub(/[{}]/, ""); n = split($0, a, ","); for (i = 1; i <= n; i++) { gsub(/^[ \t]+|[ \t]+$/, "", a[i]); if (a[i] != "") print a[i] } }
		f && /\}/ { f = 0 }'
}
# stdin: «<сет> <элемент>» -> строки «add element inet z2k_warp <сет> { … }»
_ow_elems_script()
{
	awk -v t="$OW_WARP_TABLE" '
		function out() { if (n) print "add element inet " t " " cur " { " buf " }"; n = 0; buf = "" }
		{ if ($1 != cur) { out(); cur = $1 }
		  buf = (n ? buf ", " : "") $2; n++
		  if (n >= 500) out() }
		END { out() }'
}

ipset()
{
	local cmd="${1:-}"; shift 2>/dev/null
	ow_warp_table_ensure
	case "$cmd" in
		create)
			local name="$1" type="ipv4_addr; flags interval; auto-merge;"
			case " $* " in *" hash:ip "*) type="ipv4_addr;" ;; esac
			_ow_nft add set inet $OW_WARP_TABLE "$name" "{ type $type }" ;;
		destroy)
			case "$1" in
				"$WARP_IPSET"|"$WARP_IPSET_SRC") _ow_nft flush set inet $OW_WARP_TABLE "$1" ;;  # на них ссылаются правила
				*) _ow_nft delete set inet $OW_WARP_TABLE "$1" ;;
			esac
			return 0 ;;
		list)
			if [ "${1:-}" = -n ]; then
				[ -n "${2:-}" ] && { _ow_set_exists "$2" && echo "$2"; return; }
				return 0           # пер-клиентских сетов z2kd_* на OpenWrt нет
			fi
			_ow_set_exists "$1" || return 1
			echo "Name: $1"; echo "Members:"; _ow_set_elems "$1" ;;
		save)
			_ow_set_exists "$1" || return 1
			echo "create $1 hash:net family inet"
			_ow_set_elems "$1" | sed "s/^/add $1 /" ;;
		restore)
			# Строки «add <сет> <адрес> -exist» -> скрипт nft через stdin
			# (тысячи адресов в аргументе упёрлись бы в лимит длины), порциями
			# по 500 элементов, одной транзакцией.
			awk '$1 == "add" { print $2, $3 }' | _ow_elems_script | nft -f - 2>/dev/null ;;
		swap)
			# Сеты nft не меняются местами: живой сет заполняется содержимым
			# временного одной транзакцией (flush + add).
			local src="$1" dst="$2"
			{ echo "flush set inet $OW_WARP_TABLE $dst"
			  _ow_set_elems "$src" | sed "s/^/$dst /" | _ow_elems_script
			} | nft -f - 2>/dev/null ;;
		*) return 1 ;;
	esac
}

# --- перевод правил iptables -> nft ----------------------------------------------
#
# Только формы, которые выдают warp_policy_rules и warp_all_entries. Интерфейс
# с «+» (iptables) -> маска «*» (nft): br+ -> br* (на OpenWrt — br-lan, br-guest).
ow_warp_ipt2nft()
{
	local out="" tok mark
	set -- $1
	while [ $# -gt 0 ]; do
		tok="$1"; shift
		case "$tok" in
			-i|-o)
				local ifn="$1"; shift
				case "$ifn" in *+) ifn="${ifn%+}*" ;; esac
				[ "$tok" = -i ] && out="$out iifname \"$ifn\"" || out="$out oifname \"$ifn\"" ;;
			-s) out="$out ip saddr $1"; shift ;;
			-d) out="$out ip daddr $1"; shift ;;
			-m)
				case "$1" in
					set)
						[ "$2" = --match-set ] || return 1
						case "$4" in src) out="$out ip saddr @$3" ;; dst) out="$out ip daddr @$3" ;; *) return 1 ;; esac
						shift 4 ;;
					*) return 1 ;;
				esac ;;
			-j)
				case "$1" in
					RETURN) out="$out return"; shift ;;
					Z2K_WARP) out="$out jump warp_policy"; shift ;;
					MARK)
						[ "$2" = --set-xmark ] || return 1
						mark="${3%%/*}"
						[ "$mark" = "${3#*/}" ] || return 1      # xmark вида V/V — «установить биты»
						out="$out meta mark set meta mark | $mark"; shift 3 ;;
					*) return 1 ;;
				esac ;;
			*) return 1 ;;
		esac
	done
	echo "${out# }"
}

# --- политика и привязки PREROUTING -------------------------------------------------
warp_pbr_clear_output() { return 0; }      # реликты iptables Keenetic
warp_policy_legacy_clear() { return 0; }

warp_policy_chain()
{
	local rules rule nftr script
	ow_warp_table_ensure
	rules=$(warp_policy_rules) || { _ow_nft flush chain inet $OW_WARP_TABLE warp_policy; _wlog "cannot determine WDTT ingress interfaces"; return 1; }
	script="flush chain inet $OW_WARP_TABLE warp_policy"
	if [ -n "$rules" ]; then
		while IFS= read -r rule; do
			nftr=$(ow_warp_ipt2nft "$rule") || { _wlog "незнакомое правило WARP: $rule"; return 1; }
			script="$script
add rule inet $OW_WARP_TABLE warp_policy $nftr"
		done <<EOF
$rules
EOF
	fi
	printf '%s\n' "$script" | nft -f - 2>/dev/null
}

warp_policy_sync() (
	local lock waited=0 owner entry nftr script
	lock="$(dirname "$WARP_DOMAINS")/policy.lock"
	mkdir -p "$(dirname "$lock")" || exit 1
	while ! mkdir "$lock" 2>/dev/null; do
		owner=$(cat "$lock/pid" 2>/dev/null)
		if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null; continue; fi
		[ "$waited" -lt 5 ] || exit 1
		sleep 1; waited=$((waited + 1))
	done
	printf '%s\n' "$$" > "$lock/pid"
	trap 'rm -f "$lock/pid"; rmdir "$lock" 2>/dev/null' EXIT
	trap 'exit 1' HUP INT TERM

	ow_warp_table_ensure
	if ! warp_ipset_src_load; then
		_ow_nft flush chain inet $OW_WARP_TABLE warp_policy
		_wlog "cannot apply WARP device selection"
		exit 1
	fi
	if [ "$(warp_flag)" != 1 ]; then
		_ow_nft flush chain inet $OW_WARP_TABLE prerouting; exit 0
	fi
	warp_policy_chain || exit 1

	# Привязки — как в апстриме (warp_policy_sync), одной транзакцией.
	script="flush chain inet $OW_WARP_TABLE prerouting"
	if warp_full_device_mode; then
		script="$script
add rule inet $OW_WARP_TABLE prerouting ip saddr @$WARP_IPSET_SRC jump warp_policy"
	fi
	if warp_all_traffic_mode; then
		while IFS= read -r entry; do
			[ -n "$entry" ] || continue
			nftr=$(ow_warp_ipt2nft "$entry -j Z2K_WARP") || { _wlog "незнакомая привязка WARP: $entry"; exit 1; }
			script="$script
add rule inet $OW_WARP_TABLE prerouting $nftr"
		done <<EOF
$(warp_all_entries)
EOF
	fi
	script="$script
add rule inet $OW_WARP_TABLE prerouting ip daddr @$WARP_IPSET jump warp_policy
add rule inet $OW_WARP_TABLE prerouting ip saddr . ip daddr @pairs jump warp_policy"
	printf '%s\n' "$script" | nft -f - 2>/dev/null || exit 1
)

warp_pbr_down()
{
	_ow_nft flush chain inet $OW_WARP_TABLE prerouting
	_ow_nft flush chain inet $OW_WARP_TABLE warp_policy
	ip rule del fwmark "$WARP_MARK/$WARP_MARK" table "$WARP_TABLE" 2>/dev/null
	ip rule del fwmark "$WARP_MARK" table "$WARP_TABLE" 2>/dev/null
	ip route flush table "$WARP_TABLE" 2>/dev/null
	return 0
}

# Пер-клиентских сетов нет — пары в одном сете, чистим его.
warp_dns_client_sets() { return 0; }
warp_dns_sets_destroy() { _ow_nft flush set inet $OW_WARP_TABLE pairs; return 0; }

# --- копия DNS-ответов демону (log group 189) --------------------------------------
warp_dns_capture_outputs() { return 0; }
warp_dns_capture_up()
{
	local ifaces out script proto ifn
	ifaces=$(warp_wdtt_ifaces) || return 1
	ow_warp_table_ensure
	script="flush chain inet $OW_WARP_TABLE dnscap_out
flush chain inet $OW_WARP_TABLE dnscap_fwd"
	for out in br+ nwg+ $ifaces; do
		ifn="$out"; case "$ifn" in *+) ifn="${ifn%+}*" ;; esac
		for proto in udp tcp; do
			script="$script
add rule inet $OW_WARP_TABLE dnscap_out oifname \"$ifn\" $proto sport 53 log group 189 snaplen 4096
add rule inet $OW_WARP_TABLE dnscap_fwd oifname \"$ifn\" $proto sport 53 ct state established log group 189 snaplen 4096"
		done
	done
	printf '%s\n' "$script" | nft -f - 2>/dev/null
}
warp_dns_capture_down()
{
	_ow_nft flush chain inet $OW_WARP_TABLE dnscap_out
	_ow_nft flush chain inet $OW_WARP_TABLE dnscap_fwd
	return 0
}

# --- форвард LAN -> туннель: include fw4 ----------------------------------------------
warp_forward_ensure()
{
	[ -f "$OW_WARP_FW4_INCLUDE" ] || return 0
	nft list chain inet fw4 forward 2>/dev/null | grep -q 'z2k-warp' || fw4 -q reload
}

# --- бинарник — модуль warp (наша сборка под nftables) ---------------------------------
warp_fetch_engine()
{
	[ -n "${WARP_FETCH_STUB:-}" ] && { cp "$WARP_FETCH_STUB" "$WARP_BIN" && chmod 755 "$WARP_BIN"; return; }
	local L=/opt/zapret2/openwrt/lib ver
	. $L/platform.sh; . $L/channel.sh; . $L/engine.sh; . $L/modules.sh
	OW_ZD=/opt/zapret2
	ow_module_pkgs_install warp || { _wlog "не установились пакеты для WARP"; return 1; }
	if [ -x "$WARP_BIN" ] && "$WARP_BIN" version >/dev/null 2>&1; then
		_wlog "движок WARP уже установлен (модуль warp)"
	else
		ver=$(awk '$1 == "version" { print $2 }' /opt/zapret2/.z2k-installed 2>/dev/null)
		_wlog "ставлю движок WARP (модуль warp)..."
		ow_module_install warp "" /opt/zapret2/.z2k-manifest "$ver" || return 1
	fi
	ow_module_set warp 1
	"$WARP_BIN" version >/dev/null 2>&1 || { _wlog "движок не запускается на этой архитектуре"; return 1; }
	/etc/init.d/z2k-warp enable >/dev/null 2>&1
	[ -f "$OW_WARP_FW4_INCLUDE" ] && fw4 -q reload
	_wlog "движок установлен: $WARP_BIN"
}

# Жив ли демон — по процессу. `status` procd-службы отвечает 0 и на «active
# with no instances» (служба зарегистрирована, когда WARP был выключен), и
# z2k-warp.sh тогда не стал бы его запускать.
warp_daemon_running() { pidof z2k-warpd >/dev/null 2>&1; }

# Уборка прежнего usque с Keenetic — не нужна.
warp_migrate_usque() { return 0; }
