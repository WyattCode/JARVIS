import asyncio
import importlib.util
import json
from pathlib import Path
import sys
import time
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'deploy/jarvis'))
from chat_stream_guard import guarded_stream

def event(content=None,finish=None,tool=False):
    delta={'content':content} if content is not None else {}
    if tool:delta['tool_calls']=[{'index':0,'id':'call1','function':{'name':'generate_image','arguments':'{}'}}]
    return b'data: '+json.dumps({'choices':[{'delta':delta,'finish_reason':finish}]}).encode()+b'\n\n'
DONE=b'data: [DONE]\n\n'

class GuardTests(unittest.TestCase):
    def run_guard(self,data,headers=None):
        async def run():
            r=asyncio.StreamReader();r.feed_data(data);r.feed_eof();out=[]
            async def publish(data):out.append(data)
            value=await guarded_stream(r,headers or {},publish,{'_started':time.monotonic()})
            return value,b''.join(out)
        return asyncio.run(run())
    def test_visible_preserves_body(self):
        data=event('hello')+event(finish='stop')+DONE
        yes,out=self.run_guard(data);self.assertTrue(yes);self.assertTrue(out.endswith(b'[DONE]\n\n'));self.assertIn(b'hello',out)
    def test_empty_not_published(self):
        self.assertEqual(self.run_guard(event('  ')+event(finish='stop')+DONE),(False,b''))
    def test_inline_thinking_only_is_empty_at_every_split(self):
        text='<think>internal only</think>'
        for cut in range(len(text)+1):
            with self.subTest(cut=cut):
                self.assertEqual(self.run_guard(event(text[:cut])+event(text[cut:])+event(finish='stop')+DONE),(False,b''))
    def test_inline_thinking_followed_by_answer_preserved(self):
        text='<think>hidden</think>真正的回答。'
        for cut in range(len(text)+1):
            yes,out=self.run_guard(event(text[:cut])+event(text[cut:])+event(finish='stop')+DONE)
            self.assertTrue(yes)
    def test_unclosed_thinking_is_empty(self):
        self.assertEqual(self.run_guard(event('<think>hidden')+event(finish='stop')+DONE),(False,b''))
    def test_stray_close_discards_leaked_prefix(self):
        for text in ['hidden reasoning</think>', 'hidden reasoning</think>  ']:
            self.assertEqual(self.run_guard(event(text)+event(finish='stop')+DONE),(False,b''))
    def test_stray_close_with_answer_is_not_empty(self):
        self.assertTrue(self.run_guard(event('hidden</think>answer')+event(finish='stop')+DONE)[0])
    def test_short_plain_answer_flushes_at_done(self):
        self.assertTrue(self.run_guard(event('好')+event(finish='stop')+DONE)[0])
    def test_chunk_ending_has_its_own_deadline(self):
        from unittest.mock import patch
        async def run():
            first=event('Hello. More')
            r=asyncio.StreamReader();r.feed_data(hex(len(first))[2:].encode()+b'\r\n'+first)
            original=asyncio.wait_for
            async def fast_wait(aw, timeout):return await original(aw,min(timeout,.02))
            async def publish(data):pass
            with patch('chat_stream_guard.asyncio.wait_for',fast_wait):
                task=asyncio.create_task(guarded_stream(r,{b'transfer-encoding':b'chunked'},publish,{'_started':time.monotonic()}))
                try:
                    with self.assertRaises(asyncio.TimeoutError):await original(task,.2)
                    # Timeout must originate in the parser, not the outer test deadline.
                    self.assertFalse(task.cancelled())
                finally:
                    task.cancel();await asyncio.gather(task,return_exceptions=True)
        asyncio.run(run())
    def test_format_only_is_empty_at_every_split(self):
        for text in ['```', '_', '```\n```', '[``](https://a)', '![_](https://a)', '`'*300]:
            for cut in range(len(text)+1):
                with self.subTest(text=text[:20],cut=cut):
                    self.assertEqual(self.run_guard(event(text[:cut])+event(text[cut:])+event(finish='stop')+DONE),(False,b''))
    def test_formatted_spoken_content_is_preserved(self):
        for text in ['**你好**', '`hello`', '[label](https://a)', 'snake_case', '[happy] Hi', '(((hello)))']:
            self.assertTrue(self.run_guard(event(text)+event(finish='stop')+DONE)[0])
    def test_malformed_nested_event_fields_fail_closed(self):
        invalid=[{'choices':None},{'choices':{}},{'choices':[None]},{'choices':[{'delta':None}]},
                 {'choices':[{'delta':[]} ]},{'choices':[{'index':[]} ]},{'choices':[{'index':True}]},
                 {'choices':[{'finish_reason':{}}]},{'choices':[{'delta':{'content':[]}}]},
                 {'choices':[{'delta':{'tool_calls':{}}}]},{'choices':[{'delta':{'tool_calls':[None]}}]},
                 {'choices':[{'delta':{'tool_calls':[{'index':65}]}}]},
                 {'choices':[{'delta':{'tool_calls':[{'index':0,'function':[]}]}}]},
                 {'choices':[{'delta':{'tool_calls':[{'function':{'name':3}}]}}]}]
        for value in invalid:
            with self.subTest(value=value),self.assertRaises(OSError):
                self.run_guard(b'data: '+json.dumps(value).encode()+b'\n\n'+DONE)
    def test_usage_event_with_empty_choices_is_valid(self):
        data=event('answer')+event(finish='stop')+b'data: {"choices":[],"usage":{"total_tokens":5}}\n\n'+DONE
        self.assertTrue(self.run_guard(data)[0])
    def test_reasoning_only_is_empty(self):
        data=b'data: {"choices":[{"delta":{"reasoning_content":"thinking"}}]}\n\n'+event(finish='stop')+DONE
        self.assertEqual(self.run_guard(data),(False,b''))
    def test_tool_call_not_retried(self):
        self.assertTrue(self.run_guard(event(tool=True)+event(finish='tool_calls')+DONE)[0])
    def test_broken_stream_not_empty(self):
        with self.assertRaises(OSError):self.run_guard(event(finish='stop'))
    def test_error_event_not_empty(self):
        with self.assertRaises(OSError):self.run_guard(b'data: {"error":{"message":"failed"}}\n\n'+DONE)
    def test_chunked_frames_can_split_event(self):
        data=event('hello')+event(finish='stop')+DONE
        parts=[data[:7],data[7:31],data[31:]]
        wire=b''.join(hex(len(p))[2:].encode()+b'\r\n'+p+b'\r\n' for p in parts)+b'0\r\n\r\n'
        self.assertTrue(self.run_guard(wire,{b'transfer-encoding':b'chunked'})[0])
    def test_visible_output_not_held_for_content_length_end(self):
        async def run():
            first=event('Hello. More');last=event(finish='stop')+DONE
            r=asyncio.StreamReader();r.feed_data(first);seen=asyncio.Event()
            async def publish(data):seen.set()
            task=asyncio.create_task(guarded_stream(r,{b'content-length':str(len(first)+len(last)).encode()},publish,{'_started':time.monotonic()}))
            try:
                await asyncio.wait_for(seen.wait(),1)
                r.feed_data(last);r.feed_eof();self.assertTrue(await task)
            finally:
                task.cancel();await asyncio.gather(task,return_exceptions=True)
        asyncio.run(run())
    def test_short_content_length_rejected(self):
        with self.assertRaises(asyncio.IncompleteReadError):self.run_guard(event('hello'),{b'content-length':b'9999'})
    def test_large_prelude_rejected(self):
        with self.assertRaises(OSError):self.run_guard(b':'+b'x'* (1024*1024)+b'\n')

