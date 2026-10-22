#!/bin/sh
# Сборка и запуск внутри org.gnome.Sdk//50: на хосте (ALT Atomic) нет libsecret-devel.
#   tools/dev.sh build | test | run [аргументы] | shell
set -e
cd "$(dirname "$0")/.."
SDK=org.gnome.Sdk//50
run_sdk() {
  flatpak run --share=network --socket=wayland --socket=fallback-x11 --device=dri \
    --filesystem="$PWD" --filesystem=xdg-run/keyring --own-name=ru.toxblh.RedmineAdw --talk-name=org.freedesktop.secrets \
    --talk-name=org.freedesktop.Notifications --talk-name=org.freedesktop.portal.Desktop \
    --env=SECRET_BACKEND=service --env=GSETTINGS_SCHEMA_DIR="$PWD/build/data" \
    --env=GSETTINGS_BACKEND=keyfile \
    ${DEV_ENV} --command=sh "$SDK" -c "cd \"$PWD\" && $1"
}
case "$1" in
  build) run_sdk '[ -d build ] || meson setup build --prefix=/app; ninja -C build' ;;
  test) run_sdk '[ -d build ] || meson setup build --prefix=/app; meson test -C build --print-errorlogs' ;;
  run) shift; run_sdk "ninja -C build >/dev/null && exec ./build/src/redmine-adw $*" ;;
  shell) run_sdk 'exec bash' ;;
  *) echo "usage: $0 build|test|run|shell"; exit 1 ;;
esac
