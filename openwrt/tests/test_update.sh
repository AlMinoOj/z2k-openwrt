#!/bin/sh
# Сквозной тест обновлятора (openwrt/lib/update.sh) в песочнице:
# канал — каталог на file:// (curl), подпись — тестовым ключом, проверка —
# openwrt/maint/usign-verify.sh (тот же формат, что usign на роутере), шаги —
# в журнал (Z2K_OW_STEPS_DRYRUN), корень ФС — Z2K_OW_ROOT.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
command -v openssl >/dev/null || { echo "test_update: SKIP (нет openssl)"; exit 0; }
command -v curl >/dev/null || { echo "test_update: SKIP (нет curl)"; exit 0; }
. "$ROOT/openwrt/lib/manifest.sh"
. "$ROOT/openwrt/lib/layout.sh"

fail=0; n=0
eq()  { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL: $1: ждали '$2', получили '$3'"; }; }
yes_() { n=$((n + 1)); eval "$2" || { fail=$((fail + 1)); echo "FAIL: $1"; }; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
RFS="$T/rootfs"; REM="$T/remote"; SRC="$T/src"
ZD=/opt/zapret2
sh "$ROOT/openwrt/maint/sign.sh" keygen "$T/key" >/dev/null

# --- исходники релизов: v1 = текущее дерево, v2/v3 — правки поверх ---
mk_src() { rm -rf "$SRC"; mkdir -p "$SRC"; (cd "$ROOT" && git ls-files) | while IFS= read -r f; do
	[ -n "$(ow_layout_targets "$f")" ] || continue; mkdir -p "$SRC/$(dirname "$f")"; cp "$ROOT/$f" "$SRC/$f"; done
	mkdir -p "$SRC/openwrt/etc"; cp "$T/key/z2k-update.pub" "$SRC/openwrt/etc/z2k-update.pub"; }

# publish <версия> <seq> [reset] — дерево $SRC в канал: файлы по тегу, манифест на ветку.
publish() {
	local ver="$1" seq="$2" reset="${3:-0}" prev="$REM/main/openwrt/release/manifest"
	mkdir -p "$REM/$ver" "$REM/main/openwrt/release"
	(cd "$SRC" && find . -type f | sed 's#^\./##') > "$T/list"
	while IFS= read -r f; do mkdir -p "$REM/$ver/$(dirname "$f")"; cp "$SRC/$f" "$REM/$ver/$f"; done < "$T/list"
	sh "$ROOT/openwrt/maint/build-manifest.sh" "$SRC" "$ver" "$seq" p-test "$reset" "релиз $ver" "$prev" < "$T/list" > "$T/mf"
	cp "$T/mf" "$prev"
	sh "$ROOT/openwrt/maint/sign.sh" sign "$T/key/z2k-update.key" "$prev" >/dev/null
}

# install_v1 — как установщик: раскладка в rootfs + состояние релиза.
install_from_src() {
	local mf="$REM/main/openwrt/release/manifest"
	rm -rf "$RFS"; mkdir -p "$RFS"
	ow_mf_files "$mf" | while IFS="$(printf '\t')" read -r sha mode path targets; do
		for t in $targets; do mkdir -p "$RFS$(dirname "$t")"; cp "$SRC/$path" "$RFS$t"; done
	done
	echo openwrt-main > "$RFS$ZD/.z2k-branch"
	echo "ENABLED=1" > "$RFS$ZD/config"
	cp "$mf" "$RFS$ZD/.z2k-manifest"
	printf 'version %s\nseq %s\nchannel openwrt-main\n' "$(ow_mf_get "$mf" version)" "$(ow_mf_get "$mf" seq)" > "$RFS$ZD/.z2k-installed"
}

# URL канала: под Windows (Git Bash) curl понимает только file:///C:/…
if command -v cygpath >/dev/null 2>&1; then REMURL="file:///$(cygpath -m "$REM")"; else REMURL="file://$REM"; fi

upd() { # запуск обновлятора из установленной копии
	Z2K_OW_ROOT="$RFS" Z2K_OW_TMP="$T/tmp" Z2K_OW_LOCK="$T/lock" Z2K_OW_STEPS_DRYRUN=1 \
	Z2K_OW_USIGN="$ROOT/openwrt/maint/usign-verify.sh" \
	Z2K_OW_RAW_BASE="$REMURL" Z2K_OW_CDN_BASE="$REMURL/cdn-нет" \
	Z2K_OW_INIT=/bin/true \
		sh "$RFS$ZD/openwrt/lib/update.sh" "$@"
}
sha_of() { sha256sum "$1" | awk '{print $1}'; }
state() { awk -v k="$1" '$1 == k { print $2 }' "$RFS$ZD/.z2k-installed"; }

# === v1 ===
mk_src; publish v1.0.0 1; install_from_src
out=$(upd check 2>&1); yes_ "check v1 — актуально" 'printf "%s" "$out" | grep -q "актуально"'
out=$(upd apply 2>&1); eq "apply без изменений" 0 $?
yes_ "нечего делать" 'printf "%s" "$out" | grep -q "актуально: v1.0.0"'

# === v2: lua + стратегии + удалённый файл + новый файл ===
echo "-- v2" >> "$SRC/files/lua/z2k-alert.lua"
echo "# v2" >> "$SRC/strats_new2.txt"
rm "$SRC/extras/discord-voice-hosts.txt"
publish v1.1.0 2
out=$(upd check 2>&1)
yes_ "check видит v1.1.0" 'printf "%s" "$out" | grep -q "доступно: v1.1.0"'
rm -f "$T/tmp/steps.done"
out=$(upd apply 2>&1); rc=$?
eq "apply v2 код" 0 "$rc"; [ "$rc" = 0 ] || printf '%s\n' "$out"
eq "lua обновлён" "$(sha_of "$SRC/files/lua/z2k-alert.lua")" "$(sha_of "$RFS$ZD/lua/z2k-alert.lua")"
eq "стратегии обновлены" "$(sha_of "$SRC/strats_new2.txt")" "$(sha_of "$RFS$ZD/strats_new2.txt")"
yes_ "сирота удалён" '[ ! -e "$RFS$ZD/extras/discord-voice-hosts.txt" ]'
eq "шаги" "regen-strategies regen-config validate-config restart-service" "$(tr '\n' ' ' < "$T/tmp/steps.done" | sed 's/ $//')"
eq "seq записан" 2 "$(state seq)"
eq "версия записана" v1.1.0 "$(state version)"
yes_ "снимок убран" '[ ! -d "$RFS$ZD/.z2k-rollback" ]'
yes_ "история в статусе" 'upd status 2>&1 | grep -q "v1.1.0"'

# === подмена манифеста: подпись не сходится -> ничего не меняется ===
cp "$RFS$ZD/lua/z2k-alert.lua" "$T/lua.before"
echo "-- v3" >> "$SRC/files/lua/z2k-alert.lua"; publish v1.2.0 3
sed -i 's/^seq\t3/seq\t30/' "$REM/main/openwrt/release/manifest"
out=$(upd apply 2>&1); rc=$?
yes_ "подделка отвергнута (код≠0)" '[ "$rc" != 0 ]'
yes_ "сообщение о подписи" 'printf "%s" "$out" | grep -q "подпись манифеста не прошла"'
eq "файл не тронут после подделки" "$(sha_of "$T/lua.before")" "$(sha_of "$RFS$ZD/lua/z2k-alert.lua")"
eq "seq не тронут" 2 "$(state seq)"

# === битый файл на зеркале: sha не сходится -> ничего не меняется ===
sh "$ROOT/openwrt/maint/sign.sh" sign "$T/key/z2k-update.key" "$REM/main/openwrt/release/manifest" >/dev/null  # честная подпись, seq 30
sed -i 's/^seq\t30/seq\t3/' "$REM/main/openwrt/release/manifest"
sh "$ROOT/openwrt/maint/sign.sh" sign "$T/key/z2k-update.key" "$REM/main/openwrt/release/manifest" >/dev/null
echo "мусор" >> "$REM/v1.2.0/files/lua/z2k-alert.lua"
out=$(upd apply 2>&1); rc=$?
yes_ "битый файл: отказ" '[ "$rc" != 0 ]'
yes_ "битый файл: сообщение" 'printf "%s" "$out" | grep -q "ничего не менял"'
eq "битый файл: lua цел" "$(sha_of "$T/lua.before")" "$(sha_of "$RFS$ZD/lua/z2k-alert.lua")"
cp "$SRC/files/lua/z2k-alert.lua" "$REM/v1.2.0/files/lua/z2k-alert.lua"

# === провал шага -> откат файлов и состояния ===
out=$(Z2K_OW_FAIL_STEP=restart-service upd apply 2>&1); rc=$?
yes_ "провал шага: код≠0" '[ "$rc" != 0 ]'
yes_ "провал шага: откат" 'printf "%s" "$out" | grep -q "откат"'
eq "провал шага: lua вернулся" "$(sha_of "$T/lua.before")" "$(sha_of "$RFS$ZD/lua/z2k-alert.lua")"
eq "провал шага: seq прежний" 2 "$(state seq)"

eq "провал запомнен" v1.2.0 "$(cat "$RFS$ZD/.z2k-update-failed" 2>/dev/null)"
out=$(upd apply --auto 2>&1); eq "--auto пропускает откатившуюся" 0 $?
yes_ "--auto: сообщение о пропуске" 'printf "%s" "$out" | grep -q "уже откатывалась"'

# === нормальное применение v1.2.0 (вручную) ===
out=$(upd apply 2>&1); eq "apply v1.2.0" 0 $?
eq "seq 3" 3 "$(state seq)"
yes_ "отметка провала снята" '[ ! -e "$RFS$ZD/.z2k-update-failed" ]'

# === устаревший кэш зеркала (seq меньше) -> пропуск без ошибок ===
cp "$RFS$ZD/.z2k-installed" "$T/inst"; sed -i 's/^seq 3/seq 9/' "$RFS$ZD/.z2k-installed"
out=$(upd apply 2>&1); eq "старый seq — код 0" 0 $?
yes_ "старый seq — пропуск" 'printf "%s" "$out" | grep -q "старше установленного"'
cp "$T/inst" "$RFS$ZD/.z2k-installed"

# === чужой канал ===
echo z2k-enhanced > "$RFS$ZD/.z2k-branch"
out=$(upd apply 2>&1); rc=$?
yes_ "метка апстрима — отказ" '[ "$rc" != 0 ] && printf "%s" "$out" | grep -q "метка канала"'
echo openwrt-main > "$RFS$ZD/.z2k-branch"

# === автообновление выключено в конфиге ===
echo "Z2K_AUTO_UPDATE_ENABLED=0" >> "$RFS$ZD/config"
out=$(upd apply --auto 2>&1); eq "--auto выключено — код 0" 0 $?
yes_ "--auto выключено — сообщение" 'printf "%s" "$out" | grep -q "выключено"'

# === шаги по путям ===
eq "шаги: движок" "engine restart-service" "$(echo openwrt/engine.pin | ow_steps_merged | tr '\n' ' ' | sed 's/ $//')"
eq "шаги: один перезапуск" "restart-service" "$(printf 'files/lua/a.lua\nfiles/fake/b.bin\nfiles/S99zapret2.new\n' | ow_steps_merged | tr '\n' ' ' | sed 's/ $//')"
eq "шаги: reset" "reset-state restart-service" "$(echo files/lua/a.lua | ow_steps_merged reset-state | tr '\n' ' ' | sed 's/ $//')"
eq "шаги: скрипт без шагов" "" "$(echo files/z2k-diag.sh | ow_steps_merged)"

echo "test_update: $((n - fail))/$n"
[ "$fail" -eq 0 ]
