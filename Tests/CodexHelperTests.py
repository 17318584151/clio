import importlib.util
import hashlib
import json
import os
from pathlib import Path
import plistlib
import socket
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

RESOURCES = Path(__file__).resolve().parents[1] / 'Sources/Clio/Resources/CodexHelper'


def load(name):
    spec = importlib.util.spec_from_file_location(name, RESOURCES / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


install = load('install')
relay = load('relay')


class FakeInstaller(install.Installer):
    def __init__(self, home, root):
        super().__init__(home, os.getuid(), os.getgid(), root)
        self.active = False
        self.calls = []
        self.fail_at = None
        self.ready = False

    def command(self, *args):
        self.calls.append(args)
        if args[0] == '/usr/bin/codesign':
            return subprocess.run(args, capture_output=True, check=False)
        if 'bootout' in args:
            self.active = False
        if 'bootstrap' in args:
            self.active = True
        return subprocess.CompletedProcess(args, 0, b'', b'')

    def status(self, *args):
        return dict(installed=self.ready, ready=self.ready)

    def loaded(self):
        return self.active, 123 if self.active else None

    def compatible(self):
        return True

    def check_ports(self):
        if self.fail_at == 'port':
            raise install.InstallError('端口占用。')

    def verify(self):
        if self.fail_at == 'verify':
            raise install.InstallError('证书校验失败。')

    def flush(self):
        if self.fail_at == 'flush':
            self.fail_at = None
            raise install.InstallError('解析缓存刷新失败。')


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='clio-helper-test-')
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root / 'user'
        for folder in ['user/.codex', 'etc', 'Library/Application Support', 'Library/LaunchDaemons']:
            (self.root / folder).mkdir(parents=True, exist_ok=True)
        self.helper = FakeInstaller(self.home, self.root)
        self.helper.native_source = Path(os.environ['CLIO_HELPER_BINARY'])
        self.helper.hosts.write_bytes(b'# existing\n127.0.0.1 localhost\n')
        self.helper.env.write_bytes(b'# user comment\nTOKEN=private\nHTTP_PROXY=http://old:1 # keep\n')
        self.before = {p: (p.read_bytes(), p.stat().st_mode) for p in [self.helper.env, self.helper.hosts]}
        self.chown = patch.object(install.os, 'chown')
        self.fchown = patch.object(install.os, 'fchown')
        self.sleep = patch.object(install.time, 'sleep')
        self.chown.start(); self.fchown.start(); self.sleep.start()
        self.http = socket.socket(); self.http.bind(('127.0.0.1', 0)); self.http.listen()
        self.socks = socket.socket(); self.socks.bind(('127.0.0.1', 0)); self.socks.listen()

    def tearDown(self):
        self.http.close(); self.socks.close()
        self.sleep.stop(); self.fchown.stop(); self.chown.stop()
        self.temporary.cleanup()

    def perform(self):
        return self.helper.install(f'http://127.0.0.1:{self.http.getsockname()[1]}',
                                   f'socks5h://127.0.0.1:{self.socks.getsockname()[1]}')

    def root_permissions(self):
        original_stat = Path.stat
        def owned_stat(path, *args, **kwargs):
            info = list(original_stat(path, *args, **kwargs))
            info[4] = self.helper.uid if path in (self.helper.env, self.helper.env.parent) else 0
            info[5] = 0
            return os.stat_result(info)
        return patch.object(Path, 'stat', owned_stat)

    def next_build(self, version=None):
        folder = Path(tempfile.mkdtemp(prefix='next-build-', dir=self.root))
        shutil.copy2(self.helper.native_source, folder / 'CodexHelper')
        bundle = folder / 'CodexHelper.app'
        shutil.copytree(self.helper.native_source.with_name('CodexHelper.app'), bundle)
        if version is not None:
            info_path = bundle / 'Contents/Info.plist'
            info = plistlib.loads(info_path.read_bytes())
            info['CFBundleVersion'] = version
            info_path.write_bytes(plistlib.dumps(info))
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--options', 'runtime', str(bundle)],
                       capture_output=True, check=True)
        self.helper.native_source = folder / 'CodexHelper'

    def assert_restored(self):
        for path, (data, mode) in self.before.items():
            self.assertEqual(path.read_bytes(), data)
            self.assertEqual(path.stat().st_mode, mode)

    def test_install_and_repeat(self):
        self.assertIn('已安装', self.perform())
        self.assertEqual(self.helper.hosts.read_text().count(install.BEGIN), 1)
        self.assertIn('TOKEN=private', self.helper.env.read_text())
        self.assertIn('# keep', self.helper.env.read_text())
        self.assertEqual(self.helper.env.stat().st_mode & 0o777, 0o600)
        self.assertIn(f'HTTP_PROXY=http://127.0.0.1:{self.http.getsockname()[1]}', self.helper.env.read_text())
        self.assertIn(f'ALL_PROXY=socks5h://127.0.0.1:{self.socks.getsockname()[1]}', self.helper.env.read_text())
        arguments = plistlib.loads(self.helper.plist.read_bytes())['ProgramArguments']
        self.assertEqual(arguments[0], str(self.helper.program))
        for path, source in self.helper.bundle_files.items():
            self.assertEqual(path.read_bytes(), source.read_bytes())
        info = plistlib.loads((self.helper.bundle / 'Contents/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleIconFile'], 'AppIcon')
        self.assertTrue(info['LSBackgroundOnly'])
        icon = self.helper.bundle / 'Contents/Resources/AppIcon.icns'
        self.assertEqual(icon.read_bytes()[:4], b'icns')
        self.assertLess(icon.stat().st_size, (RESOURCES.parents[3] / 'Resources/AppIcon.icns').stat().st_size)
        self.assertEqual(arguments[-2:], ['--proxy-port', str(self.socks.getsockname()[1])])
        self.assertEqual(list(self.helper.directory.glob('hosts.before-*'))[0].read_bytes(), self.before[self.helper.hosts][0])
        self.helper.ready = True
        calls = len(self.helper.calls)
        self.assertIn('无需更改', self.perform())
        self.assertEqual(len(self.helper.calls), calls)

    def test_uninstalled_status_returns_configured_proxy_ports(self):
        self.helper.env.write_text('TOKEN=private\nHTTP_PROXY=http://127.0.0.1:7890\nALL_PROXY=socks5h://127.0.0.1:7891\n')
        helper = install.Installer(self.home, os.getuid(), os.getgid(), self.root)
        status = helper.status()
        self.assertFalse(status['installed'])
        self.assertEqual(status['http'], 'http://127.0.0.1:7890')
        self.assertEqual(status['socks'], 'socks5h://127.0.0.1:7891')
        self.assertNotIn('private', str(status))

    def legacy_installation(self):
        self.helper.directory.mkdir()
        self.helper.legacy_program.write_bytes(self.helper.native_source.read_bytes())
        self.helper.plist.write_bytes(plistlib.dumps(dict(Label=install.LABEL,
            ProgramArguments=[str(self.helper.legacy_program), '--proxy-host', '127.0.0.1',
                              '--proxy-port', str(self.socks.getsockname()[1])],
            KeepAlive=True, RunAtLoad=True)))
        self.helper.active = True

    def test_legacy_native_service_upgrades_to_icon_bundle(self):
        self.legacy_installation()
        self.helper.hosts.write_text(install.merge_hosts(self.helper.hosts.read_text()))
        self.helper.env.write_text(install.merge_env(self.helper.env.read_text(),
            f'http://127.0.0.1:{self.http.getsockname()[1]}',
            f'socks5h://127.0.0.1:{self.socks.getsockname()[1]}'))
        self.helper.env.chmod(0o600)
        before = {path: path.read_bytes() for path in [self.helper.env, self.helper.hosts]}
        with self.root_permissions(), patch.object(self.helper, 'compatible', side_effect=lambda: install.Installer.compatible(self.helper)):
            self.assertTrue(self.helper.compatible())
            self.assertTrue(install.Installer.status(self.helper)['needsUpdate'])
            self.perform()
            self.assertTrue(self.helper.compatible())
            self.assertFalse(self.helper.legacy_program.exists())
            self.assertFalse(install.Installer.status(self.helper)['needsUpdate'])
        for path, data in before.items():
            self.assertEqual(path.read_bytes(), data)

    def test_failed_bundle_upgrade_restores_legacy_service(self):
        self.legacy_installation()
        before = {path: path.read_bytes() for path in [self.helper.legacy_program, self.helper.plist]}
        self.helper.fail_at = 'verify'
        with self.assertRaisesRegex(install.InstallError, '本次变更已撤销'):
            self.perform()
        self.assertTrue(self.helper.active)
        self.assertFalse(self.helper.bundle.exists())
        for path, data in before.items():
            self.assertEqual(path.read_bytes(), data)

    def test_upgrade_waits_for_old_listener_to_release_port(self):
        self.legacy_installation()
        with patch.object(self.helper, 'check_ports', side_effect=[install.InstallError('端口占用。'), None]) as check:
            self.perform()
        self.assertEqual(check.call_count, 2)
        self.assertTrue(self.helper.active)
        self.assertFalse(self.helper.legacy_program.exists())

    def test_known_legacy_build_is_recognized_and_modified_binary_is_rejected(self):
        self.legacy_installation()
        binary = b'known legacy build'
        self.helper.legacy_program.write_bytes(binary)
        with patch.object(install, 'LEGACY_NATIVE_HASH', hashlib.sha256(binary).hexdigest()):
            self.assertTrue(install.Installer.compatible(self.helper))
            self.helper.legacy_program.write_bytes(binary + b'modified')
            self.assertFalse(install.Installer.compatible(self.helper))

    def test_new_helper_version_upgrades_installed_bundle(self):
        self.perform()
        previous = self.helper.bundle_hashes()
        before = {path: path.read_bytes() for path in [self.helper.env, self.helper.hosts]}
        self.next_build(version='2')
        self.assertNotEqual(previous, self.helper.bundle_hashes(source=True))
        with self.root_permissions(), patch.object(self.helper, 'compatible', side_effect=lambda: install.Installer.compatible(self.helper)):
            self.assertTrue(self.helper.compatible())
            self.assertTrue(install.Installer.status(self.helper)['needsUpdate'])
            self.perform()
            self.assertTrue(self.helper.compatible())
            self.assertFalse(install.Installer.status(self.helper)['needsUpdate'])
        for path, data in before.items():
            self.assertEqual(path.read_bytes(), data)

    def test_same_version_rebuild_does_not_require_update_or_reinstall(self):
        self.perform()
        self.next_build()
        self.assertNotEqual(self.helper.bundle_hashes(), self.helper.bundle_hashes(source=True))
        with self.root_permissions(), \
                patch.object(self.helper, 'compatible', side_effect=lambda: install.Installer.compatible(self.helper)), \
                patch.object(self.helper, 'status', side_effect=lambda *args: install.Installer.status(self.helper, *args)), \
                patch.object(self.helper, 'running', return_value=True):
            state = self.helper.status()
            self.assertTrue(state['installed'])
            self.assertTrue(state['ready'])
            self.assertFalse(state['needsUpdate'])
            self.helper.calls.clear()
            self.assertIn('无需更改', self.perform())
            self.assertFalse(any(call[0] == '/bin/launchctl' for call in self.helper.calls))

    def test_older_bundled_version_does_not_offer_downgrade(self):
        self.next_build(version='2')
        self.perform()
        self.next_build(version='1')
        with self.root_permissions(), patch.object(self.helper, 'running', return_value=True):
            state = install.Installer.status(self.helper)
            self.assertFalse(state['needsUpdate'])
            self.assertTrue(state['ready'])

    def test_version_comparison_is_numeric(self):
        self.next_build(version='2')
        self.perform()
        self.next_build(version='10')
        with self.root_permissions():
            self.assertTrue(install.Installer.status(self.helper)['needsUpdate'])

    def test_rebuilt_source_can_remove_previous_bundle(self):
        self.perform()
        self.next_build()
        with self.root_permissions(), patch.object(self.helper, 'compatible', side_effect=lambda: install.Installer.compatible(self.helper)):
            self.assertEqual(self.helper.remove(), '已移除。')
        self.assertFalse(self.helper.bundle.exists())
        self.assertFalse(self.helper.build_record.exists())
        for path, (data, _) in self.before.items():
            self.assertEqual(path.read_bytes(), data)

    def test_modified_installed_binary_is_rejected(self):
        self.perform()
        self.helper.program.write_bytes(self.helper.program.read_bytes() + b'modified')
        with self.root_permissions():
            self.assertFalse(install.Installer.compatible(self.helper))

    def test_writable_build_record_is_rejected(self):
        self.perform()
        self.helper.build_record.chmod(0o666)
        with self.root_permissions():
            self.assertFalse(install.Installer.compatible(self.helper))

    def test_wrong_signed_bundle_identifier_is_rejected(self):
        self.perform()
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'other.helper',
                        str(self.helper.bundle)], capture_output=True, check=True)
        self.helper.build_record.write_text(json.dumps(dict(files=self.helper.bundle_hashes())))
        with self.root_permissions():
            self.assertFalse(install.Installer.compatible(self.helper))

    def test_status_accepts_hosts_entries_after_managed_block_and_rejects_conflicts(self):
        self.perform()
        self.helper.hosts.write_text(self.helper.hosts.read_text() + '127.0.0.2 other.local\n')
        original_stat = Path.stat
        def owned_stat(path, *args, **kwargs):
            info = list(original_stat(path, *args, **kwargs))
            info[4] = self.helper.uid if path == self.helper.env else 0
            info[5] = 0
            return os.stat_result(info)
        with patch.object(Path, 'stat', owned_stat), patch.object(self.helper, 'running', return_value=True):
            self.assertTrue(install.Installer.status(self.helper)['ready'])
            self.helper.hosts.write_text(self.helper.hosts.read_text() + f'127.0.0.2 {install.DOMAIN}\n')
            self.assertFalse(install.Installer.status(self.helper)['ready'])

    def test_repair_incomplete_configuration_of_loaded_service(self):
        self.perform()
        for damage in ('hosts', 'environment', 'permissions'):
            with self.subTest(damage=damage):
                if damage == 'hosts':
                    self.helper.hosts.write_bytes(self.before[self.helper.hosts][0])
                elif damage == 'environment':
                    self.helper.env.write_text(self.helper.env.read_text().replace('HTTPS_PROXY=', 'OLD_HTTPS_PROXY='))
                else:
                    self.helper.env.chmod(0o644)
                with self.root_permissions(), patch.object(self.helper, 'running', return_value=True):
                    state = install.Installer.status(self.helper)
                    self.assertTrue(state['installed'])
                    self.assertFalse(state['ready'])
                    self.assertFalse(state.get('needsUpdate', False))
                    self.perform()
                    self.assertTrue(install.Installer.status(self.helper)['ready'])
                self.assertTrue(self.helper.active)
                self.assertIn('TOKEN=private', self.helper.env.read_text())

    def test_repair_stopped_service(self):
        self.perform()
        self.helper.active = False
        with self.root_permissions(), patch.object(self.helper, 'running', side_effect=lambda: self.helper.active):
            state = install.Installer.status(self.helper)
            self.assertTrue(state['installed'])
            self.assertFalse(state['ready'])
            self.perform()
            self.assertTrue(install.Installer.status(self.helper)['ready'])

    def test_status_validates_proxy_endpoints_independently(self):
        self.helper.env.write_text('HTTP_PROXY=http://remote.example:7890\nALL_PROXY=socks5h://[::1]:7891\n')
        helper = install.Installer(self.home, os.getuid(), os.getgid(), self.root)
        status = helper.status()
        self.assertNotIn('http', status)
        self.assertEqual(status['socks'], 'socks5h://[::1]:7891')

    def test_missing_environment_does_not_invent_proxy_ports(self):
        self.helper.env.unlink()
        helper = install.Installer(self.home, os.getuid(), os.getgid(), self.root)
        status = helper.status()
        self.assertFalse(status['installed'])
        self.assertNotIn('http', status)
        self.assertNotIn('socks', status)

    def test_rollback_after_transport_failure(self):
        self.helper.fail_at = 'verify'
        with self.assertRaisesRegex(install.InstallError, '本次变更已撤销'):
            self.perform()
        self.assert_restored()
        self.assertFalse(self.helper.script.exists())
        self.assertFalse(self.helper.program.exists())
        self.assertFalse(self.helper.plist.exists())
        self.assertFalse(self.helper.active)
        self.assertFalse(self.helper.directory.exists())

    def test_remove_restores_environment_and_preserves_later_changes(self):
        self.perform()
        self.helper.env.write_text(self.helper.env.read_text() + 'LATER=keep\n')
        self.helper.hosts.write_text(self.helper.hosts.read_text() + '127.0.0.2 other.local\n')
        self.assertEqual(self.helper.remove(), '已移除。')
        self.assertEqual(self.helper.env.read_text(), self.before[self.helper.env][0].decode() + 'LATER=keep\n')
        self.assertEqual(self.helper.hosts.read_text(), self.before[self.helper.hosts][0].decode() + '127.0.0.2 other.local\n')
        self.assertFalse(self.helper.script.exists())
        self.assertFalse(self.helper.plist.exists())
        self.assertFalse(self.helper.active)
        self.assertFalse(self.helper.bundle.exists())
        self.assertEqual(self.helper.remove(), '已移除。')

    def test_remove_preserves_modified_proxy(self):
        self.perform()
        self.helper.env.write_text(self.helper.env.read_text().replace(
            f'HTTP_PROXY=http://127.0.0.1:{self.http.getsockname()[1]}', 'HTTP_PROXY=http://127.0.0.1:9999'))
        self.helper.remove()
        self.assertIn('HTTP_PROXY=http://127.0.0.1:9999', self.helper.env.read_text())

    def test_remove_failure_restores_service_and_configuration(self):
        self.perform()
        before = {p: p.read_bytes() for p in [self.helper.env, self.helper.hosts, self.helper.plist, self.helper.program]}
        self.helper.fail_at = 'flush'
        with self.assertRaisesRegex(install.InstallError, '本次变更已撤销'):
            self.helper.remove()
        self.assertTrue(self.helper.active)
        for path, data in before.items():
            self.assertEqual(path.read_bytes(), data)

    def test_remove_preserves_manual_environment(self):
        self.perform()
        self.helper.receipt.unlink()
        original = self.helper.env.read_bytes()
        self.helper.remove()
        self.assertEqual(self.helper.env.read_bytes(), original)

    def test_remove_unknown_service_is_rejected(self):
        self.perform()
        with patch.object(self.helper, 'compatible', return_value=False):
            with self.assertRaisesRegex(install.InstallError, '无法识别'):
                self.helper.remove()
        self.assertTrue(self.helper.active)

    def test_rollback_after_hosts_change(self):
        self.helper.fail_at = 'flush'
        with self.assertRaisesRegex(install.InstallError, '本次变更已撤销'):
            self.perform()
        self.assert_restored()

    def test_restore_existing_service(self):
        self.helper.directory.mkdir()
        self.helper.script.write_bytes(b'old script')
        self.helper.plist.write_bytes(b'old plist')
        self.helper.active = True
        self.helper.fail_at = 'verify'
        with self.assertRaises(install.InstallError):
            self.perform()
        self.assertEqual(self.helper.script.read_bytes(), b'old script')
        self.assertEqual(self.helper.plist.read_bytes(), b'old plist')
        self.assertTrue(self.helper.active)
        self.assert_restored()

    def test_port_conflict_preserves_existing_service(self):
        self.helper.directory.mkdir()
        self.helper.script.write_bytes(b'old script')
        self.helper.plist.write_bytes(b'old plist')
        self.helper.active = True
        self.helper.fail_at = 'port'
        with self.assertRaisesRegex(install.InstallError, '端口占用'):
            self.perform()
        self.assertTrue(self.helper.active)
        self.assert_restored()

    def test_symlink_rejected_before_commands(self):
        self.helper.env.unlink()
        self.helper.env.symlink_to(self.helper.hosts)
        with self.assertRaisesRegex(install.InstallError, '符号链接'):
            self.perform()
        self.assertEqual(self.helper.calls, [])

    def test_env_merge_preserves_and_deduplicates(self):
        before = '# comment\nSECRET="a # b"\nHTTP_PROXY=x # first\nexport HTTP_PROXY=y # second\nOTHER=yes'
        merged = install.merge_env(before, 'http://127.0.0.1:12', 'socks5h://127.0.0.1:13')
        self.assertIn('SECRET="a # b"\n', merged)
        self.assertIn('# first\n# second\n', merged)
        self.assertEqual(merged.count('HTTP_PROXY='), 1)
        self.assertEqual(install.merge_env(merged, 'http://127.0.0.1:12', 'socks5h://127.0.0.1:13'), merged)
        self.assertIn('SECRET=keep\r\n', install.merge_env('SECRET=keep\r\n', 'http://127.0.0.1:12', 'socks5h://127.0.0.1:13'))

    def test_unknown_service_is_preserved(self):
        self.helper.directory.mkdir()
        self.helper.script.write_bytes(b'unknown service')
        with patch.object(self.helper, 'compatible', return_value=False):
            with self.assertRaisesRegex(install.InstallError, '无法识别'):
                self.perform()
        self.assertEqual(self.helper.script.read_bytes(), b'unknown service')
        self.assert_restored()
        self.assertEqual(self.helper.calls, [])

    def test_failed_service_registration_restores_files(self):
        command = self.helper.command
        def fail_bootstrap(*args):
            if 'bootstrap' in args:
                return subprocess.CompletedProcess(args, 1, b'', b'')
            return command(*args)
        with patch.object(self.helper, 'command', side_effect=fail_bootstrap):
            with self.assertRaisesRegex(install.InstallError, '注册后台服务失败'):
                self.perform()
        self.assert_restored()
        self.assertFalse(self.helper.script.exists())

    def test_recovery_failure_is_reported(self):
        self.helper.directory.mkdir()
        self.helper.script.write_bytes(b'old script')
        self.helper.plist.write_bytes(b'old plist')
        self.helper.active = True
        self.helper.fail_at = 'verify'
        command = self.helper.command
        count = 0
        def fail_restore(*args):
            nonlocal count
            if 'bootstrap' in args:
                count += 1
                if count == 2:
                    return subprocess.CompletedProcess(args, 1, b'', b'')
            return command(*args)
        with patch.object(self.helper, 'command', side_effect=fail_restore):
            with self.assertRaisesRegex(install.InstallError, '恢复未完成：恢复原服务'):
                self.perform()
        self.assert_restored()

    def test_hosts_idempotence_and_conflicts(self):
        merged = install.merge_hosts('# keep\n127.0.0.1 localhost')
        self.assertEqual(install.merge_hosts(merged), merged)
        for value in [install.BEGIN, install.END, install.BLOCK * 2, f'1.2.3.4 {install.DOMAIN}\n']:
            with self.assertRaises(install.InstallError):
                install.merge_hosts(value)

    def test_endpoint_validation(self):
        for value in ['http://user:secret@127.0.0.1:12', 'http://remote:12', 'socks5h://127.0.0.1:12',
                      'http://127.0.0.1:65536', 'http://127.0.0.1:12/path']:
            with self.assertRaises(install.InstallError):
                install.endpoint(value, 'http')
        self.assertEqual(install.endpoint('socks5h://[::1]:3210', 'socks5h')[1], ('::1', 3210))


