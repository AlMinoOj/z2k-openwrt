#!/bin/sh
# update.sh — обновлятор z2k-openwrt на роутере (CLI: z2k-update).
#
#   update.sh check            есть ли новая версия в канале
#   update.sh apply [--auto]   применить; --auto — из cron (уважает
#                              Z2K_AUTO_UPDATE_ENABLED=0 в конфиге)
#   update.sh status           что установлено
#
# Источник — ТОЛЬКО канал форка (openwrt/lib/channel.sh). Манифест подписан
# ключом мейнтейнера и проверяется встроенным usign; файлы сверяются по
# sha256 из манифеста. Схема «сходимости», как у z2k (lib/auto_update.sh):
#   1. манифест: подпись, канал, seq не меньше установленного;
#   2. план: файлы, чья цель отличается по sha (или отсутствует), и сироты —
#      цели прежнего манифеста, которых нет в новом;
#   3. всё скачивается в /tmp ДО первой записи на флеш;
#   4. снимок затрагиваемых целей -> атомарная замена (cp + mv);
#   5. шаги (движок, перегенерация, перезапуск) исполняет НОВЫЙ update.sh;
#   6. проверка, что служба жива; иначе откат снимка и перезапуск;
#   7. состояние (версия, seq) пишется последним.
#
# Для тестов: Z2K_OW_ROOT — префикс корня ФС, Z2K_OW_USIGN — проверяльщик,
# Z2K_OW_STEPS_DRYRUN=1 — шаги только в журнал.

set -u

ZD="${Z2K_OW_ZD:-/opt/zapret2}"
R="${Z2K_OW_ROOT:-}"
OWL="${Z2K_OW_LIB:-$R$ZD/openwrt/lib}"
. "$OWL/platform.sh"
. "$OWL/channel.sh"
. "$OWL/engine.sh"
. "$OWL/manifest.sh"
. "$OWL/postinstall.sh"
. "$OWL/modules.sh"
OW_ZD="$R$ZD"

TMP="${Z2K_OW_TMP:-/tmp/z2k-update}"
STATE="$R$ZD/.z2k-installed"
CUR_MF="$R$ZD/.z2k-manifest"
BK="$R$ZD/.z2k-rollback"
FAILED="$R$ZD/.z2k-update-failed"   # версия, на которой откатились
PUB="${Z2K_OW_PUBKEY:-$R$ZD/etc/z2k-update.pub}"
USIGN="${Z2K_OW_USIGN:-usign}"
LOCK="${Z2K_OW_LOCK:-/tmp/z2k-update.lock}"
INIT="${Z2K_OW_INIT:-$R/etc/init.d/z2k}"

log()  { echo "[z2k-update] $*"; [ -n "$R" ] || logger -t z2k-update "$*" 2>/dev/null; }
die()  { log "ОШИБКА: $*"; exit 1; }

state_get() { [ -f "$STATE" ] && awk -v k="$1" '$1 == k { print $2; exit }' "$STATE"; }

