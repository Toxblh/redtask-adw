desktop = i18n.merge_file(
  input: 'ru.toxblh.RedTask.desktop.in',
  output: 'ru.toxblh.RedTask.desktop',
  type: 'desktop',
  po_dir: '../po',
  install: true,
  install_dir: get_option('datadir') / 'applications',
)

metainfo = i18n.merge_file(
  input: 'ru.toxblh.RedTask.metainfo.xml.in',
  output: 'ru.toxblh.RedTask.metainfo.xml',
  po_dir: '../po',
  install: true,
  install_dir: get_option('datadir') / 'metainfo',
)

install_data('ru.toxblh.RedTask.gschema.xml', install_dir: get_option('datadir') / 'glib-2.0' / 'schemas')
# схема рядом со сборкой — для запуска без установки (GSETTINGS_SCHEMA_DIR=build/data)
gnome.compile_schemas(build_by_default: true, depend_files: 'ru.toxblh.RedTask.gschema.xml')

install_subdir('icons/hicolor', install_dir: get_option('datadir') / 'icons')

resources = gnome.compile_resources('resources', 'redtask.gresource.xml', c_name: 'redmine')

desktop_utils = find_program('desktop-file-validate', required: false)
if desktop_utils.found()
  test('desktop-file', desktop_utils, args: [desktop])
endif
appstreamcli = find_program('appstreamcli', required: false)
if appstreamcli.found()
  test('metainfo', appstreamcli, args: ['validate', '--no-net', '--explain', metainfo])
endif
