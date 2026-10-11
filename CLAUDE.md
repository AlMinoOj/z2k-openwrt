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
- Апстримный `.gitignore` игнорирует любой `tools/` и `*.key`: инструменты мейнтейнера — в `openwrt/maint/`. После добавления файлов проверяй `git ls-files openwrt`.
- Новый файл в репозитории = строка в `openwrt/compat-map.tsv`. Тесты: `dash openwrt/tests/run.sh`.
- POSIX sh под busybox ash; nftables (fw4), procd, UCI. Целевые OpenWrt: 23.05, 24.10 (opkg), 25.x (apk).

## Как устроен порт (фаза 2)

- Движок = `files/S99zapret2.new` (на роутере `/opt/zapret2/init.d/z2k-engine`) + хук `# OPENWRT:` → `openwrt/lib/s99-openwrt.sh` (nft, netifd, без NDM). Логику z2k не переписываем — переопределяем функции в слое.
- `/etc/init.d/z2k` — обёртка; `/opt/etc/init.d/S99zapret2` — симлинк на неё. UCI нет: источник правды `/opt/zapret2/config`.
- Генерация конфига: `openwrt/lib/z2k-config.sh` (библиотеки z2k как есть, `set +u` обязателен, `GITHUB_RAW` → канал форка).
- Раскладка файлов — только `openwrt/lib/layout.sh`. Движок — `openwrt/engine.pin` (sha архива).
- Go 1.25.13 для сборок: `~/go/bin/go1.25.13` (1.26+ ломает MIPS softfloat).
- Под Windows tar не понимает `C:/…` — передавай POSIX-пути (`/c/…`).

## Обновления (фаза 3)

- Манифест `openwrt/release/manifest` (+`.sig`, usign) собирает только `openwrt/maint/release.sh`. Ключ мейнтейнера: `~/.z2k-openwrt-signing/z2k-update.key`, публичный — `openwrt/etc/z2k-update.pub`.
- Роутер: `z2k-update` → `openwrt/lib/update.sh`; шаги по файлам — `ow_steps_for` в `openwrt/lib/manifest.sh` (новый тип файла с эффектом — сюда).
- Синхронизация: `openwrt/maint/upstream-sync.sh [тег] [--merge] [--bump-engine]`; база — `openwrt/UPSTREAM`.
- Стенд обновлений: локальный канал (`python -m http.server` на хосте, ВМ видит его как 10.0.2.2), переменные `Z2K_OW_RAW_BASE`/`Z2K_OW_CDN_BASE`.

## Модули (фаза 5)

- Go-бинарники — модули (`openwrt/lib/modules.sh`, `z2k-module`): tg, rtproxy (апстримные сборки), detect, warp (наши сборки в `openwrt/builds`, `openwrt/maint/build-go.sh`).
- Приём порта апстримного скрипта: 1 строка-хук `# OPENWRT:` перед диспетчером + слой в `openwrt/lib/*-openwrt.sh`, переопределяющий функции. Так сделаны S99 (`s99-openwrt.sh`), z2k-warp.sh (`warp-openwrt.sh`), z2k-insta-ip-refresh.sh (`ndmc-dnsmasq.sh`).
- Go-правки: только «если есть nft — наш путь, иначе iptables апстрима», маркер `// OPENWRT:`, наш код в отдельных файлах.
- nft: `policy` — зарезервированное слово; accept в своей таблице не отменяет reject fw4 (форвард — через include `chain-pre/forward`); большие сеты — через `nft -f -`.
- busybox OpenWrt: нет `pkill`, `timeout`; procd `status` = 0 и при «active with no instances».

## Справка по апстриму

- Устройство: `ARCHITECTURE.md`, релизы: `RELEASING.md`.
- Генератор стратегий: `lib/config_official.sh` (`create_official_config`, `generate_nfqws2_opt_from_strategies`), `lib/strategies.sh`.
- Init движка Keenetic: `files/S99zapret2.new` (порядок Lua `:942-1050`, правила `:2296-2441`).
- Обновлятор: `lib/auto_update.sh` (converge `:2339-2483`), карта путей `lib/release_map.sh`, манифест `UPDATES.json`.
- Движок: `necronicle/zapret2-z2k` openwrt-embedded, пин в `lib/install.sh:1897-1903`.
