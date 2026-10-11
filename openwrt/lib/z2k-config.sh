#!/bin/sh
# z2k-config.sh — генерация стратегий и конфига движка библиотеками z2k
# (lib/strategies.sh, lib/config.sh, lib/config_official.sh) без установщика
# Keenetic. Порядок шагов — как в z2k.sh + lib/install.sh:
#
#   1. strats_new2.txt / quic_strats.ini -> strategies.conf / quic_strategies.conf
#   2. download_domain_lists: поставляемые снимки -> живые хостлисты
#   3. create_base_config: strategies.conf -> CONFIG_DIR
#   4. create_default_strategy_files: боевые пулы по категориям
#   5. create_official_config: /opt/zapret2/config с NFQWS2_OPT
#
# Шаг apply_autocircular_strategies (перезапуск службы) — отдельно,
# ow_z2k_apply_strategies: зовётся, когда init уже на месте.
#
# Окружение для библиотек z2k: пути у них `${VAR:-умолчание}`, умолчания
# совпадают с нашими, кроме INIT_SCRIPT и FWTYPE.

ow_z2k_env()
{
	export ZAPRET2_DIR="${ZAPRET2_DIR:-/opt/zapret2}"
	export ZAPRET_BASE="$ZAPRET2_DIR"
	export CONFIG_DIR="${CONFIG_DIR:-/opt/etc/zapret2}"
	export LISTS_DIR="${LISTS_DIR:-$ZAPRET2_DIR/lists}"
	export WORK_DIR="${WORK_DIR:-/tmp/z2k-work}"
	export LIB_DIR="${LIB_DIR:-$ZAPRET2_DIR/lib}"
	export INIT_SCRIPT="${INIT_SCRIPT:-/etc/init.d/z2k}"
	export Z2K_INIT_SCRIPT="$INIT_SCRIPT"
	# Генератор берёт FWTYPE для решения по IPv6 (по умолчанию iptables —
	# Keenetic). На OpenWrt 23.05+ — nftables (fw4).
	export FWTYPE="${FWTYPE:-nftables}"
	export FLOWOFFLOAD="${FLOWOFFLOAD:-none}"
	# Откуда рантайм z2k (z2k-update-lists.sh и др.) тянет файлы репозитория:
	# генератор пишет это в конфиг как Z2K_GITHUB_RAW, по умолчанию —
	# necronicle/z2k. Роутеры форка в апстрим не ходят: только канал форка.
	. "${OW_LIB_DIR:-$ZAPRET2_DIR/openwrt/lib}/channel.sh"
	export GITHUB_RAW="$Z2K_OW_RAW_BASE/$Z2K_OW_BRANCH"
	mkdir -p "$WORK_DIR" "$CONFIG_DIR" "$LISTS_DIR"
}

ow_z2k_source_libs()
{
	. "$LIB_DIR/utils.sh" || return 1
	. "$LIB_DIR/wan.sh" || return 1
	. "$LIB_DIR/strategies.sh" || return 1
	. "$LIB_DIR/config.sh" || return 1
	. "$LIB_DIR/config_official.sh" || return 1
}

# ow_z2k_generate — шаги 1–5. В подоболочке: библиотеки z2k объявляют сотни
# функций и переменных, вызывающему они не нужны.
#
# set +u обязателен: код z2k опирается на незаданные переменные (например,
# saved_Z2K_AUTOHOSTLIST без прежнего конфига), и под `set -u` вызывающего
# heredoc генератора обрывается на полпути — конфиг выходит обрезанным при
# коде возврата 0.
ow_z2k_generate()
(
	set +u
	ow_z2k_env
	ow_z2k_source_libs || { echo "z2k-config: библиотеки z2k не подключились ($LIB_DIR)" >&2; exit 1; }

	generate_strategies_conf "$ZAPRET2_DIR/strats_new2.txt" "$WORK_DIR/strategies.conf" || exit 1
	generate_quic_strategies_conf "$ZAPRET2_DIR/quic_strats.ini" "$WORK_DIR/quic_strategies.conf" || exit 1
	download_domain_lists || exit 1
	create_base_config || exit 1
	create_default_strategy_files || exit 1
	create_official_config "$ZAPRET2_DIR/config" || exit 1
)

# Шаги обновления (как au_step_regen_* апстрима): живые хостлисты НЕ
# перезаписываются снимками — их ведут geosite и пользователь.
ow_z2k_regen_strategies()
(
	set +u
	ow_z2k_env
	ow_z2k_source_libs || exit 1
	generate_strategies_conf "$ZAPRET2_DIR/strats_new2.txt" "$CONFIG_DIR/strategies.conf" || exit 1
	generate_quic_strategies_conf "$ZAPRET2_DIR/quic_strats.ini" "$CONFIG_DIR/quic_strategies.conf" || exit 1
	create_default_strategy_files
)

ow_z2k_regen_config()
(
	set +u
	ow_z2k_env
	ow_z2k_source_libs || exit 1
	create_official_config "$ZAPRET2_DIR/config"
)

# ow_z2k_apply_strategies — финальный шаг установки z2k: пулы автоциркуляра
# по категориям, перегенерация конфига и перезапуск службы через INIT_SCRIPT.
ow_z2k_apply_strategies()
(
	set +u
	ow_z2k_env
	ow_z2k_source_libs || exit 1
	apply_autocircular_strategies --auto
)
