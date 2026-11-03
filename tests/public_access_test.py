import base64
import asyncio
import math
import hashlib
import http.client
import importlib.util
import json
from pathlib import Path
import socket
import os
import signal
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('public_access',ROOT/'deploy/jarvis/public_access.py');access=importlib.util.module_from_spec(spec);spec.loader.exec_module(access)
HOST='jarvis.odn.cc';ORIGIN='https://'+HOST

class Backend(BaseHTTPRequestHandler):
 protocol_version='HTTP/1.1'
 def log_message(self,*_):pass
 def do_POST(self):
  self.rfile.read(int(self.headers.get('Content-Length','0')));self.reply()
 def do_GET(self):self.reply()
 def reply(self):
  self.server.calls.append((self.path,self.headers.get('Cookie')))
  if self.path=='/v1/realtime':
   accept=base64.b64encode(hashlib.sha1((self.headers['Sec-WebSocket-Key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
   self.send_response(101);self.send_header('Upgrade','websocket');self.send_header('Connection','Upgrade');self.send_header('Sec-WebSocket-Accept',accept);self.end_headers();self.wfile.write(b'\x81\x02ok');self.wfile.flush();self.connection.settimeout(3)
   try:self.rfile.read(1)
   except OSError:pass
   self.server.disconnected.set();self.close_connection=True;return
  if self.path=='/v1/stream':
   self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Content-Length','16');self.end_headers();self.wfile.write(b'data:a\n\n');self.wfile.flush();self.server.release.wait(3);self.wfile.write(b'data:b\n\n');self.wfile.flush();return
  if self.path in ('/v1/jobs/video_0123456789abcdef', '/v1/images/generations'):
   data=json.dumps({'urls':['/v1/files/video_0123456789abcdef/video.mp4']}).encode()
  elif self.path=='/v1/tools':
   kinds={'main':['chat','transcription','speech'],'voice':['speech','transcription'],'speech':['speech']}[self.server.role]
   data=json.dumps({'data':[{'id':k,'kind':k,'state':'ready'} for k in kinds]}).encode()
  else:data=json.dumps({'role':self.server.role,'ok':True}).encode()
  status=404 if self.path.startswith('/v1/files/')and self.server.role=='main'else 200
  self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.send_header('Connection','close');self.end_headers();self.wfile.write(data)

class PublicTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.tmp=tempfile.TemporaryDirectory();cls.dir=Path(cls.tmp.name);cls.auth=cls.dir/'auth.json';cls.credentials=cls.dir/'credentials.txt'
  access.create(cls.auth,'wyatt',cls.credentials);cls.password=cls.credentials.read_text().splitlines()[1].split('：',1)[1]
  user_salt=os.urandom(16);cfg=json.loads(cls.auth.read_text());cfg['users']=[{'username':'test','salt':user_salt.hex(),'iterations':200000,'password_hash':hashlib.pbkdf2_hmac('sha256',b'test123',user_salt,200000).hex()}];cls.auth.write_text(json.dumps(cfg))
  subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(cls.dir/'server.key'),'-out',str(cls.dir/'server.crt'),'-days','1','-subj','/CN=localhost'],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  cls.backends=[]
  for role in ['main','voice','speech']:
   s=ThreadingHTTPServer(('127.0.0.1',0),Backend);s.role=role;s.calls=[];s.release=threading.Event();s.disconnected=threading.Event();threading.Thread(target=s.serve_forever,daemon=True).start();cls.backends.append(s)
  with socket.socket()as s:s.bind(('127.0.0.1',0));cls.port=s.getsockname()[1]
  cls.args=['python3',str(ROOT/'deploy/jarvis/lan_https.py'),'--host','127.0.0.1','--port',str(cls.port),'--subnet','127.0.0.0/8','--cert-dir',str(cls.dir),'--static-dir',os.environ.get('JARVIS_STATIC_TEST_DIR',str(ROOT/'src/voice')),'--backend',str(cls.backends[0].server_port),'--voice-backend',str(cls.backends[1].server_port),'--speech-backend',str(cls.backends[2].server_port),'--auth-file',str(cls.auth),'--public-host',HOST]
  files=cls.dir/'jobs'/'video_0123456789abcdef';files.mkdir(parents=True);(files/'video.mp4').write_bytes(b'0123456789')
  cfg=cls.dir/'media.json';cfg.write_text(json.dumps({'roots':[str(cls.dir/'jobs')],'key_file':str(cls.dir/'media.key')}));cls.args+=['--media-share-config',str(cfg)]
  cls.process=subprocess.Popen(cls.args,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE);cls.ctx=ssl._create_unverified_context()
  for _ in range(100):
   try:
    with socket.create_connection(('127.0.0.1',cls.port),timeout=.1):break
   except OSError:time.sleep(.03)
  else:raise RuntimeError('public listener failed to start')
 @classmethod
 def tearDownClass(cls):
  cls.process.terminate();cls.process.wait(timeout=5)
  for s in cls.backends:s.release.set();s.shutdown();s.server_close()
  cls.tmp.cleanup()
 def request(self,path,method='GET',body=None,cookie=None,headers=None):
  c=http.client.HTTPSConnection('127.0.0.1',self.port,context=self.ctx,timeout=5)
  h={'Host':HOST,**(headers or {})}
  if cookie:h['Cookie']=cookie
  try:
   c.request(method,path,body=body,headers=h);r=c.getresponse();return r.status,dict(r.getheaders()),r.read()
  finally:c.close()
 def login(self,username='wyatt',password=None):
  return self.request('/login','POST',urllib.parse.urlencode({'username':username,'password':self.password if password is None else password}),headers={'Origin':ORIGIN,'Content-Type':'application/x-www-form-urlencoded'})
 def setUp(self):
  status,h,_=self.login();self.assertEqual(status,303);self.cookie=h['Set-Cookie'].split(';',1)[0]
 def test_additional_account_preserves_primary_and_separates_browser_storage(self):
  status,h,_=self.login('test','test123');self.assertEqual(status,303);cookie=h['Set-Cookie'].split(';',1)[0]
  status,_,body=self.request('/voice',cookie=cookie);self.assertEqual(status,200);self.assertIn(b'"username": "test"',body);self.assertIn(b'jarvis.user.',body)
  status,_,primary=self.request('/voice',cookie=self.cookie);self.assertEqual(status,200);self.assertIn(b'"username": "wyatt"',primary);self.assertIn(b'"storagePrefix": "jarvis."',primary)
  self.assertEqual(self.login('test',self.password)[0],401);self.assertEqual(self.login('wyatt','test123')[0],401)
  self.assertEqual(self.request('/logout','POST',b'',cookie=cookie,headers={'Origin':ORIGIN})[0],303)
  self.assertEqual(self.request('/v1/models',cookie=cookie)[0],401);self.assertEqual(self.request('/v1/models',cookie=self.cookie)[0],200)
 def test_anonymous_cannot_reach_any_model_voice_media_or_management_route(self):
  before=sum(len(s.calls)for s in self.backends)
  for path in ['/v1/models','/v1/tools','/v1/realtime','/v1/files/test/out.png','/health','/mcp','/v1/chat/completions','/v1/images/generations']:
   self.assertEqual(self.request(path)[0],401,path)
  self.assertEqual(sum(len(s.calls)for s in self.backends),before)
 def test_home_screen_manifest_icons_worker_and_auth_boundary(self):
  for path,kind in [('/manifest.webmanifest','application/manifest+json'),('/service-worker.js','application/javascript'),('/auth-assets/pwa.js','application/javascript'),('/auth-assets/pwa.css','text/css'),('/pwa/icon-192.png','image/png'),('/pwa/icon-512.png','image/png'),('/pwa/icon-maskable-512.png','image/png')]:
   status,h,body=self.request(path);self.assertEqual(status,200,path);self.assertIn(kind,h['Content-Type']);self.assertTrue(body);self.assertIn('no-store',h['Cache-Control'])
   self.assertEqual(self.request(path,'HEAD')[0],200,path)
   self.assertEqual(self.request(path,'POST',b'')[0],401,path)
  manifest=json.loads(self.request('/manifest.webmanifest')[2]);self.assertEqual(manifest['id'],'/');self.assertEqual(manifest['start_url'],'/voice');self.assertEqual(manifest['display'],'standalone');self.assertNotIn('orientation',manifest)
  for icon in manifest['icons']:
   body=self.request(icon['src'])[2];self.assertEqual(body[:8],b'\x89PNG\r\n\x1a\n');self.assertEqual(int.from_bytes(body[16:20],'big'),int(icon['sizes'].split('x')[0]))
  self.assertIn(b'rel="manifest"',self.request('/login')[2]);self.assertIn(b'rel="manifest"',self.request('/voice',cookie=self.cookie)[2])
  self.assertEqual(self.request('/pwa/../auth.json')[0],401)
  worker=self.request('/service-worker.js')[2];self.assertNotIn(b'caches.',worker);self.assertIn(b"request.method!=='GET'",worker)
 def test_browser_redirects_to_login_and_login_page_is_not_cacheable(self):
  status,h,_=self.request('/voice');self.assertEqual(status,303);self.assertEqual(h['Location'],'/login')
  status,h,body=self.request('/login');self.assertEqual(status,200);self.assertIn('no-store',h['Cache-Control']);self.assertEqual(h['Referrer-Policy'],'same-origin');self.assertIn("frame-ancestors 'none'",h['Content-Security-Policy']);self.assertIn('登录'.encode(),body)
 def test_login_assets_are_public_but_source_and_non_get_routes_stay_private(self):
  for path,kind in [('/favicon.svg','image/svg+xml'),('/favicon.ico','image/x-icon'),('/apple-touch-icon.png','image/png'),('/auth-assets/theme.css','text/css'),('/auth-assets/theme.js','application/javascript'),('/auth-assets/login.css','text/css'),('/auth-assets/login.js','application/javascript'),('/auth-assets/jarvis-core.webp','image/webp')]:
   status,h,body=self.request(path);self.assertEqual(status,200,path);self.assertIn(kind,h['Content-Type']);self.assertTrue(body)
   self.assertEqual(self.request(path,'HEAD')[0],200,path)
   self.assertEqual(self.request(path,'POST',b'')[0],401,path)
  for path in ['/auth-assets/asset-notes.txt','/auth-assets/jarvis-core-original.png','/auth-assets/../voice.html','/auth-assets/auth.json']:
   self.assertEqual(self.request(path)[0],401,path)
 def test_login_template_escapes_errors_and_has_complete_accessible_form(self):
  gate=access.PublicAccess(self.auth,HOST);page=gate.page('<script>alert(1)</script>')
  self.assertNotIn('<script>alert(1)</script>',page);self.assertIn('&lt;script&gt;',page)
  for value in ['id="username"','id="password"','id="showPassword"','autocomplete="current-password"','/favicon.svg','data-inline-asset="auth/jarvis-core.webp"']:
   self.assertIn(value,page)
  self.assertNotIn('{{',page)
 def test_cookie_flags_and_authentication_without_forwarding_cookie(self):
  status,h,_=self.login();self.assertIn('Secure',h['Set-Cookie']);self.assertIn('HttpOnly',h['Set-Cookie']);self.assertIn('SameSite=Strict',h['Set-Cookie']);self.assertIn('Path=/',h['Set-Cookie'])
  self.assertEqual(self.request('/v1/models',cookie=self.cookie)[0],200);self.assertIsNone(self.backends[0].calls[-1][1])
 def test_authenticated_static_page_has_frame_protection(self):
  status,h,body=self.request('/voice',cookie=self.cookie);self.assertEqual(status,200);self.assertEqual(h['X-Frame-Options'],'DENY');self.assertIn('Jarvis'.encode(),body)
 def test_wrong_password_and_non_ascii_username_fail_closed(self):
  self.assertEqual(self.login(password='wrong')[0],401);self.assertEqual(self.login(username='其他用户')[0],401)
 def test_wrong_host_or_cross_site_origins_are_rejected(self):
  self.assertEqual(self.request('/v1/models',cookie=self.cookie,headers={'Host':'evil.example'})[0],403)
  self.assertEqual(self.request('/v1/realtime',cookie=self.cookie,headers={'Origin':'https://evil.odn.cc','Upgrade':'websocket'})[0],403)
  self.assertEqual(self.request('/login','POST','username=wyatt&password=x',headers={'Content-Type':'application/x-www-form-urlencoded'})[0],403)
 def test_logout_revokes_previously_issued_cookie(self):
  self.assertEqual(self.request('/logout','POST',b'',self.cookie,{'Origin':ORIGIN})[0],303)
  self.assertEqual(self.request('/v1/models',cookie=self.cookie)[0],401)
 def test_oversized_or_ambiguous_framing_is_rejected(self):
  self.assertEqual(self.request('/login','POST',b'',headers={'Origin':ORIGIN,'Content-Length':'99999999'})[0],413)
  self.assertEqual(self.request('/login','POST',b'',headers={'Origin':ORIGIN,'Content-Length':'0','Transfer-Encoding':'chunked'})[0],400)
 def test_voice_and_media_still_reach_their_original_backends(self):
  status,_,body=self.request('/v1/audio/speech','POST',b'{}',self.cookie);self.assertEqual(status,200);self.assertEqual(json.loads(body)['role'],'speech')
  status,_,body=self.request('/v1/files/test/out.png',cookie=self.cookie);self.assertEqual(status,200);self.assertEqual(json.loads(body)['role'],'voice')
 def test_sse_arrives_before_the_upstream_finishes(self):
  s=self.backends[0];s.release.clear();c=http.client.HTTPSConnection('127.0.0.1',self.port,context=self.ctx,timeout=4)
  try:
   c.request('GET','/v1/stream',headers={'Host':HOST,'Cookie':self.cookie});r=c.getresponse();self.assertEqual(r.read(8),b'data:a\n\n');self.assertFalse(s.release.is_set());s.release.set();self.assertEqual(r.read(),b'data:b\n\n')
  finally:s.release.set();c.close()
 def test_authenticated_websocket_upgrade_and_disconnect(self):
  backend=self.backends[1];backend.disconnected.clear()
  with socket.create_connection(('127.0.0.1',self.port),timeout=4)as raw:
   with self.ctx.wrap_socket(raw,server_hostname=HOST)as sock:
    sock.sendall(f'GET /v1/realtime HTTP/1.1\r\nHost: {HOST}\r\nOrigin: {ORIGIN}\r\nCookie: {self.cookie}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n'.encode());data=b''
    while b'\r\n\r\n'not in data:data+=sock.recv(1)
    self.assertIn(b'101',data.split(b'\r\n')[0]);self.assertEqual(sock.recv(4),b'\x81\x02ok')
  self.assertTrue(backend.disconnected.wait(2))
 def test_nonexpiring_session_remains_valid_after_many_years(self):
  now=[100.0];gate=access.PublicAccess(self.auth,HOST,clock=lambda:now[0])
  class Writer:
   def __init__(self):self.data=b''
   def write(self,data):self.data+=data
   async def drain(self):pass
  async def exercise():
   body=urllib.parse.urlencode({'username':'wyatt','password':self.password}).encode()
   reader=asyncio.StreamReader();reader.feed_data(body);reader.feed_eof();writer=Writer()
   headers={b'host':[HOST],b'origin':[ORIGIN],b'content-type':['application/x-www-form-urlencoded'],b'content-length':[str(len(body))]}
   await gate.handle(reader,writer,'POST','/login',headers,('127.0.0.1',12345))
   self.assertTrue(writer.data.startswith(b'HTTP/1.1 303'))
   line=next(x for x in writer.data.decode().split('\r\n') if x.startswith('Set-Cookie: '))
   cookie=line[len('Set-Cookie: '):].split(';',1)[0];session_headers={b'host':[HOST],b'cookie':[cookie],b'origin':[ORIGIN]}
   key=gate.session(session_headers);self.assertIsNotNone(key);self.assertTrue(math.isinf(gate.sessions[key]))
   now[0]+=50*365*86400
   self.assertEqual(gate.session(session_headers),key)
   writer=Writer();await gate.handle(asyncio.StreamReader(),writer,'POST','/logout',session_headers,('127.0.0.1',12345))
   self.assertIsNone(gate.session(session_headers));self.assertIn(b'Max-Age=0',writer.data)
  asyncio.run(exercise())
 def test_login_sets_long_lived_secure_cookie(self):
  status,h,_=self.login();self.assertEqual(status,303)
  self.assertIn('Max-Age='+str(access.COOKIE_MAX_AGE),h['Set-Cookie'])
 def test_expired_sessions_and_unsafe_auth_files_are_rejected(self):
  gate=access.PublicAccess(self.auth,HOST,clock=lambda:100);token='test-token';key=hashlib.sha256(token.encode()).hexdigest();gate.sessions[key]=99
  self.assertIsNone(gate.session({b'cookie':[access.COOKIE+'='+token]}))
  p=self.dir/'unsafe.json';p.write_text(self.auth.read_text());p.chmod(0o644)
  with self.assertRaises(ValueError):access.PublicAccess(p,HOST)
 def test_public_auth_requires_static_gate_to_avoid_configuration_bypass(self):
  args=self.args.copy();i=args.index('--static-dir');del args[i:i+2]
  p=subprocess.run(args,capture_output=True,timeout=5);self.assertNotEqual(p.returncode,0);self.assertIn(b'--static-dir is required',p.stderr)
 def test_certificate_reload_keeps_login_session_and_process(self):
  pid=self.process.pid;os.kill(pid,signal.SIGHUP);time.sleep(.1)
  self.assertEqual(self.request('/v1/models',cookie=self.cookie)[0],200);self.assertIsNone(self.process.poll())
  cert=self.dir/'server.crt';original=cert.read_bytes()
  try:
   cert.write_text('not a certificate');os.kill(pid,signal.SIGHUP);time.sleep(.1)
   self.assertEqual(self.request('/v1/models',cookie=self.cookie)[0],200)
  finally:cert.write_bytes(original);os.kill(pid,signal.SIGHUP)
  self.assertEqual(self.process.pid,pid)
 def test_media_capability_is_https_and_anonymous_but_minting_is_private(self):
  endpoint='/v1/media/share';body=json.dumps({'url':'/v1/videos/video_0123456789abcdef/content'})
  self.assertEqual(self.request(endpoint,'POST',body=body)[0],401)
  status,_,data=self.request(endpoint,'POST',body=body,cookie=self.cookie);self.assertEqual(status,200)
  url=json.loads(data)['url'];self.assertTrue(url.startswith(ORIGIN+'/media/'))
  path=urllib.parse.urlsplit(url).path
  status,h,data=self.request(path,headers={'Range':'bytes=2-4'});self.assertEqual(status,206);self.assertEqual(data,b'234');self.assertEqual(h['Content-Range'],'bytes 2-4/10')
  status,h,data=self.request(path,'HEAD');self.assertEqual(status,200);self.assertEqual(data,b'');self.assertEqual(h['Content-Length'],'10')
  self.assertEqual(self.request(path.replace('/media/','/media/0'))[0],404)
  self.assertEqual(self.request(path,headers={'Host':'evil.test'})[0],403)
  self.assertEqual(self.request(path,'POST')[0],403)
 def test_completed_media_json_rewrites_without_deadlocking_post_body(self):
  for path,method,body in [('/v1/jobs/video_0123456789abcdef','GET',None),('/v1/images/generations','POST','{"prompt":"test"}')]:
   status,_,data=self.request(path,method,body=body,cookie=self.cookie)
   self.assertEqual(status,200);url=json.loads(data)['urls'][0];self.assertTrue(url.startswith(ORIGIN+'/media/'))
   self.assertEqual(self.request(urllib.parse.urlsplit(url).path)[2],b'0123456789')
 def test_media_mint_rejects_other_origin_and_non_media_routes(self):
  for value in ['/v1/chat/completions','/v1/files/../../secret','https://evil.test/foo']:
   self.assertEqual(self.request('/v1/media/share','POST',body=json.dumps({'url':value}),cookie=self.cookie)[0],400)
  self.assertEqual(self.request('/v1/media/share','POST',body='{}',cookie=self.cookie,headers={'Origin':'https://evil.test'})[0],403)
 def test_zz_login_attempts_are_bounded(self):
  for _ in range(8):self.assertEqual(self.login(password='bad')[0],401)
  status,h,_=self.login(password='bad');self.assertEqual(status,429);self.assertIn('Retry-After',h)

if __name__=='__main__':unittest.main()
