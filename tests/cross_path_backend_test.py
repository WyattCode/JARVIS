"""Cross-entrypoint controls and corrupt completed-cache recovery; only local fakes."""
import asyncio
import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'deploy/jarvis' / filename)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

brain = module('cross_path_brain', 'remote_brain.py')
media = module('cross_path_media', 'media_share.py')
PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC')
JOB = 'img_0123456789abcdef'
PATH = '/v1/files/' + JOB + '/0.png'

class Writer:
    def __init__(self): self.data = bytearray()
    def write(self, data): self.data.extend(data)
    async def drain(self): pass

class CrossPath(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.artifacts = self.root / 'artifacts'; self.artifacts.mkdir()
        self.image = self.artifacts / JOB / '0.png'; self.image.parent.mkdir(); self.image.write_bytes(PNG)
        self.calls = []; self.servers = []; self.handlers = []
        self.remote_png = PNG; self.download_gate = None
        ports = {}
        for role in ('head', 'image', 'video', 'voice', 'asr'):
            server = await asyncio.start_server(lambda r, w, role=role: self.worker(r, w, role), '127.0.0.1', 0)
            self.servers.append(server); ports[role] = server.sockets[0].getsockname()[1]
        cfg = {'base_url':'http://127.0.0.1:1/v1', 'model':'remote-chat', 'name':'test', 'api_key':'test',
               'artifact_root':str(self.artifacts), 'image_worker_port':ports['image'],
               'image_worker_machine':'image', 'video_worker_port':ports['video'],
               'video_backend_port':ports['video'], 'video_worker_machine':'video',
               'speech_backend_port':ports['voice'], 'transcription_backend_port':ports['asr']}
        self.bridge = brain.Bridge(cfg, backend=ports['head'])
        async def client(reader, writer):
            self.handlers.append(asyncio.current_task())
            await self.bridge.client(reader, writer)
        server = await asyncio.start_server(client, '127.0.0.1', 0)
        self.servers.append(server); self.port = server.sockets[0].getsockname()[1]
        self.share_cfg = self.root / 'share.json'
        self.share_cfg.write_text(json.dumps({'roots':[str(self.artifacts)],'key_file':str(self.root / 'key')}))
        self.share = media.MediaShare(self.share_cfg, 'example.test', recovery_port=self.port)
        self.signed = self.share.url(PATH)

    async def asyncTearDown(self):
        if self.download_gate: self.download_gate.set()
        for server in self.servers:
            server.close(); await server.wait_closed()
        for task in self.handlers:
            if not task.done(): task.cancel()
        await asyncio.gather(*self.handlers, return_exceptions=True)

    async def worker(self, reader, writer, role):
        self.handlers.append(asyncio.current_task())
        try:
            head = await reader.readuntil(b'\r\n\r\n')
            method, path, _ = head.split(b'\r\n',1)[0].decode().split(' ',2)
            fields = {k.lower():v.strip() for k,v in (x.split(b':',1) for x in head.split(b'\r\n')[1:] if b':' in x)}
            raw = await reader.readexactly(int(fields.get(b'content-length', b'0')))
            value = json.loads(raw) if raw else None
            self.calls.append((role, method, path, value))
            if path == PATH:
                if self.download_gate: await self.download_gate.wait()
                body = self.remote_png
            elif path == '/v1/tools':
                entries = [{'id':'fishaudio/drama-3','kind':'speech'}] if role == 'voice' else [{'id':'qwen3-asr-1.7b','kind':'transcription'}]
                body = json.dumps({'data':entries}).encode()
            elif path == '/mcp':
                body = json.dumps({'jsonrpc':'2.0','id':value['id'],'result':{'isError':False,'content':[]}}).encode()
            else:
                body = b'{"ok":true}'
            writer.write(b'HTTP/1.1 200 OK\r\nContent-Length: '+str(len(body)).encode()+b'\r\nConnection: close\r\n\r\n'+body)
            await writer.drain()
        finally:
            writer.close(); await writer.wait_closed()

    async def request(self, method, path, value=None):
        body = json.dumps(value).encode() if value is not None else b''
        reader, writer = await asyncio.open_connection('127.0.0.1', self.port)
        writer.write(f'{method} {path} HTTP/1.1\r\nHost: localhost\r\nContent-Length: {len(body)}\r\n\r\n'.encode()+body)
        await writer.drain(); raw = await asyncio.wait_for(reader.read(), 5)
        writer.close(); await writer.wait_closed()
        head, data = raw.split(b'\r\n\r\n', 1)
        return int(head.split(b' ',2)[1]), data, head

    async def rpc(self, name, args):
        status, data, _ = await self.request('POST','/mcp',{'jsonrpc':'2.0','id':7,'method':'tools/call','params':{'name':name,'arguments':args}})
        self.assertEqual(status,200)
        return json.loads(data)['result']

    async def shared(self, method='GET', target=None, headers=None):
        writer = Writer()
        await self.share.serve(writer, method, target or self.signed, headers or {})
        head, data = bytes(writer.data).split(b'\r\n\r\n',1)
        return int(head.split(b' ',2)[1]), data, head

    def downloads(self): return [c for c in self.calls if c[2] == PATH]

    async def test_http_protects_same_chat_voice_asr_release_as_mcp(self):
        for model in ('remote-chat','chat','fishaudio/drama-3','qwen3-asr-1.7b','speech','transcription'):
            for verb in ('load','unload'):
                with self.subTest(model=model,verb=verb):
                    self.assertEqual((await self.request('POST',f'/v1/tools/{model}/{verb}'))[0],403)
                    self.assertTrue((await self.rpc(verb+'_model',{'model':model}))['isError'])
        self.assertEqual((await self.request('POST','/v1/tools/release'))[0],403)
        self.assertTrue((await self.rpc('release_models',{}))['isError'])
        self.assertEqual(self.calls,[])

    async def test_encoded_control_path_cannot_bypass_protection(self):
        for path in ('/v1/tools/fishaudio%2Fdrama-3/unload','/v1/%74ools/fishaudio/drama-3/unload','/v1/tools/%72elease'):
            self.assertEqual((await self.request('POST',path))[0],403)
        self.assertEqual(self.calls,[])

    async def test_media_controls_route_to_only_the_owner(self):
        for model,role in (('qwen-image-2.1-turbo','image'),('minimax-h3','video')):
            for verb in ('load','unload'):
                path = f'/v1/tools/{model}/{verb}'
                self.assertEqual((await self.request('POST',path,{}))[0],200)
                self.assertEqual(self.calls[-1][:3],(role,'POST',path))
                self.assertFalse((await self.rpc(verb+'_model',{'model':model}))['isError'])
                self.assertEqual(self.calls[-1][:3],(role,'POST','/mcp'))
        self.assertEqual((await self.request('POST','/v1/tools/%71wen-image-2.1-turbo/load'))[0],200)
        self.assertEqual(self.calls[-1][:3],('image','POST','/v1/tools/qwen-image-2.1-turbo/load'))
        self.assertTrue(all(c[0] in ('image','video') for c in self.calls))

    async def test_http_control_rejects_unsupported_options_and_methods_without_mutation(self):
        for verb in ('load','unload'):
            path = '/v1/tools/qwen-image-2.1-turbo/'+verb
            for method in ('GET','HEAD','PUT','PATCH','DELETE'):
                self.assertEqual((await self.request(method,path))[0],405)
            for body in ({'dry_run':True},{'dry_run':False},{'hold_s':15},[],True):
                self.assertEqual((await self.request('POST',path,body))[0],400)
            self.assertEqual((await self.request('POST',path+'?dry_run=true'))[0],400)
        self.assertEqual((await self.request('POST','/v1/tools/qwen-image-2.1-turbo/reserve'))[0],400)
        self.assertEqual(self.calls,[])

    async def test_mcp_dry_run_only_supported_by_reserve_for(self):
        for name in ('load_model','unload_model'):
            for dry_run in (True,False):
                result = await self.rpc(name,{'model':'qwen-image-2.1-turbo','dry_run':dry_run})
                self.assertTrue(result['isError']); self.assertIn('dry_run',result['content'][0]['text'])
        self.assertEqual(self.calls,[])
        for dry_run in (True,False):
            args = {'model':'qwen-image-2.1-turbo','dry_run':dry_run,'hold_s':10}
            self.assertFalse((await self.rpc('reserve_for',args))['isError'])
            self.assertEqual(self.calls[-1][0],'image')
            self.assertEqual(self.calls[-1][3]['params']['arguments'],args)

    async def test_malformed_control_paths_rejected(self):
        for tail in ('%252Frelease','../release','qwen-image-2.1-turbo%20/load','qwen-image-2.1-turbo%3F/load','%FF/load','/release'):
            self.assertEqual((await self.request('POST','/v1/tools/'+tail))[0],400)
        self.assertEqual(self.calls,[])

    async def test_corrupt_completed_png_get_and_head_repair_before_success(self):
        for method in ('GET','HEAD'):
            self.image.write_bytes(PNG[:40])
            status,data,head = await self.request(method,PATH)
            self.assertEqual(status,200); self.assertEqual(data,PNG if method=='GET' else b'')
            self.assertIn(b'Content-Length: '+str(len(PNG)).encode(),head)
            self.assertEqual(self.image.read_bytes(),PNG)
        self.assertEqual(len(self.downloads()),2)

    async def test_failed_remote_repair_returns_503_and_keeps_corrupt_file_unserved(self):
        self.image.write_bytes(PNG[:40]); self.remote_png = PNG[:40]
        for method in ('GET','HEAD'):
            status,data,_ = await self.request(method,PATH)
            self.assertEqual(status,503); self.assertNotEqual(data,PNG[:40])
            self.assertEqual(self.image.read_bytes(),PNG[:40])
        self.assertEqual(list(self.image.parent.glob('.image-cache-*')),[])

    async def test_concurrent_get_head_and_signed_download_share_one_repair(self):
        self.image.write_bytes(PNG[:40]); self.download_gate = asyncio.Event()
        requests = [asyncio.create_task(self.request('GET',PATH)),asyncio.create_task(self.request('HEAD',PATH)),asyncio.create_task(self.shared())]
        for _ in range(50):
            if self.downloads(): break
            await asyncio.sleep(.01)
        await asyncio.sleep(.05); self.download_gate.set()
        results = await asyncio.gather(*requests)
        self.assertEqual([r[0] for r in results],[200,200,200]); self.assertEqual(results[2][1],PNG)
        self.assertEqual(len(self.downloads()),1)

    async def test_cancelled_waiter_does_not_cancel_shared_repair(self):
        self.image.write_bytes(PNG[:40]); self.download_gate=asyncio.Event()
        first=asyncio.create_task(self.bridge.ensure_cached_png(self.image,PATH))
        for _ in range(50):
            if self.downloads():break
            await asyncio.sleep(.01)
        first.cancel()
        with self.assertRaises(asyncio.CancelledError):await first
        second=asyncio.create_task(self.bridge.ensure_cached_png(self.image,PATH))
        await asyncio.sleep(.02);self.download_gate.set()
        self.assertEqual(await second,self.image)
        self.assertEqual(len(self.downloads()),1)

    async def test_trickling_recovery_download_has_total_deadline_inside_thread(self):
        self.image.write_bytes(PNG[:40]); ticks=iter((0,1,7))
        class Response:
            headers={}
            def __enter__(self):return self
            def __exit__(self,*args):pass
            def read1(self,size):return b'x'
        opener=SimpleNamespace(open=lambda *a,**k:Response())
        with patch.object(brain,'time',SimpleNamespace(monotonic=lambda:next(ticks))),patch.object(brain.urllib.request,'build_opener',return_value=opener):
            with self.assertRaises(brain.ImageIntegrityError):await self.bridge.ensure_cached_png(self.image,PATH)
        self.assertEqual(self.image.read_bytes(),PNG[:40])

    async def test_signed_revalidates_recovery_result_and_root_boundary(self):
        self.image.write_bytes(PNG[:40])
        async def fake_success(*args):return self.image
        with patch.object(self.bridge,'ensure_cached_png',side_effect=fake_success):
            self.assertEqual((await self.shared())[:2],(503,b''))
        outside=self.root/'outside.png';outside.write_bytes(PNG)
        async def escape(*args):
            self.image.unlink();self.image.symlink_to(outside)
            return self.image
        with patch.object(self.bridge,'ensure_cached_png',side_effect=escape):
            self.assertEqual((await self.shared())[:2],(503,b''))

    async def test_validation_is_cached_by_identity_and_runs_outside_event_loop(self):
        brain.validated_png_file.cache_clear(); calls=[]; loop_thread=threading.get_ident()
        original = brain.validate_png
        def validate(data): calls.append(threading.get_ident()); return original(data)
        with patch.object(brain,'validate_png',side_effect=validate):
            await self.request('GET',PATH); await self.request('HEAD',PATH)
            self.assertEqual(len(calls),1)
            self.image.write_bytes(PNG)
            await self.request('HEAD',PATH)
            self.assertEqual(len(calls),2)
        self.assertTrue(all(t!=loop_thread for t in calls)); self.assertEqual(self.downloads(),[])

    async def test_signed_corrupt_get_head_and_range_repair_via_bridge(self):
        for method,headers,expected in (('GET',{},PNG),('HEAD',{},b''),('GET',{b'range':['bytes=5-9']},PNG[5:10])):
            self.image.write_bytes(PNG[:40])
            status,data,_ = await self.shared(method,headers=headers)
            self.assertEqual(status,206 if headers else 200); self.assertEqual(data,expected)
        self.assertEqual(len(self.downloads()),3)

    async def test_signed_recovery_failure_is_503_without_bad_body(self):
        self.image.write_bytes(PNG[:40]); self.remote_png=PNG[:40]
        for method in ('GET','HEAD'):
            status,data,_ = await self.shared(method)
            self.assertEqual((status,data),(503,b''))
        self.share.recovery_port=None
        self.assertEqual((await self.shared())[:2],(503,b''))

    async def test_signed_bad_capability_and_symlink_escape_never_start_recovery(self):
        self.image.write_bytes(PNG[:40])
        bad = self.signed.replace('/media/','/media/f',1)
        self.assertEqual((await self.shared(target=bad))[0],404)
        outside=self.root/'outside.png'; outside.write_bytes(PNG)
        self.image.unlink(); self.image.symlink_to(outside)
        self.assertEqual((await self.shared())[0],404)
        self.assertEqual(self.calls,[])

    async def test_repair_into_primary_root_skips_corrupt_legacy_copy(self):
        legacy=self.root/'legacy'; (legacy/JOB).mkdir(parents=True)
        (legacy/JOB/'0.png').write_bytes(PNG[:40]); self.image.unlink()
        self.bridge.config['legacy_video_roots']=[str(legacy)]
        self.share.roots=[legacy,self.artifacts]
        status,data,_=await self.shared()
        self.assertEqual((status,data),(200,PNG)); self.assertEqual(len(self.downloads()),1)
        self.assertEqual((legacy/JOB/'0.png').read_bytes(),PNG[:40])

    async def test_signed_validation_cache_invalidates_and_stays_off_event_loop(self):
        media.validated_png_file.cache_clear(); calls=[]; loop_thread=threading.get_ident()
        original=media.validate_png
        def validate(data): calls.append(threading.get_ident()); return original(data)
        with patch.object(media,'validate_png',side_effect=validate):
            await self.shared(); await self.shared('HEAD'); self.assertEqual(len(calls),1)
            self.image.write_bytes(PNG); await self.shared(); self.assertEqual(len(calls),2)
        self.assertTrue(all(t!=loop_thread for t in calls))

if __name__ == '__main__': unittest.main()
