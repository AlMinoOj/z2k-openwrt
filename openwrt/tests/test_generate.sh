#!/bin/sh
# Генерация стратегий и конфига библиотеками z2k через openwrt/lib/z2k-config.sh
# в песочнице. Ловит при синхронизации с апстримом: генератор перестал
# работать без установщика Keenetic, сменил входы, начал навязывать iptables.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$ROOT/openwrt/lib/layout.sh"
fail=0; n=0
eq()  { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL: $1: ждали '$2', получили '$3'"; }; }
has() { n=$((n + 1)); grep -q -- "$2" "$3" || { fail=$((fail + 1)); echo "FAIL: $1: нет '$2' в $(basename "$3")"; }; }

# Z2K_TEST_KEEP=<каталог> — оставить песочницу для разбора.
if [ -n "${Z2K_TEST_KEEP:-}" ]; then T="$Z2K_TEST_KEEP"; mkdir -p "$T"
else T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; fi
ZD="$T/opt/zapret2"
# Раскладываем файлы так же, как установщик, но в песочницу.
OW_ZD="$ZD"
for f in $(cd "$ROOT" && git ls-files); do
	for t in $(ow_layout_targets "$f"); do
		case "$t" in "$ZD"/*) ;; *) continue ;; esac
		mkdir -p "$(dirname "$t")"; cp "$ROOT/$f" "$t"
	done
done

export ZAPRET2_DIR="$ZD" CONFIG_DIR="$T/etc/zapret2" WORK_DIR="$T/work" \
	INIT_SCRIPT="$T/init-z2k" FLOWOFFLOAD=software
unset FWTYPE
. "$ROOT/openwrt/lib/z2k-config.sh"
out=$(ow_z2k_generate 2>&1); rc=$?
eq "код генерации" 0 "$rc"
[ "$rc" = 0 ] || printf '%s\n' "$out" | tail -n 20

C="$ZD/config"
n=$((n + 1)); [ -s "$C" ] || { fail=$((fail + 1)); echo "FAIL: config не создан"; }
has "очередь" '^QNUM=200' "$C"
has "метка десинка" '^DESYNC_MARK=0x40000000' "$C"
has "порты TCP" '^NFQWS2_PORTS_TCP="' "$C"
has "init применяет fw" '^INIT_APPLY_FW=1' "$C"
has "flow offload из окружения" '^FLOWOFFLOAD=software' "$C"
has "демон от nobody" '^WS_USER=nobody' "$C"
has "служба включена" '^ENABLED=1' "$C"
n=$((n + 1)); grep -q '^FWTYPE=iptables' "$C" && { fail=$((fail + 1)); echo "FAIL: конфиг навязывает FWTYPE=iptables"; }
# Конфиг дописан до конца (обрыв heredoc под set -u давал «обрезок» с кодом 0).
has "конфиг дописан до конца" '^Z2K_GITHUB_RAW=' "$C"
has "канал форка" '^Z2K_GITHUB_RAW="https://raw.githubusercontent.com/AlMinoOj/z2k-openwrt/main"' "$C"
n=$((n + 1)); grep -q 'necronicle' "$C" && { fail=$((fail + 1)); echo "FAIL: в конфиге ссылка на апстрим: $(grep -m1 necronicle "$C")"; }

profiles=$(sed -n '/^NFQWS2_OPT="/,/^"$/p' "$C" | grep -c -- '--new')
n=$((n + 1)); [ "$profiles" -ge 5 ] || { fail=$((fail + 1)); echo "FAIL: профилей nfqws2 мало: $profiles"; }

# Боевые пулы, а не аварийные.
n=$((n + 1)); printf '%s\n' "$out" | grep -q 'аварийные' && { fail=$((fail + 1)); echo "FAIL: пулы стратегий аварийные"; }
for f in extra_strats/TCP/YT/List.txt extra_strats/TCP/RKN/List.txt extra_strats/UDP/YT/List.txt; do
	n=$((n + 1)); [ -s "$ZD/$f" ] || { fail=$((fail + 1)); echo "FAIL: пустой хостлист $f"; }
done
n=$((n + 1)); [ -s "$T/etc/zapret2/strategies.conf" ] || { fail=$((fail + 1)); echo "FAIL: нет strategies.conf"; }

# Регенерация сохраняет пользовательские флаги (как у z2k).
sed -i 's/^ENABLED=1/ENABLED=0/' "$C"
ow_z2k_generate >/dev/null 2>&1
has "ENABLED=0 пережил регенерацию" '^ENABLED=0' "$C"

echo "test_generate: $((n - fail))/$n (профилей: $profiles)"
[ "$fail" -eq 0 ]
