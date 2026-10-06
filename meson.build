project('singularity-sharing', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0',
)

i18n = import('i18n')
gnome = import('gnome')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-sharing"', language: 'c')
subdir('po')

glib_dep = dependency('glib-2.0')
gio_dep = dependency('gio-2.0')
gio_unix_dep = dependency('gio-unix-2.0')
gee_dep = dependency('gee-0.8')
json_dep = dependency('json-glib-1.0')
soup_dep = dependency('libsoup-3.0')
secret_dep = dependency('libsecret-1')
posix_dep = meson.get_compiler('vala').find_library('posix')

libsingularity_proj = subproject('libsingularity')
sharing_host_dep = libsingularity_proj.get_variable('libsingularity_sharing_host_dep')
sharing_host_vapidir = libsingularity_proj.get_variable('sharing_host_vapidir')
system_dep = dependency('singularity-system-1.0', fallback: ['libsingularity', 'libsingularity_system_dep'])

consent_helper = get_option('consent-helper')
if consent_helper == ''
  consent_helper = get_option('prefix') / get_option('libexecdir') / 'singularity-portal-consent'
endif

wayland_vapi_args = ['--vapidir', sharing_host_vapidir, '--pkg', 'rd_wayland',
  '--vapidir', libsingularity_proj.get_variable('libsingularity_system_vapidir')]

common_sources = files(
  'src/config.vala',
  'src/secrets.vala',
  'src/consent.vala',
  'src/rfb.vala',
  'src/remote_desktop.vala',
  'src/webdav.vala',
  'src/services.vala',
  'src/screens.vala',
  'src/announce.vala',
)
common_deps = [glib_dep, gio_dep, gio_unix_dep, gee_dep, json_dep, soup_dep, secret_dep, posix_dep, sharing_host_dep, system_dep]
common_c_args = [
  '-DSHARING_SYSCONFDIR="@0@"'.format(get_option('prefix') / get_option('sysconfdir')),
  '-DSHARING_CONSENT_HELPER="@0@"'.format(consent_helper),
]

executable('singularity-sharing',
  common_sources + files('src/daemon.vala'),
  dependencies: common_deps,
  vala_args: wayland_vapi_args,
  c_args: common_c_args + ['-DG_LOG_DOMAIN="singularity-sharing"'],
  install: true,
  install_dir: get_option('libexecdir'),
)

service_conf = configuration_data()
service_conf.set('libexecdir', get_option('prefix') / get_option('libexecdir'))
configure_file(
  input: 'data/dev.sinty.Sharing.service.in',
  output: 'dev.sinty.Sharing.service',
  configuration: service_conf,
  install: true,
  install_dir: get_option('datadir') / 'dbus-1' / 'services',
)
configure_file(
  input: 'data/dev.sinty.Sharing.desktop.in',
  output: 'dev.sinty.Sharing.desktop',
  configuration: service_conf,
  install: true,
  install_dir: get_option('sysconfdir') / 'xdg' / 'autostart',
)
install_data('data/dev.sinty.sharing.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas')

sharing_test = executable('sharing-test',
  common_sources + files('tests/sharing_test.vala'),
  dependencies: common_deps,
  vala_args: wayland_vapi_args,
  c_args: common_c_args,
)
test('sharing', sharing_test, env: ['GSETTINGS_BACKEND=memory', 'XDG_DATA_HOME=' + meson.current_build_dir() / 'test-data'])