state_write() { # <манифест>
	{
		echo "version $(ow_mf_get "$1" version)"
		echo "seq $(ow_mf_get "$1" seq)"
		echo "channel $(ow_mf_get "$1" channel)"
		echo "upstream_base $(ow_mf_get "$1" upstream_base)"
		echo "updated $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	} > "$STATE.tmp" && mv -f "$STATE.tmp" "$STATE"
}

# --- сеть -------------------------------------------------------------------
fetch() { # <url> <файл>
	rm -f "$2"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 2 --connect-timeout 15 -m 180 -o "$2" "$1" 2>/dev/null
	else
		uclient-fetch -q -T 30 -O "$2" "$1" 2>/dev/null
	fi
	[ -s "$2" ]
}

# fetch_repo_file <ref> <путь> <файл> <sha256> — с зеркала, сверка sha.
fetch_repo_file() {
	local url
	for url in "$(ow_file_url "$1" "$2")" "$(ow_file_cdn_url "$1" "$2")"; do
		fetch "$url" "$3" || continue
		[ "$(ow_sha256 "$3")" = "$4" ] && return 0
		log "sha не совпал: $url"
	done
	rm -f "$3"; return 1
}

# fetch_manifest -> $TMP/manifest, проверенный. Зеркала: raw (ветка), jsdelivr.
# Подпись снимает вопрос доверия к зеркалу; устаревший кэш зеркала отсекает seq.
fetch_manifest() {
	local url m="$TMP/manifest" s="$TMP/manifest.sig" ok=""
	[ -s "$PUB" ] || die "нет ключа канала $PUB"
	for url in "$Z2K_OW_MANIFEST_URL" "$Z2K_OW_CDN_BASE@$Z2K_OW_BRANCH/openwrt/release/manifest"; do
		fetch "$url" "$m" && fetch "$url.sig" "$s" || continue
		if "$USIGN" -V -q -m "$m" -p "$PUB" -x "$s" 2>/dev/null; then ok=1; break; fi
		log "подпись манифеста не прошла: $url"
	done
	[ -n "$ok" ] || die "не удалось получить подписанный манифест канала"
	ow_mf_valid "$m" || die "манифест повреждён"
	[ "$(ow_mf_get "$m" channel)" = "$Z2K_OW_CHANNEL" ] || die "манифест другого канала: $(ow_mf_get "$m" channel)"
	case "$(ow_mf_get "$m" seq)" in ''|*[!0-9]*) die "seq манифеста не число" ;; esac
}

# --- план -------------------------------------------------------------------
# plan <манифест> -> $TMP/plan ("sha mode путь цели"), $TMP/orphans (цели)
plan() {
	local sha mode path targets t first
	: > "$TMP/plan"; : > "$TMP/orphans"
	ow_mf_files "$1" | while IFS="$(printf '\t')" read -r sha mode path targets; do
		# Сборки модулей — только включённых и только под эту арку.
		ow_mf_file_applies "$path" "$1" || continue
		first=${targets%% *}
		if [ "$(ow_sha256 "$R$first")" != "$sha" ]; then
			printf '%s\t%s\t%s\t%s\n' "$sha" "$mode" "$path" "$targets" >> "$TMP/plan"; continue
		fi
		for t in $targets; do
			[ -f "$R$t" ] || { printf '%s\t%s\t%s\t%s\n' "$sha" "$mode" "$path" "$targets" >> "$TMP/plan"; break; }
		done
	done
	if [ -f "$CUR_MF" ]; then
		ow_mf_targets "$CUR_MF" | sort -u > "$TMP/old.t"
		ow_mf_targets "$1" | sort -u > "$TMP/new.t"
		# comm в busybox OpenWrt может не быть — разность множеств через awk.
		awk 'NR == FNR { n[$0] = 1; next } !($0 in n)' "$TMP/new.t" "$TMP/old.t" > "$TMP/orphans"
	fi
}

# --- снимок и откат ---------------------------------------------------------
snapshot() { # <цель> — сохранить прежнее содержимое или пометить как новую
	local t="$1"
	if [ -e "$R$t" ]; then
		mkdir -p "$BK$(dirname "$t")" && cp -p "$R$t" "$BK$t"
	else
		echo "$t" >> "$BK/.created"
	fi
}

