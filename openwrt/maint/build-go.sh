#!/bin/sh
# build-go.sh — собрать наши Go-бинарники (код пропатчен под nftables) во
# все арки из build-matrix.tsv, в openwrt/builds/.
#
#   build-go.sh z2k-detect|z2k-warpd|all
#
# Отдельно от апстримных */builds/, чтобы бинарники не конфликтовали при
# merge: после синхронизации, если upstream-sync показал правки в исходниках
# z2k-detect/ или z2k-warpd/, — пересобрать этим скриптом и закоммитить.
#
# Тулчейн пиннится как у апстрима: Go 1.26+ неверно компилирует MIPS
# soft-float (z2k-detect/Makefile). Флаги — те же, сборка воспроизводима.
set -eu

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
GO="${GO:-$HOME/go/bin/go1.25.13}"
OUT="$ROOT/openwrt/builds"
command -v "$GO" >/dev/null 2>&1 || [ -x "$GO" ] || { echo "нет тулчейна $GO (go install golang.org/dl/go1.25.13@latest && go1.25.13 download)" >&2; exit 1; }

case "${1:-}" in
	z2k-detect|z2k-warpd) MODS="$1" ;;
	all) MODS="z2k-detect z2k-warpd" ;;
	*) sed -n '2,12p' "$0" >&2; exit 2 ;;
esac

mkdir -p "$OUT"
for mod in $MODS; do
	# Колонки build-matrix.tsv: модуль пакет каталог префикс GOARCH суффикс доп_переменные
	grep -v '^#' "$ROOT/build-matrix.tsv" | awk -F '\t' -v m="$mod" '$1 == m' |
	while IFS="$(printf '\t')" read -r m pkg dir prefix goarch suffix extra; do
		[ -n "$goarch" ] || continue
		out="$OUT/$prefix-linux-$suffix"
		env_extra=""; [ "$extra" != "-" ] && env_extra="$extra"
		printf '%-10s %-9s %-10s %s ... ' "$mod" "$goarch" "$suffix" "${env_extra:-}"
		# shellcheck disable=SC2086
		( cd "$ROOT/$mod" && env CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" $env_extra \
			"$GO" build -ldflags="-s -w" -trimpath -buildvcs=false -o "$out" "$pkg" )
		echo "$(du -k "$out" | cut -f1) КБ"
	done
done
