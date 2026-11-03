"""Public MCP links and slow-but-valid PNG recovery, using only local fakes."""
import asyncio
import http.client
import json
from pathlib import Path
import time
import unittest
from unittest.mock import patch

import cross_path_backend_test as cache_fixture
import public_access_test as public_fixture


class RecoveryBoundaryTests(unittest.IsolatedAsyncioTestCase):
    asyncSetUp = cache_fixture.CrossPath.asyncSetUp
    asyncTearDown = cache_fixture.CrossPath.asyncTearDown
    shared = cache_fixture.CrossPath.shared
    slow_download = False

    async def worker(self, reader, writer, role):
        if role != 'image' or not self.slow_download:
            return await cache_fixture.CrossPath.worker(self, reader, writer, role)
        self.handlers.append(asyncio.current_task())
        try:
            await reader.readuntil(b'\r\n\r\n')
            body = cache_fixture.PNG
            writer.write(f'HTTP/1.1 200 OK\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n'.encode()+body[:20])
            await writer.drain()
            for block in (body[20:40], body[40:]):
                await asyncio.sleep(2.7)
                writer.write(block); await writer.drain()
        finally:
            writer.close(); await writer.wait_closed()

    async def test_public_waits_for_valid_repair_longer_than_old_five_second_limit(self):
        self.image.write_bytes(cache_fixture.PNG[:40]); self.slow_download = True
        started = time.monotonic()
        status, body, _ = await self.shared()
        self.assertEqual((status, body), (200, cache_fixture.PNG))
        self.assertGreater(time.monotonic()-started, 5)
        self.assertEqual(self.image.read_bytes(), cache_fixture.PNG)

    async def test_recovery_protocol_failure_becomes_explicit_503(self):
        self.image.write_bytes(cache_fixture.PNG[:40])
        class Opener:
            def open(self, *args, **kwargs):
                raise http.client.IncompleteRead(b'partial')
        with patch.object(cache_fixture.media.urllib.request, 'build_opener', return_value=Opener()):
            status, body, _ = await self.shared()
        self.assertEqual((status, body), (503, b''))


class PublicMCPBoundaryTests(unittest.TestCase):
    request = public_fixture.PublicTests.request
    login = public_fixture.PublicTests.login
    setUp = public_fixture.PublicTests.setUp

    @classmethod
    def setUpClass(cls):
        cls.original_reply = public_fixture.Backend.reply
        def reply(handler):
            if handler.path != '/mcp':
                return cls.original_reply(handler)
            handler.server.calls.append((handler.path, handler.headers.get('Cookie')))
            value = getattr(handler.server, 'mcp_value', {})
            mode = getattr(handler.server, 'mcp_mode', 'length')
            data = json.dumps(value).encode()
            handler.send_response(400 if mode == 'error' else 200)
            handler.send_header('Content-Type', 'application/json')
            if mode == 'chunked': handler.send_header('Transfer-Encoding', 'chunked')
            else: handler.send_header('Content-Length', str(97*1024*1024 if mode == 'oversized' else len(data)+5 if mode == 'truncated' else len(data)))
            handler.send_header('Connection', 'close'); handler.end_headers()
            if mode == 'chunked':
                for at in range(0,len(data),29):
                    part=data[at:at+29]
                    handler.wfile.write(f'{len(part):x}\r\n'.encode()+part+b'\r\n')
                handler.wfile.write(b'0\r\n\r\n')
            elif mode != 'oversized': handler.wfile.write(data)
        public_fixture.Backend.reply = reply
        try:
            public_fixture.PublicTests.setUpClass.__func__(cls)
        except BaseException:
            public_fixture.Backend.reply = cls.original_reply
            raise

    @classmethod
    def tearDownClass(cls):
        try: public_fixture.PublicTests.tearDownClass.__func__(cls)
        finally: public_fixture.Backend.reply = cls.original_reply

    def response(self, content, mode='length'):
        self.backends[0].mcp_value = {'jsonrpc':'2.0','id':17,'result':{'isError':False,'content':content}}
        self.backends[0].mcp_mode = mode
        status, headers, body = self.request('/mcp', 'POST', b'{"method":"tools/call"}', self.cookie,
                                             {'Content-Type':'application/json','Origin':public_fixture.ORIGIN})
        return status, headers, json.loads(body)

    def test_public_mcp_signs_file_summary_and_resource_link_without_changing_inline_image(self):
        path='/v1/files/video_0123456789abcdef/video.mp4'
        inline='a'*(2*1024*1024+100)
        summary={'id':'video_0123456789abcdef','status':'completed','files':[path],'urls':[path],'prompt':'a boat'}
        status, _, value = self.response([{'type':'text','text':json.dumps(summary)},
                                         {'type':'resource_link','uri':path,'name':'video.mp4'},
                                         {'type':'image','data':inline,'mimeType':'image/png'}])
        self.assertEqual(status,200)
        content=value['result']['content']; job=json.loads(content[0]['text']); url=content[1]['uri']
        self.assertTrue(url.startswith(public_fixture.ORIGIN+'/media/'))
        self.assertEqual(job['files'],[url]); self.assertEqual(job['urls'],[url]); self.assertEqual(job['prompt'],'a boat')
        self.assertEqual(content[2]['data'],inline)
        route=url.removeprefix(public_fixture.ORIGIN)
        self.assertEqual(self.request(route)[2],b'0123456789')

    def test_audio_resources_use_absolute_authenticated_urls_not_public_capabilities(self):
        path='/v1/files/speech_0123456789abcdef/speech.wav'
        status,_,value=self.response([{'type':'text','text':json.dumps({'id':'speech_0123456789abcdef','files':[path]})},
                                      {'type':'resource_link','uri':path,'name':'speech.wav'}])
        self.assertEqual(status,200)
        self.assertEqual(value['result']['content'][1]['uri'],public_fixture.ORIGIN+path)
        self.assertEqual(json.loads(value['result']['content'][0]['text'])['files'],[public_fixture.ORIGIN+path])
        self.assertEqual(self.request(path)[0],401)

    def test_chunked_summary_is_rewritten_and_natural_language_and_external_links_remain(self):
        path='/v1/files/video_0123456789abcdef/video.mp4'
        text='说明示例 '+path
        unrelated=json.dumps({'id':'some-user-data','files':[path]})
        status,headers,value=self.response([{'type':'text','text':text},{'type':'text','text':unrelated},
                                            {'type':'resource_link','uri':'https://example.test/image.png'},
                                            {'type':'resource_link','uri':path}],mode='chunked')
        self.assertEqual(status,200);self.assertNotIn('Transfer-Encoding',headers)
        content=value['result']['content']
        self.assertEqual(content[0]['text'],text);self.assertEqual(content[1]['text'],unrelated)
        self.assertEqual(content[2]['uri'],'https://example.test/image.png')
        self.assertTrue(content[3]['uri'].startswith(public_fixture.ORIGIN+'/media/'))

    def test_truncation_and_oversize_are_explicit_failures_and_native_errors_keep_status(self):
        for mode in ('truncated','oversized'):
            with self.subTest(mode=mode):
                status,_,value=self.response([],mode=mode)
                self.assertEqual(status,503);self.assertIn('error',value)
        status,_,value=self.response([{'type':'text','text':'invalid arguments'}],mode='error')
        self.assertEqual(status,400)
        self.assertEqual(value['result']['content'][0]['text'],'invalid arguments')


if __name__ == '__main__':
    unittest.main()
