# z2k-openwrt — план портирования

Форк `necronicle/z2k` (ветка `z2k-enhanced`) под OpenWrt. Точка ответвления:
апстрим `p-86.19` (2026-10-11). Нумерация форка начинается с `v1.0.0`.

## Цели

- Полный паритет функций с z2k: обход DPI (стратегии, списки, Lua),
  вебпанель, автообновления, Telegram-туннель, HTTP-туннель, rt-proxy, WARP,
  z2k-detect.
- OpenWrt 23.05, 24.10 (opkg) и 25.x (apk); fw4/nftables.
- Архитектуры: aarch64, arm (cortex-a7 и др.), mipsel_24kc, mips_24kc, x86_64
  (+ всё, под что есть сборки движка и Go-модулей).
- Обновления пользователи получают **только из этого репозитория**. Апстрим
  сюда вливает мейнтейнер вручную раз в неделю.

## Изоляция от официального z2k

| Канал апстрима | Что делаем в форке |
|---|---|
| `UPDATES.json` + `.sig` с `necronicle/z2k` | Свой манифест, подписан **своим** Ed25519-ключом; свой `z2k-update-pub.pem`; храповик доверия фиксирует его при установке |
| `GITHUB_RAW`, jsdelivr, gh-proxy → `necronicle/z2k` | Все URL → репозиторий форка (одна переменная, см. `openwrt/lib/channel.sh`) |
| Движок: `releases/latest` из `necronicle/zapret2-z2k` | Только пин версии + sha256; бамп — осознанно, при синхронизации |
| custom.d с `bol-van/zapret2/master` | Файлы лежат в репозитории |
| Go-бинарники из `builds/` апстрима | Из `builds/` форка, sha в нашем манифесте |
| Метка канала `.z2k-branch = z2k-enhanced` | Своя метка (`openwrt-main`); с чужой меткой автообновление выключено |
| Прокси с вшитыми учётками (`lib/utils.sh:116`, `S51z2k-warp`, `z2k-warp.sh`) | Убираем |
| VPS автора 213.176.74.63 (SNI-passthrough до GitHub, relay TG, прокси WARP) | Функциональная зависимость; SNI-passthrough подменить контент не может. Решение по каждому использованию — в фазе соответствующего модуля |

## Версии

`vMAJOR.MINOR.PATCH`:
- MINOR — еженедельная синхронизация с апстримом и новые функции;
- PATCH — срочный фикс между синхронизациями;
- MAJOR — несовместимые изменения (переустановка, смена формата конфига).

В манифесте поле `upstream_base` (например `p-86.19`) — до какой версии
апстрима дотянут форк. Теги апстрима (`p-*`, `r-*`) в наш GitHub не пушим.

## Принцип раскладки кода (чтобы merge апстрима был дешёвым)

1. **Файлы апстрима по возможности не трогаем.** OpenWrt-код живёт в
   `openwrt/` (init.d, nft, uci, lib-переопределения, установщик, обновлятор,
   инструменты мейнтейнера).
2. Поведение апстримных скриптов меняем переопределением переменных и функций
   после `source` (пути у них уже `${VAR:-умолчание}`).
3. Keenetic-only файлы (`files/ndm/*`, `files/000-zapret2.sh`,
   `files/S99zapret2.new`, `files/z2k-ppe-deoffload.sh`, `lib/install.sh`,
   `z2k.sh`, `webpanel/install.sh`, `webpanel/lighttpd.conf`) **не удаляем** —
   иначе modify/delete-конфликт на каждой синхронизации. Они просто не
   попадают в поставку (наша карта путей).
4. Неизбежные правки внутри апстримных файлов — точечные, с маркером
   `# OPENWRT:` в строке или над блоком. Список таких файлов ведём в
   `openwrt/compat-map.tsv` (класс `patched`).
5. README форка — `.github/README.md` (GitHub показывает его вместо корневого,
   конфликтов с апстримом нет).

## Целевая раскладка на роутере

