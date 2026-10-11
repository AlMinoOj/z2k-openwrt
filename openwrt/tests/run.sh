#!/bin/sh
# Прогон тестов порта: классификация всех файлов + openwrt/tests/test_*.sh.
# Оболочка по умолчанию — dash (ближе всего к busybox ash), можно Z2K_TEST_SH=sh.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
SH="${Z2K_TEST_SH:-$(command -v dash || echo sh)}"
fail=0

echo "== синтаксис ($SH -n)"
for f in "$ROOT"/openwrt/lib/*.sh "$ROOT"/openwrt/tools/*.sh "$ROOT"/openwrt/tests/*.sh; do
	[ -f "$f" ] || continue
	"$SH" -n "$f" || { echo "FAIL: синтаксис $f"; fail=1; }
done

echo "== compat-map: все файлы классифицированы"
"$SH" "$ROOT/openwrt/tools/compat-check.sh" || fail=1

for t in "$HERE"/test_*.sh; do
	echo "== $(basename "$t")"
	"$SH" "$t" || fail=1
done

[ "$fail" -eq 0 ] && echo "OK" || echo "ЕСТЬ ПАДЕНИЯ"
exit "$fail"
