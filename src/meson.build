core_sources = files(
  'util.vala',
  'api/models.vala',
  'textile/textile.vala',
  'notify/rules.vala',
)

app_sources = core_sources + files(
  'application.vala',
  'api/client.vala',
  'store/settings.vala',
  'store/cache.vala',
  'store/notif_store.vala',
  'notify/poller.vala',
  'ui/window.vala',
  'ui/login.vala',
  'ui/widgets.vala',
  'ui/rich_text.vala',
  'ui/person.vala',
  'ui/lists.vala',
  'ui/notifications.vala',
  'ui/issue_page.vala',
  'ui/issue_dialogs.vala',
  'ui/editor.vala',
  'ui/preferences.vala',
  'ui/shots.vala',
)

app_deps = [
  dependency('gtk4', version: '>= 4.16'),
  dependency('libadwaita-1', version: '>= 1.9'),
  dependency('libsoup-3.0'),
  dependency('json-glib-1.0'),
  dependency('webkitgtk-6.0'),
  dependency('libsecret-1'),
  meson.get_compiler('c').find_library('m'),
]

executable('redmine-adw', app_sources, resources,
  vala_args: ['--target-glib=2.80', '--gresourcesdir=' + meson.project_source_root() / 'data', files('config.vapi')],
  dependencies: app_deps,
  install: true,
)
