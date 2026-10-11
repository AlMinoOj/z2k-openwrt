#!/bin/sh
# tg-redirect.sh — перехват Telegram для туннеля z2k на nftables.
#
# Ставится на роутер вместо апстримного files/z2k-tg-redirect.sh (тот —
# iptables + ipset) под тем же именем /opt/zapret2/z2k-tg-redirect.sh и с теми
# же функциями: их зовут сторож туннеля (tg-tunnel-watchdog.sh), панель и
# диагностика z2k, и менять их не нужно.
#
# Всё в своей таблице inet z2k_tg — fw4 reload её не трогает, снимается
# одной командой:
#   * TCP:443 к дата-центрам Telegram (IPv4)  -> redirect :1443 (туннель);
#   * HTTP к CDN Telegram (168.119.95.238)    -> redirect :1444 (тот же процесс);
#   * TCP к IPv6 дата-центрам                 -> reset: клиент сразу уходит на
#     IPv4, где его ловит туннель (иначе ждёт таймаут IPv6).
# Перехват и из LAN (prerouting), и с самого роутера (output).
# UDP-маршрутизация Telegram в апстриме выведена из работы — здесь её нет.

Z2K_TG_TABLE=z2k_tg
Z2K_TG_SET="z2k_tg_dc"
Z2K_TG_PORT=1443
Z2K_TG_CDN_PORT=1444
Z2K_TG_CIDRS="149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 185.76.151.0/24"
Z2K_TG_SET6="z2k_tg_dc6"
Z2K_TG_CIDRS6="2001:67c:4e8::/48 2001:b28:f23c::/47 2001:b28:f23f::/48 2a0a:f280:203::/48"
Z2K_TG_CDN_CIDRS="168.119.95.238/32"

_z2k_tg_list() { echo "$*" | sed 's/ \{1,\}/, /g'; }

# Таблица целиком, одной транзакцией: создать (если нет) -> удалить -> собрать.
z2k_tg_ensure_rules()
{
	nft -f - <<EOF
table inet $Z2K_TG_TABLE
delete table inet $Z2K_TG_TABLE
table inet $Z2K_TG_TABLE {
	set $Z2K_TG_SET { type ipv4_addr; flags interval; elements = { $(_z2k_tg_list $Z2K_TG_CIDRS) } }
	set ${Z2K_TG_SET}_cdn { type ipv4_addr; flags interval; elements = { $(_z2k_tg_list $Z2K_TG_CDN_CIDRS) } }
	set $Z2K_TG_SET6 { type ipv6_addr; flags interval; elements = { $(_z2k_tg_list $Z2K_TG_CIDRS6) } }

	chain prerouting {
		type nat hook prerouting priority dstnat - 5; policy accept;
		ip daddr @$Z2K_TG_SET tcp dport 443 redirect to :$Z2K_TG_PORT comment "z2k: telegram -> tunnel"
		ip daddr @${Z2K_TG_SET}_cdn tcp dport 80 redirect to :$Z2K_TG_CDN_PORT comment "z2k: telegram cdn -> tunnel"
	}
	chain output {
		type nat hook output priority -105; policy accept;
		ip daddr @$Z2K_TG_SET tcp dport 443 redirect to :$Z2K_TG_PORT
		ip daddr @${Z2K_TG_SET}_cdn tcp dport 80 redirect to :$Z2K_TG_CDN_PORT
	}
	chain forward6 {
		type filter hook forward priority filter - 5; policy accept;
		ip6 daddr @$Z2K_TG_SET6 meta l4proto tcp reject with tcp reset comment "z2k: telegram ipv6 -> ipv4"
	}
	chain output6 {
		type filter hook output priority filter - 5; policy accept;
		ip6 daddr @$Z2K_TG_SET6 meta l4proto tcp reject with tcp reset
	}
}
EOF
}

z2k_tg_remove_rules() { nft delete table inet "$Z2K_TG_TABLE" 2>/dev/null; return 0; }

# Сторож z2k спрашивает про цепочки iptables PREROUTING/OUTPUT — отвечаем по
# своим цепочкам: правило перехвата на месте?
z2k_tg_rule_present()
{
	local chain
	case "$1" in PREROUTING) chain=prerouting ;; OUTPUT) chain=output ;; *) chain="$1" ;; esac
	nft list chain inet "$Z2K_TG_TABLE" "$chain" 2>/dev/null | grep -q "redirect to :$Z2K_TG_PORT"
}

# Совместимость с апстримом: эти слои на nft не нужны или собраны в таблицу.
z2k_tg_ensure_ipset() { return 0; }
z2k_tg_ensure_ipset6() { return 0; }
z2k_tg_ensure_rules6() { return 0; }
z2k_tg_remove_rules6() { return 0; }
z2k_tg_remove_legacy_rules() { return 0; }
z2k_tg_remove_retired_tcp_rules() { return 0; }
z2k_tg_udp_down() { return 0; }
z2k_tg_udp_ensure() { return 0; }
z2k_tg_udp_enabled() { return 1; }

# Разорвать уже установленные соединения к Telegram, чтобы клиенты сразу
# переподключились через туннель. conntrack — необязательный пакет OpenWrt.
z2k_tg_flush_conntrack()
{
	command -v conntrack >/dev/null 2>&1 || return 0
	local c
	for c in $Z2K_TG_CIDRS $Z2K_TG_CDN_CIDRS; do
		conntrack -D -d "$c" >/dev/null 2>&1 || true
	done
}