rollback() {
	log "откат: возвращаю прежние файлы"
	local f t
	if [ -f "$BK/.created" ]; then
		while IFS= read -r t; do rm -f "$R$t"; done < "$BK/.created"
	fi
	( cd "$BK" 2>/dev/null && find . -type f ! -name .created ) | while IFS= read -r f; do
		t=${f#.}
		mkdir -p "$R$(dirname "$t")" && cp -p "$BK$t" "$R$t.z2k-new" && mv -f "$R$t.z2k-new" "$R$t"
	done
	rm -rf "$BK"
	run_steps restart-service || log "после отката служба не поднялась — нужна ручная проверка"
}

# --- шаги ---------------------------------------------------------------------
service_enabled() { grep -q '^ENABLED=1' "$R$ZD/config" 2>/dev/null; }

run_steps() {
	local s rc=0
	if [ -z "$R" ]; then ow_postinstall "$ZD" >/dev/null 2>&1; else ow_blob_aliases "$R$ZD"; fi
	for s in "$@"; do
		log "шаг: $s"
		if [ -n "${Z2K_OW_STEPS_DRYRUN:-}" ]; then   # тесты: шаги только в журнал
			[ "${Z2K_OW_FAIL_STEP:-}" = "$s" ] && { log "шаг $s не удался (тест)"; return 1; }
			echo "$s" >> "$TMP/steps.done"; continue
		fi
		case "$s" in
			engine)
				ow_engine_fetch "$ZD/openwrt/engine.pin" /tmp/z2k-engine.tar.gz &&
				ow_engine_install /tmp/z2k-engine.tar.gz "$ZD/openwrt/engine.pin" "$ZD" || rc=1
				rm -f /tmp/z2k-engine.tar.gz ;;
			regen-strategies) . "$OWL/z2k-config.sh"; ow_z2k_regen_strategies >/dev/null 2>&1 || rc=1 ;;
			regen-config)     . "$OWL/z2k-config.sh"; ow_z2k_regen_config >/dev/null 2>&1 || rc=1 ;;
			validate-config)
				local v=0
				sh "$ZD/z2k-config-validator.sh" "$ZD/config" >/dev/null 2>&1 || v=$?
				[ "$v" -le 1 ] || { log "конфиг не прошёл проверку (код $v)"; rc=1; } ;;
			reset-state)
				rm -f "$ZD/extra_strats/cache/autocircular/state.tsv" "$ZD/extra_strats/cache/autocircular/state.tsv.lock" ;;
			restart-service)
				if service_enabled; then "$INIT" restart >/dev/null 2>&1 || rc=1
				else log "обход выключен в конфиге — не перезапускаю"; fi ;;
			cron) sh "$ZD/openwrt/bin/z2k-cron" install >/dev/null 2>&1 || rc=1 ;;
			fw4)  fw4 -q reload >/dev/null 2>&1 || rc=1 ;;
			restart-tg|restart-rtproxy|restart-warp)
				# Модуль выключен — его службу не трогаем.
				local svc; svc=$(ow_module_field "${s#restart-}" 4)
				if ow_module_enabled "${s#restart-}" && [ -x "$R/etc/init.d/$svc" ]; then
					"$R/etc/init.d/$svc" restart >/dev/null 2>&1 || rc=1
				fi ;;
			*) log "неизвестный шаг: $s"; rc=1 ;;
		esac
		[ "$rc" = 0 ] || { log "шаг $s не удался"; return 1; }
	done
	return 0
}

healthy() {
	[ -n "${Z2K_OW_STEPS_DRYRUN:-}" ] && return 0
	service_enabled || return 0
	sleep 2
	"$INIT" status >/dev/null 2>&1
}

# --- команды ------------------------------------------------------------------
cmd_status() {
	echo "установлено: $(state_get version || true) (seq $(state_get seq || true), канал $(state_get channel || true))"
	echo "z2k апстрима: $(state_get upstream_base || true)"
	echo "движок: $(cat "$R$ZD/.z2k-engine-version" 2>/dev/null)"
	[ -f "$CUR_MF" ] && { echo "история:"; ow_mf_releases "$CUR_MF" 5 | sed 's/^/  /'; }
	return 0
}

cmd_check() {
	mkdir -p "$TMP"
	fetch_manifest
	local m="$TMP/manifest" new cur
	new=$(ow_mf_get "$m" seq); cur=$(state_get seq); cur=${cur:-0}
	if [ "$new" -gt "$cur" ]; then
		echo "доступно: $(ow_mf_get "$m" version) (установлено: $(state_get version || echo нет))"
		ow_mf_releases "$m" $((new - cur)) | sed 's/^/  /'
		return 0
	fi
	echo "актуально: $(state_get version)"
	return 0
}

