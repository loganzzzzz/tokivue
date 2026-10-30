#!/usr/bin/env python3
"""Read-only Codex telemetry. Python 3.9+, no third-party packages."""
import argparse
import base64
import contextlib
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import socket
import sqlite3
import subprocess
import struct
import sys
import threading
import time
import urllib.request
import uuid
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

ROOT = Path(__file__).resolve().parent
STATE = Path(os.environ.get('CODEX_MONITOR_HOME', Path.home() / '.codex-usage-monitor'))
KEYS = ('input_tokens', 'cached_input_tokens', 'cache_write_input_tokens',
        'output_tokens', 'reasoning_output_tokens', 'total_tokens')
COLLECTOR_REVISION = '3-image-generation-counts'


def utcnow():
    return dt.datetime.now(dt.timezone.utc)


def timezone(name):
    try:
        return ZoneInfo(name)
    except ZoneInfoNotFoundError:
        # Windows may not include an IANA database. Modern Beijing time is UTC+8.
        if name == 'Asia/Shanghai':
            return dt.timezone(dt.timedelta(hours=8), name='Asia/Shanghai')
        raise


def inode_key(number):
    # NTFS file IDs can exceed SQLite's signed 64-bit INTEGER range.
    return number if -(2**63) <= number < 2**63 else 'fileid:' + hex(number)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def save_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    temp.chmod(0o600)
    temp.replace(path)


def load_config():
    p = STATE / 'config.json'
    if p.exists():
        return json.loads(p.read_text(encoding='utf-8-sig'))
    config = {
        'device_id': str(uuid.uuid4()), 'device_name': socket.gethostname(),
        'timezone': 'Asia/Shanghai', 'work_start_hour': 9, 'work_end_hour': 18,
        'codex_home': str(Path(os.environ.get('CODEX_HOME', Path.home() / '.codex'))),
        'codex_binary': shutil.which('codex'),
        'start_date': utcnow().astimezone(timezone('Asia/Shanghai')).date().isoformat(),
        'account_key': None, 'upload_url': '', 'upload_secret': '', 'prices_per_million': {},
    }
    save_json(p, config)
    return config


def schedule_slot(now, config):
    local = now.astimezone(timezone(config['timezone']))
    work = local.weekday() < 5 and config['work_start_hour'] <= local.hour < config['work_end_hour']
    minutes = 10 if work else 60
    return int(now.timestamp()) // (minutes * 60), minutes


