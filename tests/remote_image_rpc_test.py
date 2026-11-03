"""Full HTTP/MCP routing tests with an isolated worker and persistent image cache."""
import asyncio,base64,importlib.util,json,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('image_rpc_brain',ROOT/'deploy/jarvis/remote_brain.py');brain=importlib.util.module_from_spec(spec);spec.loader.exec_module(brain)
PNG=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC')
JOB='img_0123456789abcdef'
PATH='/v1/files/'+JOB+'/0.png'

class ImageRpcTests(unittest.IsolatedAsyncioTestCase):
 async def asyncSetUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name);self.requests=[];self.status='completed';self.invalid_png=False;self.large=False;self.download_mode=None
  self.worker=await asyncio.start_server(self.worker_client,'127.0.0.1',0);self.worker_port=self.worker.sockets[0].getsockname()[1]
  self.cfg={'base_url':'http://127.0.0.1:1234/v1','model':'test','name':'test','api_key':'test','image_worker_port':self.worker_port,'image_worker_machine':'remote','video_worker_port':self.worker_port,'video_backend_port':self.worker_port,'artifact_root':str(self.root)}
  await self.start_bridge()
 async def start_bridge(self):
  self.bridge=brain.Bridge(self.cfg,backend=self.worker_port)
  self.server=await asyncio.start_server(self.bridge.client,'127.0.0.1',0);self.port=self.server.sockets[0].getsockname()[1]
 async def asyncTearDown(self):
  self.server.close();self.worker.close();await self.server.wait_closed();await self.worker.wait_closed();await asyncio.sleep(.01)
 def rpc_result(self,ident):
  job={'id':JOB,'model':'qwen-image-2.1-turbo','status':self.status,'files':['http://localhost'+PATH] if self.status=='completed' else [],'progress':100 if self.status=='completed' else 0}
  content=[{'type':'text','text':json.dumps(job)}]
  if self.status=='completed':content+=[{'type':'image','data':base64.b64encode(PNG).decode(),'mimeType':'image/png'},{'type':'resource_link','uri':'http://localhost'+PATH,'name':'0.png','mimeType':'image/png'}]
  result={'jsonrpc':'2.0','id':ident,'result':{'isError':False,'content':content}}
  if self.large:result['result']['_meta']={'padding':'x'*(2*1024*1024+1)}
  return result
 async def worker_client(self,reader,writer):
  try:
   head=await reader.readuntil(b'\r\n\r\n');line=head.split(b'\r\n')[0].decode();self.requests.append(line)
   if line.startswith('GET '):body=b'bad' if self.invalid_png else PNG;mime='image/png'
   else:
    length=int(next(x.split(b':',1)[1] for x in head.split(b'\r\n') if x.lower().startswith(b'content-length:')));value=json.loads(await reader.readexactly(length));body=json.dumps(self.rpc_result(value['id'])).encode();mime='application/json'
   declared=str(len(body));extra=''
   if line.startswith('GET '):
    if self.download_mode in ('truncated','truncated-exact','no-length-truncated'):body=PNG[:40]
    if self.download_mode=='truncated-exact':declared=str(len(body))
    if self.download_mode in ('no-length-truncated','no-length-valid'):declared=None
    if self.download_mode=='bad-crc':body=body[:40]+bytes([body[40]^1])+body[41:]
    if self.download_mode=='oversize':declared=str(33*1024*1024)
    if self.download_mode=='bad-length':declared='invalid'
    if self.download_mode=='chunked-truncated':
     declared=None;extra='Transfer-Encoding: chunked\r\n';body=b'28\r\n'+PNG[:40]+b'\r\n'
   length_header='' if declared is None else 'Content-Length: '+declared+'\r\n'
   writer.write(f'HTTP/1.1 200 OK\r\nContent-Type: {mime}\r\n{length_header}{extra}Connection: close\r\n\r\n'.encode()+body);await writer.drain()
  finally:writer.close();await writer.wait_closed()
 async def request(self,method,path,value=None):
  reader,writer=await asyncio.open_connection('127.0.0.1',self.port);body=json.dumps(value).encode() if value is not None else b''
  writer.write(f'{method} {path} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n'.encode()+body);await writer.drain()
  head=await reader.readuntil(b'\r\n\r\n');status=int(head.split(b' ',2)[1]);length=int(next(x.split(b':',1)[1] for x in head.split(b'\r\n') if x.lower().startswith(b'content-length:')));data=await reader.readexactly(length);writer.close();await writer.wait_closed();return status,data
 async def rpc(self,name,args=None):
  code,data=await self.request('POST','/mcp',{'jsonrpc':'2.0','id':7,'method':'tools/call','params':{'name':name,'arguments':args or {}}});return code,json.loads(data)
 def assert_cached(self):
  self.assertEqual((self.root/JOB/'0.png').read_bytes(),PNG);self.assertEqual(self.bridge.cached_image_job(JOB)['status'],'completed')
 def client_result(self,ident):
  value=self.rpc_result(ident);content=value['result']['content'];job=json.loads(content[0]['text'])
  job['files']=[PATH] if self.status=='completed' else [];content[0]['text']=json.dumps(job)
  for block in content:
   if block['type']=='resource_link':block['uri']=PATH
  return value
 async def test_generate_image_retains_files_and_preserves_inline_and_resource_content(self):
  code,value=await self.rpc('generate_image',{'prompt':'test'});self.assertEqual(code,200);self.assertEqual(value,self.client_result(7));self.assert_cached();self.assertIn('GET '+PATH+' HTTP/1.1',self.requests)
 async def test_large_inline_response_still_mirrors_files(self):
  self.large=True;code,value=await self.rpc('generate_image',{'prompt':'test'});self.assertEqual(code,200);self.assertEqual(value,self.client_result(7));self.assert_cached()
 async def test_pending_generate_caches_when_zero_wait_get_job_completes(self):
  self.status='queued';code,value=await self.rpc('generate_image',{'wait_s':0});self.assertEqual(code,200);self.assertIsNone(self.bridge.cached_image_job(JOB))
  self.status='completed';code,value=await self.rpc('get_job',{'id':JOB,'wait_s':0});self.assertEqual(code,200);self.assert_cached()
 async def test_waiting_get_job_completion_also_mirrors(self):
  code,value=await self.rpc('get_job',{'job_id':JOB,'wait_s':10});self.assertEqual(code,200);self.assert_cached()
 async def test_cached_job_and_file_survive_both_worker_loss_and_bridge_restart(self):
  await self.rpc('generate_image');self.worker.close();await self.worker.wait_closed();self.server.close();await self.server.wait_closed();await self.start_bridge();before=len(self.requests)
  code,value=await self.rpc('get_job',{'id':JOB});self.assertEqual(code,200);self.assertFalse(value['result']['isError']);self.assertTrue(any(c['type']=='resource_link' for c in value['result']['content']))
  self.assertEqual(await self.request('GET',PATH),(200,PNG));code,data=await self.request('GET','/v1/jobs/'+JOB);self.assertEqual(code,200);self.assertEqual(json.loads(data)['status'],'completed');self.assertEqual(len(self.requests),before)
 async def test_invalid_png_does_not_report_success_or_write_completed_metadata(self):
  self.invalid_png=True;code,value=await self.rpc('generate_image');self.assertGreaterEqual(code,400);self.assertIsNone(self.bridge.cached_image_job(JOB));self.assertFalse((self.root/JOB/'.jarvis-job.json').exists())
 async def test_missing_png_invalidates_cached_completion(self):
  await self.rpc('generate_image');(self.root/JOB/'0.png').unlink();self.assertIsNone(self.bridge.cached_image_job(JOB))
 async def test_image_cache_is_usable_by_existing_share_signer(self):
  await self.rpc('generate_image')
  module_spec=importlib.util.spec_from_file_location('image_share',ROOT/'deploy/jarvis/media_share.py');share=importlib.util.module_from_spec(module_spec);module_spec.loader.exec_module(share)
  cfg=self.root/'share.json';cfg.write_text(json.dumps({'roots':[str(self.root)],'key_file':str(self.root/'share.key')}));self.assertIn('/media/',share.MediaShare(cfg,'example.test').url(PATH))

 async def test_broken_download_variants_never_commit_completed_cache(self):
  for mode in ['truncated','truncated-exact','no-length-truncated','bad-crc','oversize','bad-length','chunked-truncated']:
   with self.subTest(mode=mode):
    self.download_mode=mode;code,value=await self.rpc('generate_image');self.assertEqual(code,503);self.assertIsNone(self.bridge.cached_image_job(JOB));self.assertFalse((self.root/JOB/'0.png').exists());self.assertFalse((self.root/JOB/'.jarvis-job.json').exists())
 async def test_valid_png_without_content_length_is_accepted(self):
  self.download_mode='no-length-valid';code,value=await self.rpc('generate_image');self.assertEqual(code,200);self.assert_cached()
 async def test_existing_corrupt_cache_is_rejected_then_repaired_on_get_job(self):
  await self.rpc('generate_image');(self.root/JOB/'0.png').write_bytes(PNG[:40]);self.assertIsNone(self.bridge.cached_image_job(JOB))
  code,value=await self.rpc('get_job',{'id':JOB});self.assertEqual(code,200);self.assert_cached()
 async def test_failed_download_does_not_overwrite_previous_valid_image(self):
  await self.rpc('generate_image');self.download_mode='truncated';code,value=await self.rpc('generate_image');self.assertEqual(code,503);self.assert_cached()
 async def test_retry_after_download_failure_succeeds(self):
  self.download_mode='truncated';code,_=await self.rpc('generate_image');self.assertEqual(code,503)
  self.download_mode=None;code,_=await self.rpc('generate_image');self.assertEqual(code,200);self.assert_cached()

if __name__=='__main__':unittest.main()
