#!/usr/bin/env python3
"""Install the collector as a current-user Windows scheduled task, without a password."""
import argparse
import datetime as dt
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import xml.etree.ElementTree as ET

import monitor

ROOT = Path(__file__).resolve().parent
NS = 'http://schemas.microsoft.com/windows/2004/02/mit/task'
MARKER = 'Codex Usage Monitor local collector v1'


def console_executable(path):
    # Electron's desktop entry point has the same filename as the Rust CLI.
    # PE subsystem 3 is a console executable; subsystem 2 is a GUI application.
    with path.open('rb') as stream:
        header = stream.read(64)
        if len(header) != 64 or header[:2] != b'MZ':
            return False
        stream.seek(struct.unpack_from('<I', header, 60)[0])
        pe = stream.read(94)
    return (len(pe) == 94 and pe[:4] == b'PE\0\0'
            and struct.unpack_from('<H', pe, 24)[0] in (0x10b, 0x20b)
            and struct.unpack_from('<H', pe, 92)[0] == 3)


def native_binary(path):
    p = Path(path)
    candidates = []
    if p.suffix.lower() == '.exe' and p.name.lower() == 'codex.exe':
        candidates = [p.parent / 'resources/codex.exe', p.parent / 'resources/bin/codex.exe', p]
    # Resolve npm's wrapper to its native optional-dependency executable; never run a .cmd via shell.
    if p.suffix.lower() in ('.cmd', '.ps1', '.js'):
        base = p.parent / 'node_modules' / '@openai'
        candidates = list(base.glob('codex/vendor/*/codex/codex.exe'))
        candidates += list(base.glob('codex-*/vendor/*/codex/codex.exe'))
        candidates += list(base.glob('codex/node_modules/@openai/codex-*/vendor/*/codex/codex.exe'))
        arch = os.environ.get('PROCESSOR_ARCHITECTURE', '').lower()
        target = 'aarch64' if arch == 'arm64' else 'x86_64'
        candidates = sorted(candidates, key=lambda c: target not in str(c))
    for candidate in candidates:
        try:
            if candidate.is_file() and console_executable(candidate):
                return str(candidate.resolve())
        except OSError:
            continue
    return None


def probe_cli(binary):
    """Check only help/version. Never start a model or execute a desktop GUI."""
    flags = getattr(subprocess, 'CREATE_NO_WINDOW', 0) if os.name == 'nt' else 0
    for args in (['--version'], ['app-server', '--help']):
        try:
            result = subprocess.run([binary, *args], stdin=subprocess.DEVNULL,
                                    capture_output=True, timeout=20, creationflags=flags)
        except OSError as exc:
            code = getattr(exc, 'winerror', None) or exc.errno
            return False, '无法启动命令行程序：' + type(exc).__name__ + '，错误码 ' + str(code)
        except subprocess.TimeoutExpired:
            return False, '命令行验证超时（20 秒）'
        output = (result.stdout + result.stderr).decode('utf-8', errors='replace').lower()
        valid = bool(re.search(r'codex(?:-cli)?\s+\d', output)) if args == ['--version'] else (
            'app-server' in output and 'usage:' in output)
        if result.returncode or not valid:
            return False, '未通过 Codex CLI / app-server 验证，退出码 ' + str(result.returncode)
    return True, '已验证 Codex CLI 和 app-server'


def powershell(script):
    system = Path(os.environ['SystemRoot']) / 'System32'
    result = subprocess.run([str(system / 'WindowsPowerShell/v1.0/powershell.exe'),
                             '-NoProfile', '-NonInteractive', '-Command',
                             '[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(); ' + script],
                            capture_output=True, timeout=60)
    if result.returncode:
        raise RuntimeError('Windows information query failed. Check local PowerShell policy.')
    return result.stdout.decode('utf-8-sig').strip()


