#!/bin/sh
# z2k-openwrt — установка одной командой:
#
#   wget -qO- https://raw.githubusercontent.com/AlMinoOj/z2k-openwrt/main/openwrt/get.sh | sh
#
# Качает подписанный манифест последнего релиза канала, проверяет подпись
# встроенным usign, скачивает файлы релиза по тегу со сверкой sha256 и
# запускает openwrt/install.sh из проверенной копии. Нужны только штатные
# средства OpenWrt 23.05+ (uclient-fetch/wget, usign, sha256sum).

set -u
REPO="${Z2K_OW_REPO:-AlMinoOj/z2k-openwrt}"
BRANCH="${Z2K_OW_BRANCH:-main}"
RAW="${Z2K_OW_RAW_BASE:-https://raw.githubusercontent.com/$REPO}"
CDN="${Z2K_OW_CDN_BASE:-https://cdn.jsdelivr.net/gh/$REPO}"
USIGN="${Z2K_OW_USIGN:-usign}"
W=/tmp/z2k-get

die() { echo "[z2k] ОШИБКА: $*" >&2; exit 1; }
say() { echo "[z2k] $*"; }

[ "$(id -u)" = 0 ] || die "нужен root"
[ -r /etc/openwrt_release ] || die "это не OpenWrt"

fetch() { # <url> <файл>
	rm -f "$2"
	if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 2 --connect-timeout 15 -o "$2" "$1" 2>/dev/null
	else wget -q -T 30 -O "$2" "$1" 2>/dev/null; fi
	[ -s "$2" ]
}
sha() { sha256sum "$1" | awk '{print $1}'; }

rm -rf "$W"; mkdir -p "$W/src"

# Ключ канала — с той же ветки по HTTPS (якорь доверия установки; дальше
# обновления сверяются с ним, а не с сетью).
fetch "$RAW/$BRANCH/openwrt/etc/z2k-update.pub" "$W/pub" ||
	fetch "$CDN@$BRANCH/openwrt/etc/z2k-update.pub" "$W/pub" || die "не скачался ключ канала"

ok=""
for base in "$RAW/$BRANCH" "$CDN@$BRANCH"; do
	fetch "$base/openwrt/release/manifest" "$W/manifest" && fetch "$base/openwrt/release/manifest.sig" "$W/manifest.sig" || continue
	"$USIGN" -V -q -m "$W/manifest" -p "$W/pub" -x "$W/manifest.sig" 2>/dev/null && { ok=1; break; }
	say "подпись манифеста не прошла ($base), пробую зеркало"
done
[ -n "$ok" ] || die "не удалось получить подписанный манифест"
head -n 1 "$W/manifest" | grep -qx '#z2k-openwrt-manifest 1' || die "манифест неизвестного формата"
VER=$(awk -F '\t' '$1 == "version" { print $2; exit }' "$W/manifest")
say "релиз $VER"

n=0
awk -F '\t' '$1 == "file" { print $2 "\t" $4 }' "$W/manifest" > "$W/files"
while IFS="$(printf '\t')" read -r want path; do
	mkdir -p "$W/src/$(dirname "$path")"
	got=""
	for url in "$RAW/$VER/$path" "$CDN@$VER/$path"; do
		fetch "$url" "$W/src/$path" && [ "$(sha "$W/src/$path")" = "$want" ] && { got=1; break; }
	done
	[ -n "$got" ] || die "не скачался или не совпал по sha: $path"
	n=$((n + 1))
done < "$W/files"
say "скачано и проверено файлов: $n"

# Тот же ключ, которым проверен манифест, — в установку (install.sh раскладывает
# openwrt/etc/* по манифестному layout; он уже в списке, но на всякий случай).
mkdir -p "$W/src/openwrt/etc"; cp -f "$W/pub" "$W/src/openwrt/etc/z2k-update.pub"
cp "$W/manifest" "$W/src/openwrt/manifest.installed"

Z2K_OW_MANIFEST="$W/src/openwrt/manifest.installed" sh "$W/src/openwrt/install.sh"
rc=$?
rm -rf "$W"
exit $rc
