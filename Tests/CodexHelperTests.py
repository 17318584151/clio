import importlib.util
import os
from pathlib import Path
import plistlib
import socket
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
        process = subprocess.Popen([os.environ['CLIO_HELPER_BINARY'], '--proxy-host', '127.0.0.1',
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
