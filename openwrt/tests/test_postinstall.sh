#!/bin/sh
# Псевдонимы блобов (openwrt/lib/postinstall.sh) совпадают с теми, что
# создаёт установщик z2k (lib/install.sh: ln -sf <файл> "$fakedir/<имя>"),
# и реально создаются.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$ROOT/openwrt/lib/postinstall.sh"
fail=0; n=0
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL: $1: ждали '$2', получили '$3'"; }; }

ups=$(grep -oE 'ln -sf [A-Za-z0-9_.]+ "\$fakedir/[A-Za-z0-9_]+"' "$ROOT/lib/install.sh" |
	sed -E 's/ln -sf ([^ ]+) "\$fakedir\/([^"]+)"/\2:\1/' | sort -u)
ours=$(printf '%s\n' $OW_BLOB_ALIASES | sort -u)
eq "псевдонимы = lib/install.sh" "$ups" "$ours"

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/files/fake"; cp "$ROOT"/files/fake/* "$T/files/fake/"
echo "чужой" > "$T/files/fake/quic1"
ow_blob_aliases "$T"
n=$((n + 1)); { [ -L "$T/files/fake/quic_google" ] || cmp -s "$T/files/fake/quic_google" "$T/files/fake/quic_initial_www_google_com.bin"; } || { fail=$((fail + 1)); echo "FAIL: quic_google не создан"; }   # Git Bash: ln -s копирует
eq "чужой файл не тронут" "чужой" "$(cat "$T/files/fake/quic1")"

echo "test_postinstall: $((n - fail))/$n"
[ "$fail" -eq 0 ]
