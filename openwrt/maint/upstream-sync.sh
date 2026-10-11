#!/bin/sh
# upstream-sync.sh — еженедельная синхронизация с официальным z2k.
#
#   upstream-sync.sh [<тег апстрима>] [--merge] [--bump-engine]
#
# Без тега — последний релиз апстрима (current в его UPDATES.json).
# По умолчанию только ОТЧЁТ, ничего не меняет:
#   * подпись манифеста апстрима (его же ключом, files/etc/z2k-update-pub.pem);
#   * релизы апстрима в окне upstream_base..тег с описаниями;
#   * изменённые файлы по классам openwrt/compat-map.tsv:
#       portable  — едут как есть, разбирать не нужно;
#       patched   — наши правки внутри: проверить после merge;
#       replaced  — у нас замена: перенести смысл правки вручную;
#       keenetic/dev — на роутер не влияют;
#       unknown   — НОВЫЙ файл: назначить класс в compat-map.tsv;
#   * смена пина движка (lib/install.sh: fallback_url).
# --merge        git merge тега; при успехе — openwrt/UPSTREAM и коммит.
# --bump-engine  скачать новый движок апстрима, посчитать sha, обновить engine.pin.
#
# Дальше: dash openwrt/tests/run.sh, проверка в QEMU, openwrt/maint/release.sh minor.
set -eu

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$ROOT"
die() { echo "upstream-sync: $*" >&2; exit 1; }
hr()  { printf '\n== %s\n' "$*"; }

TAG=""; MERGE=0; BUMP=0
for a in "$@"; do
	case "$a" in
		--merge) MERGE=1 ;;
		--bump-engine) BUMP=1 ;;
		-*) die "неизвестный флаг $a" ;;
		*) TAG="$a" ;;
	esac
done

git remote get-url upstream >/dev/null 2>&1 || die "нет remote upstream (git remote add upstream https://github.com/necronicle/z2k.git)"
echo "fetch upstream…"
git fetch -q upstream --tags
BASE="${Z2K_SYNC_BASE:-$(sed -n "s/^upstream_base=//p" openwrt/UPSTREAM)}"
[ -n "$BASE" ] || die "нет upstream_base в openwrt/UPSTREAM"
git rev-parse -q --verify "refs/tags/$BASE" >/dev/null || die "нет тега базы $BASE"

if [ -z "$TAG" ]; then
	TAG=$(git show upstream/z2k-enhanced:UPDATES.json | sed -n 's/^  "current": "\(.*\)",$/\1/p')
	[ -n "$TAG" ] || die "не удалось прочитать current из UPDATES.json апстрима"
fi
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "нет тега $TAG"
echo "база форка: $BASE  ->  апстрим: $TAG"
[ "$BASE" = "$TAG" ] && { echo "форк уже на $TAG — синхронизировать нечего"; exit 0; }
git merge-base --is-ancestor "$BASE" "$TAG" || die "$TAG не потомок $BASE — что-то не так с историей апстрима"

# --- подпись апстрима ---
hr "подпись манифеста апстрима"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
git show "$TAG:UPDATES.json" > "$T/m"
git show "$TAG:UPDATES.json.sig" > "$T/sig" 2>/dev/null || true
git show "$TAG:files/etc/z2k-update-pub.pem" > "$T/pub"
# ключ апстрима не должен смениться молча
if ! git diff --quiet "$BASE" "$TAG" -- files/etc/z2k-update-pub.pem; then
	echo "ВНИМАНИЕ: апстрим СМЕНИЛ ключ подписи в окне — проверьте вручную, прежде чем доверять"
fi
if [ -s "$T/sig" ] && openssl pkeyutl -verify -pubin -inkey "$T/pub" -rawin -in "$T/m" -sigfile "$T/sig" >/dev/null 2>&1; then
	echo "OK: UPDATES.json $TAG подписан ключом апстрима"
else
	echo "ВНИМАНИЕ: подпись UPDATES.json $TAG НЕ сошлась (или её нет)"
fi

# --- релизы в окне ---
hr "релизы апстрима после $BASE"
grep '^{"v": ' "$T/m" | awk -v base="$BASE" 'f { print } $0 ~ "^\\{\"v\": \"" base "\"" { f = 1 }' |
	sed -e 's/^{"v": "\([^"]*\)", "type": "\([^"]*\)", "ts": "\([^T"]*\)[^"]*".*"desc": "\(.*\)", "changed_files".*/\1 [\2] \3 — \4/' \
	    -e 's/\\n/ /g' | cut -c1-400

