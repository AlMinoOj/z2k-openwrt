#!/bin/sh
# Слой WARP (openwrt/lib/warp-openwrt.sh) поверх настоящего files/z2k-warp.sh:
#   * каждое правило, которое апстримный генератор выдаёт в режимах «весь
#     трафик / устройства / списки», переводится в nft (новая форма правила
#     у апстрима — падение здесь, при синхронизации);
#   * замена ipset собирает корректные скрипты nft (порции, swap).
# nft — заглушка-функция: пишет скрипты в журнал.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
fail=0; n=0
eq()  { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL: $1: ждали '$2', получили '$3'"; }; }
has() { n=$((n + 1)); printf '%s\n' "$3" | grep -qF -- "$2" || { fail=$((fail + 1)); echo "FAIL: $1: нет «$2» в:"; printf '%s\n' "$3" | sed 's/^/    /'; }; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ZD="$T/zd"; mkdir -p "$ZD/openwrt/lib" "$ZD/lists/warp" "$T/tmp"
cp "$ROOT/openwrt/lib/warp-openwrt.sh" "$ZD/openwrt/lib/"
cp "$ROOT/files/z2k-warp-list-filter.awk" "$ZD/"
echo "GAME_WARP_ENABLED=1" > "$ZD/config"

export ZAPRET2_DIR="$ZD" Z2K_OW_WARP_TEST=1 Z2K_WARP_SOURCE_ONLY=1 \
	WARP_DOMAINS="$T/tmp/domains.v1" WARP_AWGM_DIR="$T/nonexistent" WARP_BIN=/bin/false
NFTLOG="$T/nft.log"; : > "$NFTLOG"
nft() { if [ "$1" = -f ]; then cat >> "$NFTLOG"; else echo "$*" >> "$NFTLOG"; fi; return 0; }
. "$ROOT/files/z2k-warp.sh"
set +u   # z2k-warp.sh написан без set -u (warp_all_entries читает необязательный $1)

translate_all() { # правила апстрима -> nft; печатает перевод, код 1 при незнакомом
	local r out rc=0
	while IFS= read -r r; do
		[ -n "$r" ] || continue
		out=$(ow_warp_ipt2nft "$r") || { echo "НЕЗНАКОМО: $r"; rc=1; continue; }
		echo "$out"
	done
	return $rc
}

# --- режим «весь трафик»: ни устройств, ни списков ---
rules=$(warp_policy_rules); tr=$(printf '%s\n' "$rules" | translate_all); eq "весь трафик: всё переводится" 0 $?
has "весь трафик: локальные мимо" "ip daddr 192.168.0.0/16 return" "$tr"
has "весь трафик: wdtt мимо" 'iifname "wdtt0" return' "$tr"
has "весь трафик: метка" "meta mark set meta mark | 0x989" "$tr"
ent=$(warp_all_entries | sed 's/$/ -j Z2K_WARP/' | translate_all); eq "привязки: всё переводится" 0 $?
has "привязка LAN" 'iifname "br*" jump warp_policy' "$ent"
has "привязка nwg с подсетью" 'iifname "nwg*" ip saddr 10.0.0.0/8 jump warp_policy' "$ent"

# --- режим «устройства» ---
echo "192.168.1.10" > "$ZD/lists/warp/devices.txt"
tr=$(warp_policy_rules | translate_all); eq "устройства: всё переводится" 0 $?
has "устройства: по сету источников" "ip saddr @z2k_warp_src meta mark set meta mark | 0x989" "$tr"

# --- режим «списки»: домены + устройства ---
printf 'example.org\n1.2.3.0/24\n' > "$ZD/lists/warp/my.txt"
printf 'v1\nexample.org\n' > "$WARP_DOMAINS"
tr=$(warp_policy_rules | translate_all); eq "списки: всё переводится" 0 $?
has "списки: nwg" 'iifname "nwg*" ip saddr 172.16.0.0/12 meta mark set meta mark | 0x989' "$tr"
has "списки: устройства" "ip saddr @z2k_warp_src meta mark set meta mark | 0x989" "$tr"

# --- незнакомая форма -> отказ ---
ow_warp_ipt2nft "-p tcp --dport 443 -j ACCEPT" >/dev/null; eq "незнакомое правило -> отказ" 1 $?
ow_warp_ipt2nft "-j MARK --set-xmark 0x1/0xff" >/dev/null; eq "xmark с чужой маской -> отказ" 1 $?

# --- замена ipset: restore порциями, swap ---
: > "$NFTLOG"
i=0; while [ $i -lt 1203 ]; do echo "add z2k_warp_new 10.$((i / 250)).$((i % 250)).0/24 -exist"; i=$((i + 1)); done | ipset restore -exist
eq "restore: 3 порции по ≤500" 3 "$(grep -c '^add element inet z2k_warp z2k_warp_new {' "$NFTLOG")"
eq "restore: все элементы" 1203 "$(grep '^add element' "$NFTLOG" | tr ',' '\n' | grep -c '/24')"

# --- политика собирается одной транзакцией ---
: > "$NFTLOG"
warp_policy_chain; eq "policy_chain код" 0 $?
has "policy: flush перед правилами" "flush chain inet z2k_warp warp_policy" "$(cat "$NFTLOG")"
has "policy: правило в nft" "add rule inet z2k_warp warp_policy ip saddr @z2k_warp_src meta mark set meta mark | 0x989" "$(cat "$NFTLOG")"

# --- копия DNS: log group 189, LAN как br* ---
: > "$NFTLOG"
warp_dns_capture_up
has "dns: output" 'add rule inet z2k_warp dnscap_out oifname "br*" udp sport 53 log group 189 snaplen 4096' "$(cat "$NFTLOG")"
has "dns: forward established" 'dnscap_fwd oifname "br*" tcp sport 53 ct state established log group 189' "$(cat "$NFTLOG")"

echo "test_warp_openwrt: $((n - fail))/$n"
[ "$fail" -eq 0 ]
