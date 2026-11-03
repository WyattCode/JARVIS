import importlib.util
from datetime import datetime, timezone
from pathlib import Path
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('clock_brain', Path(__file__).resolve().parents[1]/'deploy/jarvis/remote_brain.py')
brain = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(brain)
CONFIG = {'model': 'test', 'name': 'Test'}

class ClockTests(unittest.TestCase):
    def at(self, utc, messages):
        with patch.object(brain, 'datetime') as clock:
            clock.now.side_effect = lambda zone: utc.astimezone(zone)
            return brain.chat_body({'messages': messages}, CONFIG)['messages']

    def test_midnight_refresh_without_mutating_history(self):
        messages = [{'role':'system','content':'Speak Chinese'}, {'role':'user','content':'今天几号？'}]
        before = self.at(datetime(2026,10,27,15,59,59,tzinfo=timezone.utc), messages)
        after = self.at(datetime(2026,10,27,16,0,0,tzinfo=timezone.utc), messages)
        self.assertIn('2026-10-27 (星期二)', before[1]['content'])
        self.assertIn('23:59:59', before[1]['content'])
        self.assertIn('2026-10-28 (星期三)', after[1]['content'])
        self.assertIn('00:00:00', after[1]['content'])
        self.assertEqual(len(messages), 2)
        self.assertEqual(after[0], messages[0])
        self.assertEqual(after[2], messages[1])

    def test_tool_sequence_and_multimodal_content_preserved(self):
        messages = [{'role':'user','content':[{'type':'text','text':'hi'}]},
                    {'role':'assistant','content':None,'tool_calls':[{'id':'abc'}]},
                    {'role':'tool','tool_call_id':'abc','content':'done'}]
        result = brain.chat_body({'messages':messages}, CONFIG)['messages']
        self.assertEqual(result[1:], messages)
        self.assertIn('Asia/Shanghai (UTC+08:00)', result[0]['content'])
        self.assertIn('not evidence of the user physical location', result[0]['content'])
        self.assertIn('does not provide live news', result[0]['content'])

    def test_no_accumulation_for_repeated_requests(self):
        body = {'messages':[{'role':'user','content':'hello'}]}
        for _ in range(3):
            self.assertEqual(len(brain.chat_body(body, CONFIG)['messages']), 2)
        self.assertEqual(len(body['messages']), 1)

    def test_invalid_messages_rejected(self):
        for value in [None, {}, 'hello', [None]]:
            with self.assertRaises(ValueError):
                brain.chat_body({'messages':value}, CONFIG)

if __name__ == '__main__': unittest.main()
