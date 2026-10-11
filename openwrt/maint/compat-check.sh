#!/bin/sh
# compat-check.sh — классификация файлов по openwrt/compat-map.tsv.
#
#   compat-check.sh                 все файлы git: сводка по классам; exit 1, если есть unknown
#   compat-check.sh --list          все файлы git: "класс<TAB>путь"
#   compat-check.sh --stdin         пути со stdin (по одному в строке): "класс<TAB>путь"
#   compat-check.sh --class X       все файлы git класса X (portable, patched, …)
#
# Шаблоны карты — glob как в shell `case` (`*` совпадает и со `/`), первое
# совпадение побеждает. Используется openwrt/maint/upstream-sync.sh.

set -eu

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
MAP="${COMPAT_MAP:-$ROOT/openwrt/compat-map.tsv}"

classify() {
	awk -F '\t' -v map="$MAP" '
	function glob2re(g,    i, c, r) {
		r = "^"
		for (i = 1; i <= length(g); i++) {
			c = substr(g, i, 1)
			if (c == "*") r = r ".*"
			else if (c == "?") r = r "."
			else if (index("\\^$.[]|()+{}", c)) r = r "\\" c
			else r = r c
		}
		return r "$"
	}
	BEGIN {
		n = 0
		while ((getline line < map) > 0) {
			if (line ~ /^#/ || line ~ /^[ \t]*$/) continue
			split(line, f, "\t")
			if (f[2] == "") { printf "compat-map: нет класса в строке: %s\n", line > "/dev/stderr"; exit 2 }
			n++; re[n] = glob2re(f[1]); cls[n] = f[2]
		}
	}
	{
		c = "unknown"
		for (i = 1; i <= n; i++) if ($0 ~ re[i]) { c = cls[i]; break }
		print c "\t" $0
	}'
}

git_files() { git -C "$ROOT" ls-files; }

case "${1:-}" in
	--list)  git_files | classify ;;
	--stdin) classify ;;
	--class)
		[ -n "${2:-}" ] || { echo "usage: $0 --class <класс>" >&2; exit 2; }
		git_files | classify | awk -F '\t' -v c="$2" '$1 == c { print $2 }' ;;
	"")
		out=$(git_files | classify)
		printf '%s\n' "$out" | awk -F '\t' '{ n[$1]++ } END { for (c in n) printf "%-9s %5d\n", c, n[c] }' | sort
		unk=$(printf '%s\n' "$out" | awk -F '\t' '$1 == "unknown" { print $2 }')
		if [ -n "$unk" ]; then
			echo "НЕ КЛАССИФИЦИРОВАНЫ (добавьте в openwrt/compat-map.tsv):" >&2
			printf '  %s\n' $unk >&2
			exit 1
		fi ;;
	*) sed -n '2,9p' "$0" >&2; exit 2 ;;
esac