def discover_binary(config, diagnostics=None):
    seen = set()
    def check(candidate):
        if not candidate:
            return None
        found = native_binary(candidate)
        if not found or found.casefold() in seen:
            return None
        seen.add(found.casefold())
        ok, reason = probe_cli(found)
        if diagnostics is not None:
            diagnostics.append(found + '：' + reason)
        return found if ok else None
    candidates = [config.get('codex_binary'), shutil.which('codex.exe'), shutil.which('codex')]
    if os.environ.get('LOCALAPPDATA'):
        candidates.append(str(Path(os.environ['LOCALAPPDATA']) / 'Programs/OpenAI/Codex/bin/codex.exe'))
    if os.environ.get('CODEX_INSTALL_DIR'):
        candidates.append(str(Path(os.environ['CODEX_INSTALL_DIR']) / 'codex.exe'))
    for candidate in candidates:
        found = check(candidate)
        if found:
            return found
    # Search only the installed Codex/ChatGPT app packages, not the user's documents or credentials.
    try:
        locations = json.loads(powershell(
            "@(@(Get-AppxPackage '*Codex*'; Get-AppxPackage '*ChatGPT*') | "
            "Select-Object -ExpandProperty InstallLocation -Unique) | ConvertTo-Json -Compress"))
        if isinstance(locations, str):
            locations = [locations]
        for location in locations or []:
            if location:
                for executable in Path(location).rglob('codex.exe'):
                    found = check(executable)
                    if found:
                        return found
    except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired):
        pass
    return None


def task_name(state):
    suffix = hashlib.sha256(str(state).casefold().encode('utf-8')).hexdigest()[:12]
    return 'CodexUsageMonitor-' + suffix


def build_task_xml(sid, pythonw, runner, state, start):
    ET.register_namespace('', NS)
    def add(parent, name, text=None, **attrs):
        element = ET.SubElement(parent, '{' + NS + '}' + name, attrs)
        if text is not None:
            element.text = str(text)
        return element
    root = ET.Element('{' + NS + '}Task', {'version': '1.2'})
    info = add(root, 'RegistrationInfo')
    add(info, 'Description', MARKER)
    triggers = add(root, 'Triggers')
    timer = add(triggers, 'TimeTrigger')
    repetition = add(timer, 'Repetition')
    add(repetition, 'Interval', 'PT1M')
    add(repetition, 'StopAtDurationEnd', 'false')
    add(timer, 'StartBoundary', start)
    add(timer, 'Enabled', 'true')
    login = add(triggers, 'LogonTrigger')
    add(login, 'Enabled', 'true')
    add(login, 'UserId', sid)
    principal = add(add(root, 'Principals'), 'Principal', id='CollectorUser')
    add(principal, 'UserId', sid)
    add(principal, 'LogonType', 'InteractiveToken')
    add(principal, 'RunLevel', 'LeastPrivilege')
    settings = add(root, 'Settings')
    for key, value in [('MultipleInstancesPolicy', 'IgnoreNew'), ('DisallowStartIfOnBatteries', 'false'),
                       ('StopIfGoingOnBatteries', 'false'), ('StartWhenAvailable', 'true'),
                       ('RunOnlyIfNetworkAvailable', 'false'), ('AllowStartOnDemand', 'true'),
                       ('Enabled', 'true'), ('Hidden', 'false'), ('WakeToRun', 'false'),
                       ('ExecutionTimeLimit', 'PT30M')]:
        add(settings, key, value)
    action = add(add(root, 'Actions', Context='CollectorUser'), 'Exec')
    add(action, 'Command', pythonw)
    add(action, 'Arguments', subprocess.list2cmdline([str(runner)]))
    add(action, 'WorkingDirectory', state)
    return ET.tostring(root, encoding='utf-16', xml_declaration=True)


def schtasks(*args):
    exe = Path(os.environ['SystemRoot']) / 'System32/schtasks.exe'
    return subprocess.run([str(exe), *args], capture_output=True, timeout=60)


