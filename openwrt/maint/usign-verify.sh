#!/bin/sh
# usign-verify.sh — проверка подписи формата usign через openssl (там, где
# usign нет: машина мейнтейнера, CI, тесты). Интерфейс — подмножество usign:
#   usign-verify.sh -V [-q] -m <файл> -p <ключ.pub> -x <файл.sig>
# Код возврата 0 — подпись верна.
set -u
m=""; p=""; x=""
while [ $# -gt 0 ]; do
	case "$1" in
		-V|-q) ;;
		-m) m="$2"; shift ;;
		-p) p="$2"; shift ;;
		-x) x="$2"; shift ;;
		*) echo "usign-verify.sh: неизвестный аргумент $1" >&2; exit 2 ;;
	esac
	shift
done
[ -f "$m" ] && [ -f "$p" ] && [ -f "$x" ] || exit 1

t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
sed -n 2p "$p" | base64 -d > "$t/pub" 2>/dev/null || exit 1
sed -n 2p "$x" | base64 -d > "$t/sig" 2>/dev/null || exit 1
[ "$(wc -c < "$t/pub")" -eq 42 ] && [ "$(wc -c < "$t/sig")" -eq 74 ] || exit 1
[ "$(head -c 2 "$t/pub")" = Ed ] && [ "$(head -c 2 "$t/sig")" = Ed ] || exit 1
# Номер ключа в подписи обязан совпасть с номером ключа (как в usign).
[ "$(head -c 10 "$t/pub" | tail -c 8 | od -An -tx1)" = "$(head -c 10 "$t/sig" | tail -c 8 | od -An -tx1)" ] || exit 1

# DER SubjectPublicKeyInfo для Ed25519: фиксированный префикс + 32 байта ключа.
{ printf '\060\052\060\005\006\003\053\145\160\003\041\000'; tail -c 32 "$t/pub"; } > "$t/pub.der"
tail -c 64 "$t/sig" > "$t/sig.raw"
openssl pkeyutl -verify -pubin -keyform DER -inkey "$t/pub.der" -rawin -in "$m" -sigfile "$t/sig.raw" >/dev/null 2>&1
