#!/bin/sh
# z2k-cron: блок в crontab ставится и снимается, чужие строки не трогаются,
# час автообновления берётся из конфига и подтягивается сторожем.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
fail=0; n=0
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL: $1: ждали '$2', получили '$3'"; }; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export Z2K_OW_ZD="$T/zd" Z2K_OW_CRONTAB="$T/root"
mkdir -p "$T/zd"
C() { sh "$ROOT/openwrt/bin/z2k-cron" "$@" >/dev/null 2>&1; }

printf '15 1 * * * /usr/bin/чужое\n' > "$T/root"
echo "Z2K_AU_HOUR=05" > "$T/zd/config"
C install
eq "чужая строка цела" 1 "$(grep -c 'чужое' "$T/root")"
eq "автообновление в 5:00" 1 "$(grep -c "^0 5 \* \* \* $T/zd/openwrt/bin/z2k-cron auto-update" "$T/root")"
eq "сторож каждые 5 минут" 1 "$(grep -c '^\*/5 \* \* \* \* .*z2k-cron watchdog' "$T/root")"
C install
eq "повторная установка не дублирует" 1 "$(grep -c 'z2k-openwrt BEGIN' "$T/root")"

sed -i 's/^Z2K_AU_HOUR=.*/Z2K_AU_HOUR=23/' "$T/zd/config"
C watchdog
eq "сторож подтянул час" 1 "$(grep -c '^0 23 \* \* \* .*auto-update' "$T/root")"
eq "старого часа нет" 0 "$(grep -c '^0 5 \* \* \* .*auto-update' "$T/root")"

echo "Z2K_AU_HOUR=мусор" > "$T/zd/config"; C install
eq "мусор в часе -> 2:00" 1 "$(grep -c '^0 2 \* \* \* .*auto-update' "$T/root")"
echo "Z2K_AU_HOUR=0" > "$T/zd/config"; C install
eq "час 0" 1 "$(grep -c '^0 0 \* \* \* .*auto-update' "$T/root")"

C remove
eq "блок снят" 0 "$(grep -c 'z2k' "$T/root")"
eq "чужая строка осталась" 1 "$(grep -c 'чужое' "$T/root")"

. "$ROOT/openwrt/lib/manifest.sh"
eq "шаг cron" "cron" "$(echo openwrt/bin/z2k-cron | ow_steps_merged)"

echo "test_cron: $((n - fail))/$n"
[ "$fail" -eq 0 ]
