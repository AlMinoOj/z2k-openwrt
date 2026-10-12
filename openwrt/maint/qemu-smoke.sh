#!/bin/sh
# qemu-smoke.sh — проверка сборки на чистом OpenWrt в QEMU (x86_64).
#
#   qemu-smoke.sh <образ.img.gz|.img> [--modules "tg rtproxy"] [--port 2240]
#                 [--keep] [--no-reboot]
#
# Образ — официальный x86-64 generic-ext4-combined нужной версии
# (downloads.openwrt.org/releases/<версия>/targets/x86/64/). Запуск на копии,
# образ не меняется. Шаги:
#   1. бандл из рабочего дерева (make-bundle.sh --with-engine --arch x86_64);
#   2. ВМ с двумя сетями (LAN 192.168.1.0/24, WAN — slirp с выходом наружу);
#   3. вход root по SSH без пароля (так у свежего OpenWrt), установка;
#   4. router-smoke.sh: служба, nft, очередь, трафик через nfqws2, перезапуски,
#      cron, обновлятор, диагностика, панель, модули;
#   5. перезагрузка — z2k поднимается сам (router-smoke.sh ещё раз);
#   6. удаление — следов не остаётся.
#
# Хост: qemu-system-x86_64, ssh, gzip, git; Windows (Git Bash) или Linux.
# Переменные: QEMU — путь к qemu-system-x86_64; ACCEL — tcg|kvm|whpx (по
# умолчанию kvm, если есть /dev/kvm, иначе tcg); Z2K_SMOKE_DIR — рабочий каталог.
#
# Сеть slirp сама завершает TCP, поэтому обход DPI здесь не проверить —
# только механику. Код выхода: 0 — всё прошло.
set -u

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
IMG=""; MODS="tg"; PORT=2240; KEEP=0; REBOOT=1
while [ $# -gt 0 ]; do
	case "$1" in
		--modules) MODS="$2"; shift ;;
		--port) PORT="$2"; shift ;;
		--keep) KEEP=1 ;;
		--no-reboot) REBOOT=0 ;;
		-h|--help) sed -n '2,24p' "$0"; exit 0 ;;
		*) IMG="$1" ;;
	esac
	shift
done
[ -n "$IMG" ] && [ -f "$IMG" ] || { echo "нужен образ OpenWrt x86-64 (.img.gz или .img)" >&2; exit 2; }

QEMU="${QEMU:-$(command -v qemu-system-x86_64 || command -v qemu-system-x86_64.exe || echo "/c/Program Files/qemu/qemu-system-x86_64.exe")}"
[ -x "$QEMU" ] || { echo "не найден qemu-system-x86_64 (переменная QEMU)" >&2; exit 2; }
[ -n "${ACCEL:-}" ] || { [ -w /dev/kvm ] && ACCEL=kvm || ACCEL=tcg; }
W="${Z2K_SMOKE_DIR:-$(mktemp -d)}"; mkdir -p "$W"
LOG="$W/smoke.log"
winpath() { command -v cygpath >/dev/null 2>&1 && cygpath -w "$1" || echo "$1"; }

SSHO="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 -o PreferredAuthentications=none,publickey"
vm() { ssh $SSHO -p "$PORT" root@127.0.0.1 "$@"; }
say() { echo "[smoke] $*" | tee -a "$LOG"; }
QPID=""
stop_vm() { [ -n "$QPID" ] && kill "$QPID" 2>/dev/null; QPID=""; }
cleanup() { stop_vm; [ "$KEEP" = 1 ] || rm -rf "$W"; }
trap cleanup EXIT INT TERM

wait_ssh() { # <секунд>
	local t="$1"
	while [ "$t" -gt 0 ]; do
		vm true 2>/dev/null && return 0
		kill -0 "$QPID" 2>/dev/null || { say "QEMU завершился"; return 1; }
		sleep 5; t=$((t - 5))
	done
	return 1
}

fails=0
step() { # <описание> <rc>
	if [ "$2" = 0 ]; then say "ok    $1"; else say "FAIL  $1"; fails=$((fails + 1)); fi
}

: > "$LOG"
say "образ: $(basename "$IMG"), ускорение: $ACCEL, модули: ${MODS:-none}, каталог: $W"

# --- 1. бандл -------------------------------------------------------------------------
sh "$ROOT/openwrt/maint/make-bundle.sh" "$W/bundle.tar.gz" --with-engine --arch x86_64 >>"$LOG" 2>&1
step "бандл собран" $?
[ -s "$W/bundle.tar.gz" ] || exit 1

