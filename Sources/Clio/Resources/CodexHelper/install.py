import argparse
import ast
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import pwd
import re
import socket
import stat
import subprocess
import tempfile
import time
from urllib.parse import urlsplit

LABEL = 'local.codex.backend-relay'
DOMAIN = 'codex-cloud-backend.chatgpt.com'
BEGIN = '# BEGIN Codex backend relay'
END = '# END Codex backend relay'
BLOCK = f'{BEGIN}\n127.0.0.1 {DOMAIN}\n::1 {DOMAIN}\n{END}\n'
LEGACY_HASH = '829b89207bc87684c0f03149e71fff9287ba3716bf72a8563c200a475b87c7be'
# Native helper shipped in Clio 1.1.26 for Apple Silicon.
LEGACY_NATIVE_HASH = 'd4247d46d53fe551372cc38d6355c06594c36dfb80b3711b5b5ef48773384f52'
KEY = re.compile(r'^(\s*(?:export\s+)?)(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY)\s*=')


class InstallError(Exception):
    pass


def endpoint(value, scheme):
    parsed = urlsplit(value)
    try:
        port = parsed.port
    except ValueError:
        port = None
    if (parsed.scheme != scheme or parsed.hostname not in ('127.0.0.1', '::1', 'localhost')
            or not port or parsed.username is not None or parsed.password is not None
            or parsed.path or parsed.query or parsed.fragment):
        raise InstallError('请输入不含认证信息的本机 HTTP 和 SOCKS5 代理地址及端口。')
    host = f'[{parsed.hostname}]' if ':' in parsed.hostname else parsed.hostname
    return f'{scheme}://{host}:{port}', (parsed.hostname, port)


def merge_env(original, http, socks):
    values = dict(HTTP_PROXY=http, HTTPS_PROXY=http, ALL_PROXY=socks, NO_PROXY='localhost,127.0.0.1,::1')
    seen, lines = set(), []
    for line in original.splitlines(keepends=True):
        match = KEY.match(line)
        if not match:
            lines.append(line)
            continue
        key = match[2]
        # Only an unquoted whitespace-prefixed # starts an inline comment.
        tail = line[match.end():].rstrip('\r\n')
        quoted, comment = None, ''
        for index, char in enumerate(tail):
            if char in ('"', "'"):
                quoted = None if quoted == char else (char if quoted is None else quoted)
            if char == '#' and quoted is None and index > 0 and tail[index - 1].isspace():
                comment = tail[index:]
                break
        if key not in seen:
            lines.append(f'{match[1]}{key}={values[key]}' + (f' {comment}' if comment else '') + '\n')
            seen.add(key)
        elif comment:
            lines.append(comment + '\n')
    result = ''.join(lines)
    if result and not result.endswith('\n'):
        result += '\n'
    return result + ''.join(f'{key}={value}\n' for key, value in values.items() if key not in seen)


def merge_hosts(original, removing=False):
    lines, inside, blocks = [], False, 0
    for line in original.splitlines(keepends=True):
        marker = line.strip()
        if marker == BEGIN:
            if inside or blocks:
                raise InstallError('hosts 的 Codex 标记重复，需先检查现有配置。')
            inside, blocks = True, blocks + 1
        elif marker == END:
            if not inside:
                raise InstallError('hosts 的 Codex 标记不完整。')
            inside = False
        elif not inside:
            if DOMAIN in line.split('#', 1)[0].split()[1:]:
                raise InstallError('hosts 存在标记之外的 Codex 映射，需先检查现有配置。')
            lines.append(line)
    if inside:
        raise InstallError('hosts 的 Codex 标记不完整。')
    result = ''.join(lines)
    return result if removing else result + ('\n' if result and not result.endswith('\n') else '') + BLOCK


def restore_env(current, original, managed):
    previous = {}
    for line in original.splitlines(keepends=True):
        match = KEY.match(line)
        if match:
            previous.setdefault(match[2], []).append(line)
    restored, lines = set(), []
    for line in current.splitlines(keepends=True):
        match = KEY.match(line)
        if not match:
            lines.append(line)
            continue
        key = match[2]
        value = line[match.end():].split(' #', 1)[0].strip().strip('\"\'')
        if value != managed.get(key):
            lines.append(line)
        elif key not in restored:
            lines.extend(previous.get(key, []))
            restored.add(key)
    return ''.join(lines)


