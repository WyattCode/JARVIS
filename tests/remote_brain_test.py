import http.client
import asyncio
import importlib.util
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('brain', ROOT/'deploy/jarvis/remote_brain.py')
brain = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(brain)
CONFIG = {'model':'new-brain','name':'New Brain','api_key':'server-only-secret','reasoning_effort':'high'}

class Upstream(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_): pass
    def do_GET(self):
        if self.server.remote:
            body={'data':[{'id':'new-brain','status':{'value':'loaded'},'meta':{'n_ctx':262144}}]}
        else:
            body={'data':[{'id':'old-chat','kind':'chat','state':'ready'}, {'id':'ears','kind':'transcription','state':'ready'}]}
        if getattr(self.server,'missing',False):body={'data':[]}
        encoded=json.dumps(body).encode();self.send_response(200);self.send_header('Content-Length',str(len(encoded)));self.send_header('Connection','close');self.end_headers();self.wfile.write(encoded)
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.server.calls.append((self.headers.get('Authorization'),body))
        if getattr(self.server,'auth_failed',False):
            self.send_response(401);self.send_header('Content-Length','0');self.send_header('Connection','close');self.end_headers();return
        self.send_response(200);self.send_header('Content-Type','text/event-stream' if body.get('stream') else 'application/json');self.send_header('Connection','close');self.end_headers()
        if not body.get('stream'):
            self.wfile.write(json.dumps({'choices':[{'message':{'content':'ok'}}]}).encode());return
        try:
            for _ in range(200 if body.get('cancel_test') else 2):
                self.wfile.write(b'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n');self.wfile.flush();time.sleep(.01)
            self.wfile.write(b'data: [DONE]\n\n');self.wfile.flush()
        except (BrokenPipeError,ConnectionResetError): self.server.cancelled.set()

