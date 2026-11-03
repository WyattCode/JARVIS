"""Verify public experiment routing, authentication and live withdrawal."""
import sys,json,subprocess,threading,time,socket,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parent))
import public_access_test as public_tests
from public_access_test import Backend,ThreadingHTTPServer,HOST,ORIGIN

class VoiceExperiment(public_tests.PublicTests):
 @classmethod
 def setUpClass(cls):
  super().setUpClass()
  cls.new=ThreadingHTTPServer(('127.0.0.1',0),Backend);cls.new.role='voice';cls.new.calls=[];cls.new.release=threading.Event();cls.new.disconnected=threading.Event();threading.Thread(target=cls.new.serve_forever,daemon=True).start()
  cls.feature=cls.dir/'voice-test.json';cls.feature.write_text(json.dumps({'enabled':True,'backend_port':cls.new.server_port}))
  cls.process.terminate();cls.process.wait(timeout=5);cls.process.stderr.close()
  cls.args+=['--voice-test-config',str(cls.feature)]
  cls.process=subprocess.Popen(cls.args,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
  for _ in range(100):
   try:
    with socket.create_connection(('127.0.0.1',cls.port),timeout=.1):break
   except OSError:time.sleep(.03)
 @classmethod
 def tearDownClass(cls):
  super().tearDownClass();cls.process.stderr.close();cls.new.shutdown();cls.new.server_close()
 def test_experiment_login_and_origin_remain_required(self):
  before=len(self.new.calls)
  self.assertEqual(self.request('/v1/realtime?voice_variant=new')[0],401)
  self.assertEqual(self.request('/v1/realtime?voice_variant=new',cookie=self.cookie,headers={'Origin':'https://evil.example'})[0],403)
  self.assertEqual(len(self.new.calls),before)
 def test_experiment_routes_real_websocket_to_separate_backend(self):
  import ssl
  c=self.ctx.wrap_socket(socket.create_connection(('127.0.0.1',self.port)),server_hostname=HOST)
  try:
   c.sendall(('GET /v1/realtime?voice_variant=new HTTP/1.1\r\nHost: '+HOST+'\r\nOrigin: '+ORIGIN+'\r\nCookie: '+self.cookie+'\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
   c.settimeout(5);self.assertIn(b'101 Switching Protocols',c.recv(4096))
   self.assertEqual(self.new.calls[-1],('/v1/realtime',None))
  finally:c.close()
 def test_experiment_can_be_withdrawn_without_gateway_restart(self):
  pid=self.process.pid
  status,_,body=self.request('/voice',cookie=self.cookie);self.assertEqual(status,200);self.assertIn(b'data-voice-test-toggle',body)
  original=self.feature.read_bytes()
  try:
   self.feature.write_text('{"enabled":false,"backend_port":'+str(self.new.server_port)+'}')
   self.assertEqual(json.loads(self.request('/v1/voice-test',cookie=self.cookie)[2]),{'enabled':False,'ready':False})
   self.assertEqual(self.request('/v1/realtime?voice_variant=new',cookie=self.cookie)[0],503)
   self.assertNotIn(b'data-voice-test-toggle',self.request('/voice',cookie=self.cookie)[2])
   self.assertEqual(self.process.pid,pid)
   self.assertEqual(self.request('/v1/models',cookie=self.cookie)[0],200)
  finally:self.feature.write_bytes(original)
 def test_experiment_malformed_schema_fails_closed_without_breaking_requests(self):
  original=self.feature.read_bytes()
  try:
   for value in ['[]','null','1','"bad"','true','{"enabled":true,"backend_port":true}']:
    self.feature.write_text(value)
    self.assertEqual(json.loads(self.request('/v1/voice-test',cookie=self.cookie)[2]),{'enabled':False,'ready':False},value)
    self.assertEqual(self.request('/voice',cookie=self.cookie)[0],200,value)
    self.assertEqual(self.request('/v1/realtime?voice_variant=new',cookie=self.cookie)[0],503,value)
  finally:self.feature.write_bytes(original)
 def test_experiment_health(self):
  self.assertEqual(json.loads(self.request('/v1/voice-test',cookie=self.cookie)[2]),{'enabled':True,'ready':True})

if __name__=='__main__':unittest.main(defaultTest='VoiceExperiment')
