#!/bin/sh
# engine.sh — установка движка zapret2 (openwrt-embedded) по пину
# openwrt/engine.pin. Требует platform.sh (ow_engine_arch).
#
# Раскладка — как у install_bin.sh движка: nfq2/nfqws2, ip2net/ip2net,
# mdig/mdig. Каталог binaries/ (сборки всех арок, ~5 МБ) после выбора
# удаляется: флеш на роутерах OpenWrt маленький.

# ow_pin_get <ключ> <файл пина> — значение KEY=value (файл не исполняется).
ow_pin_get()
{
	sed -n "s/^$1=//p" "$2" | head -n 1
}

ow_sha256()
{
	sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

# ow_engine_fetch <файл пина> <куда положить архив>
ow_engine_fetch()
{
	local pin="$1" out="$2" url sha got
	url=$(ow_pin_get ENGINE_URL "$pin")
	sha=$(ow_pin_get ENGINE_SHA256 "$pin")
	[ -n "$url" ] && [ -n "$sha" ] || { echo "engine: пин неполный ($pin)" >&2; return 1; }

	if [ -s "$out" ] && [ "$(ow_sha256 "$out")" = "$sha" ]; then
		return 0
	fi
	rm -f "$out"
	curl -fsSL --retry 3 --connect-timeout 15 -o "$out" "$url" || {
		echo "engine: не скачался $url" >&2; rm -f "$out"; return 1; }
	got=$(ow_sha256 "$out")
	[ "$got" = "$sha" ] || {
		echo "engine: sha256 не совпал: ждали $sha, получили $got" >&2
		rm -f "$out"; return 1; }
	return 0
}

# ow_engine_install <архив> <файл пина> <ZAPRET_BASE> [пакетная арка]
#
# Распаковывает во временный каталог рядом с целью, кладёт бинарники своей
# арки и переносит дерево в ZAPRET_BASE поверх (файлы z2k и пользователя с
# другими именами не трогаются; конфиг движка — config.default, наш config
# не перетирается). Архив должен быть уже проверен ow_engine_fetch.
ow_engine_install()
{
	local tgz="$1" pin="$2" zd="$3" pa="${4:-}" top arch stage src b
	top=$(ow_pin_get ENGINE_TOPDIR "$pin")
	[ -n "$top" ] || { echo "engine: в пине нет ENGINE_TOPDIR" >&2; return 1; }
	arch=$(ow_engine_arch $pa) || {
		echo "engine: под архитектуру '$(ow_pkg_arch)' сборки движка нет" >&2; return 1; }

	stage="${zd%/}.engine-stage.$$"
	rm -rf "$stage"; mkdir -p "$stage" || return 1
	tar -xzf "$tgz" -C "$stage" || { echo "engine: архив не распаковался" >&2; rm -rf "$stage"; return 1; }
	src="$stage/$top"
	[ -d "$src/binaries/$arch" ] || {
		echo "engine: в архиве нет binaries/$arch" >&2; rm -rf "$stage"; return 1; }

	for b in nfq2:nfqws2 ip2net:ip2net mdig:mdig; do
		mkdir -p "$src/${b%%:*}"
		cp -f "$src/binaries/$arch/${b#*:}" "$src/${b%%:*}/${b#*:}" || { rm -rf "$stage"; return 1; }
		chmod 755 "$src/${b%%:*}/${b#*:}"
	done
	rm -rf "$src/binaries" "$src/tests"

	# Бинарник обязан запуститься на этом роутере, иначе дерево не трогаем.
	if [ -z "${Z2K_OW_SKIP_EXEC_CHECK:-}" ]; then
		"$src/nfq2/nfqws2" --version >/dev/null 2>&1 || {
			echo "engine: nfqws2 ($arch) не запускается на этом роутере" >&2
			rm -rf "$stage"; return 1; }
	fi

	mkdir -p "$zd" || { rm -rf "$stage"; return 1; }
	cp -a "$src/." "$zd/" || { echo "engine: копирование в $zd не удалось" >&2; rm -rf "$stage"; return 1; }
	rm -rf "$stage"
	ow_pin_get ENGINE_VERSION "$pin" > "$zd/.z2k-engine-version"
	return 0
}
