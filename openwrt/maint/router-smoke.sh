#!/bin/sh
# router-smoke.sh — проверка установленного z2k-openwrt на самом роутере.
#
# Выполняется НА РОУТЕРЕ (или в ВМ), с машины мейнтейнера — по SSH:
#   ssh root@192.168.1.1 'sh -s' < openwrt/maint/router-smoke.sh
#   ssh root@192.168.1.1 'Z2K_SMOKE_RESTART=0 sh -s' < openwrt/maint/router-smoke.sh
# В ВМ его зовёт openwrt/maint/qemu-smoke.sh.
#
# Проверяет механику, а не обход: служба, правила nft, очередь, трафик через
# демон, перезапуск, cron, обновлятор, диагностика, панель, модули.
# Работает ли обход у провайдера — только руками, на живом роутере.
#
#   Z2K_SMOKE_RESTART=0  не трогать службу (без stop/start/restart)
#   Z2K_SMOKE_URL=…      адрес для проверки трафика (по умолчанию google)
#
# Код выхода: 0 — всё прошло, 1 — есть падения.

ZD=/opt/zapret2
QNUM=200
RESTART="${Z2K_SMOKE_RESTART:-1}"
URL="${Z2K_SMOKE_URL:-https://www.google.com/generate_204}"
pass=0; fail=0

