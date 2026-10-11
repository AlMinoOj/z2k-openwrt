#!/bin/sh
# channel.sh — откуда роутер берёт z2k-openwrt. Единственное место, где
# записан адрес репозитория форка; всё остальное строит URL отсюда.
#
# Роутеры НЕ ходят в necronicle/z2k: обновления — только из этого канала,
# манифест подписан ключом форка (openwrt/etc/z2k-update-pub.pem).
#
# Переопределение (для тестового канала или своего зеркала) — переменными
# окружения или из UCI до подключения этого файла.

Z2K_OW_REPO="${Z2K_OW_REPO:-AlMinoOj/z2k-openwrt}"
Z2K_OW_BRANCH="${Z2K_OW_BRANCH:-main}"

# Метка канала в /opt/zapret2/.z2k-branch. Обновлятор работает только при
# совпадении: роутер, на котором стоит апстримный z2k (метка z2k-enhanced),
# автообновлением форка не трогается, и наоборот.
Z2K_OW_CHANNEL="${Z2K_OW_CHANNEL:-openwrt-$Z2K_OW_BRANCH}"

Z2K_OW_RAW_BASE="${Z2K_OW_RAW_BASE:-https://raw.githubusercontent.com/$Z2K_OW_REPO}"
Z2K_OW_CDN_BASE="${Z2K_OW_CDN_BASE:-https://cdn.jsdelivr.net/gh/$Z2K_OW_REPO}"

# Манифест канала (ветка — всегда свежий) и подпись к нему.
Z2K_OW_MANIFEST_URL="${Z2K_OW_MANIFEST_URL:-$Z2K_OW_RAW_BASE/$Z2K_OW_BRANCH/openwrt/release/manifest}"
Z2K_OW_MANIFEST_SIG_URL="${Z2K_OW_MANIFEST_SIG_URL:-$Z2K_OW_MANIFEST_URL.sig}"

# ow_file_url <ref> <путь в репозитории> — неизменяемый адрес файла релиза
# (ref — тег vX.Y.Z или коммит). Контент сверяется с files_sha256 манифеста.
ow_file_url() { echo "$Z2K_OW_RAW_BASE/$1/$2"; }

# Зеркало jsdelivr того же файла (кеш до 12 ч — годится только с проверкой sha).
ow_file_cdn_url() { echo "$Z2K_OW_CDN_BASE@$1/$2"; }
