#!/bin/sh
# sign.sh — ключ и подпись манифеста форка в формате usign (OpenWrt).
#
# Роутер проверяет подпись встроенным usign (Ed25519, им же подписаны
# пакетные фиды OpenWrt) — без openssl и лишних бинарников на роутере.
# Подписывает мейнтейнер у себя обычным openssl 3.x: Ed25519 — тот же,
# меняется только упаковка (usign = формат signify):
#   публичный ключ: base64("Ed" | keynum[8] | pubkey[32])
#   подпись:        base64("Ed" | keynum[8] | sig[64])
# keynum — первые 8 байт sha256(pubkey): связывает подпись с ключом.
#
#   sign.sh keygen [каталог]        приватный ключ (PEM) + публичный в формате usign
#                                   по умолчанию ~/.z2k-openwrt-signing
#   sign.sh pub <key.pem> <out.pub> публичный ключ usign из приватного
#   sign.sh sign <key.pem> <файл>   -> <файл>.sig
#
# Приватный ключ НИКОГДА не кладётся в репозиторий (.gitignore апстрима
# режет *.key, но держите ключ вне дерева вовсе).

set -eu

die() { echo "sign.sh: $*" >&2; exit 1; }
command -v openssl >/dev/null || die "нужен openssl 3.x"

b64() { base64 | tr -d '\n'; }

# raw 32-байтный публичный ключ из приватного PEM (хвост DER SubjectPublicKeyInfo)
pub_raw() { openssl pkey -in "$1" -pubout -outform DER 2>/dev/null | tail -c 32; }

keynum_of_pubfile() { # $1 — файл с raw pubkey
	openssl dgst -sha256 -binary "$1" | head -c 8
}

make_pub() { # <key.pem> <out.pub>
	local t; t=$(mktemp -d)
	pub_raw "$1" > "$t/pub"
	[ "$(wc -c < "$t/pub")" -eq 32 ] || { rm -rf "$t"; die "это не ключ Ed25519: $1"; }
	keynum_of_pubfile "$t/pub" > "$t/kn"
	{ printf 'untrusted comment: z2k-openwrt update key\n'
	  { printf 'Ed'; cat "$t/kn" "$t/pub"; } | b64; printf '\n'; } > "$2"
	rm -rf "$t"
}

case "${1:-}" in
	keygen)
		dir="${2:-$HOME/.z2k-openwrt-signing}"
		[ -e "$dir/z2k-update.key" ] && die "ключ уже есть: $dir/z2k-update.key (не перезаписываю)"
		mkdir -p "$dir"; chmod 700 "$dir" 2>/dev/null || true
		( umask 077; openssl genpkey -algorithm ed25519 -out "$dir/z2k-update.key" )
		make_pub "$dir/z2k-update.key" "$dir/z2k-update.pub"
		echo "приватный ключ: $dir/z2k-update.key  (храните вне репозитория, сделайте резервную копию)"
		echo "публичный ключ: $dir/z2k-update.pub  -> скопируйте в openwrt/etc/z2k-update.pub"
		;;
	pub)
		[ $# -eq 3 ] || die "usage: sign.sh pub <key.pem> <out.pub>"
		make_pub "$2" "$3"
		;;
	sign)
		[ $# -eq 3 ] || die "usage: sign.sh sign <key.pem> <файл>"
		key="$2"; f="$3"; t=$(mktemp -d)
		pub_raw "$key" > "$t/pub"
		[ "$(wc -c < "$t/pub")" -eq 32 ] || { rm -rf "$t"; die "это не ключ Ed25519: $key"; }
		keynum_of_pubfile "$t/pub" > "$t/kn"
		openssl pkeyutl -sign -inkey "$key" -rawin -in "$f" -out "$t/sig"
		[ "$(wc -c < "$t/sig")" -eq 64 ] || { rm -rf "$t"; die "подпись не 64 байта"; }
		{ printf 'untrusted comment: signed by z2k-openwrt maintainer\n'
		  { printf 'Ed'; cat "$t/kn" "$t/sig"; } | b64; printf '\n'; } > "$f.sig"
		rm -rf "$t"
		echo "подпись: $f.sig"
		;;
	*) sed -n '2,18p' "$0" >&2; exit 2 ;;
esac
