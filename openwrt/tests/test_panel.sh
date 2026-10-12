#!/bin/sh
# Слой вебпанели (openwrt/lib/panel-openwrt.sh): устройства для WARP из
# соседей LAN и аренд DHCP в формате апстрима; исключения — команды nft.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
fail=0; n=0
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL: $1: ждали '$2', получили '$3'"; }; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

export ZAPRET2_DIR="$T" Z2K_OW_PANEL_TEST=1 OW_DHCP_LEASES="$T/leases" WARP_LISTS_DIR="$T"
ip() { cat <<'N'
192.168.1.10 dev br-lan lladdr AA:BB:CC:00:00:10 REACHABLE
192.168.1.11 dev br-lan lladdr aa:bb:cc:00:00:11 STALE
10.0.2.2 dev eth1 lladdr 52:55:0a:00:02:02 REACHABLE
192.168.1.12 dev br-lan  FAILED
N
}
printf '1791000000 aa:bb:cc:00:00:11 192.168.1.11 phone *\n1791000000 aa:bb:cc:00:00:20 192.168.1.20 tv *\n' > "$T/leases"
echo "aa-bb-cc-00-00-11" > "$T/devices.txt"
NFTLOG="$T/nft"; nft() { echo "$*" >> "$NFTLOG"; }
. "$ROOT/openwrt/lib/panel-openwrt.sh"

out=$(warp_neighbors | tr '\037' '|')
eq "устройства: первым активное" "aa:bb:cc:00:00:10|192.168.1.10|aa:bb:cc:00:00:10|br-lan|1|0" "$(printf '%s\n' "$out" | head -n 1)"
eq "устройства: имя из аренды, выбрано" "aa:bb:cc:00:00:11|192.168.1.11|phone|br-lan|0|1" "$(printf '%s\n' "$out" | grep ':11|')"
eq "устройства: только аренда" "aa:bb:cc:00:00:20|192.168.1.20|tv||0|0" "$(printf '%s\n' "$out" | grep ':20|')"
eq "устройства: WAN не попадает" "" "$(printf '%s\n' "$out" | grep eth1)"
eq "устройства: FAILED не попадает" "3" "$(printf '%s\n' "$out" | grep -c .)"

_exclude_ipset_apply add 203.0.113.7; _exclude_ipset_apply del 2001:db8::1
eq "исключение v4" "add element inet zapret2 nozapret { 203.0.113.7 }" "$(sed -n 1p "$NFTLOG")"
eq "исключение v6" "delete element inet zapret2 nozapret6 { 2001:db8::1 }" "$(sed -n 2p "$NFTLOG")"

eq "challenge: realm rpcd" "rpcd" "$(_panel_random_hex() { echo x; }; panel_ndm_challenge | cut -f1)"

echo "test_panel: $((n - fail))/$n"
[ "$fail" -eq 0 ]