| Что | Где |
|---|---|
| Данные, движок, списки, Lua, lib | `/opt/zapret2` (как у апстрима и у zapret на OpenWrt) |
| Настройки | `/etc/config/z2k` (UCI) → генерируется `/opt/zapret2/config` |
| Сервисы | `/etc/init.d/z2k`, `z2k-tg-tunnel`, `z2k-http-tunnel`, `z2k-rt-proxy`, `z2k-warp`, `z2k-panel` (procd, respawn) |
| Правила | `/usr/share/nftables.d/` или fw4 include `/etc/z2k/fw4.nft` |
| Планировщик | штатный cron (`/etc/crontabs/root`) |
| CLI | `/usr/bin/z2k` |
| Ключ доверия, храповик | `/opt/zapret2/etc/z2k-update-pub.pem`, `/etc/z2k/.trust/pinned` |

## Фазы

### Фаза 0. Подготовка (готово, кроме ключа)
- [x] Полный клон, remote `upstream`, ветка `main` от `p-86.19`.
- [x] План, правила проекта (`CLAUDE.md`).
- [x] Репозиторий `AlMinoOj/z2k-openwrt` (private), push `main` без тегов
      апстрима (2026-10-11).
- [x] Actions в репозитории выключены (workflows апстрима завязаны на
      `necronicle/*`); свой CI — фаза 7.
- [ ] Ключ подписи Ed25519 — генерирует мейнтейнер локально, в репозиторий
      кладётся только публичный (к фазе 3).
- [ ] Перед релизом 1.0 сделать репозиторий публичным (роутеры качают raw
      без токена; jsdelivr работает только с публичными).

### Фаза 1. Каркас (в работе)
- [x] `openwrt/compat-map.tsv`: путь → класс (`portable` / `patched` /
  `replaced` / `keenetic` / `dev` / `openwrt`), первое совпадение побеждает.
  На 2026-10-11: dev 698, portable 118, patched 35 (все пока TODO), replaced 21,
  keenetic 10.
- [x] `openwrt/tools/compat-check.sh`: сводка, `--list`, `--stdin`, `--class`;
  exit 1 при неклассифицированных файлах.
- [x] `openwrt/lib/platform.sh`: серия OpenWrt и поддержка (23.05+), opkg/apk,
  пакетная арка → GOARCH / уровень ARM / каталог движка / имя Go-сборки
  (суффиксы mipsel|mipsle, x86|386, mips64el|mips64le; GOARM=7-сборки не
  ставятся на ARMv5/v6).
- [x] `openwrt/lib/channel.sh`: репозиторий, ветка, метка канала
  `openwrt-main`, URL манифеста и файлов.
- [x] Тесты: `openwrt/tests/run.sh` (dash), `test_platform.sh` — 72 проверки.
- [x] README форка: `.github/README.md`.
- [ ] Установщик `openwrt/install.sh` (однострочник для пользователя),
  деинсталлятор — после фазы 2 (нужно, что ставить).
- Позже: OpenWrt-feed с пакетами `z2k` (noarch) и `z2k-bin-<arch>`.

### Фаза 2. Ядро обхода
- Движок из `zapret2-z2k` openwrt-embedded (пин + sha), `install_bin.sh`.
- procd-init `openwrt/init.d/z2k` на основе апстримного
  `init.d/openwrt/zapret2` из архива движка; z2k-генератор `NFQWS2_OPT`
  (`lib/config_official.sh`, `lib/strategies.sh`), Lua-цепочка
  (`--lua-init=@…` в порядке `S99zapret2.new:942-1050`), `WS_USER=nobody`.
- UCI `z2k` → `/opt/zapret2/config` (единая писалка `set_flag` апстрима).
- nft: очередь NFQUEUE (`QNUM=200`, метка `0x40000000`, connmark-исключение
  `0x20000000`), фикс MASQUERADE для помеченного UDP, порт-сеты, исключение
  из flow offload. Аналог ipset `zport_tcp/udp` — nft set.
- sysctl conntrack (`tcp_be_liberal`, `checksum=0`); Keenetic-only `fastnat`,
  `fastroute`, PPE — нет.
- kmods: `kmod-nft-queue`, `kmod-nft-nat`, `kmod-nft-offload`(если есть),
  `kmod-nf-conntrack`.

### Фаза 3. Обновления
- Мейнтейнер: `openwrt/tools/upstream-sync.sh` — проверка подписи апстрима,
  отчёт по окну `upstream_base..тег` (описания релизов, файлы с классами из
  `compat-map.tsv`, бамп пина движка), `git merge`, тесты.
