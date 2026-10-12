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
| Настройки | `/opt/zapret2/config` (как у z2k; UCI в 1.0 нет — см. фазу 2) |
| Сервисы | `/etc/init.d/z2k` → движок `/opt/zapret2/init.d/z2k-engine`; модули фазы 5–6 — свои init |
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
      `necronicle/*`). Своего CI нет — решение мейнтейнера (фаза 7).
- [ ] Ключ подписи Ed25519 — генерирует мейнтейнер локально, в репозиторий
      кладётся только публичный (к фазе 3).
- [ ] Перед релизом 1.0 сделать репозиторий публичным (роутеры качают raw
      без токена; jsdelivr работает только с публичными).

### Фаза 1. Каркас (в работе)
- [x] `openwrt/compat-map.tsv`: путь → класс (`portable` / `patched` /
  `replaced` / `keenetic` / `dev` / `openwrt`), первое совпадение побеждает.
  На 2026-10-11: dev 698, portable 118, patched 35 (все пока TODO), replaced 21,
  keenetic 10.
- [x] `openwrt/maint/compat-check.sh`: сводка, `--list`, `--stdin`, `--class`;
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

### Фаза 2. Ядро обхода (код готов, ждёт проверки на живом OpenWrt)
Решения (2026-10-11):
- **Движок z2k = `files/S99zapret2.new` апстрима**, ставится как
  `/opt/zapret2/init.d/z2k-engine`. В нём ~3000 строк логики z2k (автохостлист,
  кэш ротации, отладка, исключения, whitelist, Lua-цепочка), апстрим правит его
  постоянно — переписывать под procd значило бы переносить каждую правку руками.
  Патч — 1 строка-хук `# OPENWRT:` перед диспетчером, подключающая
  `openwrt/lib/s99-openwrt.sh`: межсетевой экран — апстримный nft-путь zapret2
  (`common/nft.sh` + функции из `init.d/openwrt/functions` движка: netifd,
  `@wanif`, flow offload), исключения `nozapret` — nft-сеты, модули — kmod,
  iptables-слои z2k (connmark политик Keenetic, UDP masquerade, RST-фильтр,
  подметалки) на nft не включаются, планировщик и lighttpd Keenetic — нет.
- **UCI в 1.0 нет.** Источник правды — `/opt/zapret2/config`: генератор z2k
  пишет его с нуля по списку ключей, панель/меню — через `set_flag`. Второй
  источник (UCI) затирал бы их.
- `/etc/init.d/z2k` — обёртка rc.common над движком; `/opt/etc/init.d/S99zapret2`
  — симлинк на неё (код z2k зовёт этот путь по умолчанию).
- Пути z2k не меняем: `/opt/zapret2`, `/opt/etc/zapret2`, custom.d в
  `init.d/keenetic/custom.d` (так пишет генератор конфига).

Сделано:
- [x] `openwrt/engine.pin` — v1.0.5.2-z2k-r0, sha256 архива целиком; бинарники
  статические, на musl работают. Сборок нет под mips64el и ppc64.
- [x] `openwrt/lib/engine.sh` — скачать/проверить/разложить, бинарники своей
  арки в `nfq2/`, `ip2net/`, `mdig/`, `binaries/` удаляется (−5 МБ флеша).
- [x] `openwrt/lib/layout.sh` — единственная раскладка файлов (установщик и
  будущий install_map).
- [x] `openwrt/lib/z2k-config.sh` — генерация библиотеками z2k без установщика
  Keenetic (`set +u` обязателен; `GITHUB_RAW` → канал форка, иначе в конфиг
  уходит `necronicle/z2k`).
- [x] `openwrt/lib/s99-openwrt.sh`, хук в `files/S99zapret2.new`.
- [x] `openwrt/init.d/z2k`, `openwrt/hotplug/90-z2k` (reload_ifsets на ifup/ifdown).
- [x] `openwrt/install.sh` (из локальной копии/бандла), `openwrt/uninstall.sh`,
  `openwrt/maint/make-bundle.sh` (75 файлов, 5,3 МБ с движком).
- [x] flow offload fw4 → `FLOWOFFLOAD` движка (своя flowtable с исключениями).
- [x] Тесты: `test_engine` (реальный архив), `test_generate` (генератор в
  песочнице), `test_layout` (раскладка ↔ compat-map, хук S99).
