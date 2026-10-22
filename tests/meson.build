test_deps = [dependency('glib-2.0'), dependency('gobject-2.0'), dependency('gio-2.0'), dependency('json-glib-1.0'), meson.get_compiler('c').find_library('m')]
foreach t : ['test_textile', 'test_logic']
  exe = executable(t, [t + '.vala'] + core_sources,
    vala_args: ['--target-glib=2.80', files('../src/config.vapi')],
    dependencies: test_deps)
  test(t, exe)
endforeach