- Мейнтейнер: `openwrt/tools/release.sh` — версия, `UPDATES.json` (карта путей
  OpenWrt, `files_sha256`, `history[]` со `steps`, `upstream_base`), подпись
  своим ключом, тег `vX.Y.Z`, push.
- Роутер: обновлятор на базе converge-логики `lib/auto_update.sh` (план по
  расхождению sha, скачивание заранее, атомарный `mv`, снимок, откат,
  health-check, тег пишется последним) в своём файле `openwrt/lib/update.sh`;
  шаги транслированы под procd; проверка подписи `z2k-verify` (ставим его,
  апстрим не ставит) или `openssl` 3.x; защита от даунгрейда по `seq`.
- Режимы: автоприменение (раз в сутки по cron с джиттером) / только вручную.

### Фаза 4. Списки и cron
- `files/z2k-update-lists.sh` без `ndmc`; geosite; задания cron вместо
  `z2k-scheduler.sh` (auto-update, update-lists, tcp16-probe, selfheal).

### Фаза 5. Модули
- Telegram-туннель и HTTP-туннель: nft `redirect to :1443/:1444`, наборы
  `tg_dc`/`tg_dc6`, UDP-маршрутизация `Z2K_TG_UDP` → nft + `ip rule`.
- rt-proxy: dnsmasq `address=/rutracker.org/10.171.171.171` вместо
  `ndmc ip host`, nft redirect на `:1445`.
- WARP: `kmod-tun`, policy routing (table 989, fwmark `0x989`), nft-набор
  вместо ipset; маршрутизация по доменам через dnsmasq-full `nftset` вместо
  NFLOG; устройства — из DHCP-аренд/ubus вместо `ndmc show ip hotspot`.
- z2k-detect: вызовы `iptables` (`internal/classify/raw_linux.go`,
  `internal/prober/raw_linux.go`) → nft (патч Go) или `iptables-nft`.
- `ndmc ip host` (Instagram, relay, GitHub) → dnsmasq.

### Фаза 6. Вебпанель
- uhttpd, отдельный инстанс на 8088, CGI `webpanel/cgi/api.sh`.
- Вход: rpcd/ubus `session login` (учётка LuCI) вместо NDM `/auth`.
- Убрать ручки PPE/fastroute, добавить flow offload; списки устройств из ubus.
- `luci-app-z2k` — пункт меню со ссылкой/iframe.

### Фаза 7. CI и тесты
- Свой `ci.yml`: shellcheck, dash-синтаксис, переиспользуемые тесты апстрима
  (Lua, генератор конфига, стратегии, панель), Go vet/test, сверка
  `build-matrix.tsv`.
- Смоук OpenWrt в QEMU (x86_64, malta-mipsel): установка, `nft list ruleset`,
  nfqws2 на очереди, `sh -n` всех скриптов.
- `scripts/router_suite.sh` → реальный OpenWrt-роутер по SSH.

### Фаза 8. Пилот и 1.0.0
- 2–3 роутера разных архитектур, неделя на канале `beta`, затем `v1.0.0`.

## Еженедельный цикл мейнтейнера

1. `openwrt/tools/upstream-sync.sh <тег апстрима>` → отчёт.
2. Разбор `patched` / `replaced` / `unknown`, merge, правки.
3. Тесты + QEMU-смоук.
4. `openwrt/tools/release.sh minor` → подписанный релиз.

## Риски

- Флеш: Go-бинарники 5–9 МБ каждый (warpd/mipsel ≈ 8,9 МБ) — модули ставятся
  по выбору; на 16 МБ флеша WARP/detect — в `/tmp` или extroot.
- Секрет туннеля вшит в сборки `tg-mtproxy-client` апстрима при сборке:
  пересобрать сами без него не можем — используем готовые сборки по sha.
- Чаще всего меняются `lib/config_official.sh` и `webpanel/cgi/actions.sh` —
  правки в них держать минимальными.
- Апстримные бинарники nfqws2 (статика) проверить на musl/ядрах целевых
  версий; наличие `nfnetlink_queue`/nft-queue в kmods.