- [x] **QEMU x86_64, OpenWrt 23.05.6, 24.10.8 (opkg) и 25.12.5 (apk)** — 2026-10-11:
  установка с нуля, пакеты, движок, генерация, старт; nfqws2 от nobody на
  очереди 200; правила на @wanif, nozapret засеян; трафик идёт через демон
  (31 пакет на запрос); `fw4 reload` таблицу не трогает; ifup/ifdown →
  reload_ifsets; перезагрузка → автозапуск; ENABLED=0 → не стартует; stop
  снимает все правила очереди; uninstall чистый; переустановка. Флеш 7 МБ,
  RSS nfqws2 ~17 МБ. Стенд: `scratchpad/vm/run24.sh|run25.sh` (TCG, без WHPX).
- [ ] **Обход на настоящем роутере.** Сеть QEMU (slirp) сама завершает TCP и
  отправляет фейки nfqws2 как настоящие данные — часть стратегий на стенде
  ломает соединение (rutracker), это ограничение стенда, а не порта.
- [x] OpenWrt 23.05.6 в QEMU — то же, что на 24.10 (2026-10-11).
- [ ] Наблюдать: нужен ли на nft аналог z2k UDP masquerade fix (на iptables
  чинил NAT сгенерированных UDP-пакетов); у апстрима на nft — notrack/postnat.

### Фаза 3. Обновления (готово, кроме ключа мейнтейнера и первого релиза)
Решения (2026-10-11):
- **Подпись — формат usign** (Ed25519). Роутер проверяет встроенным `usign`
  (есть в 23.05/24.10/25.12, им подписаны фиды OpenWrt) — openssl и Go-бинарник
  на роутере не нужны. Мейнтейнер подписывает обычным openssl 3.x
  (`openwrt/maint/sign.sh`): тот же Ed25519, другая упаковка.
- **Манифест — текст с TAB** (`openwrt/release/manifest` + `.sig`), разбор awk
  на busybox. Поля: channel, seq, version (= git-тег), upstream_base, date,
  reset_state, `file sha mode путь цели`, `release …` (история).
- **Шаги выводятся на роутере из изменившихся файлов** (`ow_steps_for` в
  `openwrt/lib/manifest.sh`, аналог `z2k_steps_for` апстрима), канонический
  порядок: engine → regen-strategies → regen-config → validate-config →
  reset-state → restart-service.

Сделано:
- [x] `openwrt/maint/sign.sh` (keygen/pub/sign), `usign-verify.sh` (проверка
  формата usign через openssl — CI, тесты, release.sh).
- [x] `openwrt/maint/build-manifest.sh`, `release.sh` (версия minor/patch/major,
  seq+1, тесты, подпись, сверка с `openwrt/etc/z2k-update.pub`, коммит, тег,
  push: сначала тег, потом ветка).
- [x] `openwrt/maint/upstream-sync.sh` — отчёт (подпись апстрима, релизы в
  окне, файлы по классам, удалённые, смена пина движка), `--merge`,
  `--bump-engine`; база — `openwrt/UPSTREAM`.
- [x] `openwrt/lib/update.sh` + CLI `z2k-update check|apply [--auto]|status`:
  подпись, канал, seq (откат кэша зеркала — пропуск), план по sha, сироты,
  скачивание до записи, снимок, атомарная замена, шаги новым кодом, проверка
  службы, откат, отметка откатившейся версии (ночной режим её не повторяет),
  `Z2K_AUTO_UPDATE_ENABLED=0` уважается.
- [x] `openwrt/get.sh` — установка одной командой по подписанному манифесту.
- [x] `openwrt/lib/postinstall.sh` — псевдонимы блобов (как lib/install.sh),
  ссылка `/usr/bin/z2k-update`.
- [x] Тесты: `test_update` (39 проверок: подделка, битый файл, откат, сироты,
  seq, канал, --auto), `test_postinstall`.
- [x] **QEMU 25.12.5, настоящий usign**: get.sh → v1.0.0; apply v1.1.0
  (3 файла, 4 шага, 34 с под TCG); v1.2.0 со сломанным Lua → служба не
  поднялась → откат на v1.1.0, обход работает.
