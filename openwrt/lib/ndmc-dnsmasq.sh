# ndmc-dnsmasq.sh — замена `ndmc ip host` (Keenetic) записями dnsmasq OpenWrt.
#
# Подключается хуком (`# OPENWRT:`) в files/z2k-insta-ip-refresh.sh: тот
# закрепляет рабочие адреса Instagram/WhatsApp статическими DNS-записями
# роутера через ndmc. Здесь — функция ndmc с тем же интерфейсом (функция
# перекрывает команду), но только для команд этого скрипта, и только внутри
# него: остальной код z2k по-прежнему видит, что ndmc нет.
#
# Записи — секции `config domain` в UCI dhcp с именами z2k_ig_* (видны в
# LuCI, «Имена хостов»); dnsmasq отдаёт все адреса одного имени.

[ -r /etc/openwrt_release ] || [ -n "${Z2K_OW_NDMC_TEST:-}" ] || return 0

_ow_ig_sections() { # -> «секция имя адрес»
	uci -q show dhcp | awk -F'[.=]' '
		$2 ~ /^z2k_ig_/ && $3 == "name" { n[$2] = $0; sub(/^[^=]*=/, "", n[$2]); gsub(/\x27/, "", n[$2]) }
		$2 ~ /^z2k_ig_/ && $3 == "ip"   { a[$2] = $0; sub(/^[^=]*=/, "", a[$2]); gsub(/\x27/, "", a[$2]) }
		END { for (s in n) if (s in a) print s, n[s], a[s] }'
}

ndmc()
{
	[ "${1:-}" = -c ] || return 1
	set -- $2
	case "$*" in
		"show running-config")
			_ow_ig_sections | while read -r s h ip; do echo "ip host $h $ip"; done ;;
		"system configuration save")
			uci -q commit dhcp && /etc/init.d/dnsmasq reload >/dev/null 2>&1 ;;
		"ip host "*)
			local s
			s="z2k_ig_$(printf '%s %s' "$3" "$4" | md5sum | cut -c1-12)"
			uci -q batch <<EOF
set dhcp.$s=domain
set dhcp.$s.name='$3'
set dhcp.$s.ip='$4'
EOF
			;;
		"no ip host "*)
			local s h ip found=1
			for s in $(_ow_ig_sections | awk -v h="$4" -v ip="$5" '$2 == h && $3 == ip { print $1 }'); do
				uci -q delete "dhcp.$s" && found=0
			done
			return $found ;;
		*) return 1 ;;
	esac
}
