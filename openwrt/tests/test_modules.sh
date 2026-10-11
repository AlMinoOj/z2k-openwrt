#!/bin/sh
# Модули: выбор сборки под арку, «нужен ли файл этому роутеру».
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
. "$ROOT/openwrt/lib/platform.sh"
. "$ROOT/openwrt/lib/modules.sh"
fail=0; n=0
eq() { n=$((n + 1)); [ "$2" = "$3" ] || { fail=$((fail + 1)); echo "FAIL: $1: ждали '$2', получили '$3'"; }; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

all=$(cd "$ROOT" && git ls-files 'mtproxy-client/builds/*')
eq "tg mipsel" mtproxy-client/builds/tg-mtproxy-client-linux-mipsel "$(ow_module_build_for_arch tg "$all" mipsel_24kc)"
eq "tg x86_64" mtproxy-client/builds/tg-mtproxy-client-linux-amd64 "$(ow_module_build_for_arch tg "$all" x86_64)"
eq "rtproxy arm64" mtproxy-client/builds/z2k-rt-proxy-linux-arm64 "$(ow_module_build_for_arch rtproxy "$all" aarch64_cortex-a53)"
ow_module_build_for_arch tg "$all" arm_arm926ej-s >/dev/null; eq "tg на ARMv5 — код 2" 2 $?
ow_module_build_for_arch rtproxy "$all" riscv64_riscv64 >/dev/null; eq "rtproxy riscv64 нет" 1 $?

eq "модуль по пути" tg "$(ow_module_of_path mtproxy-client/builds/tg-mtproxy-client-linux-arm)"
eq "не модуль" "" "$(ow_module_of_path files/lua/z2k-alert.lua)"

# Манифест с двумя арками tg; включён только tg; роутер x86_64.
printf 'file\ta\t755\tmtproxy-client/builds/tg-mtproxy-client-linux-amd64\t/opt/sbin/tg-mtproxy-client\n' > "$T/mf"
printf 'file\tb\t755\tmtproxy-client/builds/tg-mtproxy-client-linux-mipsel\t/opt/sbin/tg-mtproxy-client\n' >> "$T/mf"
printf 'file\tc\t755\tmtproxy-client/builds/z2k-rt-proxy-linux-amd64\t/opt/sbin/z2k-rt-proxy\n' >> "$T/mf"
export OW_MODULES_FILE="$T/mods"
ow_module_set tg 1
printf "DISTRIB_ARCH='x86_64'\nDISTRIB_RELEASE='24.10.0'\n" > "$T/rel"; export Z2K_OW_RELEASE_FILE="$T/rel"
ow_mf_file_applies mtproxy-client/builds/tg-mtproxy-client-linux-amd64 "$T/mf"; eq "своя арка включённого — нужен" 0 $?
ow_mf_file_applies mtproxy-client/builds/tg-mtproxy-client-linux-mipsel "$T/mf"; eq "чужая арка — не нужен" 1 $?
ow_mf_file_applies mtproxy-client/builds/z2k-rt-proxy-linux-amd64 "$T/mf"; eq "выключенный модуль — не нужен" 1 $?
ow_mf_file_applies files/lua/x.lua "$T/mf"; eq "обычный файл — нужен" 0 $?
ow_module_set tg 0; eq "выключение" "" "$(ow_modules_enabled)"

echo "test_modules: $((n - fail))/$n"
[ "$fail" -eq 0 ]