- [x] **Ключ мейнтейнера** (2026-10-11): `openwrt/etc/z2k-update.pub`,
  приватный — у мейнтейнера в `~/.z2k-openwrt-signing/`.
- [ ] Первый релиз `v1.0.0` (после фаз 4–6 или раньше — как решит мейнтейнер);
  репозиторий публичный (raw/jsdelivr без токена).

### Фаза 4. Расписание и сторож (готово)
- [x] `openwrt/bin/z2k-cron` вместо резидентного `files/z2k-scheduler.sh`:
  блок в `/etc/crontabs/root` между маркерами (чужие строки не трогаются),
  `install|remove|auto-update|lists|tcp16|watchdog`.
  - `0 Z2K_AU_HOUR` — `z2k-update apply --auto` (задержка 0–59 мин, постоянная
    для роутера: md5 MAC-адресов и имени);
  - `30 3` — перемер tcp16 (пропускается, пока нет `z2k-detect` — фаза 5);
  - `0 4` — `z2k-update-lists.sh` (geosite runetfreedom, Cloudflare, игры WARP);
  - `*/5` — сторож: nfqws2 жив, хуки таблицы zapret2 на месте, час
    автообновления в cron = `Z2K_AU_HOUR` конфига (меняют панель/меню),
    `debug_rotate`.
- [x] Шаг обновления `cron` (смена `z2k-cron` переустанавливает блок).
- [x] `files/z2k-update-lists.sh` — portable (ndmc закрыт проверкой, перезапуск
  через симлинк S99zapret2, канал — `Z2K_GITHUB_RAW` из конфига).
- [x] Найдено в QEMU и исправлено: наложившиеся перезапуски (cron + списки +
  панель) оставляли nfqws2-сироту, новый демон падал с
  «nfq_create_queue(): Operation not permitted». Теперь `/etc/init.d/z2k`
  сериализует изменяющие действия замком-каталогом, а `stop_all_nfqws` в
  `s99-openwrt.sh` ждёт реального завершения nfqws2 (затем SIGKILL).
- [x] QEMU 24.10.8: блок cron, crond; сторож поднимает убитый nfqws2 и
  возвращает снятые правила; списки за ~100 с (RKN из geosite 74 709 доменов)
  с перезапуском; 3 параллельных перезапуска + сторож → один nfqws2.
- [x] Тест `test_cron` (11). busybox OpenWrt: нет `pkill`, `comm` не
  гарантирован — в коде порта не используются.

### Фаза 5. Модули (готово, всё на nftables — решение мейнтейнера 2026-10-12)
Общее:
- [x] `openwrt/lib/modules.sh`, `z2k-module list|enable|disable`: Go-бинарники
  ставятся по выбору (флеш), только под арку роутера; по умолчанию — по
  свободному месту (tg ≥20 МБ, rtproxy ≥30 МБ). Обновлятор и get.sh берут из
  манифеста только нужные сборки. Пакеты модуля ставятся сами (warp:
  kmod-tun, kmod-nfnetlink-log).
- [x] Наши Go-сборки (detect, warpd пропатчены под nft) — `openwrt/builds`,
  `openwrt/maint/build-go.sh` (Go 1.25.13, build-matrix.tsv); апстримные
  `*/builds` этих модулей не едут. upstream-sync напоминает о пересборке.
- [x] Симлинки `/opt/etc/init.d/S*` на наши procd-службы (код z2k зовёт их);
  S51z2k-warp — на переходник (z2k-warp.sh зовёт через `sh`).
- [x] Модули: tg, rtproxy, detect, warp. Везде логика апстрима сохранена, а
  платформа заменена хуком/слоем; апстримные сторожа работают без правок.

Модули (всё проверено в QEMU 24.10.8 без iptables, 2026-10-12):
- [x] **tg** — `init.d/z2k-tg` (procd respawn), `lib/tg-redirect.sh` (nft-таблица
  inet z2k_tg, те же функции, что у апстримного z2k-tg-redirect.sh), сторож
  z2k-cron tg. Relay — сервер автора (вшит в сборку), свой — Z2K_RELAY_URL/
  Z2K_RELAY_SECRET. core.telegram.org через туннель — 200, CONNECT_OK.
