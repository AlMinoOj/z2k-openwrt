# z2k-openwrt — форк z2k под OpenWrt

Отвечай пользователю по-русски. План и статус фаз: [openwrt/docs/PLAN.md](openwrt/docs/PLAN.md).
В конце сессии отметь сделанное в PLAN.md (чекбоксы/статус фазы).

## Главное

- Форк `necronicle/z2k` (`z2k-enhanced`), remote `upstream`. Рабочая ветка `main`. Точка ответвления `p-86.19`.
- Версии форка `vX.Y.Z` с `v1.0.0`. Теги апстрима (`p-*`, `r-*`) в origin не пушить.
- Апстрим вливает мейнтейнер вручную раз в неделю. Роутеры пользователей НИКОГДА не должны тянуть что-либо с `necronicle/*` или `bol-van/*` в рантайме (кроме пина движка по sha, зафиксированного в репозитории).
- Приватный ключ подписи — только у мейнтейнера. Claude его не генерирует и не видит.

## Правила правок (чтобы merge апстрима был дешёвым)

- OpenWrt-код — в `openwrt/`. Файлы апстрима не трогать, если можно переопределить переменную/функцию после `source`.
- Keenetic-only файлы не удалять: исключать из поставки через `openwrt/compat-map.tsv`.
- Неизбежная правка апстримного файла: точечно, с маркером `# OPENWRT:`, и файл помечается `patched` в `openwrt/compat-map.tsv`.
- README форка — `.github/README.md`.
- POSIX sh под busybox ash; nftables (fw4), procd, UCI. Целевые OpenWrt: 23.05, 24.10 (opkg), 25.x (apk).

## Справка по апстриму

- Устройство: `ARCHITECTURE.md`, релизы: `RELEASING.md`.
- Генератор стратегий: `lib/config_official.sh` (`create_official_config`, `generate_nfqws2_opt_from_strategies`), `lib/strategies.sh`.
- Init движка Keenetic: `files/S99zapret2.new` (порядок Lua `:942-1050`, правила `:2296-2441`).
- Обновлятор: `lib/auto_update.sh` (converge `:2339-2483`), карта путей `lib/release_map.sh`, манифест `UPDATES.json`.
- Движок: `necronicle/zapret2-z2k` openwrt-embedded, пин в `lib/install.sh:1897-1903`.
