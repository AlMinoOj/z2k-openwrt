#!/bin/sh
# make-bundle.sh — бандл для установки без сети до GitHub (тест на роутере,
# QEMU): только файлы, которые едут на роутер (openwrt/lib/layout.sh), плюс
# по желанию архив движка.
#
#   make-bundle.sh [выходной.tar.gz] [--with-engine] [--arch <пакетная арка>]
#   --arch mipsel_24kc — положить сборки модулей (tg, rtproxy, …) под эту арку
#
# На роутере:
#   mkdir /tmp/z2k && tar -xzf z2k-bundle.tar.gz -C /tmp/z2k
#   sh /tmp/z2k/openwrt/install.sh            (движок скачается по пину)
#   Z2K_OW_ENGINE_TGZ=/tmp/z2k/engine.tar.gz sh /tmp/z2k/openwrt/install.sh
set -eu

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
OUT="${1:-$ROOT/z2k-bundle.tar.gz}"
case "$OUT" in --with-engine) OUT="$ROOT/z2k-bundle.tar.gz" ;; esac
WITH_ENGINE=0; ARCH=""; prev=""
for a in "$@"; do
	[ "$a" = --with-engine ] && WITH_ENGINE=1
	[ "$prev" = --arch ] && ARCH="$a"
	prev="$a"
done

. "$ROOT/openwrt/lib/layout.sh"
. "$ROOT/openwrt/lib/engine.sh"
. "$ROOT/openwrt/lib/platform.sh"
. "$ROOT/openwrt/lib/modules.sh"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

# Только отслеживаемые git файлы: мусор рабочего дерева в бандл не попадает.
git -C "$ROOT" ls-files | while IFS= read -r f; do
	[ -n "$(ow_layout_targets "$f")" ] || continue
	ow_layout_is_build "$f" && continue
	mkdir -p "$STAGE/$(dirname "$f")"
	cp "$ROOT/$f" "$STAGE/$f"
done

if [ -n "$ARCH" ]; then
	all=$(git -C "$ROOT" ls-files '*/builds/*')
	for m in $OW_ALL_MODULES; do
		p=$(ow_module_build_for_arch "$m" "$all" "$ARCH") || { echo "модуль $m: нет сборки под $ARCH"; continue; }
		mkdir -p "$STAGE/$(dirname "$p")"; cp "$ROOT/$p" "$STAGE/$p"
		echo "модуль $m: $p"
	done
fi

if [ "$WITH_ENGINE" = 1 ]; then
	ow_engine_fetch "$ROOT/openwrt/engine.pin" "$STAGE/engine.tar.gz"
fi

( cd "$STAGE" && tar -czf "$OUT" . )
echo "бандл: $OUT ($(du -k "$OUT" | cut -f1) КБ, файлов: $(find "$STAGE" -type f | wc -l))"