- [x] **rtproxy** — `init.d/z2k-rtproxy`: домены -> 10.171.171.171 через UCI
  dnsmasq, nft redirect :1445. rutracker.org — 200.
- [x] **detect** — `internal/nftfw` (таблица inet z2k_detect), 2 правки
  `// OPENWRT:` в апстримном Go. probe/classify работают.
- [x] **warp** — Go: nat/nft.go, domainroute/pairs_nft.go (+2 правки);
  шелл: хук в z2k-warp.sh -> `lib/warp-openwrt.sh` (замена ipset поверх
  nft-сетов, перевод правил iptables->nft, log group 189); fw4 include
  chain-pre/forward; `init.d/z2k-warp` + переходник. Регистрация Cloudflare,
  wg (WAW), warp=on через туннель, выключение снимает всё.
- [x] **Instagram** — хук в z2k-insta-ip-refresh.sh -> `lib/ndmc-dnsmasq.sh`
  (функция ndmc: ip host -> UCI dnsmasq z2k_ig_*).
- Найдено в QEMU: `policy` — зарезервированное слово nft (имя цепочки
  нельзя); procd `status` отвечает 0 на «active with no instances».
- [x] Z2K_WARP_VPS_PROXY по умолчанию — прокси автора с учёткой, как у
  апстрима: оставляем (решение мейнтейнера 2026-10-12). Так же — relay TG и
  остальные сервисы автора.

### Фаза 6. Вебпанель (готово)
Решения (2026-10-12):
- **lighttpd из пакетов OpenWrt, не uhttpd.** uhttpd передаёт в CGI только
  стандартные заголовки, а защита панели (auth.sh: CSRF/DNS rebinding)
  держится на X-Z2K-Panel и Sec-Fetch-Site — проверено в QEMU. lighttpd 1.4.85
  (+mod-cgi, mod-setenv, ~230 КБ) берёт шаблон конфига апстрима как есть.
- **Вход — учётка роутера через rpcd** (`ubus call session login`, та же, что
  в LuCI). Фронтенд апстрима считал хеш Keenetic у себя — правка auth.js:
  при realm "rpcd" пароль уходит как есть (как в LuCI по HTTP).
- **Панель — код апстрима**: хук `# OPENWRT:` в api.sh ->
  `openwrt/lib/panel-openwrt.sh` (вход, устройства из DHCP/соседей LAN,
  исключения в nft, обновления через наш канал, удаление, отказ PPE/
  маршрутного кэша/политик Keenetic). Обновления: `update.sh json` отдаёт
  проверенный манифест в формате UPDATES.json — подсчёт и история апстримные.
- Прятать лишнее — правка toggles.js по `www/platform.json` (index.html и
  style.css не трогаем: апстрим меняет их в каждом релизе).

Сделано:
- [x] `openwrt/init.d/z2k-panel` (procd, lighttpd -D, адрес LAN:8088, файлы
  bind/port для проверки Host), `www/platform.json`, cgi-bin/api (postinstall),
  установка пакетов и запуск в install.sh (`Z2K_OW_PANEL=0` — без панели),
  шаг обновления restart-panel, удаление.
- [x] Тесты: test_panel (8), json в test_update.
- [x] QEMU 24.10.8: статус, защита (без заголовка / чужой Host / cross-site —
  403), вход rpcd (неверный 401, верный 200 + сессия, билет одноразовый),
  устройства только с br-*, исключение -> nft-сет, переключатель категории
  (задача + перезапуск обхода), PPE отказывает; в браузере — вход, дашборд,
  на «Режимах» скрыты ppe/fastroute и карточка политики.
- [ ] Без пароля root rpcd пускает с любым паролем (как LuCI) — предупреждать
  при включении входа в панель.
- [ ] Тексты «меню роутера: пункт Веб-панель» (меню z2k на OpenWrt нет):
  выключить вход — `Z2K_PANEL_AUTH=0` в /opt/zapret2/config.
- [x] z2k-diag.sh (диагностика) — фаза 7.

### Фаза 7. Проверки на OpenWrt (готово; CI не делаем — решение мейнтейнера 2026-10-12)
Решения:
- **Без GitHub Actions.** Релизы выпускает один мейнтейнер раз в неделю,
  `release.sh` и так не выпустит релиз с упавшими тестами.