# --- файлы по классам ---
hr "изменённые файлы по классам compat-map"
# Удалённые в апстриме — отдельно: их класс уже не важен, важно не держать
# у себя ссылок на них (layout, compat-map).
git diff --name-only --diff-filter=D "$BASE" "$TAG" > "$T/deleted"
git diff --name-only --diff-filter=d "$BASE" "$TAG" | sh openwrt/maint/compat-check.sh --stdin > "$T/cls"
if [ -s "$T/deleted" ]; then
	echo "-- удалены в апстриме ($(wc -l < "$T/deleted" | tr -d ' ')): уберите их строки из compat-map/layout, если были"
	sed 's/^/   /' "$T/deleted" | head -15
fi
for c in unknown replaced patched portable keenetic dev; do
	cnt=$(awk -F '\t' -v c="$c" '$1 == c' "$T/cls" | wc -l | tr -d ' ')
	[ "$cnt" -gt 0 ] || continue
	case "$c" in
		unknown)  note="НОВЫЕ — назначьте класс в openwrt/compat-map.tsv" ;;
		replaced) note="у нас замена — перенесите смысл вручную" ;;
		patched)  note="наши правки внутри — проверить после merge" ;;
		portable) note="едут как есть" ;;
		*)        note="на роутер не влияют" ;;
	esac
	echo "-- $c ($cnt): $note"
	case "$c" in
		portable|keenetic|dev) awk -F '\t' -v c="$c" '$1 == c { print "   " $2 }' "$T/cls" | head -15
		                       [ "$cnt" -gt 15 ] && echo "   … и ещё $((cnt - 15))" ;;
		*) awk -F '\t' -v c="$c" '$1 == c { print $2 }' "$T/cls" | while IFS= read -r f; do
			printf '   %-48s %s\n' "$f" "$(git diff --shortstat "$BASE" "$TAG" -- "$f" | sed 's/^ *//')"
		   done ;;
	esac
done

# --- пин движка ---
hr "движок"
pin_of() { git show "$1:lib/install.sh" | sed -n 's/^[[:space:]]*local fallback_url="\(.*\)"$/\1/p' | head -n 1; }
OLD_URL=$(pin_of "$BASE"); NEW_URL=$(pin_of "$TAG")
OUR_URL=$(sed -n 's/^ENGINE_URL=//p' openwrt/engine.pin)
echo "апстрим: $NEW_URL"
echo "у нас:   $OUR_URL"
if [ "$NEW_URL" != "$OUR_URL" ]; then
	echo "ДВИЖОК СМЕНИЛСЯ — обновите openwrt/engine.pin (--bump-engine) и проверьте в QEMU"
	if [ "$BUMP" = 1 ]; then
		curl -fsSL --retry 3 -o "$T/e.tgz" "$NEW_URL" || die "движок не скачался"
		sha=$(sha256sum "$T/e.tgz" | awk '{print $1}')
		top=$(tar -tzf "$T/e.tgz" | head -n 1 | cut -d/ -f1)
		ver=$(echo "$NEW_URL" | sed -n 's#.*/download/\([^/]*\)/.*#\1#p')
		tar -xzf "$T/e.tgz" -C "$T" "$top/binaries" 2>/dev/null; echo "сборки: $(ls "$T/$top/binaries" 2>/dev/null | tr '\n' ' ')"
		sed -i -e "s#^ENGINE_VERSION=.*#ENGINE_VERSION=$ver#" -e "s#^ENGINE_URL=.*#ENGINE_URL=$NEW_URL#" \
		       -e "s#^ENGINE_SHA256=.*#ENGINE_SHA256=$sha#" -e "s#^ENGINE_TOPDIR=.*#ENGINE_TOPDIR=$top#" openwrt/engine.pin
		echo "engine.pin обновлён: $ver ($sha) — закоммитьте после проверки"
	fi
else
	echo "без изменений"
fi

# --- merge ---
if [ "$MERGE" = 1 ]; then
	hr "merge $TAG"
	[ -z "$(git status --porcelain -- . ':!openwrt/engine.pin')" ] || die "рабочее дерево не чистое"
	if git merge --no-ff -m "upstream: merge z2k $TAG" "$TAG"; then
		sed -i "s/^upstream_base=.*/upstream_base=$TAG/" openwrt/UPSTREAM
		git add openwrt/UPSTREAM; git commit -q -m "upstream: база форка $TAG"
		echo "готово. Дальше: dash openwrt/tests/run.sh, проверка в QEMU, openwrt/maint/release.sh minor -m \"…\""
	else
		echo "КОНФЛИКТЫ. Разрешите их, затем:"
		echo "  git commit && sed -i 's/^upstream_base=.*/upstream_base=$TAG/' openwrt/UPSTREAM && git commit -am 'upstream: база форка $TAG'"
		exit 1
	fi
else
	echo; echo "отчёт готов. Слить: openwrt/maint/upstream-sync.sh $TAG --merge"
fi