# --- 2. ВМ -------------------------------------------------------------------------------
case "$IMG" in
	*.gz) gzip -dc "$IMG" > "$W/disk.img" 2>/dev/null ;;  # у образов OpenWrt «trailing garbage» — норма
	*) cp "$IMG" "$W/disk.img" ;;
esac
[ -s "$W/disk.img" ] || { say "образ не распаковался"; exit 1; }
"$QEMU" -M q35 -m 512 -smp 2 -accel "$ACCEL" \
	-drive file="$(winpath "$W/disk.img")",format=raw,if=virtio \
	-netdev user,id=lan,net=192.168.1.0/24,host=192.168.1.2,dhcpstart=192.168.1.100,hostfwd=tcp:127.0.0.1:$PORT-192.168.1.1:22 \
	-device virtio-net-pci,netdev=lan \
	-netdev user,id=wan -device virtio-net-pci,netdev=wan \
	-display none -serial file:"$(winpath "$W/serial.log")" >>"$LOG" 2>&1 &
QPID=$!
wait_ssh 400; step "ВМ загрузилась, SSH без пароля" $?
[ "$fails" = 0 ] || exit 1
say "$(vm "sed -n \"s/^DISTRIB_DESCRIPTION='\(.*\)'/\1/p\" /etc/openwrt_release")"

# --- 3. установка ------------------------------------------------------------------------
vm 'rm -rf /tmp/z2k && mkdir -p /tmp/z2k && tar -xzf - -C /tmp/z2k' < "$W/bundle.tar.gz"
step "бандл в ВМ" $?
vm "Z2K_OW_ENGINE_TGZ=/tmp/z2k/engine.tar.gz Z2K_OW_MODULES='${MODS:-none}' sh /tmp/z2k/openwrt/install.sh" >>"$LOG" 2>&1
step "install.sh" $?
vm 'rm -rf /tmp/z2k'

# --- 4. проверки --------------------------------------------------------------------------
sleep 10   # модули и панель стартуют фоном
vm 'sh -s' < "$ROOT/openwrt/maint/router-smoke.sh" 2>&1 | tee -a "$LOG" | grep -v '^ok '
rc=$(grep -c '^FAIL' "$LOG"); step "router-smoke.sh после установки" "$rc"

# --- 5. перезагрузка ------------------------------------------------------------------------
if [ "$REBOOT" = 1 ]; then
	vm reboot >/dev/null 2>&1
	sleep 20
	wait_ssh 400; step "перезагрузка" $?
	t=120; while [ $t -gt 0 ] && ! vm 'pidof nfqws2' >/dev/null 2>&1; do sleep 5; t=$((t - 5)); done
	sleep 15
	before=$(grep -c '^FAIL' "$LOG")
	vm 'Z2K_SMOKE_RESTART=0 sh -s' < "$ROOT/openwrt/maint/router-smoke.sh" 2>&1 | tee -a "$LOG" | grep -v '^ok '
	step "router-smoke.sh после перезагрузки (автозапуск)" $(( $(grep -c '^FAIL' "$LOG") - before ))
fi

# --- 6. удаление ----------------------------------------------------------------------------
vm 'sh /opt/zapret2/openwrt/uninstall.sh' >>"$LOG" 2>&1
step "uninstall.sh" $?
left=$(vm 'for t in zapret2 z2k_tg z2k_rtproxy z2k_warp z2k_warpd z2k_detect; do nft list table inet $t >/dev/null 2>&1 && echo "nft:$t"; done
	for p in nfqws2 tg-mtproxy-client z2k-rt-proxy z2k-warpd z2k-detect lighttpd; do pidof $p >/dev/null && echo "процесс:$p"; done
	grep -q z2k-openwrt /etc/crontabs/root 2>/dev/null && echo cron
	ls /etc/init.d/z2k* /usr/bin/z2k-update /usr/bin/z2k-module /etc/hotplug.d/iface/90-z2k 2>/dev/null
	[ -d /opt/zapret2 ] && echo /opt/zapret2
	uci -q show dhcp | grep -q z2k_ && echo uci-dhcp
	true' 2>&1)
[ -z "$left" ]; step "после удаления следов нет${left:+: $(echo $left)}" $?

stop_vm
say "итог: $([ "$fails" = 0 ] && echo ВСЁ ПРОШЛО || echo "ПАДЕНИЙ: $fails"); журнал: $LOG$([ "$KEEP" = 1 ] || echo ' (удаляется, --keep — оставить)')"
[ "$fails" = 0 ]