- **Вместо CI — прогон на настоящем OpenWrt в QEMU** перед релизом: тесты с
  заглушками не ловят того, что видит только живой nft/procd (так прятались
  `policy` как имя цепочки и обрыв конфига под `set -u`).
- Тестовый набор апстрима для роутера (`scripts/router_suite.sh`) не
  переносим — он про Keenetic; свой — `router-smoke.sh`.

Сделано:
- [x] `openwrt/maint/router-smoke.sh` — проверка установленного z2k на роутере
  (`ssh root@роутер 'sh -s' < openwrt/maint/router-smoke.sh`): синтаксис,
  служба, nfqws2 не от root, nft и очередь, сет wanif, трафик через демон
  (рост счётчика очереди), stop/start, два перезапуска разом, fw4 reload, cron,
  обновлятор, ключ, диагностика без тревог, панель (403 без заголовка и с
  чужим Host), модули. `Z2K_SMOKE_RESTART=0` — не трогать службу.
- [x] `openwrt/maint/qemu-smoke.sh <образ.img.gz>` — чистый официальный образ
  x86-64: бандл → ВМ → SSH без пароля → установка → router-smoke → перезагрузка
  (автозапуск, router-smoke ещё раз) → удаление (следов нет). Под TCG ~10 мин.
- [x] Диагностика: хук `# OPENWRT:` в `files/z2k-diag.sh` ->
  `openwrt/lib/diag-openwrt.sh`. Было на OpenWrt: «/opt не смонтирован»,
  «правил телеграма нет», «список подсетей пуст», NFQUEUE 0, «нет модулей
  Netfilter», WARP routing 0. Теперь: раздел `nftables` (очередь, nozapret,
  телеграм, счётчик очереди из /proc, hotplug), `platform` (версия, fw4, kmod,
  offload), счёт в шкале апстрима для его вердикта, закрепы Instagram из
  dnsmasq. Тест `test_diag` (17).
- [x] Найдено первым же прогоном: пакет lighttpd при установке включает свою
  службу со стандартным конфигом — после перезагрузки рядом с панелью
  поднимался второй lighttpd (спор с uhttpd/LuCI за :80) и переживал
  удаление z2k. Установщик теперь выключает службу пакета, если поставил его
  сам; router-smoke ловит «чужой lighttpd».
- [ ] Остаётся: на x86 (нет device-tree) в отчёт попадает строка
  «can't open /proc/device-tree/model» — у роутеров ARM/MIPS её нет.

### Релиз v1.0.0 (2026-10-12)
- [x] README для пользователей (`.github/README.md`): установка одной
  командой, панель, модули, обновления, управление, удаление.
- [ ] Репозиторий публичный (Settings → General → Danger Zone → Change
  visibility) — делает мейнтейнер.
- [ ] `sh openwrt/maint/release.sh v1.0.0 -m "Первый релиз"` — делает
  мейнтейнер (ключ подписи у него).
- [ ] Проверка установки с GitHub (`get.sh`) на чистой ВМ.

### Фаза 8. Пилот
- 2–3 роутера разных архитектур, неделя на канале `beta`, затем `v1.0.0`.

## Еженедельный цикл мейнтейнера

1. `openwrt/maint/upstream-sync.sh <тег апстрима>` → отчёт.
2. Разбор `patched` / `replaced` / `unknown`, merge, правки.
3. `dash openwrt/tests/run.sh` + `openwrt/maint/qemu-smoke.sh` на образах
   23.05 / 24.10 / 25.x (и `router-smoke.sh` на своём роутере).
4. `openwrt/maint/release.sh minor` → подписанный релиз.

## Риски

- Флеш: Go-бинарники 5–9 МБ каждый (warpd/mipsel ≈ 8,9 МБ) — модули ставятся
  по выбору; на 16 МБ флеша WARP/detect — в `/tmp` или extroot.
- Секрет туннеля вшит в сборки `tg-mtproxy-client` апстрима при сборке:
  пересобрать сами без него не можем — используем готовые сборки по sha.
- Чаще всего меняются `lib/config_official.sh` и `webpanel/cgi/actions.sh` —
  правки в них держать минимальными.
- Апстримные бинарники nfqws2 (статика) проверить на musl/ядрах целевых
  версий; наличие `nfnetlink_queue`/nft-queue в kmods.