def safe_path(path):
    for item in [path] + list(path.parents):
        if item.is_symlink():
            raise InstallError('安装路径含符号链接，已停止安装。')
    if path.exists() and not (path.is_file() or path.is_dir()):
        raise InstallError('安装路径不是普通文件或目录。')


def atomic_write(path, data, mode, uid, gid):
    safe_path(path)
    descriptor, temporary = tempfile.mkstemp(prefix='.codex-helper-', dir=path.parent)
    try:
        with os.fdopen(descriptor, 'wb') as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
            os.fchmod(output.fileno(), mode)
            os.fchown(output.fileno(), uid, gid)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class Installer:
    def __init__(self, home, uid, gid, root=Path('/')):
        self.uid, self.gid = uid, gid
        self.env = home / '.codex/.env'
        # /etc is a system symlink on macOS; resolve that fixed alias only.
        self.hosts = Path('/private/etc/hosts') if root == Path('/') else root / 'etc/hosts'
        self.directory = root / 'Library/Application Support/CodexBackendRelay'
        self.script = self.directory / 'codex-backend-relay.py'
        self.legacy_program = self.directory / 'CodexHelper'
        self.bundle = self.directory / 'CodexHelper.app'
        self.program = self.bundle / 'Contents/MacOS/CodexHelper'
        self.plist = root / f'Library/LaunchDaemons/{LABEL}.plist'
        self.source = Path(__file__).with_name('relay.py')
        self.native_source = Path(__file__).with_name('CodexHelper')
        self.receipt = self.directory / 'clio-install.json'
        self.build_record = self.directory / 'helper-build.json'
        self.env_backup = self.directory / 'env.before-clio'

    @property
    def bundle_files(self):
        source = self.native_source.with_name('CodexHelper.app')
        return {self.bundle / relative: source / relative for relative in [
            'Contents/MacOS/CodexHelper', 'Contents/Info.plist',
            'Contents/Resources/AppIcon.icns', 'Contents/_CodeSignature/CodeResources']}

    @property
    def bundle_directories(self):
        return [self.bundle, self.bundle / 'Contents', self.bundle / 'Contents/MacOS',
                self.bundle / 'Contents/Resources', self.bundle / 'Contents/_CodeSignature']

    def bundle_hashes(self, source=False):
        return {str(path.relative_to(self.bundle)): hashlib.sha256((origin if source else path).read_bytes()).hexdigest()
                for path, origin in self.bundle_files.items()}

    def recognized_bundle(self):
        for path in [self.directory, *self.bundle_directories, *self.bundle_files, self.build_record]:
            safe_path(path)
            info = path.stat()
            mode = 0o755 if path.is_dir() or path == self.program else 0o644
            if info.st_uid != 0 or info.st_gid != 0 or stat.S_IMODE(info.st_mode) != mode:
                return False
        record = json.loads(self.build_record.read_bytes())
        return (record['files'] == self.bundle_hashes()
                and self.command('/usr/bin/codesign', '--verify', '--strict', '-R',
                                 '=identifier "com.kira.clio.codex-helper"', str(self.bundle)).returncode == 0)

    def command(self, *args):
        return subprocess.run(args, capture_output=True, timeout=45, check=False)

    def loaded(self):
        result = self.command('/bin/launchctl', 'print', f'system/{LABEL}')
        text = result.stdout.decode(errors='replace')
        match = re.search(r'\bpid = (\d+)', text)
        return result.returncode == 0, int(match[1]) if match else None

    def running(self):
        _, pid = self.loaded()
        if not pid:
            return False
        for host in ('127.0.0.1', '::1'):
            try:
                with socket.create_connection((host, 443), timeout=2):
                    pass
            except OSError:
                return False
        return True

    def service_proxy(self):
        config = plistlib.loads(self.plist.read_bytes())
        args = config['ProgramArguments']
        if len(args) == 3:
            assignment = next(node for node in ast.parse(self.script.read_text()).body
                              if isinstance(node, ast.Assign)
                              and any(isinstance(target, ast.Name) and target.id == 'PROXY' for target in node.targets))
            host, port = ast.literal_eval(assignment.value)
            return endpoint(f'socks5h://{host}:{port}', 'socks5h')[0]
        offset = 1 if args[0] in (str(self.program), str(self.legacy_program)) else 3
        host = f'[{args[offset + 1]}]' if ':' in args[offset + 1] else args[offset + 1]
        return endpoint(f'socks5h://{host}:{args[offset + 3]}', 'socks5h')[0]

    def compatible(self):
        try:
            config = plistlib.loads(self.plist.read_bytes())
            args = config['ProgramArguments']
            base = ['/usr/bin/python3', '-I', str(self.script)]
            if config.get('Label') != LABEL or not config.get('KeepAlive') or not config.get('RunAtLoad'):
                return False
            if args[0] in (str(self.program), str(self.legacy_program)):
                program = Path(args[0])
                if program == self.program:
                    binary_matches = self.recognized_bundle()
                else:
                    digest = hashlib.sha256(program.read_bytes()).hexdigest()
                    binary_matches = digest in (hashlib.sha256(self.native_source.read_bytes()).hexdigest(), LEGACY_NATIVE_HASH)
                return (len(args) == 5 and args[1] == '--proxy-host' and args[3] == '--proxy-port'
                        and binary_matches
                        and bool(endpoint(self.service_proxy(), 'socks5h')))
            digest = hashlib.sha256(self.script.read_bytes()).hexdigest()
            if args == base and digest == LEGACY_HASH:
                return True
            if digest != hashlib.sha256(self.source.read_bytes()).hexdigest() or args[:3] != base:
                return False
            return (len(args) == 7 and args[3] == '--proxy-host' and args[5] == '--proxy-port'
                    and endpoint(f'socks5h://{("[" + args[4] + "]") if ":" in args[4] else args[4]}:{args[6]}', 'socks5h'))
        except (OSError, ValueError, KeyError, IndexError, TypeError, InstallError):
            return False

    def status(self, http=None, socks=None):
        installed = bool(self.compatible())
        detected = {}
        try:
            for path in [self.env, self.hosts, self.directory, self.script, self.plist, self.legacy_program, *self.bundle_files, self.build_record]:
                safe_path(path)
            env = self.env.read_bytes().decode('utf-8') if self.env.exists() else ''
            # Export only validated loopback endpoints; no other user content leaves this process.
            values = {}
            for line in env.splitlines():
                match = KEY.match(line)
                if match:
                    values[match[2]] = line[match.end():].split(' #', 1)[0].strip().strip('\"\'')
            for name, key, scheme in [('http', 'HTTP_PROXY', 'http'), ('socks', 'ALL_PROXY', 'socks5h')]:
                try:
                    detected[name] = endpoint(values.get(key, ''), scheme)[0]
                except (ValueError, InstallError):
                    pass
            detected_http = detected.get('http', '')
            detected_socks = detected.get('socks', '')
            expected = merge_env(env, http or detected_http, socks or detected_socks)
            hosts = self.hosts.read_bytes().decode('utf-8')
            program = plistlib.loads(self.plist.read_bytes())['ProgramArguments'][0]
            native = program in (str(self.program), str(self.legacy_program))
            executable = Path(program) if native else self.script
            needs_update = installed and (program != str(self.program) or self.bundle_hashes() != self.bundle_hashes(source=True))
            permissions = all(stat.S_IMODE(p.stat().st_mode) == mode and p.stat().st_uid == owner
                              and (owner != 0 or p.stat().st_gid == 0)
                              for p, mode, owner in [(self.env, 0o600, self.uid), (executable, 0o755 if native else 0o644, 0),
                                                     (self.plist, 0o644, 0), (self.directory, 0o755, 0)])
            ready = (env == expected and BLOCK in hosts and bool(merge_hosts(hosts))
                     and permissions and self.compatible() and not needs_update
                     and self.service_proxy() == (socks or detected_socks) and self.running())
            return dict(installed=installed, ready=bool(ready), needsUpdate=needs_update, message='辅助服务可更新。' if needs_update else '已安装，IPv4 / IPv6 转发服务正在运行。' if ready
                        else '配置不完整或服务未运行，可安装或修复。', **detected)
        except (OSError, ValueError, KeyError, IndexError, TypeError, InstallError):
            return dict(installed=installed, ready=False, message='已安装，配置不完整或服务未运行。' if installed else '未安装。', **detected)

    def flush(self):
        for args in [('/usr/bin/dscacheutil', '-flushcache'), ('/usr/bin/killall', '-HUP', 'mDNSResponder')]:
            if self.command(*args).returncode:
                raise InstallError('刷新系统解析缓存失败。')

    def verify(self):
        for host in ('127.0.0.1', '[::1]'):
            result = self.command('/usr/bin/curl', '--noproxy', '*', '--connect-to',
                                  f'{DOMAIN}:443:{host}:443', '--connect-timeout', '10', '--max-time', '15',
                                  '-sS', '-o', '/dev/null', f'https://{DOMAIN}/')
            if result.returncode:
                raise InstallError('转发连接或加密证书校验失败，请检查代理是否可访问 Codex 后台。')
        if not self.running():
            raise InstallError('服务未同时监听本机 IPv4 和 IPv6。')

    def check_ports(self):
        for family, host in [(socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')]:
            with socket.socket(family, socket.SOCK_STREAM) as probe:
                if family == socket.AF_INET6:
                    probe.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                try:
                    probe.bind((host, 443))
                except OSError:
                    raise InstallError('本机 443 端口被其他服务占用，已停止安装。')

    def install(self, http, socks):
        http, http_address = endpoint(http, 'http')
        socks, socks_address = endpoint(socks, 'socks5h')
        for path in [self.env, self.hosts, self.directory, self.script, self.legacy_program, *self.bundle_files, self.plist, self.receipt, self.build_record, self.env_backup]:
            safe_path(path)
        if self.env.parent.exists() and self.env.parent.stat().st_uid != self.uid:
            raise InstallError('Codex 配置目录不属于当前用户，已停止安装。')
        if self.status(http, socks).get('ready'):
            return '已安装，配置无需更改。'
        for address in (http_address, socks_address):
            try:
                with socket.create_connection(address, timeout=3):
                    pass
            except OSError:
                raise InstallError('本机代理端口无法连接，安装未开始。')
        if (self.script.exists() or self.legacy_program.exists() or self.bundle.exists() or self.plist.exists()) and not self.compatible():
            raise InstallError('发现无法识别的同名服务，已保留现有配置并停止安装。')
        old_loaded, _ = self.loaded()
        if old_loaded and not self.compatible():
            raise InstallError('发现无法识别的已加载服务，已停止安装。')
        upgrade_only = (old_loaded and (self.legacy_program.exists() or self.program.exists())
                        and self.compatible() and self.service_proxy() == socks)
        original_hosts = self.hosts.read_bytes().decode('utf-8')
        new_hosts = merge_hosts(original_hosts).encode()
        original_env = self.env.read_bytes().decode('utf-8') if self.env.exists() else ''
        new_env = merge_env(original_env, http, socks).encode()
        paths = [self.hosts, self.env, self.script, self.legacy_program, *self.bundle_files, self.plist, self.receipt, self.build_record, self.env_backup]
        snapshots = {p: (p.read_bytes(), p.stat()) if p.exists() else None for p in paths}
        directory_stat = self.directory.stat() if self.directory.exists() else None
        created = []
        backup = None
        changed = False
        try:
            for path, mode, uid, gid in [(self.env.parent, 0o700, self.uid, self.gid),
                                         (self.directory, 0o755, 0, 0),
                                         *((path, 0o755, 0, 0) for path in self.bundle_directories)]:
                if not path.exists():
                    path.mkdir(mode=mode)
                    os.chown(path, uid, gid)
                    created.append(path)
            if old_loaded:
                if self.command('/bin/launchctl', 'bootout', f'system/{LABEL}').returncode:
                    raise InstallError('停止已有服务失败。')
                changed = True
            attempts = 20 if old_loaded else 1
            for attempt in range(attempts):
                try:
                    self.check_ports()
                    break
                except InstallError:
                    if attempt == attempts - 1:
                        raise
                    time.sleep(0.1)
            backup = self.directory / f'hosts.before-{time.time_ns()}'
            atomic_write(backup, snapshots[self.hosts][0], 0o600, 0, 0)
            config = dict(Label=LABEL, ProgramArguments=[str(self.program),
                          '--proxy-host', socks_address[0], '--proxy-port', str(socks_address[1])],
                          KeepAlive=True, RunAtLoad=True, ThrottleInterval=10)
            changed = True
            os.chmod(self.directory, 0o755)
            os.chown(self.directory, 0, 0)
            if not self.receipt.exists():
                atomic_write(self.env_backup, original_env.encode(), 0o600, 0, 0)
            receipt = dict(uid=self.uid, env_existed=snapshots[self.env] is not None,
                           managed=dict(HTTP_PROXY=http, HTTPS_PROXY=http, ALL_PROXY=socks,
                                        NO_PROXY='localhost,127.0.0.1,::1'))
            if self.receipt.exists():
                previous = json.loads(self.receipt.read_bytes())
                if previous['uid'] != self.uid:
                    raise InstallError('该辅助服务由其他用户安装，已停止操作。')
                receipt['env_existed'] = previous['env_existed']
            atomic_write(self.receipt, json.dumps(receipt).encode(), 0o600, 0, 0)
            for path, source in self.bundle_files.items():
                atomic_write(path, source.read_bytes(), 0o755 if path == self.program else 0o644, 0, 0)
            atomic_write(self.build_record, json.dumps(dict(files=self.bundle_hashes())).encode(), 0o644, 0, 0)
            atomic_write(self.plist, plistlib.dumps(config), 0o644, 0, 0)
            if self.command('/bin/launchctl', 'bootstrap', 'system', str(self.plist)).returncode:
                raise InstallError('注册后台服务失败。')
            time.sleep(1)
            self.verify()
            if not upgrade_only:
                atomic_write(self.env, new_env, 0o600, self.uid, self.gid)
                hosts_stat = snapshots[self.hosts][1]
                atomic_write(self.hosts, new_hosts, stat.S_IMODE(hosts_stat.st_mode), hosts_stat.st_uid, hosts_stat.st_gid)
                self.flush()
            self.script.unlink(missing_ok=True)
            self.legacy_program.unlink(missing_ok=True)
            return '已安装。'
        except Exception as error:
            failures = []
            if changed:
                try:
                    stopped = self.command('/bin/launchctl', 'bootout', f'system/{LABEL}')
                    if stopped.returncode and self.loaded()[0]:
                        failures.append('停止新服务')
                except Exception:
                    failures.append('停止新服务')
                for path, snapshot in snapshots.items():
                    try:
                        if snapshot:
                            data, info = snapshot
                            atomic_write(path, data, stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid)
                        else:
                            path.unlink(missing_ok=True)
                    except Exception:
                        failures.append('恢复文件')
                if directory_stat:
                    try:
                        os.chmod(self.directory, stat.S_IMODE(directory_stat.st_mode))
                        os.chown(self.directory, directory_stat.st_uid, directory_stat.st_gid)
                    except Exception:
                        failures.append('恢复目录权限')
                if old_loaded:
                    try:
                        if self.command('/bin/launchctl', 'bootstrap', 'system', str(self.plist)).returncode:
                            failures.append('恢复原服务')
                    except Exception:
                        failures.append('恢复原服务')
                try:
                    self.flush()
                except Exception:
                    failures.append('刷新解析缓存')
            if backup and not failures:
                try:
                    backup.unlink(missing_ok=True)
                except OSError:
                    failures.append('清理本次备份')
            for path in reversed(created):
                try:
                    path.rmdir()
                except OSError:
                    pass
            detail = str(error) if isinstance(error, InstallError) else '文件操作或系统命令失败。'
            raise InstallError(detail + ('恢复未完成：' + '、'.join(failures) if failures else '本次变更已撤销。'))

    def remove(self):
        for path in [self.env, self.hosts, self.directory, self.script, self.legacy_program, *self.bundle_files, self.plist, self.receipt, self.build_record, self.env_backup]:
            safe_path(path)
        if not self.script.exists() and not self.legacy_program.exists() and not self.bundle.exists() and not self.plist.exists() and not self.loaded()[0]:
            return '已移除。'
        if not self.compatible():
            raise InstallError('无法识别现有辅助服务，已停止移除。')
        current = self.env.read_bytes().decode('utf-8') if self.env.exists() else ''
        if self.receipt.exists():
            receipt = json.loads(self.receipt.read_bytes())
            if receipt['uid'] != self.uid:
                raise InstallError('该辅助服务由其他用户安装，已停止移除。')
            original = self.env_backup.read_bytes().decode('utf-8')
            restored = restore_env(current, original, receipt['managed'])
            remove_empty_env = not receipt['env_existed']
        else:
            # Manual installations have no record of changes to the user's environment.
            restored = current
            remove_empty_env = False
        hosts = merge_hosts(self.hosts.read_bytes().decode('utf-8'), removing=True).encode()
        paths = [self.hosts, self.env, self.script, self.legacy_program, *self.bundle_files, self.plist, self.receipt, self.build_record, self.env_backup]
        snapshots = {p: (p.read_bytes(), p.stat()) if p.exists() else None for p in paths}
        was_loaded, _ = self.loaded()
        try:
            if was_loaded and self.command('/bin/launchctl', 'bootout', f'system/{LABEL}').returncode:
                raise InstallError('停止辅助服务失败。')
            info = snapshots[self.hosts][1]
            atomic_write(self.hosts, hosts, stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid)
            if self.env.exists():
                if not restored and remove_empty_env:
                    self.env.unlink()
                else:
                    atomic_write(self.env, restored.encode(), 0o600, self.uid, self.gid)
            self.flush()
            for path in [self.script, self.legacy_program, *self.bundle_files, self.plist, self.receipt, self.build_record, self.env_backup]:
                path.unlink(missing_ok=True)
            for path in reversed(self.bundle_directories):
                try:
                    path.rmdir()
                except OSError:
                    pass
            return '已移除。'
        except Exception as error:
            failures = []
            for path, snapshot in snapshots.items():
                try:
                    if snapshot:
                        data, info = snapshot
                        atomic_write(path, data, stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid)
                except Exception:
                    failures.append('恢复文件')
            try:
                if was_loaded and not self.loaded()[0]:
                    if self.command('/bin/launchctl', 'bootstrap', 'system', str(self.plist)).returncode:
                        failures.append('恢复服务')
                self.flush()
            except Exception:
                failures.append('恢复服务或解析缓存')
            detail = str(error) if isinstance(error, InstallError) else '移除失败。'
            raise InstallError(detail + ('恢复未完成：' + '、'.join(failures) if failures else '本次变更已撤销。'))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['status', 'install', 'remove'])
    parser.add_argument('--uid', type=int, required=True)
    parser.add_argument('--http')
    parser.add_argument('--socks')
    parser.add_argument('--helper-binary')
    args = parser.parse_args()
    account = pwd.getpwuid(args.uid)
    installer = Installer(Path(account.pw_dir), args.uid, account.pw_gid)
    if args.helper_binary:
        installer.native_source = Path(args.helper_binary)
    try:
        if args.action == 'status':
            result = installer.status()
        else:
            if os.geteuid() != 0 or args.uid == 0:
                raise InstallError('安装需要管理员权限和有效的登录用户。')
            lock_fd = os.open('/var/run/local.codex.backend-relay.install.lock',
                              os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            with os.fdopen(lock_fd, 'w') as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    raise InstallError('另一项安装正在执行，请等待完成。')
                if args.action == 'remove':
                    result = dict(installed=False, message=installer.remove())
                else:
                    result = dict(installed=True, ready=True, message=installer.install(args.http or '', args.socks or ''))
        print(json.dumps(result, ensure_ascii=False))
    except Exception as error:
        print(json.dumps(dict(installed=bool(installer.compatible()), message=str(error) if isinstance(error, InstallError)
                              else '检测或安装失败，请检查文件权限及系统 Python。'), ensure_ascii=False))
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