cmd_apply() {
	local auto=0; [ "${1:-}" = "--auto" ] && auto=1
	if [ "$auto" = 1 ] && grep -q '^Z2K_AUTO_UPDATE_ENABLED=0' "$R$ZD/config" 2>/dev/null; then
		log "автообновление выключено (Z2K_AUTO_UPDATE_ENABLED=0)"; return 0
	fi
	[ "$(cat "$R$ZD/.z2k-branch" 2>/dev/null)" = "$Z2K_OW_CHANNEL" ] ||
		die "метка канала $R$ZD/.z2k-branch не '$Z2K_OW_CHANNEL' — обновления этого канала не для этой установки"

	mkdir "$LOCK" 2>/dev/null || die "обновление уже идёт ($LOCK)"
	trap 'rm -rf "$LOCK"' EXIT INT TERM
	rm -rf "$TMP"; mkdir -p "$TMP/stage"

	fetch_manifest
	local m="$TMP/manifest" new cur ver reset="" sha mode path targets t steps
	new=$(ow_mf_get "$m" seq); cur=$(state_get seq); cur=${cur:-0}
	ver=$(ow_mf_get "$m" version)
	if [ "$new" -lt "$cur" ]; then
		log "в канале seq $new старше установленного $cur (кэш зеркала?) — пропускаю"; return 0
	fi
	[ "$(ow_mf_get "$m" reset_state)" = 1 ] && [ "$new" -gt "$cur" ] && reset=reset-state
	# Версия уже откатывалась — ночной запуск не повторяет её каждую ночь.
	# Ручной apply пробует снова: причина могла быть на роутере (место, сеть).
	# Исправленный релиз выйдет с новой версией и пройдёт мимо этой отметки.
	if [ "$auto" = 1 ] && [ "$(cat "$FAILED" 2>/dev/null)" = "$ver" ]; then
		log "$ver уже откатывалась на этом роутере — автообновление пропускает (вручную: z2k-update apply)"; return 0
	fi

	plan "$m"
	if [ ! -s "$TMP/plan" ] && [ ! -s "$TMP/orphans" ] && [ -z "$reset" ]; then
		state_write "$m"; cp -f "$m" "$CUR_MF"
		log "актуально: $ver"; return 0
	fi
	log "обновление до $ver: файлов $(wc -l < "$TMP/plan"), удалить $(wc -l < "$TMP/orphans")"

	# 3. скачать всё
	while IFS="$(printf '\t')" read -r sha mode path targets; do
		mkdir -p "$TMP/stage/$(dirname "$path")"
		fetch_repo_file "$ver" "$path" "$TMP/stage/$path" "$sha" || die "не скачался $path — ничего не менял"
	done < "$TMP/plan"

	# 4. снимок и замена
	rm -rf "$BK"; mkdir -p "$BK"
	while IFS="$(printf '\t')" read -r sha mode path targets; do
		for t in $targets; do snapshot "$t"; done
	done < "$TMP/plan"
	while IFS= read -r t; do [ -n "$t" ] && snapshot "$t"; done < "$TMP/orphans"

	while IFS="$(printf '\t')" read -r sha mode path targets; do
		for t in $targets; do
			mkdir -p "$R$(dirname "$t")" &&
			cp -f "$TMP/stage/$path" "$R$t.z2k-new" && chmod "$mode" "$R$t.z2k-new" &&
			mv -f "$R$t.z2k-new" "$R$t" || { log "не записался $t"; rollback; exit 1; }
		done
	done < "$TMP/plan"
	while IFS= read -r t; do [ -n "$t" ] && rm -f "$R$t"; done < "$TMP/orphans"

	# 5. шаги — новым кодом
	steps=$(cut -f3 "$TMP/plan" | ow_steps_merged $reset | tr '\n' ' ')
	log "шаги: ${steps:-нет}"
	if ! Z2K_OW_TMP="$TMP" sh "$R$ZD/openwrt/lib/update.sh" run-steps $steps; then
		rollback; echo "$ver" > "$FAILED"; die "обновление до $ver откатено: шаги не прошли"
	fi
	# 6. жива ли служба
	if ! healthy; then
		rollback; echo "$ver" > "$FAILED"; die "обновление до $ver откатено: служба не поднялась"
	fi
	# 7. состояние
	cp -f "$m" "$CUR_MF"; state_write "$m"
	rm -rf "$BK" "$FAILED"
	log "готово: $ver"
}

case "${1:-}" in
	check)     cmd_check ;;
	apply)     shift; cmd_apply "$@" ;;
	status)    cmd_status ;;
	run-steps) shift; mkdir -p "$TMP"; run_steps "$@" ;;
	*) sed -n '2,9p' "$0"; exit 2 ;;
esac
