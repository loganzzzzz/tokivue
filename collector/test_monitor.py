import datetime as dt
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import monitor as m

C = {'timezone': 'Asia/Shanghai', 'work_start_hour': 9, 'work_end_hour': 18,
     'start_date': '2026-09-01', 'account_key': 'account'}


def event(total, last, timestamp='2026-09-09T01:00:00Z'):
    def tokens(n):
        return {'input_tokens': n, 'cached_input_tokens': n // 2,
                'output_tokens': n // 10, 'reasoning_output_tokens': n // 20,
                'total_tokens': n + n // 10}
    return {'timestamp': timestamp, 'type': 'event_msg', 'payload': {'type': 'token_count',
            'info': {'total_token_usage': tokens(total), 'last_token_usage': tokens(last)}}}


class MonitorTests(unittest.TestCase):
    def test_native_image_success_dimensions_and_private_fields(self):
        png = b'\x89PNG\r\n\x1a\n'+b'\0\0\0\rIHDR'+m.struct.pack('>II',1086,1448)
        entry={'timestamp':'2026-10-08T16:01:00Z','type':'event_msg','payload':{
            'type':'item_completed','item':{'type':'Extension','kind':'image_gen.generation',
            'id':'exec-image-1','status':'completed','result':m.base64.b64encode(png).decode(),
            'failure':None,'savedPath':'/private/image.png','revisedPrompt':'private prompt'}}}
        one=m.image_event(entry,C)
        self.assertEqual((one['day'],one['width'],one['height']),('2026-10-09',1086,1448))
        self.assertEqual(one['usage_status'],'unavailable')
        self.assertNotIn('private',json.dumps(one));self.assertNotIn('total_tokens',one)
        entry['timestamp']='2026-10-09T01:00:00Z'
        self.assertEqual(m.image_event(entry,C)['id'],one['id'])
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'sessions').mkdir();(root/'archived_sessions').mkdir()
            text=json.dumps(entry)+'\n'
            (root/'sessions/a.jsonl').write_text(text)
            (root/'archived_sessions/a.jsonl').write_text(text)
            db=m.database(root/'test.sqlite');config=dict(C,codex_home=folder)
            m.scan(db,config);m.scan(db,config)
            self.assertEqual(db.execute('SELECT count(*) FROM image_events').fetchone()[0],1)
            self.assertEqual(db.execute('SELECT count(*) FROM events').fetchone()[0],0)
            db.close()
        entry['payload']['item']['result']='not-base64'
        self.assertIsNone(m.image_event(entry,C)['width'])
        for status in ('failed','in_progress'):
            entry['payload']['item']['status']=status
            self.assertIsNone(m.image_event(entry,C))

    @patch.object(m.sys, 'platform', 'darwin')
    def test_macos_cli_bundle_migration(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / 'ChatGPT.app/Contents/Resources'
            old = root / 'codex'
            new = root / 'codex-cli/bin/codex'
            new.parent.mkdir(parents=True)
            new.write_text('stub'); new.chmod(0o700)
            self.assertEqual(m.resolve_codex_binary(str(old)), str(new))
            old.write_text('stub'); old.chmod(0o700)
            self.assertEqual(m.resolve_codex_binary(str(old)), str(old))
            old.unlink(); new.chmod(0o600)
            self.assertEqual(m.resolve_codex_binary(str(old)), str(old))
            new.unlink(); new.mkdir()
            self.assertEqual(m.resolve_codex_binary(str(old)), str(old))
            nested = root / 'codex-cli/CodexCLI.app/Contents/MacOS/codex'
            nested.parent.mkdir(parents=True)
            nested.write_text('stub'); nested.chmod(0o700)
            self.assertEqual(m.resolve_codex_binary(str(old)), str(nested))
            # Do not replace an explicitly configured unrelated CLI or GUI path.
            unrelated = str(root / 'other-cli')
            self.assertEqual(m.resolve_codex_binary(unrelated), unrelated)

    @patch.object(m.sys, 'platform', 'win32')
    def test_windows_cli_path_is_preserved(self):
        binary = r'C:\\tools\\codex.exe'
        self.assertEqual(m.resolve_codex_binary(binary), binary)

    def test_astra_fields_and_model_switch(self):
        state = {}
        m.token_event({'type':'turn_context','payload':{'model':'gpt-6-astra'}},state,C)
        one = event(100,100)
        for key in ('total_token_usage','last_token_usage'):
            one['payload']['info'][key]['cache_write_input_tokens'] = 20
        result = m.token_event(one,state,C)
        self.assertEqual(result['model'],'gpt-6-astra')
        self.assertEqual((result['cached_input_tokens'],result['cache_write_input_tokens']), (50,20))
        self.assertEqual(result['total_tokens'],110)  # Cache/reasoning are subsets.
        m.token_event({'type':'turn_context','payload':{'model':'gpt-5.6-sol'}},state,C)
        result = m.token_event(event(10,10,'2026-09-09T01:01:00Z'),state,C)
        self.assertEqual((result['model'],result['total_tokens']),('gpt-5.6-sol',11))

    def test_compaction_counts_request_only_and_keeps_normal_baseline(self):
        state = {'model':'gpt-6-astra'}
        first = m.token_event(event(100,100),state,C)
        usage = event(300,300)['payload']['info']['last_token_usage']
        record = {'response_id':'compression-1','usage':usage,
                  'turn_token_usage':{'total_tokens':9999},'thread_token_usage':{'total_tokens':999999}}
        self.assertIsNone(m.token_event({'type':'token_usage_record','payload':record},state,C))
        compressed = {'type':'compacted','timestamp':'2026-09-09T01:01:00Z',
                      'payload':{'compaction_response_id':'compression-1','latest_token_usage_record':record}}
        extra = m.token_event(compressed,state,C)
        self.assertEqual(extra['total_tokens'],330)
        self.assertEqual(extra['source'],'compaction')
        synthetic = event(100,100,'2026-09-09T01:01:00.010Z')
        synthetic['payload']['info']['last_token_usage'] = {'total_tokens':20000}
        self.assertIsNone(m.token_event(synthetic,state,C))
        next_request = m.token_event(event(120,20,'2026-09-09T01:02:00Z'),state,C)
        self.assertEqual(sum(x['total_tokens'] for x in (first,extra,next_request)),462)
        # Copied compaction metadata may get a new timestamp but retains its response ID.
        compressed['timestamp']='2026-09-09T02:01:00Z'
        self.assertEqual(m.token_event(compressed,state,C)['id'],extra['id'])
        del compressed['payload']['latest_token_usage_record']
        self.assertEqual(m.token_event(compressed,state,C)['id'],extra['id'])

    def test_compaction_without_matching_usage_is_unknown(self):
        for payload in ({}, {'compaction_response_id':'new','latest_token_usage_record':{
                'response_id':'old','usage':{'input_tokens':100,'total_tokens':100}}}):
            state = {}
            self.assertIsNone(m.token_event({'type':'compacted','timestamp':'2026-09-09T01:00:00Z',
                                            'payload':payload},state,C))
            self.assertEqual(state['unmeasured_compactions'],1)

    def test_context_estimate_is_not_usage_even_at_first_scan(self):
        one = event(100,100)
        one['payload']['info']['last_token_usage'] = {'total_tokens':20706}
        state = {}
        self.assertIsNone(m.token_event(one,state,C))
        self.assertEqual(m.token_event(event(200,100),state,C)['total_tokens'],110)

    def test_request_and_session_aggregates_not_added_twice(self):
        state = {}
        record = {'type':'token_usage_record','payload':{
            'response_id':'normal','usage':{'input_tokens':100,'total_tokens':110},
            'thread_token_usage':{'total_tokens':99999},'turn_token_usage':{'total_tokens':999}}}
        self.assertIsNone(m.token_event(record,state,C))
        self.assertEqual(m.token_event(event(100,100),state,C)['total_tokens'],110)
        self.assertIsNone(m.token_event(record,state,C))
        self.assertIsNone(m.token_event(event(100,100),state,C))

    def test_image_tool_output_is_not_invented_token_usage(self):
        image = {'type':'event_msg','payload':{'type':'item_completed','item':{
            'type':'McpToolCall','server':'image_gen','tool':'imagegen','status':'completed',
            'result':{'structuredContent':{'model':'gpt-image-2','bytes':999999}}}}}
        self.assertIsNone(m.token_event(image,{},C))

    def test_archive_move_and_revision_backfill_preserve_uploaded_events(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); logs=root/'sessions';logs.mkdir();archive=root/'archived_sessions';archive.mkdir()
            p=logs/'a.jsonl'; normal=event(100,100)
            usage=event(300,300)['payload']['info']['last_token_usage']
            comp={'type':'compacted','timestamp':'2026-09-09T01:01:00Z','payload':{
                'compaction_response_id':'comp','latest_token_usage_record':{'response_id':'comp','usage':usage}}}
            p.write_text(json.dumps(normal)+'\n'+json.dumps(comp)+'\n',encoding='utf-8')
            db=m.database(root/'test.sqlite');config=dict(C,codex_home=folder)
            old=m.token_event(normal,{},config)
            db.execute('INSERT INTO events VALUES(?,?,?,?,?,1)',(old['id'],old['timestamp'],old['day'],old['model'],json.dumps(old)))
            db.execute('INSERT INTO files VALUES(?,?,?,?)',(str(p),p.stat().st_ino,p.stat().st_size,'{}'));db.commit()
            self.assertEqual(m.scan(db,config)[0],1)  # Migration discovers compression only.
            self.assertEqual(db.execute('SELECT uploaded FROM events WHERE id=?',(old['id'],)).fetchone()[0],1)
            p.rename(archive/'a.jsonl')
            self.assertEqual(m.scan(db,config)[0],0)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM events').fetchone()[0],2)
            (archive/'b.jsonl').write_text(json.dumps(event(20,20,'2026-09-09T01:02:00Z'))+'\n')
            self.assertEqual(m.scan(db,config)[0],1)  # Archived-only history is included.
            db.close()

    def test_schedule_boundaries(self):
        for s, expected in [('2026-09-09T08:59:00+08:00',60), ('2026-09-09T09:00:00+08:00',10),
                            ('2026-09-09T17:59:00+08:00',10), ('2026-09-09T18:00:00+08:00',60),
                            ('2026-09-12T10:00:00+08:00',60)]:
            self.assertEqual(m.schedule_slot(dt.datetime.fromisoformat(s), C)[1], expected)

    def test_cumulative_repeat_and_reset(self):
        state = {'model': 'example'}
        self.assertEqual(m.token_event(event(100,100),state,C)['total_tokens'],110)
        self.assertIsNone(m.token_event(event(100,100),state,C))
        self.assertEqual(m.token_event(event(200,100),state,C)['total_tokens'],110)
        self.assertEqual(m.token_event(event(20,20),state,C)['total_tokens'],22)

    def test_timezone_and_no_reasoning_double_count(self):
        result = m.token_event(event(100,100,'2026-09-08T17:00:00Z'),{},C)
        self.assertEqual(result['day'],'2026-09-09')
        self.assertEqual(result['total_tokens'],110)

    def test_incremental_partial_line_and_copied_log(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); logs = root/'sessions'; logs.mkdir()
            p = logs/'a.jsonl'; one = json.dumps(event(100,100))+'\n'
            two = json.dumps(event(200,100,'2026-09-09T01:01:00Z'))+'\n'
            p.write_text(one + two[:30])
            db = m.database(root/'test.sqlite'); config = dict(C,codex_home=folder)
            self.assertEqual(m.scan(db,config)[0],1)
            self.assertEqual(m.scan(db,config)[0],0)
            with p.open('a') as f: f.write(two[30:])
            self.assertEqual(m.scan(db,config)[0],1)
            (logs/'copy.jsonl').write_text(one+two)
            self.assertEqual(m.scan(db,config)[0],0)
            self.assertEqual(db.execute('SELECT COUNT(*) FROM events').fetchone()[0],2)
            db.close()

    def test_upload_failure_keeps_outbox(self):
        with tempfile.TemporaryDirectory() as folder:
            db = m.database(Path(folder)/'test.sqlite')
            db.execute('INSERT INTO snapshots(id,data) VALUES(?,?)',('abc','{"id":"abc"}'));db.commit()
            config = dict(C,upload_url='https://script.google.com/macros/s/example/exec',
                          upload_secret='secret',device_id='device',device_name='Mac')
            with patch('urllib.request.urlopen',side_effect=TimeoutError):
                with self.assertRaises(TimeoutError):m.upload(db,config)
            self.assertEqual(db.execute('SELECT uploaded FROM snapshots').fetchone()[0],0)
            db.close()


if __name__ == '__main__':
    unittest.main()