class Rpc:
    def __init__(self, binary, codex_home):
        if not binary:
            raise RuntimeError('Codex executable missing; set codex_binary in config.json')
        if os.name == 'nt' and Path(binary).suffix.lower() != '.exe':
            raise RuntimeError('Windows requires the native codex.exe path; rerun install_windows.py')
        env = dict(os.environ, CODEX_HOME=codex_home)
        # Stdio is the default across CLI versions; --stdio is a newer alias.
        self.proc = subprocess.Popen([binary, 'app-server'], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                                     encoding='utf-8', env=env,
                                     creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
        self.responses = queue.Queue()
        self.seq = 0
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            try:
                self.responses.put(json.loads(line))
            except ValueError:
                pass
        self.responses.put(None)

    def send(self, message):
        self.proc.stdin.write(json.dumps(message) + '\n')
        self.proc.stdin.flush()

    def call(self, method, params=None):
        self.seq += 1
        message = {'id': self.seq, 'method': method}
        if params is not None:
            message['params'] = params
        self.send(message)
        deadline = time.monotonic() + 35
        while time.monotonic() < deadline:
            try:
                result = self.responses.get(timeout=max(.01, deadline - time.monotonic()))
            except queue.Empty:
                break
            if result is None:
                raise RuntimeError('Codex app-server exited')
            if result.get('id') != self.seq:
                continue
            if 'error' in result:
                raise RuntimeError('Codex method failed: ' + method)
            return result['result']
        raise TimeoutError('Codex method timed out: ' + method)

    def close(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.proc.stdin.close()
        self.proc.stdout.close()


def resolve_codex_binary(binary):
    """Recover known macOS bundle layout changes without selecting the GUI app."""
    if sys.platform != 'darwin':
        return binary
    if binary and Path(binary).is_file() and os.access(binary, os.X_OK):
        return binary
    layouts = ('codex', 'codex-cli/bin/codex',
               'codex-cli/CodexCLI.app/Contents/MacOS/codex')
    resources = []
    if binary:
        path = Path(binary)
        for parent in path.parents:
            if (parent.name == 'Resources' and parent.parent.name == 'Contents'
                    and parent.parent.parent.suffix == '.app'
                    and path.relative_to(parent).as_posix() in layouts):
                resources.append(parent)
                break
    else:
        resources = [Path('/Applications') / app / 'Contents/Resources'
                     for app in ('ChatGPT.app', 'Codex.app')]
    for root in resources:
        for layout in layouts:
            candidate = root / layout
            if candidate.is_file() and os.access(candidate, os.X_OK):
                return str(candidate)
    return binary


def read_account(config):
    config['codex_binary'] = resolve_codex_binary(config.get('codex_binary'))
    rpc = Rpc(config['codex_binary'], config['codex_home'])
    try:
        rpc.call('initialize', {'clientInfo': {'name': 'codex_usage_monitor', 'version': '1.0.0'}})
        rpc.send({'method': 'initialized'})
        limits = rpc.call('account/rateLimits/read')
        if not limits.get('accountId'):
            raise RuntimeError('No account identity returned; refusing to mix accounts')
        account_key = digest(limits['accountId'])
        if config['account_key'] and config['account_key'] != account_key:
            raise RuntimeError('Codex account changed; use a separate CODEX_MONITOR_HOME for this account')
        config['account_key'] = account_key
        buckets = limits.get('rateLimitsByLimitId')
        if not buckets:
            primary = limits.get('rateLimits')
            buckets = {primary.get('limitId') or 'codex': primary} if primary else {}
        windows = []
        for bucket_id, bucket in buckets.items():
            for name in ('primary', 'secondary'):
                window = bucket.get(name)
                if window is not None:
                    windows.append({'limit_id': bucket_id, 'window': name,
                                    'used_percent': window.get('usedPercent'),
                                    'duration_minutes': window.get('windowDurationMins'),
                                    'resets_at': window.get('resetsAt')})
        # Deliberately omit reset-credit identifiers, email, threadUsage and auth material.
        result = {'account_key': account_key, 'observed_at': utcnow().isoformat(), 'windows': windows,
                  'reset_credits': (limits.get('rateLimitResetCredits') or {}).get('availableCount')}
        try:
            usage = rpc.call('account/usage/read')
            result['account_lifetime_tokens'] = (usage.get('summary') or {}).get('lifetimeTokens')
        except (RuntimeError, TimeoutError):
            result['account_lifetime_tokens'] = None
        return result
    finally:
        rpc.close()


def database(path):
    db = sqlite3.connect(path)
    db.execute('PRAGMA journal_mode=WAL')
    db.executescript('''
      CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY, inode INTEGER, offset INTEGER, state TEXT);
      CREATE TABLE IF NOT EXISTS events(id TEXT PRIMARY KEY, timestamp TEXT, day TEXT, model TEXT,
        data TEXT NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS snapshots(id TEXT PRIMARY KEY, data TEXT NOT NULL,
        uploaded INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS image_events(id TEXT PRIMARY KEY, timestamp TEXT, day TEXT,
        data TEXT NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
    ''')
    return db


def usage_event(timestamp, usage, event_id, state, config, **extra):
    delta = {k: int(usage.get(k) or 0) for k in KEYS}
    # A post-compaction context-size estimate has total_tokens but no input/output.
    # It is not a completed model request and must not become billable usage.
    if not timestamp or not delta['total_tokens'] or not (delta['input_tokens'] or delta['output_tokens']):
        return None
    if any(n < 0 for n in delta.values()):
        raise ValueError('Negative usage')
    instant = dt.datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
    day = instant.astimezone(timezone(config['timezone'])).date().isoformat()
    if day < config['start_date']:
        return None
    return dict(id=event_id, timestamp=timestamp, day=day,
                model=state.get('model', 'unknown'), **delta, **extra)


def token_event(entry, state, config):
    payload = entry.get('payload') or {}
    if entry.get('type') == 'turn_context':
        state['model'] = payload.get('model', 'unknown')
        return None
    if entry.get('type') == 'token_usage_record':
        # Normal requests also emit token_count. Do not add these two streams.
        state['latest_usage_record'] = {k: payload.get(k) for k in ('response_id', 'usage')}
        return None
    if entry.get('type') == 'compacted':
        response_id = payload.get('compaction_response_id')
        record = payload.get('latest_token_usage_record') or state.get('latest_usage_record') or {}
        if not response_id or record.get('response_id') != response_id or not record.get('usage'):
            state['unmeasured_compactions'] = state.get('unmeasured_compactions', 0) + 1
            return None
        # Compression usage is separate from token_count's cumulative usage.
        # Ignore turn/thread aggregates: those include earlier requests.
        event_id = digest([config['account_key'], 'compaction', response_id])
        return usage_event(entry.get('timestamp'), record['usage'], event_id, state, config,
                           source='compaction')
    if entry.get('type') != 'event_msg':
        return None
    if payload.get('type') != 'token_count':
        return None
    info = payload.get('info') or {}
    total = info.get('total_token_usage')
    if not total:
        return None
    current = {k: int(total.get(k) or 0) for k in KEYS}
    previous = state.get('total')
    state['total'] = current
    if previous == current:
        return None
    # Reconstruct increments from cumulative usage, not repeated last_token_usage notifications.
    if previous is None or any(current[k] < previous[k] for k in ('input_tokens', 'output_tokens', 'total_tokens')):
        last = info.get('last_token_usage')
        if not last:
            state['unknown_baselines'] = state.get('unknown_baselines', 0) + 1
            return None
        delta = {k: int(last.get(k) or 0) for k in KEYS}
    else:
        delta = {k: max(0, current[k] - previous[k]) for k in KEYS}
    # No device/session ID: copied logs and inherited fork history share the same fingerprint.
    timestamp = entry.get('timestamp')
    event_id = digest([config['account_key'], timestamp, current, info.get('last_token_usage')])
    return usage_event(timestamp, delta, event_id, state, config)


def image_event(entry, config):
    """Count confirmed native imagegen completions; never upload image/prompt/path data."""
    payload = entry.get('payload') or {}
    item = payload.get('item') or {}
    if (entry.get('type') != 'event_msg' or payload.get('type') != 'item_completed'
            or item.get('type') != 'Extension' or item.get('kind') != 'image_gen.generation'
            or item.get('status') != 'completed' or item.get('failure')
            or not (item.get('result') or item.get('savedPath'))):
        return None
    identity = item.get('id')
    timestamp = entry.get('timestamp')
    if not isinstance(identity, str) or not identity or not timestamp:
        return None
    instant = dt.datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
    day = instant.astimezone(timezone(config['timezone'])).date().isoformat()
    if day < config['start_date']:
        return None
    width = height = None
    # Read only the PNG header, never decode/upload full image bytes or local paths.
    encoded = item.get('result')
    if isinstance(encoded, str):
        if encoded.startswith('data:image/png;base64,'):
            encoded = encoded[22:]
        try:
            header = base64.b64decode(encoded[:48], validate=True)
            if header[:8] == b'\x89PNG\r\n\x1a\n' and header[12:16] == b'IHDR':
                width, height = struct.unpack('>II', header[16:24])
                if not (0 < width <= 20000 and 0 < height <= 20000):
                    width = height = None
        except (ValueError, struct.error):
            pass
    return {'id': digest([config['account_key'], 'imagegen', identity]),
            'timestamp': timestamp, 'day': day, 'source': 'imagegen',
            'status': 'completed', 'usage_status': 'unavailable', 'width': width, 'height': height}


def scan(db, config):
    added = 0
    bad_lines = 0
    home = Path(config['codex_home'])
    revision = db.execute("SELECT value FROM meta WHERE key='collector_revision'").fetchone()
    if not revision or revision[0] != COLLECTOR_REVISION:
        # Re-read existing logs once to backfill compression since start_date.
        # Preserve event IDs and upload acknowledgments, including older clients' IDs.
        with db:
            db.execute('DELETE FROM files')
            db.execute("INSERT OR REPLACE INTO meta VALUES('collector_revision',?)", (COLLECTOR_REVISION,))
    for folder in ('sessions', 'archived_sessions'):
        for path in sorted((home / folder).rglob('*.jsonl')):
            stat = path.stat()
            identity = inode_key(stat.st_ino)
            row = db.execute('SELECT inode,offset,state FROM files WHERE path=?', (str(path),)).fetchone()
            offset, state = (row[1], json.loads(row[2])) if row and row[0] == identity and stat.st_size >= row[1] else (0, {})
            if offset == stat.st_size:
                continue
            with path.open('rb') as stream, db:
                stream.seek(offset)
                while True:
                    line = stream.readline()
                    if not line or not line.endswith(b'\n'):
                        break  # Partial last line is retried on the next scan.
                    offset = stream.tell()
                    if not any(marker in line for marker in
                               (b'"token_count"', b'"turn_context"', b'"compacted"', b'"token_usage_record"',
                                b'"image_gen.generation"')):
                        continue
                    try:
                        entry = json.loads(line)
                        generated = image_event(entry, config)
                        if generated:
                            db.execute('INSERT OR IGNORE INTO image_events(id,timestamp,day,data) VALUES(?,?,?,?)',
                                       (generated['id'], generated['timestamp'], generated['day'], json.dumps(generated)))
                        event = token_event(entry, state, config)
                    except (ValueError, TypeError, KeyError):
                        bad_lines += 1
                        continue
                    if event:
                        result = db.execute('INSERT OR IGNORE INTO events(id,timestamp,day,model,data) VALUES(?,?,?,?,?)',
                                            (event['id'], event['timestamp'], event['day'], event['model'], json.dumps(event)))
                        added += result.rowcount
                db.execute('INSERT OR REPLACE INTO files VALUES(?,?,?,?)',
                           (str(path), identity, offset, json.dumps(state)))
    return added, bad_lines


def local_summary(db, config):
    today = utcnow().astimezone(timezone(config['timezone'])).date().isoformat()
    rows = [json.loads(r[0]) for r in db.execute('SELECT data FROM events')]
    today_tokens = sum(r['total_tokens'] for r in rows if r['day'] == today)
    images = db.execute('SELECT COUNT(*),COALESCE(SUM(day=?),0) FROM image_events', (today,)).fetchone()
    return {'today_tokens': today_tokens, 'recorded_tokens': sum(r['total_tokens'] for r in rows),
            'recorded_image_generations': images[0], 'today_image_generations': images[1],
            'event_count': len(rows), 'since': config['start_date']}


def upload(db, config):
    if not config.get('upload_url') or not config.get('upload_secret'):
        return 'not_configured'
    url = config['upload_url']
    if not url.startswith('https://script.google.com/macros/s/') or not url.endswith('/exec'):
        raise ValueError('upload_url must be a deployed Google Apps Script /exec HTTPS URL')
    sent = 0
    while True:
        events = db.execute('SELECT id,data FROM events WHERE uploaded=0 LIMIT 300').fetchall()
        snapshots = db.execute('SELECT id,data FROM snapshots WHERE uploaded=0 LIMIT 10').fetchall()
        images = db.execute('SELECT id,data FROM image_events WHERE uploaded=0 LIMIT 100').fetchall()
        if not events and not snapshots and not images:
            break
        payload = {'version': 1, 'secret': config['upload_secret'], 'account_key': config['account_key'],
                   'device_id': config['device_id'], 'device_name': config['device_name'],
                   'events': [json.loads(r[1]) for r in events], 'snapshots': [json.loads(r[1]) for r in snapshots],
                   'image_events': [json.loads(r[1]) for r in images]}
        request = urllib.request.Request(url, data=json.dumps(payload).encode(), headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=60) as response:
            ack = json.load(response)
        expected = {r[0] for r in events + snapshots + images}
        if ack.get('ok') is not True or set(ack.get('ack_ids', [])) != expected:
            raise RuntimeError('Upload not acknowledged; data retained for retry')
        with db:
            db.executemany('UPDATE events SET uploaded=1 WHERE id=?', [(r[0],) for r in events])
            db.executemany('UPDATE snapshots SET uploaded=1 WHERE id=?', [(r[0],) for r in snapshots])
            db.executemany('UPDATE image_events SET uploaded=1 WHERE id=?', [(r[0],) for r in images])
        sent += len(expected)
    return 'uploaded_' + str(sent)


@contextlib.contextmanager
def process_lock():
    STATE.mkdir(parents=True, exist_ok=True)
    STATE.chmod(0o700)
    fd = os.open(str(STATE / 'monitor.lock'), os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(fd, 'r+b') as stream:
        try:
            if os.name == 'nt':
                import msvcrt
                if os.fstat(stream.fileno()).st_size == 0:
                    stream.write(b'0')
                    stream.flush()
                stream.seek(0)
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (BlockingIOError, OSError):
            yield False
            return
        yield True


def run(force=False):
    with process_lock() as acquired:
        if not acquired:
            return
        config = load_config()
        db = database(STATE / 'usage.sqlite')
        try:
            slot = json.dumps(schedule_slot(utcnow(), config))
            last = db.execute("SELECT value FROM meta WHERE key='last_slot'").fetchone()
            if not force and last and last[0] == slot:
                return
            account = read_account(config)
            save_json(STATE / 'config.json', config)
            count, invalid = scan(db, config)
            snapshot = dict(account, id=str(uuid.uuid4()), device_id=config['device_id'])
            with db:
                db.execute('INSERT INTO snapshots(id,data) VALUES(?,?)', (snapshot['id'], json.dumps(snapshot)))
            summary = dict(snapshot, local=local_summary(db, config), device_name=config['device_name'],
                           scan_new_events=count, invalid_lines=invalid, upload_status='pending')
            save_json(STATE / 'latest.json', summary)
            try:
                summary['upload_status'] = upload(db, config)
            except Exception as exc:
                # No raw HTTP errors or URLs: logs must not disclose the shared secret.
                summary['upload_status'] = 'failed_' + type(exc).__name__
            with db:
                db.execute("INSERT OR REPLACE INTO meta VALUES('last_slot',?)", (slot,))
            save_json(STATE / 'latest.json', summary)
            print(json.dumps({'new_events': count, 'today_tokens': summary['local']['today_tokens'],
                              'upload': summary['upload_status'], 'invalid_lines': invalid}, ensure_ascii=False))
            if summary['upload_status'].startswith('failed_'):
                raise RuntimeError(summary['upload_status'])
        finally:
            db.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['run', 'init', 'status'])
    parser.add_argument('--force', action='store_true')
    args = parser.parse_args()
    if args.command == 'init':
        STATE.mkdir(parents=True, exist_ok=True)
        STATE.chmod(0o700)
        load_config()
        print('Configuration created: ' + str(STATE / 'config.json'))
    elif args.command == 'status':
        print((STATE / 'latest.json').read_text(encoding='utf-8') if (STATE / 'latest.json').exists() else 'No samples yet')
    else:
        try:
            run(args.force)
        except Exception as exc:
            print('Monitor failed: ' + str(exc), file=sys.stderr)
            sys.exit(1)


if __name__ == '__main__':
    main()
