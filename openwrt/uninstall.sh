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
rm -f /usr/bin/z2k-update

rm -f /etc/init.d/z2k /etc/hotplug.d/iface/90-z2k
[ -L /opt/etc/init.d/S99zapret2 ] && rm -f /opt/etc/init.d/S99zapret2
rmdir /opt/etc/init.d 2>/dev/null
rm -rf /opt/zapret2 /opt/etc/zapret2 /tmp/z2k-work /tmp/z2k-traffic-debug
rmdir /opt/etc /opt 2>/dev/null

say "z2k удалён"
say "если до установки был включён flow offloading fw4, верните его:"
say "  uci set firewall.@defaults[0].flow_offloading=1 && uci commit firewall && fw4 reload"
