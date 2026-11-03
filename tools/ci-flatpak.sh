#!/usr/bin/env bash
# Сборка flatpak без flatpak-builder: на общих раннерах ALS нет FUSE и bwrap (песочницы flatpak).
# Компилируем meson-ом в chroot из файлов GNOME SDK (так же, как flatpak-builder в песочнице: /usr — SDK,
# /app — префикс), дальше обычные flatpak build-finish/build-export/build-bundle. Нужен root (chroot).
# Запуск: [FLATPAK_REPO=dir] tools/ci-flatpak.sh → build-ci/redtask-<версия>-x86_64.flatpak (+ OSTree-репозиторий)
set -Eeuo pipefail

MANIFEST=ru.toxblh.RedTask.json
APP_ID=$(jq -r .id $MANIFEST)
BRANCH=$(jq -r '.["runtime-version"]' $MANIFEST)
VERSION=$(sed -n "s/^  version: '\(.*\)',/\1/p" meson.build)
OUT="$PWD/build-ci/redtask-$VERSION-x86_64.flatpak"
WORK=$(mktemp -d "$PWD/.ci-flatpak.XXXX")
REPO="${FLATPAK_REPO:-$WORK/repo}"
trap 'rm -rf "$WORK"' EXIT

flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user -y --noninteractive flathub "org.gnome.Platform//$BRANCH" "org.gnome.Sdk//$BRANCH"
SDK=$(flatpak info --user --show-location "org.gnome.Sdk//$BRANCH")/files

# Корень chroot: /usr из SDK (жёсткие ссылки, если та же ФС), /etc — его etc, /app — что соберём.
R="$WORK/root"
mkdir -p "$R"/{app,src,tmp,dev,proc}
cp -al "$SDK" "$R/usr" 2>/dev/null || { rm -rf "$R/usr"; cp -a "$SDK" "$R/usr"; }
for d in bin lib lib64 sbin etc; do ln -s usr/$d "$R/$d"; done
mknod -m 666 "$R/dev/null" c 1 3 2>/dev/null || : > "$R/dev/null"  # без CAP_MKNOD — обычный файл
git ls-files -z | xargs -0 cp --parents -t "$R/src"
chroot "$R" /usr/bin/env -i PATH=/app/bin:/usr/bin HOME=/tmp LANG=C.UTF-8 \
    sh -ec 'meson setup /tmp/b /src --prefix=/app --buildtype=release >/dev/null
            meson compile -C /tmp/b && meson test -C /tmp/b --print-errorlogs && meson install -C /tmp/b >/dev/null'

flatpak build-init "$WORK/build" "$APP_ID" org.gnome.Sdk org.gnome.Platform "$BRANCH"
cp -a "$R/app/." "$WORK/build/files/"
for p in $(jq -r '.cleanup[]' $MANIFEST); do
    case $p in /*) rm -rf "$WORK/build/files$p" ;; *) find "$WORK/build/files" -name "$p" -delete ;; esac
done
mapfile -t ARGS < <(jq -r '.["finish-args"][]' $MANIFEST)
flatpak build-finish "$WORK/build" --command="$(jq -r .command $MANIFEST)" "${ARGS[@]}"

# build-export проверяет иконку в песочнице bwrap — её нет; иконка SVG и так в hicolor/scalable.
FLATPAK_VALIDATE_ICON=/bin/true flatpak build-export "$REPO" "$WORK/build" stable
flatpak build-update-repo --generate-static-deltas --prune --prune-depth=3 "$REPO"
mkdir -p "$(dirname "$OUT")"
flatpak build-bundle "$REPO" "$OUT" "$APP_ID" stable --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo
ls -la "$OUT"
