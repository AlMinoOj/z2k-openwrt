#!/bin/sh
# Слой диагностики (openwrt/lib/diag-openwrt.sh): счёт правил nft в шкале
# апстрима, сеты вместо ipset, вопросы iptables раздела WARP.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
fail=0; n=0
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL: $1: ждали '$2', получили '$3'"; }; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

export ZAPRET2_DIR="$T" Z2K_OW_DIAG_TEST=1
V6=1   # 0 — в таблице zapret2 только ipv4 tcp
nft() {
	case "$*" in
	"list table inet zapret2")
		cat <<'N'
table inet zapret2 {
	set nozapret {
		type ipv4_addr
		flags interval
		elements = { 10.0.0.0/8, 192.168.0.0/16,
			     203.0.113.7 }
	}
	chain postnat {
		type filter hook postrouting priority srcnat + 1; policy accept;
		meta nfproto ipv4 tcp dport { 80, 443 } ct original packets 0-20 meta mark set meta mark | 0x20000000 queue flags bypass to 200
N
		[ "$V6" = 1 ] && cat <<'N'
		meta nfproto ipv6 tcp dport { 80, 443 } ct original packets 0-20 meta mark set meta mark | 0x20000000 queue flags bypass to 200
		meta nfproto ipv4 udp dport { 443 } ct original packets 0-8 meta mark set meta mark | 0x20000000 queue flags bypass to 200
		meta nfproto ipv6 udp dport { 443 } ct original packets 0-8 meta mark set meta mark | 0x20000000 queue flags bypass to 200
N
		cat <<'N'
	}
	chain prenat {
		type filter hook prerouting priority dstnat - 1; policy accept;
		meta nfproto ipv4 tcp sport { 80, 443 } ct reply packets 0-10 queue flags bypass to 200
N
		[ "$V6" = 1 ] && cat <<'N'
		meta nfproto ipv4 udp sport { 443 } ct reply packets 0-8 queue flags bypass to 200
		meta nfproto ipv4 tcp sport { 80, 443 } ct reply packets 0-10 queue flags bypass to 2001
N
		printf '\t}\n}\n' ;;
	"list set inet zapret2 nozapret")
		nft list table inet zapret2 | sed -n '/set nozapret {/,/^	}/p' ;;
	"list table inet z2k_tg")
		cat <<'N'
table inet z2k_tg {
	chain prerouting {
		type nat hook prerouting priority dstnat - 5; policy accept;
		ip daddr @z2k_tg_dc tcp dport 443 redirect to :1443 comment "z2k: telegram -> tunnel"
		ip daddr @z2k_tg_dc_cdn tcp dport 80 redirect to :1444 comment "z2k: telegram cdn -> tunnel"
	}
	chain output {
		type nat hook output priority -105; policy accept;
		ip daddr @z2k_tg_dc tcp dport 443 redirect to :1443
	}
	chain forward6 {
		type filter hook forward priority filter - 5; policy accept;
		ip6 daddr @z2k_tg_dc6 meta l4proto tcp reject with tcp reset comment "z2k: telegram ipv6 -> ipv4"
	}
}
N
		;;
	"list set inet z2k_tg z2k_tg_dc")
		printf '%s\n' 'table inet z2k_tg {' '	set z2k_tg_dc {' '		type ipv4_addr' '		flags interval' \
			'		elements = { 91.105.192.0/23, 91.108.4.0/22,' '			     149.154.160.0/20 }' '	}' '}' ;;
	"list table inet z2k_warp")
		printf '%s\n' 'table inet z2k_warp {' '	chain prerouting {' '		type filter hook prerouting priority mangle; policy accept;' \
			'		iifname "br-lan" jump warp_policy' '	}' '}' ;;
	"list table inet z2k_warpd")
		printf '%s\n' 'table inet z2k_warpd {' '	chain post {' '		type nat hook postrouting priority srcnat; policy accept;' \
			'		oifname "z2ktun0" masquerade' '	}' '}' ;;
	"list table inet fw4")
		printf '%s\n' 'table inet fw4 {' '	chain forward {' '		type filter hook forward priority filter; policy drop;' \
			'		oifname "z2ktun*" meta mark & 0x00000989 == 0x00000989 accept comment "z2k-warp: lan -> warp"' \
			'		iifname "z2ktun*" ct state established,related accept comment "z2k-warp: warp -> lan"' \
			'		jump handle_reject' '	}' '}' ;;
	*) return 1 ;;
	esac
}
. "$ROOT/openwrt/lib/diag-openwrt.sh"

eq "очередь: шкала апстрима (tcp+udp, input+forward)" "2 4 1" "$(nfqueue_counts)"
eq "очередь: настоящие правила" "4 2" "$(_ow_d_queue_rules)"
V6=0
eq "очередь: только tcp" "1 2 1" "$(nfqueue_counts)"
V6=1
eq "connbytes 0:N" "0" "$(nfqws_first_packets_state)"
eq "редирект телеграма" "1 1" "$(tg_redirect_counts)"

eq "ipset list: сет nft" "3" "$(ipset list z2k_tg_dc | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')"
eq "ipset list: Members" "Members:" "$(ipset list z2k_tg_dc | sed -n 2p)"
eq "ipset list: нет сета" "1" "$(ipset list nope >/dev/null; echo $?)"
eq "ipset: прочее не поддержано" "1" "$(ipset create x bitmap:port; echo $?)"
eq "nozapret: элементы" "10.0.0.0/8 192.168.0.0/16 203.0.113.7" "$(_ow_d_set_elems zapret2 nozapret | tr '\n' ' ' | sed 's/ $//')"

eq "warp: метка" "1" "$(iptables -w -t mangle -S PREROUTING | grep -c z2k_warp)"
eq "warp: nat" "1" "$(iptables -w -t nat -S POSTROUTING | grep -c z2ktun0)"
eq "warp: прочее iptables" "1" "$(iptables -t mangle -vnL >/dev/null; echo $?)"
eq "bitmap:port не нужен" "n/a" "$(bitmap_port_ok)"

tg_user_disabled() { return 1; }
QNUM=200
out=$(print_iptables)
eq "раздел: заголовок" "=== nftables ===" "$(printf '%s\n' "$out" | sed -n 2p)"
eq "раздел: TG set" "TG set z2k_tg_dc  : 3 DC subnets (expected 10)" "$(printf '%s\n' "$out" | grep 'TG set z2k_tg_dc ')"
eq "раздел: v6 reject" "TG v6 REJECT FWD  : 1  (expected 1 — fast-reject dead v6 DCs)" "$(printf '%s\n' "$out" | grep 'REJECT FWD')"

echo "test_diag: $((n - fail))/$n"
[ "$fail" -eq 0 ]
