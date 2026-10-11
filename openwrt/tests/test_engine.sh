#!/bin/sh
# Установка движка по пину в песочницу: sha архива, выбор бинарников арки,
# удаление чужих сборок, пользовательский config не перетирается.
#
# Архив движка берётся из Z2K_TEST_ENGINE_TGZ или скачивается по пину
# (кэш в $TMPDIR). Без сети и без кэша тест пропускается.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$ROOT/openwrt/lib/platform.sh"
. "$ROOT/openwrt/lib/engine.sh"
PIN="$ROOT/openwrt/engine.pin"
fail=0; n=0
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL: $1: ждали '$2', получили '$3'"; }; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
CACHE="${TMPDIR:-/tmp}/z2k-engine-$(ow_pin_get ENGINE_SHA256 "$PIN").tar.gz"
TGZ="${Z2K_TEST_ENGINE_TGZ:-$CACHE}"
if ! ow_engine_fetch "$PIN" "$TGZ" 2>/dev/null; then
	echo "test_engine: SKIP (нет архива движка и сети)"; exit 0
fi
eq "sha архива" "$(ow_pin_get ENGINE_SHA256 "$PIN")" "$(ow_sha256 "$TGZ")"

# Битый архив пин не пропускает.
cp "$TGZ" "$T/bad.tgz"; printf 'x' >> "$T/bad.tgz"
n=$((n + 1)); ow_engine_fetch "$PIN" "$T/bad.tgz" 2>/dev/null
# fetch перекачает файл заново при несовпадении sha — значит, он не принял порченый.
[ "$(ow_sha256 "$T/bad.tgz")" = "$(ow_pin_get ENGINE_SHA256 "$PIN")" ] || { [ ! -e "$T/bad.tgz" ] || { fail=$((fail + 1)); echo "FAIL: порченый архив принят"; }; }

# Установка под mipsel в песочницу (запуск бинарника на хосте невозможен).
ZD="$T/opt/zapret2"
mkdir -p "$ZD"; echo "ENABLED=1 # пользовательский" > "$ZD/config"
Z2K_OW_SKIP_EXEC_CHECK=1 ow_engine_install "$TGZ" "$PIN" "$ZD" mipsel_24kc
eq "код установки" 0 $?
eq "версия" "$(ow_pin_get ENGINE_VERSION "$PIN")" "$(cat "$ZD/.z2k-engine-version")"
for b in nfq2/nfqws2 ip2net/ip2net mdig/mdig; do
	n=$((n + 1)); [ -s "$ZD/$b" ] || { fail=$((fail + 1)); echo "FAIL: нет $b"; }
done
# Бинарник — именно mipsel: ELF, 32 бита, little endian.
eq "nfqws2 — ELF32 LE" "7f454c460101" "$(od -An -tx1 -N6 "$ZD/nfq2/nfqws2" | tr -d ' \n')"
n=$((n + 1)); [ ! -d "$ZD/binaries" ] || { fail=$((fail + 1)); echo "FAIL: binaries/ не удалён"; }
eq "config пользователя цел" "ENABLED=1 # пользовательский" "$(cat "$ZD/config")"
for f in common/nft.sh common/base.sh init.d/openwrt/functions init.d/custom.d.examples.linux/50-stun4all lua/zapret-lib.lua.gz ipset/create_ipset.sh; do
	n=$((n + 1)); [ -f "$ZD/$f" ] || { fail=$((fail + 1)); echo "FAIL: нет $f"; }
done
n=$((n + 1)); ls "$ZD"/*.engine-stage.* >/dev/null 2>&1 && { fail=$((fail + 1)); echo "FAIL: остался stage"; }

# Неподдерживаемая арка.
n=$((n + 1)); Z2K_OW_SKIP_EXEC_CHECK=1 ow_engine_install "$TGZ" "$PIN" "$T/x" mips64el_mips64r2 2>/dev/null && { fail=$((fail + 1)); echo "FAIL: mips64el принят"; }

echo "test_engine: $((n - fail))/$n"
[ "$fail" -eq 0 ]
