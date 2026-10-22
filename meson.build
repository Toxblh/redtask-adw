project('redmine-adw', ['c', 'vala'],
  version: '0.1.0',
  meson_version: '>= 1.0.0',
  license: 'GPL-3.0-or-later',
)

i18n = import('i18n')
gnome = import('gnome')

app_id = 'ru.toxblh.RedmineAdw'
pkgdatadir = get_option('prefix') / get_option('datadir') / meson.project_name()
localedir = get_option('prefix') / get_option('localedir')

add_project_arguments('-DGETTEXT_PACKAGE="redmine-adw"', '-DG_LOG_DOMAIN="RedmineAdw"', '-w', language: 'c')

conf = configuration_data()
conf.set_quoted('APP_ID', app_id)
conf.set_quoted('VERSION', meson.project_version())
conf.set_quoted('GETTEXT_PACKAGE', 'redmine-adw')
conf.set_quoted('LOCALEDIR', localedir)
configure_file(output: 'config.h', configuration: conf)
add_project_arguments('-include', 'config.h', '-I' + meson.current_build_dir(), language: 'c')

subdir('data')
subdir('src')
subdir('po')
subdir('tests')

gnome.post_install(
  glib_compile_schemas: true,
  gtk_update_icon_cache: true,
  update_desktop_database: true,
)
