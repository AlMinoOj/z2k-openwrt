#!/bin/sh
# build-manifest.sh — собрать манифест релиза (формат: openwrt/lib/manifest.sh).
#
#   build-manifest.sh <корень> <версия> <seq> <upstream_base> <reset 0|1> <описание> [прежний манифест]
#
# Пути файлов — на stdin (относительно корня, по одному в строке); в манифест
# попадают те, у кого есть цель в openwrt/lib/layout.sh. История берётся из
# прежнего манифеста, новая запись — сверху. Пишет в stdout.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../lib/manifest.sh"
. "$HERE/../lib/layout.sh"
. "$HERE/../lib/channel.sh"

[ $# -ge 6 ] || { sed -n '2,9p' "$0" >&2; exit 2; }
root="$1" ver="$2" seq="$3" up="$4" reset="$5" desc="$6" prev="${7:-}"
date="${Z2K_OW_RELEASE_DATE:-$(date -u +%Y-%m-%d)}"
TAB=$(printf '\t')

mode_of() {
	case "$1" in
		/etc/init.d/*|/etc/hotplug.d/*|*/init.d/z2k-engine|*.sh|*/openwrt/bin/*) echo 755 ;;
		*) echo 644 ;;
	esac
}

echo "$OW_MANIFEST_MAGIC"
printf 'channel\t%s\nseq\t%s\nversion\t%s\nupstream_base\t%s\ndate\t%s\nreset_state\t%s\n' \
	"$Z2K_OW_CHANNEL" "$seq" "$ver" "$up" "$date" "$reset"
sort | while IFS= read -r f; do
	targets=$(OW_ZD=/opt/zapret2 ow_layout_targets "$f")
	[ -n "$targets" ] || continue
	[ -f "$root/$f" ] || { echo "build-manifest: нет файла $f" >&2; exit 1; }
	sha=$(sha256sum "$root/$f" | awk '{print $1}')
	printf 'file\t%s\t%s\t%s\t%s\n' "$sha" "$(mode_of "${targets%% *}")" "$f" "$targets"
done
printf 'release\t%s\t%s\t%s\t%s\n' "$ver" "$date" "$up" "$desc"
[ -n "$prev" ] && [ -f "$prev" ] && grep "^release$TAB" "$prev" || true
