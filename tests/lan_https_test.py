import http.client
import json
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT=Path(__file__).resolve().parents[1]
class Handler(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args):pass
    def do_GET(self):self.reply()
    def do_POST(self):self.reply()
    def reply(self):
        role=self.server.role
        if self.headers.get('Content-Length'):self.rfile.read(int(self.headers['Content-Length']))
        status=200;body=b''
        if self.path=='/v1/tools':
            kinds={'main':['chat','transcription','speech'],'voice':['speech','transcription'],'worker':['speech']}[role]
            if role=='main' and getattr(self.server,'missing_role',False):kinds=['chat','chat','speech']
            body=json.dumps({'data':[{'id':k,'kind':k,'state':'failed'if role=='worker'and self.server.failed else'ready'}for k in kinds]}).encode()
        elif self.path=='/v1/realtime':status=101
        elif self.path.startswith('/v1/files/'):
            status=404 if role=='main' else 200;body=b'voice-file'
        elif self.path=='/v1/audio/speech':body=b'worker-audio'
        else:status=404
        self.send_response(status);self.send_header('X-Upstream',role);self.send_header('Content-Length',str(len(body)));self.send_header('Connection','close');self.end_headers()
        if body:self.wfile.write(body)

class GatewayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which('openssl'):raise unittest.SkipTest('openssl unavailable')
        cls.tmp=tempfile.TemporaryDirectory();folder=Path(cls.tmp.name)
        subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(folder/'server.key'),'-out',str(folder/'server.crt'),'-days','1','-subj','/CN=localhost'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
        cls.servers=[]
        for role in ('main','voice','worker'):
            server=ThreadingHTTPServer(('127.0.0.1',0),Handler);server.role=role;server.failed=False;threading.Thread(target=server.serve_forever,daemon=True).start();cls.servers.append(server)
        with socket.socket()as probe:probe.bind(('127.0.0.1',0));cls.port=probe.getsockname()[1]
        cls.process=subprocess.Popen(['python3',str(ROOT/'deploy/jarvis/lan_https.py'),'--host','127.0.0.1','--subnet','127.0.0.0/8','--port',str(cls.port),'--backend',str(cls.servers[0].server_port),'--voice-backend',str(cls.servers[1].server_port),'--speech-backend',str(cls.servers[2].server_port),'--cert-dir',str(folder),'--static-dir',str(ROOT/'src/voice')],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        cls.context=ssl._create_unverified_context()
        for _ in range(200):
            try:
                with socket.create_connection(('127.0.0.1',cls.port),timeout=.1):break
            except OSError:time.sleep(.02)
        else:raise RuntimeError('gateway did not start')
    @classmethod
    def tearDownClass(cls):
        cls.process.terminate();cls.process.wait(timeout=5)
        for server in cls.servers:server.shutdown();server.server_close()
        cls.tmp.cleanup()
    def request(self,path,method='GET',body=None,extra_headers=None):
        c=http.client.HTTPSConnection('127.0.0.1',self.port,context=self.context,timeout=5)
        try:
            c.request(method,path,body=body,headers={'Authorization':'Bearer local-test-value',**(extra_headers or {})});r=c.getresponse();return r.status,dict(r.getheaders()),r.read()if r.status!=101 else b''
        finally:c.close()
    def test_websocket_routes_to_voice_coordinator(self):
        status,headers,_=self.request('/v1/realtime');self.assertEqual(status,101);self.assertEqual(headers['X-Upstream'],'voice')
    def test_speech_routes_to_worker(self):
        status,headers,body=self.request('/v1/audio/speech','POST',b'{}');self.assertEqual(status,200);self.assertEqual(headers['X-Upstream'],'worker');self.assertEqual(body,b'worker-audio')
    def test_media_404_falls_back_to_coordinator(self):
        status,headers,body=self.request('/v1/files/example/output.png');self.assertEqual(status,200);self.assertEqual(headers['X-Upstream'],'voice');self.assertEqual(body,b'voice-file')
    def test_unhealthy_worker_does_not_report_healthy(self):
        self.servers[2].failed=True
        try:
            status,_,_=self.request('/health');self.assertEqual(status,503)
        finally:self.servers[2].failed=False
        self.assertEqual(self.request('/health')[0],200)
    def test_cross_site_websocket_is_rejected(self):
        self.assertEqual(self.request('/v1/realtime',extra_headers={'Origin':'https://untrusted.invalid'})[0],403)
        status,_,_=self.request('/v1/realtime',extra_headers={'Origin':f'https://127.0.0.1:{self.port}'})
        self.assertEqual(status,101)
    def test_missing_required_role_is_not_masked_by_duplicate_models(self):
        self.servers[0].missing_role=True
        try:self.assertEqual(self.request('/health')[0],503)
        finally:self.servers[0].missing_role=False
    def test_html_keeps_security_policy(self):
        status,headers,body=self.request('/voice');self.assertEqual(status,200);self.assertIn("default-src 'self'",headers['Content-Security-Policy']);self.assertIn(b'Jarvis',body)

if __name__=='__main__':unittest.main()
