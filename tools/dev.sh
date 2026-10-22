#!/bin/sh
# Сборка и запуск внутри org.gnome.Sdk//50: на хосте (ALT Atomic) нет libsecret-devel.
#   tools/dev.sh build | test | run [аргументы] | shell
set -e
cd "$(dirname "$0")/.."
SDK=org.gnome.Sdk//50
LOCALES='mkdir -p build/locale/ru/LC_MESSAGES && cp build/po/ru/LC_MESSAGES/redmine-adw.mo build/locale/ru/LC_MESSAGES/'
run_sdk() {
  flatpak run --share=network ${SOCKETS---socket=wayland --socket=fallback-x11} --device=dri \
    --filesystem="$PWD" --filesystem=xdg-run/keyring --own-name=ru.toxblh.RedmineAdw --talk-name=org.freedesktop.secrets \
    --talk-name=org.freedesktop.Notifications --talk-name=org.freedesktop.portal.Desktop \
    --env=SECRET_BACKEND=service --env=GSETTINGS_SCHEMA_DIR="$PWD/build/data" \
    --env=GSETTINGS_BACKEND=keyfile --env=REDMINE_ADW_LOCALEDIR="$PWD/build/locale" \
    ${DEV_ENV} --command=sh "$SDK" -c "cd \"$PWD\" && $1"
}
case "$1" in
  build) run_sdk '[ -d build ] || meson setup build --prefix=/app; ninja -C build' ;;
  test) run_sdk '[ -d build ] || meson setup build --prefix=/app; meson test -C build --print-errorlogs' ;;
  run) shift; run_sdk "ninja -C build >/dev/null && $LOCALES && exec ./build/src/redmine-adw $*" ;;
  shell) run_sdk 'exec bash' ;;
  # tools/dev.sh shot имя ШxВ [VAR=знач…] — PNG окна в build/shots/имя.png (ключ — из ~/.env-redmine).
  # Безголово: окно живёт в своём mutter --headless (своя шина D-Bus, свой сокет Wayland, без X11) —
  # на экране пользователя ничего не появляется.
  shot) name=$2; size=$3; shift 3; mkdir -p build/shots
    . ~/.env-redmine
    extra=""; for kv in "$@"; do extra="$extra --env=$kv"; done
    export WAYLAND_DISPLAY=redmine-adw-shot-$$
    unset DISPLAY
    pidf=$(mktemp)
    dbus-run-session -- sh -c "echo \$\$ > $pidf; exec mutter --headless --wayland --no-x11 --virtual-monitor 1920x1200 --wayland-display=$WAYLAND_DISPLAY" >/dev/null 2>&1 &
    trap 'kill $(cat $pidf) 2>/dev/null; rm -f $pidf' EXIT
    for i in $(seq 100); do [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && break; sleep 0.1; done
    SOCKETS="--socket=wayland --nosocket=x11 --nosocket=fallback-x11"
    DEV_ENV="--env=REDMINE_ADW_DEV_KEY=$REDMINE --env=REDMINE_ADW_DEV_SERVER=https://my.basealt.space --env=REDMINE_ADW_SHOT=$PWD/build/shots/$name.png --env=REDMINE_ADW_SHOT_SIZE=$size $extra" \
      run_sdk "ninja -C build >/dev/null && $LOCALES && exec ./build/src/redmine-adw" ;;
  *) echo "usage: $0 build|test|run|shell"; exit 1 ;;
esac
