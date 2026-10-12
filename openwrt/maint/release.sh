#!/bin/sh
# release.sh — выпуск релиза форка: манифест, подпись, коммит, тег, push.
#
#   release.sh <minor|patch|major|vX.Y.Z> -m "что изменилось" [опции]
#     --reset-state   роутеры сбросят кэш автоподбора стратегий
#     --skip-tests    не гонять openwrt/tests/run.sh (не рекомендуется)
#     --no-push       всё локально, без git push (проверить перед выпуском)
#
# Ключ: Z2K_OW_SIGNING_KEY (по умолчанию ~/.z2k-openwrt-signing/z2k-update.key).
# Подпись сверяется с openwrt/etc/z2k-update.pub — релиз чужим ключом не выйдет.
#
# Порядок публикации: сначала тег (по нему роутеры качают файлы), потом ветка
# с манифестом — манифест не может сослаться на ещё не опубликованный тег.
set -eu

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$ROOT"
. openwrt/lib/manifest.sh
. openwrt/lib/layout.sh
. openwrt/lib/channel.sh

die() { echo "release: $*" >&2; exit 1; }

BUMP=""; DESC=""; RESET=0; TESTS=1; PUSH=1
while [ $# -gt 0 ]; do
	case "$1" in
		-m) DESC="$2"; shift ;;
		--reset-state) RESET=1 ;;
		--skip-tests) TESTS=0 ;;
		--no-push) PUSH=0 ;;
		minor|patch|major|v[0-9]*) BUMP="$1" ;;
		*) die "неизвестный аргумент: $1" ;;
	esac
	shift
done
[ -n "$BUMP" ] || die "укажите minor|patch|major|vX.Y.Z"
[ -n "$DESC" ] || die "укажите описание: -m \"…\""
case "$DESC" in *"	"*) die "в описании не должно быть табуляции" ;; esac

KEY="${Z2K_OW_SIGNING_KEY:-$HOME/.z2k-openwrt-signing/z2k-update.key}"
PUB=openwrt/etc/z2k-update.pub
MF=openwrt/release/manifest
[ -f "$KEY" ] || die "нет ключа подписи: $KEY (openwrt/maint/sign.sh keygen)"
[ -f "$PUB" ] || die "нет публичного ключа канала: $PUB"
[ "$(git rev-parse --abbrev-ref HEAD)" = "$Z2K_OW_BRANCH" ] || die "релиз выпускается с ветки $Z2K_OW_BRANCH"
[ -z "$(git status --porcelain)" ] || die "рабочее дерево не чистое — закоммитьте изменения"

# --- версия и seq ---
prev_ver=""; prev_seq=0
if [ -f "$MF" ]; then prev_ver=$(ow_mf_get "$MF" version); prev_seq=$(ow_mf_get "$MF" seq); fi
case "$BUMP" in
	v*) VER="$BUMP" ;;
	*)
		[ -n "$prev_ver" ] || die "первого релиза ещё нет — укажите версию явно (v1.0.0)"
		IFS=. read -r ma mi pa <<EOF
${prev_ver#v}
EOF
		case "$BUMP" in
			major) VER="v$((ma + 1)).0.0" ;;
			minor) VER="v$ma.$((mi + 1)).0" ;;
			patch) VER="v$ma.$mi.$((pa + 1))" ;;
		esac ;;
esac
echo "$VER" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' || die "версия не vX.Y.Z: $VER"
git rev-parse -q --verify "refs/tags/$VER" >/dev/null && die "тег $VER уже есть"
SEQ=$((prev_seq + 1))
UPSTREAM=$(sed -n 's/^upstream_base=//p' openwrt/UPSTREAM)
[ -n "$UPSTREAM" ] || die "нет upstream_base в openwrt/UPSTREAM"

if [ "$TESTS" = 1 ]; then
	echo "== тесты"
	dash openwrt/tests/run.sh >/dev/null 2>&1 || sh openwrt/tests/run.sh || die "тесты не прошли"
fi

# --- манифест ---
mkdir -p "$(dirname "$MF")"   # к первому релизу каталога ещё нет
git ls-files | sh openwrt/maint/build-manifest.sh "$ROOT" "$VER" "$SEQ" "$UPSTREAM" "$RESET" "$DESC" "$MF" > "$MF.new"
mv -f "$MF.new" "$MF"
TAB=$(printf '	')
ow_mf_valid "$MF" || die "собранный манифест невалиден"

sh openwrt/maint/sign.sh sign "$KEY" "$MF" >/dev/null
sh openwrt/maint/usign-verify.sh -V -q -m "$MF" -p "$PUB" -x "$MF.sig" ||
	{ git checkout -- "$MF" "$MF.sig" 2>/dev/null || true; die "подпись не сходится с $PUB — не тот ключ?"; }

echo "== $VER (seq $SEQ, z2k $UPSTREAM): файлов $(grep -c "^file$TAB" "$MF")"
git add "$MF" "$MF.sig"
git commit -q -m "release: $VER — $DESC"
git tag -a "$VER" -m "$VER — $DESC"

if [ "$PUSH" = 1 ]; then
	git push -q origin "$VER"
	git push -q origin "$Z2K_OW_BRANCH"
	echo "опубликовано: $VER"
else
	echo "локально: коммит и тег $VER (без push). Отменить: git tag -d $VER && git reset --hard HEAD~1"
fi
