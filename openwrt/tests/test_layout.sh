#!/bin/sh
# Раскладка (openwrt/lib/layout.sh) согласована с картой совместимости:
#   * на роутер едут только portable/patched/openwrt;
#   * всё portable/patched из «ядра» (данные nfqws2, генераторы, движок) едет;
#   * хук S99 стоит ровно один раз и перед диспетчером.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$ROOT/openwrt/lib/layout.sh"
fail=0; n=0
ok()  { n=$((n + 1)); }
bad() { n=$((n + 1)); fail=$((fail + 1)); echo "FAIL: $*"; }

classes=$(git -C "$ROOT" ls-files | sh "$ROOT/openwrt/maint/compat-check.sh" --stdin)
cls() { printf '%s\n' "$classes" | awk -F '\t' -v p="$1" '$2 == p { print $1; exit }'; }

# 1. Ничего лишнего.
for f in $(git -C "$ROOT" ls-files); do
	[ -n "$(ow_layout_targets "$f")" ] || continue
	c=$(cls "$f")
	case "$c" in
		portable|patched|openwrt) ok ;;
		*) bad "едет на роутер, но класс '$c': $f" ;;
	esac
done

# 2. Ядро едет целиком. Отложенное по фазам (Go-сборки, панель, туннели,
# WARP, insta) перечислено явно — новый файл апстрима в этих каталогах
# уронит тест, и его придётся осознанно разложить или отложить.
deferred() {
	case "$1" in
		*/builds/*) return 0 ;;                                   # фаза 5
		webpanel/*|lib/webpanel.sh|lib/menu.sh) return 0 ;;       # фаза 6 (menu.sh — CLI)
		files/z2k-tg-*|files/z2k-fix-tg-watchdog.sh|files/z2k-warp.sh|files/z2k-insta-ip-refresh.sh) return 0 ;;  # фаза 5
	esac
	return 1
}
for f in $(git -C "$ROOT" ls-files); do
	c=$(cls "$f")
	case "$c" in portable|patched) ;; *) continue ;; esac
	deferred "$f" && continue
	if [ -n "$(ow_layout_targets "$f")" ]; then ok; else bad "класс $c, но не разложен: $f"; fi
done

# 3. Ключевые цели.
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL: $1: ждали '$2', получили '$3'"; }; }
eq "S99 -> движок" /opt/zapret2/init.d/z2k-engine "$(ow_layout_targets files/S99zapret2.new)"
eq "слой S99" /opt/zapret2/openwrt/lib/s99-openwrt.sh "$(ow_layout_targets openwrt/lib/s99-openwrt.sh)"
eq "init" /etc/init.d/z2k "$(ow_layout_targets openwrt/init.d/z2k)"
eq "список в две цели" "/opt/zapret2/files/lists/telegram_ips.txt /opt/zapret2/lists/telegram_ips.txt" "$(ow_layout_targets files/lists/telegram_ips.txt)"
eq "снимок хостлиста" /opt/zapret2/files/lists/extra_strats/TCP/RKN/List.txt "$(ow_layout_targets files/lists/extra_strats/TCP/RKN/List.txt)"
eq "install.sh апстрима не едет" "" "$(ow_layout_targets lib/install.sh)"
eq "хуки NDM не едут" "" "$(ow_layout_targets files/ndm/93-z2k-warp.sh)"

# 4. Хук в S99.
hooks=$(grep -c 's99-openwrt.sh' "$ROOT/files/S99zapret2.new")
eq "хук S99 ровно один" 1 "$hooks"
hl=$(grep -n '^\[ -r "\$ZAPRET_BASE/openwrt/lib/s99-openwrt.sh" \]' "$ROOT/files/S99zapret2.new" | cut -d: -f1)
cl=$(grep -n '^case "\$1" in' "$ROOT/files/S99zapret2.new" | tail -n 1 | cut -d: -f1)
n=$((n + 1))
if [ -n "$hl" ] && [ -n "$cl" ] && [ "$hl" -lt "$cl" ]; then :; else fail=$((fail + 1)); echo "FAIL: хук S99 должен стоять перед диспетчером (хук=$hl, case=$cl)"; fi

echo "test_layout: $((n - fail))/$n"
[ "$fail" -eq 0 ]