class BridgeTests(unittest.TestCase):
    def test_separate_transcription_service_routes_and_metadata(self):
        b=brain.Bridge({**CONFIG,'base_url':'http://127.0.0.1:1234/v1','transcription_backend_port':18795})
        async def metadata(remote,path,port=None,**kwargs):
            if remote:return {'data':[{'id':'new-brain'}]}
            if port==18795:return {'data':[{'id':'qwen3-asr-1.7b','kind':'transcription','state':'ready'}]}
            return {'data':[{'id':'whisper','kind':'transcription'},{'id':'speech','kind':'speech'}]}
        b.fetch_json=metadata
        for path in ['/models','/tools']:
            result=asyncio.run(b.metadata(path))
            self.assertEqual([m['id'] for m in result['data']],['new-brain','speech','qwen3-asr-1.7b'])
        self.assertEqual(b.video_ports('/v1/audio/transcriptions','POST'),[18795])
        self.assertEqual(b.video_ports('/v1/audio/speech','POST'),[8190])
    def test_speech_backend_metadata_and_preview_route_share_coordinator(self):
        b=brain.Bridge({**CONFIG,'base_url':'http://127.0.0.1:1234/v1','speech_backend_port':8194})
        async def metadata(remote,path,port=None,**kwargs):
            if remote:return {'data':[{'id':'new-brain'}]}
            if port==8194:return {'data':[{'id':'speech','kind':'speech','voices':['Mae','zh-test'],'default_voice':'Mae'}]}
            return {'data':[{'id':'speech','kind':'speech','voices':['Mae']},{'id':'ears','kind':'transcription'}]}
        b.fetch_json=metadata
        for path in ['/models','/tools']:
            result=asyncio.run(b.metadata(path))
            self.assertEqual(next(m for m in result['data'] if m['kind']=='speech')['voices'],['Mae','zh-test'])
        self.assertEqual(b.video_ports('/v1/audio/speech','POST'),[8194])
        self.assertEqual(b.video_ports('/v1/audio/transcriptions','POST'),[8190])
    @classmethod
    def setUpClass(cls):
        cls.servers=[]
        for remote in (False,True):
            s=ThreadingHTTPServer(('127.0.0.1',0),Upstream);s.remote=remote;s.calls=[];s.cancelled=threading.Event();threading.Thread(target=s.serve_forever,daemon=True).start();cls.servers.append(s)
        cls.tmp=tempfile.TemporaryDirectory();folder=Path(cls.tmp.name);artifacts=folder/'artifacts';(artifacts/'image_saved').mkdir(parents=True);(artifacts/'image_saved/image-0.png').write_bytes(b'archived-image')
        (artifacts/'video_0123456789abcdef').mkdir();(artifacts/'video_0123456789abcdef/video.mp4').write_bytes(b'new-video')
        history=folder/'history.json';history.write_text(json.dumps({'jobs':{'image_saved':{'id':'image_saved','status':'completed','urls':['/v1/files/image_saved/image-0.png']}},'videos':{'video_failed':{'id':'video_failed','status':'failed','error':{'message':'old failure'}}}}))
        c={**CONFIG,'base_url':f'http://127.0.0.1:{cls.servers[1].server_port}/v1','artifact_root':str(artifacts),'job_history':str(history)};p=folder/'config.json';p.write_text(json.dumps(c))
        with socket.socket()as probe:probe.bind(('127.0.0.1',0));cls.port=probe.getsockname()[1]
        cls.process=subprocess.Popen(['python3',str(ROOT/'deploy/jarvis/remote_brain.py'),'--config',str(p),'--port',str(cls.port),'--backend',str(cls.servers[0].server_port)],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        for _ in range(100):
            try:
                with socket.create_connection(('127.0.0.1',cls.port),timeout=.1):break
            except OSError:time.sleep(.02)
        else:raise RuntimeError('bridge did not start')
    @classmethod
    def tearDownClass(cls):
        cls.process.terminate();cls.process.wait(timeout=5)
        for s in cls.servers:s.shutdown();s.server_close()
        cls.tmp.cleanup()
    def request(self,path,body=None):
        c=http.client.HTTPConnection('127.0.0.1',self.port,timeout=4)
        try:
            c.request('POST'if body is not None else'GET',path,body=json.dumps(body)if body is not None else None,headers={'Authorization':'Bearer browser-value','Content-Type':'application/json'});r=c.getresponse();return r.status,r.read()
        finally:c.close()
    def test_high_default_and_explicit_efforts(self):
        self.assertEqual(brain.chat_body({},CONFIG)['reasoning_effort'],'high')
        for effort in brain.EFFORTS:
            out=brain.chat_body({'reasoning_effort':effort},CONFIG);self.assertEqual(out['reasoning_effort'],effort);self.assertEqual(out['chat_template_kwargs']['enable_thinking'],effort!='none')
        self.assertEqual(brain.chat_body({'reasoning_effort':'high','chat_template_kwargs':{'enable_thinking':False}},CONFIG)['reasoning_effort'],'none')
    def test_text_uses_new_model_and_server_auth(self):
        self.assertEqual(self.request('/v1/chat/completions',{'messages':[]})[0],200)
        auth,body=self.servers[1].calls[-1];self.assertEqual(auth,'Bearer server-only-secret');self.assertEqual(body['model'],'new-brain');self.assertEqual(body['reasoning_effort'],'high')
    def test_stream_preserves_done(self):
        status,body=self.request('/v1/chat/completions',{'messages':[],'stream':True});self.assertEqual(status,200);self.assertIn(b'[DONE]',body)
    def test_metadata_replaces_local_chat_without_leaking_credentials(self):
        for path in ('/v1/models','/v1/tools'):
            status,body=self.request(path);self.assertEqual(status,200);self.assertNotIn(b'server-only-secret',body);d=json.loads(body)['data'];self.assertEqual([m['id']for m in d],['new-brain','ears'])
    def test_invalid_effort_and_unknown_model_do_not_hit_upstream(self):
        count=len(self.servers[1].calls)
        for body in ({'reasoning_effort':'xhigh'},{'reasoning_effort':[]},{'model':'missing'}):self.assertEqual(self.request('/v1/chat/completions',body)[0],400)
        self.assertEqual(len(self.servers[1].calls),count)
    def test_client_disconnect_closes_upstream(self):
        self.servers[1].cancelled.clear();c=http.client.HTTPConnection('127.0.0.1',self.port,timeout=3);c.request('POST','/v1/chat/completions',body=json.dumps({'messages':[],'stream':True,'cancel_test':True}));r=c.getresponse();r.read(16);r.close();c.close();self.assertTrue(self.servers[1].cancelled.wait(3))
    def test_missing_remote_model_does_not_fall_back_to_local_chat(self):
        self.servers[1].missing=True
        try:self.assertEqual(self.request('/v1/models')[0],503)
        finally:self.servers[1].missing=False
    def test_remote_auth_failure_does_not_prompt_for_browser_key(self):
        self.servers[1].auth_failed=True
        try:
            status,body=self.request('/v1/chat/completions',{'messages':[]});self.assertEqual(status,503);self.assertNotIn(b'server-only-secret',body)
        finally:self.servers[1].auth_failed=False
    def test_voice_effort_aliases_override_only_their_own_request(self):
        for effort in ('low','medium','high','none'):
            out=brain.chat_body({'model':'new-brain--jarvis-'+effort,'reasoning_effort':'high'},CONFIG)
            self.assertEqual(out['model'],'new-brain');self.assertEqual(out['reasoning_effort'],effort)
        self.assertEqual(brain.chat_body({},CONFIG)['reasoning_effort'],'high')
    def test_metadata_exposes_voice_effort_aliases(self):
        status,body=self.request('/v1/models');m=json.loads(body)['data'][0]
        self.assertEqual(status,200);self.assertEqual(m['jarvis']['voice_effort_models']['medium'],'new-brain--jarvis-medium')
    def pdf_request(self,payload):
        c=http.client.HTTPConnection('127.0.0.1',self.port,timeout=20)
        try:
            c.request('POST','/v1/jarvis/extract-pdf',body=payload,headers={'Content-Type':'application/pdf'});r=c.getresponse();return r.status,r.read()
        finally:c.close()
    def test_pdf_text_extracts_real_document(self):
        data=b'%PDF-1.4\n';offsets=[0]
        text=b'BT /F1 12 Tf 72 720 Td (Hello attachment PDF) Tj ET'
        objects=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',b'<< /Length '+str(len(text)).encode()+b' >>\nstream\n'+text+b'\nendstream']
        for i,obj in enumerate(objects,1):offsets.append(len(data));data+=str(i).encode()+b' 0 obj\n'+obj+b'\nendobj\n'
        xref=len(data);data+=b'xref\n0 6\n0000000000 65535 f \n'+b''.join(f'{x:010d} 00000 n \n'.encode()for x in offsets[1:])+b'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n'+str(xref).encode()+b'\n%%EOF'
        status,body=self.pdf_request(data);self.assertEqual(status,200);self.assertIn('Hello attachment PDF',json.loads(body)['text'])
    def test_invalid_pdf_is_rejected_without_chat_request(self):
        count=len(self.servers[1].calls);self.assertEqual(self.pdf_request(b'not a PDF')[0],400);self.assertEqual(len(self.servers[1].calls),count)
    def test_completed_media_remains_readable_from_saved_index(self):
        self.assertEqual(self.request('/v1/files/image_saved/image-0.png'),(200,b'archived-image'))
        status,body=self.request('/v1/jobs/image_saved');self.assertEqual(status,200);self.assertEqual(json.loads(body)['status'],'completed')
    def test_failed_video_history_remains_available(self):
        status,body=self.request('/v1/videos/video_failed');self.assertEqual(status,200);self.assertEqual(json.loads(body)['error']['message'],'old failure')
    def test_generated_video_file_survives_missing_in_memory_job(self):
        self.assertEqual(self.request('/v1/files/video_0123456789abcdef/video.mp4'),(200,b'new-video'))
        self.assertEqual(self.request('/v1/videos/video_0123456789abcdef/content'),(200,b'new-video'))
    def test_voice_preview_unknown_and_path_traversal_return_404(self):
        for path in ['/v1/voice-previews/missing.wav','/v1/voice-previews/../../upstream.json','/v1/voice-previews/%2e%2e%2fsecret.wav']:
            self.assertEqual(self.request(path)[0],404)
    def test_non_chat_requests_stay_on_local_backend(self):
        count=len(self.servers[1].calls);status,_=self.request('/v1/audio/transcriptions',{'model':'ears','file':'audio'});self.assertEqual(status,200);self.assertEqual(len(self.servers[1].calls),count);auth,body=self.servers[0].calls[-1];self.assertEqual(auth,'Bearer browser-value');self.assertEqual(body['model'],'ears')

if __name__=='__main__':unittest.main()