def owned_task(name):
    result = schtasks('/Query', '/TN', name, '/XML')
    if result.returncode:
        return False
    # Some Windows versions output UTF-16, others output the console OEM code page.
    data = result.stdout
    try:
        root = ET.fromstring(data)
    except (ET.ParseError, ValueError):
        import ctypes
        text = data.decode('cp' + str(ctypes.windll.kernel32.GetOEMCP()))
        text = re.sub(r'<\?xml[^>]*\?>', '', text).strip()
        root = ET.fromstring(text)
    if root.findtext('m:RegistrationInfo/m:Description', namespaces={'m': NS}) != MARKER:
        raise RuntimeError('A task with this name belongs to another program; it was not changed.')
    return True


def restrict_directory(state, sid):
    exe = Path(os.environ['SystemRoot']) / 'System32/icacls.exe'
    result = subprocess.run([str(exe), str(state), '/inheritance:r', '/grant:r',
                             '*' + sid + ':(OI)(CI)F', '*S-1-5-18:(OI)(CI)F'],
                            capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError('Unable to protect the configuration folder with Windows user permissions.')


def apply_connection(config, connection):
    url = connection.get('upload_url', config.get('upload_url', ''))
    secret = connection.get('upload_secret', config.get('upload_secret', ''))
    expected = connection.get('account_key', config.get('account_key'))
    if not re.fullmatch(r'https://script\.google\.com/macros/s/[A-Za-z0-9_-]+/exec', url):
        raise ValueError('Invalid Google Apps Script upload URL.')
    if len(secret) < 32:
        raise ValueError('Upload key is missing or too short (at least 32 characters required).')
    if expected and not re.fullmatch(r'[a-f0-9]{64}', expected):
        raise ValueError('Invalid account fingerprint.')
    if config.get('account_key') and expected and config['account_key'] != expected:
        raise ValueError('Connection belongs to another account; existing device data was not changed.')
    # Do not import a device ID, local database, machine path or start date from another device.
    return dict(config, upload_url=url, upload_secret=secret, account_key=expected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', nargs='?', choices=['install', 'check', 'uninstall'], default='install')
    args = parser.parse_args()
    if os.name != 'nt':
        raise RuntimeError('This installer is for Windows 10/11. Use install_macos.py on a Mac.')
    if sys.version_info < (3, 9):
        raise RuntimeError('Python 3.9 or later is required.')
    state = monitor.STATE.resolve()
    name = task_name(state)
    if args.action == 'uninstall':
        if owned_task(name):
            schtasks('/End', '/TN', name)
            if schtasks('/Delete', '/TN', name, '/F').returncode:
                raise RuntimeError('Could not remove scheduled task. Check Windows Task Scheduler.')
        print('已停止并卸载定时任务。配置和历史数据保留在：' + str(state))
        return
    if args.action == 'check':
        print('定时任务：' + ('已注册' if owned_task(name) else '未注册'))
        if not (state / 'config.json').exists():
            raise RuntimeError('请先运行 01-install.cmd')
        monitor.run(force=True)
        latest = json.loads((state / 'latest.json').read_text(encoding='utf-8'))
        print('最近采集时间：' + latest['observed_at'])
        print('设备：' + latest['device_name'])
        print('上传状态：' + latest['upload_status'])
        if latest['upload_status'] == 'not_configured':
            raise RuntimeError('上传尚未配置，请重新运行安装入口。')
        return
    python = Path(sys.executable).resolve()
    pythonw = python.with_name('pythonw.exe')
    if not pythonw.is_file():
        raise RuntimeError('pythonw.exe is missing. Install the standard Windows Python distribution.')
    sid = powershell('[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value')
    if not re.fullmatch(r'S-1-[0-9-]+', sid):
        raise RuntimeError('Could not identify the current Windows user.')
    state.mkdir(parents=True, exist_ok=True)
    restrict_directory(state, sid)
    config = monitor.load_config()
    pairing = ROOT / 'connection.private.json'
    connection = {}
    if pairing.exists():
        connection = json.loads(pairing.read_text(encoding='utf-8-sig'))
        print('已读取私有连接文件（不显示密钥）。')
    elif not config.get('upload_secret'):
        connection['upload_url'] = input('请输入 Google Apps Script 接收端 HTTPS 地址：').strip()
        connection['upload_secret'] = getpass.getpass('请输入 Google 接收端 UPLOAD_SECRET（输入不回显）：').strip()
    config = apply_connection(config, connection)
    print('正在查找并验证 Codex 命令行程序（跳过桌面客户端入口）…')
    diagnostics = []
    binary = discover_binary(config, diagnostics)
    for message in diagnostics:
        print(message)
    if not binary:
        print('未自动找到原生 codex.exe。请按说明安装 Codex CLI，或粘贴客户端内 codex.exe 的完整路径。')
        candidate = input('codex.exe 路径：').strip().strip('"')
        binary = native_binary(candidate) if candidate else None
        if binary:
            ok, reason = probe_cli(binary)
            print(reason)
            if not ok:
                binary = None
    if not binary:
        raise RuntimeError('codex.exe not found. See WINDOWS-README.md.')
    config['codex_binary'] = binary
    print('Codex: ' + binary)
    print('日志目录：' + config['codex_home'])
    if not Path(config['codex_home']).is_dir():
        raise RuntimeError('Codex data directory not found. Log in and run a Codex task on this PC first.')
    print('正在检查 Codex 登录账号，请耐心等待…')
    try:
        monitor.read_account(config)  # Verify the same account before enabling a recurring upload.
    except PermissionError as exc:
        code = getattr(exc, 'winerror', None) or exc.errno
        raise RuntimeError('登录检查被 Windows 拒绝，错误码 ' + str(code)
                           + '。请确认使用平常登录 Codex 的同一 Windows 用户；'
                           '若客户端内 CLI 不可执行，请按 WINDOWS-README.md 安装独立 CLI 后重试。') from None
    existed = owned_task(name)
    if existed:
        schtasks('/End', '/TN', name)
    with monitor.process_lock() as acquired:
        if not acquired:
            raise RuntimeError('Collector is already running. Wait and rerun the installer.')
        monitor.save_json(state / 'config.json', config)
        for filename in ('monitor.py', 'windows_runner.py', 'install_windows.py', 'deployment.json'):
            source = ROOT / filename
            target = state / filename
            if source.resolve() != target.resolve():
                shutil.copy2(source, target)
        start = (dt.datetime.now().astimezone() + dt.timedelta(minutes=1)).replace(microsecond=0).isoformat()
        xml = build_task_xml(sid, str(pythonw), state / 'windows_runner.py', str(state), start)
        task_file = state / 'task.xml'
        task_file.write_bytes(xml)
        create_args = ['/Create', '/TN', name, '/XML', str(task_file)]
        if existed:
            create_args.append('/F')
        if schtasks(*create_args).returncode:
            raise RuntimeError('Task registration failed. No elevation requested; check your Windows task policy.')
        if not owned_task(name):
            raise RuntimeError('Task registration could not be verified.')
    print('定时任务已注册：' + name)
    print('北京时间：周一至周五 09–18 点每 10 分钟，其余时段每小时。')
    print('正在首次采集并验证上传；历史日志较多或网络慢时可能需要几分钟…')
    result = subprocess.run([str(python), str(state / 'windows_runner.py'), '--force'], timeout=1800)
    if result.returncode:
        raise RuntimeError('Task installed, but first upload failed. Run 02-check.cmd; see scheduler.log.')
    latest = json.loads((state / 'latest.json').read_text(encoding='utf-8'))
    if not latest.get('upload_status', '').startswith('uploaded_'):
        raise RuntimeError('Task installed, but upload confirmation is missing. Run 02-check.cmd.')
    print('安装完成，首次采集与上传成功。以后无需打开 Codex 客户端；需保持 Windows 用户已登录。')
    print('数据和日志目录：' + str(state))
    print('私有连接文件已导入配置，可移走解压目录中的 connection.private.json。')


if __name__ == '__main__':
    try:
        main()
    except (Exception, KeyboardInterrupt) as exc:
        # Never dump configuration, HTTP response content, environment or authentication material.
        print('未完成：' + (str(exc) if isinstance(exc, (RuntimeError, ValueError)) else type(exc).__name__), file=sys.stderr)
        sys.exit(1)
