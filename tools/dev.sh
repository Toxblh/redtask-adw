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
  # tools/dev.sh shot имя ШxВ [VAR=знач…] — PNG окна в build/shots/имя.png (ключ — из ~/.env-redmine)
  shot) name=$2; size=$3; shift 3; mkdir -p build/shots
    . ~/.env-redmine
    extra=""; for kv in "$@"; do extra="$extra --env=$kv"; done
    DEV_ENV="--env=REDMINE_ADW_DEV_KEY=$REDMINE --env=REDMINE_ADW_DEV_SERVER=https://my.basealt.space --env=REDMINE_ADW_SHOT=$PWD/build/shots/$name.png --env=REDMINE_ADW_SHOT_SIZE=$size $extra" \
      run_sdk "ninja -C build >/dev/null && exec ./build/src/redmine-adw" ;;
  *) echo "usage: $0 build|test|run|shell"; exit 1 ;;
esac