ok()   { pass=$((pass + 1)); echo "ok    $*"; }
bad()  { fail=$((fail + 1)); echo "FAIL  $*"; }
chk()  { # <описание> <команда…>
	local d="$1"; shift
	if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
note() { echo "--    $*"; }

nfqws_n()   { pidof nfqws2 | wc -w | tr -d ' '; }
queue_seq() { awk -v q=$QNUM '$1 == q { print $8 }' /proc/net/netfilter/nfnetlink_queue 2>/dev/null; }
queue_rules() { nft list table inet zapret2 2>/dev/null | grep -cE "queue .*to $QNUM([^0-9]|\$)"; }
wait_for() { # <секунд> <условие для eval>
	local t="$1"
	while [ "$t" -gt 0 ]; do eval "$2" >/dev/null 2>&1 && return 0; sleep 1; t=$((t - 1)); done
	return 1
}

echo "== z2k-openwrt smoke: $(sed -n "s/^DISTRIB_DESCRIPTION='\(.*\)'/\1/p" /etc/openwrt_release) $(sed -n "s/^DISTRIB_ARCH='\(.*\)'/\1/p" /etc/openwrt_release)"
[ -d "$ZD" ] || { bad "z2k не установлен ($ZD нет)"; exit 1; }

# --- файлы -----------------------------------------------------------------------------
synerr=""
for f in "$ZD"/*.sh "$ZD"/openwrt/lib/*.sh "$ZD"/openwrt/bin/* "$ZD"/init.d/z2k-engine /etc/init.d/z2k*; do
	[ -f "$f" ] || continue
	case "$(head -c 2 "$f")" in '#!') ;; *) case "$f" in *.sh) ;; *) continue ;; esac ;; esac
	sh -n "$f" 2>/dev/null || synerr="$synerr $f"
done
[ -z "$synerr" ] && ok "синтаксис скриптов (sh -n)" || bad "синтаксис:$synerr"
chk "конфиг /opt/zapret2/config" test -s "$ZD/config"
"$ZD/nfq2/nfqws2" --version 2>&1 | grep -q version && ok "движок nfqws2 запускается" || bad "движок nfqws2 не запускается"
chk "симлинк /opt/etc/init.d/S99zapret2" test -L /opt/etc/init.d/S99zapret2

# --- служба и правила ----------------------------------------------------------------------
chk "служба z2k в автозапуске" /etc/init.d/z2k enabled
n=$(nfqws_n)
[ "$n" = 1 ] && ok "nfqws2 запущен (1 процесс)" || bad "nfqws2: процессов $n, ждали 1"
pid=$(pidof nfqws2 | awk '{print $1}')
if [ -n "$pid" ]; then
	u=$(awk '/^Uid:/ {print $2}' /proc/$pid/status 2>/dev/null)
	[ "$u" != 0 ] && ok "nfqws2 без root (uid $u)" || bad "nfqws2 работает от root"
fi
chk "таблица nft inet zapret2" nft list table inet zapret2
r=$(queue_rules)
[ "${r:-0}" -ge 2 ] && ok "правила очереди $QNUM: $r" || bad "правил очереди $QNUM: ${r:-0}"
chk "очередь $QNUM открыта демоном" test -n "$(queue_seq)"
w=$(nft list set inet zapret2 wanif 2>/dev/null | grep -c 'elements')
[ "$w" -ge 1 ] && ok "сет wanif заполнен" || bad "сет wanif пуст — правила не привязаны к WAN"
chk "сет nozapret есть" nft list set inet zapret2 nozapret

# Трафик самого роутера идёт через демон: счётчик очереди растёт.
s1=$(queue_seq)
if curl -s -m 20 -o /dev/null "$URL" 2>/dev/null || wget -q -T 20 -O /dev/null "$URL" 2>/dev/null; then
	ok "HTTPS с роутера ($URL)"
else
	bad "HTTPS с роутера не прошёл ($URL)"
fi
s2=$(queue_seq)
[ -n "$s1" ] && [ -n "$s2" ] && [ "$s2" -gt "$s1" ] && ok "трафик прошёл через nfqws2 (+$((s2 - s1)) пакетов)" \
	|| bad "счётчик очереди не вырос ($s1 -> $s2)"

# --- перезапуск -----------------------------------------------------------------------------
if [ "$RESTART" = 1 ]; then
	/etc/init.d/z2k stop >/dev/null 2>&1
	[ "$(queue_rules)" = 0 ] && [ "$(nfqws_n)" = 0 ] && ok "stop: правила сняты, демон остановлен" \
		|| bad "stop: правил $(queue_rules), демонов $(nfqws_n)"
	/etc/init.d/z2k start >/dev/null 2>&1
	wait_for 30 '[ "$(nfqws_n)" = 1 ] && [ "$(queue_rules)" -ge 2 ]' && ok "start: демон и правила на месте" \
		|| bad "start: правил $(queue_rules), демонов $(nfqws_n)"
	/etc/init.d/z2k restart >/dev/null 2>&1 &
	/etc/init.d/z2k restart >/dev/null 2>&1
	wait
	sleep 3
	[ "$(nfqws_n)" = 1 ] && ok "два перезапуска разом: один nfqws2" || bad "два перезапуска разом: демонов $(nfqws_n)"
	fw4 reload >/dev/null 2>&1
	[ "$(queue_rules)" -ge 2 ] && ok "fw4 reload не снимает правила" || bad "после fw4 reload правил $(queue_rules)"
else
	note "перезапуск пропущен (Z2K_SMOKE_RESTART=0)"
fi

# --- планировщик, обновлятор, диагностика ---------------------------------------------------
chk "блок z2k в cron" grep -q 'z2k-openwrt BEGIN' /etc/crontabs/root
chk "crond запущен" pidof crond
st=$(z2k-update status 2>&1)
case "$st" in *"канал openwrt-main"*) ok "z2k-update status: $(echo "$st" | head -1)" ;; *) bad "z2k-update status: $st" ;; esac
chk "ключ обновлений на месте" test -s "$ZD/etc/z2k-update.pub"
d=$(sh "$ZD/z2k-diag.sh" 2>/dev/null)
v=$(printf '%s\n' "$d" | sed -n '2,/^===/p' | grep '\[!\]')
[ -z "$v" ] && ok "диагностика: явных проблем не найдено" || bad "диагностика:
$v"
printf '%s\n' "$d" | grep -q '^=== nftables ===' && ok "диагностика: слой OpenWrt подключён" || bad "диагностика без слоя OpenWrt"

# --- панель ---------------------------------------------------------------------------------
if /etc/init.d/z2k-panel enabled 2>/dev/null; then
	b=$(cat "$ZD/webpanel/bind" 2>/dev/null); p=$(cat "$ZD/webpanel/port" 2>/dev/null)
	u="http://${b:-192.168.1.1}:${p:-8088}"
	code() { curl -s -m 10 -o /dev/null -w '%{http_code}' "$@"; }
	wait_for 15 '[ "$(code "$u/")" = 200 ]'
	c=$(code "$u/"); [ "$c" = 200 ] && ok "панель $u отвечает" || bad "панель $u: $c"
	c=$(code "$u/cgi-bin/api/status"); [ "$c" = 403 ] && ok "панель: без заголовка X-Z2K-Panel — 403" || bad "панель без заголовка: $c (ждали 403)"
	c=$(code -H 'X-Z2K-Panel: 1' -H "Host: 203.0.113.1:${p:-8088}" "$u/cgi-bin/api/status"); [ "$c" = 403 ] && ok "панель: чужой Host — 403" || bad "панель с чужим Host: $c (ждали 403)"
	c=$(code -H 'X-Z2K-Panel: 1' "$u/cgi-bin/api/status")
	case "$c" in 200|401) ok "панель: API отвечает ($c)" ;; *) bad "панель: API $c" ;; esac
	# Служба пакета lighttpd (стандартный конфиг) спорит с uhttpd/LuCI за :80.
	other=0
	for lp in $(pidof lighttpd); do
		tr '\0' ' ' < /proc/$lp/cmdline 2>/dev/null | grep -q z2k-panel || other=$((other + 1))
	done
	[ "$other" = 0 ] && ok "чужого lighttpd нет" || bad "запущен lighttpd не панели ($other) — служба пакета lighttpd включена?"
else
	note "панель не включена"
fi

# --- модули ---------------------------------------------------------------------------------
z2k-module list 2>/dev/null | awk '$2 == "включён" {print $1}' | while read -r m; do
	case "$m" in
		tg)      wait_for 20 "pgrep -f 'tg-mtproxy-client .*--listen=:1443'" && echo "ok    модуль tg: туннель запущен" || echo "FAIL  модуль tg: туннель не запущен"
		         nft list chain inet z2k_tg prerouting 2>/dev/null | grep -q 'redirect to :1443' && echo "ok    модуль tg: перехват в nft" || echo "FAIL  модуль tg: нет перехвата в nft" ;;
		rtproxy) wait_for 20 "pidof z2k-rt-proxy" && echo "ok    модуль rtproxy запущен" || echo "FAIL  модуль rtproxy не запущен" ;;
		detect)  /opt/sbin/z2k-detect --help >/dev/null 2>&1; [ $? -le 2 ] && echo "ok    модуль detect запускается" || echo "FAIL  модуль detect не запускается" ;;
		warp)    test -x /opt/sbin/z2k-warpd && echo "ok    модуль warp установлен" || echo "FAIL  модуль warp: нет бинарника" ;;
	esac
done > /tmp/.z2k-smoke-mod
while read -r l; do
	echo "$l"
	case "$l" in ok*) pass=$((pass + 1)) ;; FAIL*) fail=$((fail + 1)) ;; esac
done < /tmp/.z2k-smoke-mod
rm -f /tmp/.z2k-smoke-mod

echo "== итог: прошло $pass, упало $fail"
[ "$fail" -eq 0 ]