SPEC=importlib.util.spec_from_file_location('brain_fixture',ROOT/'tests/remote_brain_test.py')
fixture=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(fixture)
Base=fixture.Upstream
class ControlledUpstream(Base):
    def do_POST(self):
        sequence=getattr(self.server,'sequence',None)
        if not sequence:return super().do_POST()
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.server.calls.append((self.headers.get('Authorization'),body))
        data=sequence.pop(0)
        self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Content-Length',str(len(data)));self.send_header('Connection','close');self.end_headers();self.wfile.write(data)
fixture.Upstream=ControlledUpstream
class IntegrationTests(unittest.TestCase):
    setUpClass=classmethod(fixture.BridgeTests.setUpClass.__func__)
    tearDownClass=classmethod(fixture.BridgeTests.tearDownClass.__func__)
    request=fixture.BridgeTests.request
    def tearDown(self):self.servers[1].sequence=[]
    def test_voice_alias_filters_urls_internal_english_and_traditional(self):
        self.servers[1].sequence=[event('We need to call generate_image. 圖片已生成：https://a.test/a.png，請查看。')+event(finish='stop')+DONE]
        status,body=self.request('/v1/chat/completions',{'model':'new-brain--jarvis-low','stream':True,'messages':[{'role':'user','content':'生成图片'}]})
        self.assertEqual(status,200);self.assertNotIn(b'https://',body);self.assertNotIn(b'We need',body)
        text=''.join(c.get('delta',{}).get('content','') for line in body.splitlines() if line.startswith(b'data:') and line[5:].strip()!=b'[DONE]' for c in json.loads(line[5:]).get('choices',[]))
        self.assertIn('图片已生成',text);self.assertNotIn('圖片',text)
    def test_text_route_preserves_english_and_urls(self):
        self.servers[1].sequence=[event('English text: https://a.test/a.png')+event(finish='stop')+DONE]
        status,body=self.request('/v1/chat/completions',{'stream':True,'messages':[{'role':'user','content':'请给链接'}]})
        self.assertEqual(status,200);self.assertIn(b'https://a.test/a.png',body);self.assertIn(b'English text',body)
    def test_voice_filtered_empty_retries_once_in_chinese(self):
        before=len(self.servers[1].calls)
        self.servers[1].sequence=[event('We need to call generate_image.')+event(finish='stop')+DONE,event('请在界面查看图片。')+event(finish='stop')+DONE]
        status,body=self.request('/v1/chat/completions',{'model':'new-brain--jarvis-low','stream':True,'messages':[{'role':'user','content':'生成图片'}]})
        self.assertEqual(status,200);self.assertEqual(len(self.servers[1].calls)-before,2);self.assertNotIn(b'We need',body)
        self.assertIn('不得再次执行',self.servers[1].calls[-1][1]['messages'][-1]['content'])
    def test_voice_completed_receipt_does_not_retry_or_repeat_tool(self):
        before=len(self.servers[1].calls)
        self.servers[1].sequence=[event('http://a.test/a.png')+event(finish='stop')+DONE]
        messages=[{'role':'user','content':'生成图片'},{'role':'assistant','tool_calls':[{'id':'x','function':{'name':'generate_image','arguments':'{"prompt":"English prompt"}'}}]}, {'role':'tool','tool_call_id':'x','content':'{"status":"completed","urls":["http://a.test/a.png"]}'}]
        status,body=self.request('/v1/chat/completions',{'model':'new-brain--jarvis-low','stream':True,'messages':messages})
        self.assertEqual(status,200);self.assertEqual(len(self.servers[1].calls)-before,1);self.assertNotIn(b'http',body)
        self.assertNotIn('http',self.servers[1].calls[-1][1]['messages'][-1]['content'])
    def test_empty_retried_before_any_output(self):
        server=self.servers[1];start=len(server.calls)
        server.sequence=[event(finish='stop')+DONE,event('recovered')+event(finish='stop')+DONE]
        status,body=self.request('/v1/chat/completions',{'stream':True,'messages':[{'role':'user','content':'hello'}]})
        self.assertEqual(status,200);self.assertIn(b'recovered',body);self.assertEqual(len(server.calls)-start,2)
        self.assertEqual(body.count(b'[DONE]'),1)
    def test_think_only_retried_and_never_leaked(self):
        self.servers[1].sequence=[event('<thi')+event('nk>hidden</think>')+event(finish='stop')+DONE,event('recovered')+event(finish='stop')+DONE]
        status,body=self.request('/v1/chat/completions',{'stream':True,'messages':[]})
        self.assertEqual(status,200);self.assertIn(b'recovered',body);self.assertNotIn(b'hidden',body);self.assertEqual(body.count(b'[DONE]'),1)
    def test_two_think_only_replies_fail_explicitly(self):
        self.servers[1].sequence=[event('<think>hidden</think>')+event(finish='stop')+DONE]*2
        status,body=self.request('/v1/chat/completions',{'stream':True,'messages':[]})
        self.assertEqual(status,503)
    def test_format_only_retried_before_publish(self):
        self.servers[1].sequence=[event('```')+event(finish='stop')+DONE,event('recovered')+event(finish='stop')+DONE]
        status,body=self.request('/v1/chat/completions',{'stream':True,'messages':[]})
        self.assertEqual(status,200);self.assertIn(b'recovered',body);self.assertNotIn(b'```',body)
    def test_two_format_only_replies_fail_explicitly(self):
        self.servers[1].sequence=[event('```')+event(finish='stop')+DONE]*2
        self.assertEqual(self.request('/v1/chat/completions',{'stream':True,'messages':[]})[0],503)
    def test_malformed_choices_after_finish_emits_error(self):
        self.servers[1].sequence=[event('Hello. More')+event(finish='stop')+b'data: {"choices":null}\n\n'+DONE]
        status,body=self.request('/v1/chat/completions',{'stream':True,'messages':[]})
        self.assertEqual(status,200);self.assertIn(b'"error"',body);self.assertNotIn(b'[DONE]',body);self.assertNotIn(b'"choices":null',body)
    def test_malformed_choices_before_publish_is_503(self):
        self.servers[1].sequence=[b'data: {"choices":null}\n\n'+DONE]
        self.assertEqual(self.request('/v1/chat/completions',{'stream':True,'messages':[]})[0],503)
    def test_two_empty_replies_fail_explicitly(self):
        self.servers[1].sequence=[event(finish='stop')+DONE]*2
        status,body=self.request('/v1/chat/completions',{'stream':True,'messages':[]})
        self.assertEqual(status,503);self.assertIn('空回复',json.loads(body)['error']['message'])
    def test_tool_call_not_duplicated(self):
        server=self.servers[1];start=len(server.calls)
        server.sequence=[event(tool=True)+event(finish='tool_calls')+DONE]
        status,body=self.request('/v1/chat/completions',{'stream':True,'messages':[]})
        self.assertEqual(status,200);self.assertEqual(len(server.calls)-start,1);self.assertIn(b'generate_image',body)
    def test_broken_visible_stream_emits_error_not_success(self):
        self.servers[1].sequence=[event('Partial. More')+event(finish='stop')]
        status,body=self.request('/v1/chat/completions',{'stream':True,'messages':[]})
        self.assertEqual(status,200);self.assertIn(b'"error"',body);self.assertNotIn(b'[DONE]',body)
    def test_broken_empty_stream_not_retried(self):
        server=self.servers[1];start=len(server.calls);server.sequence=[event(finish='stop')]
        status,body=self.request('/v1/chat/completions',{'stream':True,'messages':[]})
        self.assertEqual(status,503);self.assertEqual(len(server.calls)-start,1)

if __name__=='__main__':unittest.main()
