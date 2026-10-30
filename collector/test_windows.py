import datetime as dt
import json
from pathlib import Path
import sqlite3
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

import monitor as m
import install_windows as w


def executable_fixture(path, subsystem=3):
    path.parent.mkdir(parents=True, exist_ok=True)
    data=bytearray(222);data[:2]=b'MZ';struct.pack_into('<I',data,60,128)
    data[128:132]=b'PE\0\0';struct.pack_into('<H',data,152,0x20b)
    struct.pack_into('<H',data,220,subsystem);path.write_bytes(data)


class WindowsCompatibilityTests(unittest.TestCase):
    def test_desktop_codex_is_rejected_and_bundled_cli_preferred(self):
        with tempfile.TemporaryDirectory() as folder:
            app=Path(folder)/'WindowsApps/OpenAI.Codex/app/Codex.exe'
            executable_fixture(app,2)
            self.assertIsNone(w.native_binary(app))
            cli=app.parent/'resources/codex.exe';executable_fixture(cli)
            self.assertEqual(w.native_binary(app),str(cli.resolve()))

    def test_discovery_skips_denied_cli_and_tries_next_candidate(self):
        with tempfile.TemporaryDirectory() as folder:
            old=Path(folder)/'old/codex.exe';new=Path(folder)/'new/codex.exe'
            executable_fixture(old);executable_fixture(new)
            responses=[PermissionError(13,'private detail must not be printed'),
                       subprocess.CompletedProcess([],0,b'codex-cli 0.143.0\n',b''),
                       subprocess.CompletedProcess([],0,b'Usage: codex app-server [OPTIONS]\n',b'')]
            diagnostics=[]
            with patch.object(w.shutil,'which',return_value=str(new)),patch.object(w.subprocess,'run',side_effect=responses) as run:
                self.assertEqual(w.discover_binary({'codex_binary':str(old)},diagnostics),str(new.resolve()))
                self.assertEqual(run.call_count,3)
            self.assertIn('PermissionError',diagnostics[0])
            self.assertNotIn('private detail',str(diagnostics))

    def test_probe_rejects_non_cli_help_and_timeout(self):
        with patch.object(w.subprocess,'run',return_value=subprocess.CompletedProcess([],0,b'26.825.5331',b'')):
            self.assertFalse(w.probe_cli('codex.exe')[0])
        with patch.object(w.subprocess,'run',side_effect=subprocess.TimeoutExpired([],20)):
            self.assertFalse(w.probe_cli('codex.exe')[0])
        responses=[subprocess.CompletedProcess([],0,b'codex-cli 1.0',b''),
                   subprocess.CompletedProcess([],2,b'',b'unsupported subcommand')]
        with patch.object(w.subprocess,'run',side_effect=responses):
            self.assertFalse(w.probe_cli('codex.exe')[0])

    def test_gui_candidate_never_executed(self):
        with tempfile.TemporaryDirectory() as folder:
            app=Path(folder)/'app/Codex.exe';executable_fixture(app,2)
            with patch.object(w.shutil,'which',return_value=None),patch.object(w,'powershell',return_value='[]'),patch.dict(w.os.environ,{},clear=True),patch.object(w.subprocess,'run') as run:
                self.assertIsNone(w.discover_binary({'codex_binary':str(app)}))
                run.assert_not_called()

    def test_timezone_without_windows_iana_database(self):
        config = {'timezone': 'Asia/Shanghai', 'work_start_hour': 9, 'work_end_hour': 18}
        with patch.object(m, 'ZoneInfo', side_effect=m.ZoneInfoNotFoundError):
            self.assertEqual(m.schedule_slot(dt.datetime.fromisoformat('2026-09-09T01:00:00+00:00'), config)[1], 10)
            self.assertEqual(m.schedule_slot(dt.datetime.fromisoformat('2026-09-12T01:00:00+00:00'), config)[1], 60)
            with self.assertRaises(m.ZoneInfoNotFoundError):
                m.timezone('Invalid/Timezone')

    def test_large_ntfs_ids_remain_exact_in_sqlite(self):
        db = sqlite3.connect(':memory:')
        db.execute('CREATE TABLE files(inode INTEGER)')
        for value in [123, 2**63-1, 2**64-1, 2**100+21]:
            db.execute('DELETE FROM files')
            db.execute('INSERT INTO files VALUES(?)', (m.inode_key(value),))
            self.assertEqual(db.execute('SELECT inode FROM files').fetchone()[0], m.inode_key(value))
        db.close()

    def test_configuration_unicode_roundtrip(self):
        with tempfile.TemporaryDirectory() as folder:
            with patch.object(m, 'STATE', Path(folder)):
                config = m.load_config()
                config['device_name'] = '罗根的电脑'
                config['codex_home'] = 'C:\\Users\\罗根\\.codex'
                m.save_json(Path(folder) / 'config.json', config)
                self.assertEqual(m.load_config(), config)

    def test_pairing_cannot_clone_device_or_switch_account(self):
        config = {'device_id': 'windows-device', 'account_key': 'a'*64, 'codex_home': 'local', 'start_date': '2026-09-09'}
        connection = {'device_id': 'mac-device', 'account_key': 'a'*64, 'codex_home': 'remote',
                      'start_date': '2020-01-01', 'upload_url': 'https://script.google.com/macros/s/example/exec',
                      'upload_secret': 'x'*40}
        result = w.apply_connection(config, connection)
        for key in ('device_id', 'codex_home', 'start_date'):
            self.assertEqual(result[key], config[key])
        connection['account_key'] = 'b'*64
        with self.assertRaises(ValueError):
            w.apply_connection(config, connection)
        connection['account_key'] = 'a'*64
        connection['upload_url'] = 'https://example.com/exec'
        with self.assertRaises(ValueError):
            w.apply_connection(config, connection)

    def test_task_xml_paths_and_no_password(self):
        pythonw = 'C:\\Users\\罗根 & Test\\Python\\pythonw.exe'
        runner = 'C:\\Users\\罗根 & Test\\.codex-usage-monitor\\windows_runner.py'
        xml = w.build_task_xml('S-1-5-21-123-456', pythonw, runner, 'C:\\Users\\罗根 & Test',
                               '2026-09-09T14:01:00+08:00')
        tree = ET.fromstring(xml)
        ns = {'m': w.NS}
        find = lambda name: tree.findtext(name, namespaces=ns)
        self.assertEqual(find('m:Actions/m:Exec/m:Command'), pythonw)
        self.assertEqual(find('m:Actions/m:Exec/m:Arguments'), '"' + runner + '"')
        self.assertEqual(find('m:Principals/m:Principal/m:LogonType'), 'InteractiveToken')
        self.assertEqual(find('m:Principals/m:Principal/m:RunLevel'), 'LeastPrivilege')
        self.assertEqual(find('m:Triggers/m:TimeTrigger/m:Repetition/m:Interval'), 'PT1M')
        self.assertIsNone(find('m:Triggers/m:TimeTrigger/m:Repetition/m:Duration'))
        self.assertEqual(find('m:Settings/m:MultipleInstancesPolicy'), 'IgnoreNew')
        self.assertEqual(find('m:Settings/m:DisallowStartIfOnBatteries'), 'false')
        self.assertEqual(find('m:Settings/m:WakeToRun'), 'false')
        self.assertNotIn(b'upload_secret', xml)

    def test_native_npm_binary_resolution(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            wrapper = root / 'codex.cmd'
            wrapper.write_text('@echo off')
            actual = root / 'node_modules/@openai/codex-win32-x64/vendor/x86_64-pc-windows-msvc/codex/codex.exe'
            executable_fixture(actual)
            self.assertEqual(w.native_binary(str(wrapper)), str(actual.resolve()))
            self.assertIsNone(w.native_binary(str(root / 'missing/codex.cmd')))

    def test_repeated_lock_does_not_grow(self):
        with tempfile.TemporaryDirectory() as folder:
            with patch.object(m, 'STATE', Path(folder)):
                for _ in range(5):
                    with m.process_lock() as acquired:
                        self.assertTrue(acquired)
                self.assertLessEqual((Path(folder) / 'monitor.lock').stat().st_size, 1)


if __name__ == '__main__':
    unittest.main()