class RelayTests(unittest.TestCase):
    def test_dual_stack_domain_handshake_and_bytes(self):
        proxy = socket.socket(); proxy.bind(('127.0.0.1', 0)); proxy.listen()
        proxy.settimeout(5)
        observed, errors = [], []

        def upstream():
            try:
                for _ in range(2):
                    connection, _ = proxy.accept()
                    with connection:
                        connection.settimeout(5)
                        self.assertEqual(relay.read_exact(connection, 3), b'\x05\x01\x00')
                        connection.sendall(b'\x05\x00')
                        header = relay.read_exact(connection, 5)
                        self.assertEqual(header[:4], b'\x05\x01\x00\x03')
                        observed.append(relay.read_exact(connection, header[4]))
                        self.assertEqual(relay.read_exact(connection, 2), b'\x01\xbb')
                        connection.sendall(b'\x05\x00\x00\x01\x00\x00\x00\x00\x00\x00')
                        connection.sendall(relay.read_exact(connection, 6))
            except Exception as error:
                errors.append(error)

        thread = threading.Thread(target=upstream); thread.start()
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            port = reservation.getsockname()[1]
        executable = Path(os.environ['CLIO_HELPER_BINARY']).with_name('CodexHelper.app') / 'Contents/MacOS/CodexHelper'
        process = subprocess.Popen([str(executable), '--proxy-host', '127.0.0.1',
                                    '--proxy-port', str(proxy.getsockname()[1]), '--port', str(port)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            for host in ['127.0.0.1', '::1']:
                deadline = time.monotonic() + 5
                while True:
                    try:
                        client = socket.create_connection((host, port), timeout=5)
                        break
                    except ConnectionRefusedError:
                        if time.monotonic() >= deadline or process.poll() is not None:
                            raise
                        time.sleep(0.02)
                with client:
                    client.sendall(b'\x16\x03\x01abc')
                    self.assertEqual(relay.read_exact(client, 6), b'\x16\x03\x01abc')
            name = subprocess.check_output(['/bin/ps', '-p', str(process.pid), '-o', 'comm='], text=True).strip()
            self.assertEqual(Path(name).name, 'CodexHelper')
        finally:
            process.terminate(); process.wait(timeout=5)
            thread.join(6); proxy.close()
        self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(observed, [relay.TARGET, relay.TARGET])

    def test_listener_conflict_does_not_take_over_port(self):
        with socket.socket() as occupied:
            occupied.bind(('127.0.0.1', 0)); occupied.listen()
            result = subprocess.run([os.environ['CLIO_HELPER_BINARY'], '--proxy-host', '127.0.0.1',
                                     '--proxy-port', '1', '--port', str(occupied.getsockname()[1])],
                                    capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'loopback port unavailable', result.stderr)

    def test_arbitrary_proxy_and_invalid_port_rejected(self):
        for host, port in [('example.com', '1234'), ('127.0.0.1', '65536'), ('127.0.0.1', '0')]:
            result = subprocess.run([os.environ['CLIO_HELPER_BINARY'], '--proxy-host', host, '--proxy-port', port],
                                    capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 2)


if __name__ == '__main__':
    unittest.main()
