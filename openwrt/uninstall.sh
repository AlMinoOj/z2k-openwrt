#!/bin/sh
# z2k-openwrt — удаление. Снимает службу и правила, удаляет файлы z2k.
# Пакеты (curl, kmod-nft-queue …) не удаляются: ими могут пользоваться другие.
# Offload fw4, выключенный установщиком, не включается обратно сам — команда
# для этого печатается в конце.

set -u
[ "$(id -u)" = 0 ] || { echo "нужен root" >&2; exit 1; }

say() { echo "[z2k] $*"; }

if [ -x /etc/init.d/z2k ]; then
	/etc/init.d/z2k stop >/dev/null 2>&1
	/etc/init.d/z2k disable >/dev/null 2>&1
fi
nft delete table inet zapret2 2>/dev/null
[ -f /opt/zapret2/openwrt/bin/z2k-cron ] && sh /opt/zapret2/openwrt/bin/z2k-cron remove >/dev/null 2>&1
rm -f /usr/bin/z2k-update /usr/bin/z2k-module
for s in z2k-tg z2k-rtproxy z2k-warp; do
	[ -x /etc/init.d/$s ] && { /etc/init.d/$s stop >/dev/null 2>&1; /etc/init.d/$s disable >/dev/null 2>&1; }
	rm -f /etc/init.d/$s
done
for t in z2k_tg z2k_rtproxy z2k_warp; do nft delete table inet $t 2>/dev/null; done
rm -f /opt/sbin/tg-mtproxy-client /opt/sbin/z2k-rt-proxy /opt/sbin/z2k-detect /opt/sbin/z2k-warpd
rmdir /opt/sbin 2>/dev/null

rm -f /etc/init.d/z2k /etc/hotplug.d/iface/90-z2k
for l in S99zapret2 S98tg-tunnel S96z2k-rt-proxy S51z2k-warp; do [ -L /opt/etc/init.d/$l ] && rm -f /opt/etc/init.d/$l; done
rmdir /opt/etc/init.d 2>/dev/null
rm -rf /opt/zapret2 /opt/etc/zapret2 /tmp/z2k-work /tmp/z2k-traffic-debug
rmdir /opt/etc /opt 2>/dev/null

say "z2k удалён"
say "если до установки был включён flow offloading fw4, верните его:"
say "  uci set firewall.@defaults[0].flow_offloading=1 && uci commit firewall && fw4 reload"
