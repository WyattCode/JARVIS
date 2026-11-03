import asyncio, json, unittest
import tempfile, threading
from pathlib import Path
from unittest.mock import AsyncMock, patch
from video_offload_test import OffloadHttpTests, brain
from model_status_test import CFG
import remote_image_rpc_test as image_fixtures

class MediaReadFailures(OffloadHttpTests):
 async def test_connection_failure_reads_next_host(self):
  self.servers[2].close();await self.servers[2].wait_closed()
  for method in ('GET','HEAD'):
   self.calls.clear()
   out=await self.request(f'{method} /v1/videos/video_old HTTP/1.1\r\nHost: local\r\n\r\n'.encode())
   self.assertIn(b'200',out.split(b'\r\n')[0]);self.assertEqual([x[0] for x in self.calls],['head'])
 async def test_connection_failure_never_retries_creation(self):
  self.servers[2].close();await self.servers[2].wait_closed()
  body=b'{"prompt":"test"}'
  out=await self.request(b'POST /v1/videos HTTP/1.1\r\nHost: local\r\nContent-Length: '+str(len(body)).encode()+b'\r\n\r\n'+body)
  self.assertIn(b'503',out.split(b'\r\n')[0]);self.assertEqual(self.calls,[])
 async def test_gateway_failure_reads_next_host(self):
  async def failed(reader,writer):
   await reader.readuntil(b'\r\n\r\n');writer.write(b'HTTP/1.1 503 Error\r\nContent-Length: 0\r\n\r\n');await writer.drain();writer.close();await writer.wait_closed()
  server=await asyncio.start_server(failed,'127.0.0.1',0);self.servers.append(server)
  self.b.config['video_backend_port']=server.sockets[0].getsockname()[1]
  out=await self.request(b'GET /v1/videos/video_old HTTP/1.1\r\nHost: local\r\n\r\n')
  self.assertIn(b'200',out.split(b'\r\n')[0]);self.assertEqual([x[0] for x in self.calls],['head'])

class AudioToolRouting(unittest.IsolatedAsyncioTestCase):
 def setUp(self):
  self.b=brain.Bridge(CFG)
  async def fetch(remote,path,port=None,**kw):
   return {'data':[{'id':'qwen3-asr-1.7b','kind':'transcription'},{'id':'fishaudio/drama-3','kind':'speech'}]}
  self.b.fetch_json=AsyncMock(side_effect=fetch)
 async def test_asr_default_is_pinned_and_routes_to_coordinator(self):
  params={'name':'transcribe_audio','arguments':{'audio':'data:audio/wav;base64,AA=='}}
  self.assertIsNone(await self.b.prepare_audio_tool(params));self.assertEqual(params['arguments']['model'],'qwen3-asr-1.7b')
  self.assertEqual(self.b.mcp_ports({'method':'tools/call','params':params}),[8194])
 async def test_old_or_mismatched_asr_is_refused(self):
  p={'name':'transcribe_audio','arguments':{'model':'whisper-large-v3-turbo'}}
  self.assertIsNotNone(await self.b.prepare_audio_tool(p))
  async def mismatch(remote,path,port=None,**kw):return {'data':[{'kind':'transcription','id':'old' if port==8194 else 'qwen3-asr-1.7b'}]}
  self.b.fetch_json=AsyncMock(side_effect=mismatch)
  self.assertIsNotNone(await self.b.prepare_audio_tool({'name':'transcribe_audio','arguments':{}}))
 async def test_unavailable_adapter_refuses_instead_of_fallback(self):
  self.b.fetch_json=AsyncMock(side_effect=OSError('offline'))
  self.assertIsNotNone(await self.b.prepare_audio_tool({'name':'transcribe_audio','arguments':{}}))
 async def test_blank_audio_model_cannot_disable_explicit_pinning(self):
  for bad_id in ('', '   '):
   self.b.fetch_json=AsyncMock(return_value={'data':[{'id':bad_id,'kind':'transcription'}]})
   params={'name':'transcribe_audio','arguments':{}}
   self.assertIsNotNone(await self.b.prepare_audio_tool(params))
   self.assertNotIn('model',params['arguments'])
 async def test_speech_and_voice_list_use_guarded_service(self):
  for name in ('synthesize_speech','list_voices'):
   self.assertEqual(self.b.mcp_ports({'method':'tools/call','params':{'name':name,'arguments':{}}}),[8194])
 async def test_audio_job_and_file_reads_preserve_new_and_old_jobs(self):
  for prefix in ('speech','transcription'):
   for path in (f'/v1/jobs/{prefix}_abcd',f'/v1/files/{prefix}_abcd/speech.wav'):
    self.assertEqual(self.b.video_ports(path,'GET'),[8194,8190])
   for op in ('get_job','cancel_job'):
    self.assertEqual(self.b.mcp_ports({'method':'tools/call','params':{'name':op,'arguments':{'id':prefix+'_abcd'}}}),[8194,8190])

class AudioMcpHttpAudit(unittest.IsolatedAsyncioTestCase):
 async def asyncSetUp(self):
  self.calls=[];self.servers=[];self.handlers=[]
  async def backend(reader,writer,role):
   try:
    head=await reader.readuntil(b'\r\n\r\n')
    headers={k.lower():v.strip() for k,v in (line.split(b':',1) for line in head.split(b'\r\n')[1:] if b':' in line)}
    value=json.loads(await reader.readexactly(int(headers[b'content-length'])))
    self.calls.append((role,value))
    body=json.dumps({'jsonrpc':'2.0','id':value.get('id'),'result':{'isError':False,'content':[{'type':'text','text':'ok'}]}}).encode()
    writer.write(b'HTTP/1.1 200 OK\r\nContent-Length: '+str(len(body)).encode()+b'\r\nConnection: close\r\n\r\n'+body);await writer.drain()
   finally:
    writer.close();await writer.wait_closed()
  ports={}
  for role in ('head','audio'):
   server=await asyncio.start_server(lambda r,w,role=role:backend(r,w,role),'127.0.0.1',0)
   self.servers.append(server);ports[role]=server.sockets[0].getsockname()[1]
  config={**CFG,'speech_backend_port':ports['audio']}
  self.bridge=brain.Bridge(config,ports['head'])
  async def fetch(*args,**kwargs):return {'data':[{'id':'qwen3-asr-1.7b','kind':'transcription'},{'id':'fishaudio/drama-3','kind':'speech'}]}
  self.bridge.fetch_json=fetch
  async def client(reader,writer):
   task=asyncio.current_task();self.handlers.append(task)
   await self.bridge.client(reader,writer)
  self.server=await asyncio.start_server(client,'127.0.0.1',0);self.servers.append(self.server)
  self.port=self.server.sockets[0].getsockname()[1]
 async def asyncTearDown(self):
  for server in self.servers:server.close()
  for server in self.servers:await server.wait_closed()
  for task in self.handlers:
   if not task.done():task.cancel()
  await asyncio.gather(*self.handlers,return_exceptions=True)
 async def send(self,name,args):
  value={'jsonrpc':'2.0','id':37,'method':'tools/call','params':{'name':name,'arguments':args}}
  data=json.dumps(value).encode();reader,writer=await asyncio.open_connection('127.0.0.1',self.port)
  writer.write(b'POST /mcp HTTP/1.1\r\nHost: local\r\nContent-Length: '+str(len(data)).encode()+b'\r\n\r\n'+data);await writer.drain()
  return reader,writer
 async def test_default_model_is_pinned_in_actual_forwarded_http_payload(self):
  for name,args,model in [('transcribe_audio',{'audio':'AA=='},'qwen3-asr-1.7b'),('synthesize_speech',{'input':'测试'},'fishaudio/drama-3')]:
   reader,writer=await self.send(name,args)
   raw=await asyncio.wait_for(reader.read(),2);writer.close();await writer.wait_closed()
   self.assertIn(b'200',raw.split(b'\r\n')[0]);self.assertEqual(self.calls[-1][0],'audio')
   forwarded=self.calls[-1][1];self.assertEqual(forwarded['id'],37);self.assertEqual(forwarded['params']['arguments']['model'],model)
  self.assertEqual(len(self.calls),2)
 async def test_disconnected_caller_during_model_lookup_submits_no_audio_job(self):
  started=asyncio.Event();release=asyncio.Event()
  async def fetch(*args,**kwargs):
   started.set();await release.wait()
   return {'data':[{'id':'qwen3-asr-1.7b','kind':'transcription'}]}
  self.bridge.fetch_json=fetch
  reader,writer=await self.send('transcribe_audio',{'audio':'AA=='})
  await asyncio.wait_for(started.wait(),1);writer.close();await writer.wait_closed()
  await asyncio.sleep(0.01);release.set()
  await asyncio.wait_for(asyncio.gather(*self.handlers),1)
  self.assertEqual(self.calls,[])
 async def test_cancellation_is_sent_once_to_the_probed_owner(self):
  probes=[]
  async def rpc(port,value,timeout=15):
   probes.append((port,value))
   if port==self.bridge.backend:
    return {'result':{'isError':False,'content':[{'type':'text','text':json.dumps({'id':value['params']['arguments']['id'],'status':'queued'})}]}}
   return {'result':{'isError':True,'content':[]}}
  self.bridge.local_rpc=rpc
  reader,writer=await self.send('cancel_job',{'id':'transcription_old'})
  raw=await asyncio.wait_for(reader.read(),2);writer.close();await writer.wait_closed()
  self.assertIn(b'200',raw.split(b'\r\n')[0]);self.assertEqual(len(self.calls),1)
  role,value=self.calls[0];self.assertEqual(role,'head');self.assertEqual(value['params'],{'name':'cancel_job','arguments':{'id':'transcription_old'}})
  self.assertEqual(len(probes),2);self.assertTrue(all(value['params']['name']=='get_job' for _,value in probes))

class CachedPngAudit(unittest.IsolatedAsyncioTestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
  self.root=Path(self.tmp.name);self.job=image_fixtures.JOB
  folder=self.root/self.job;folder.mkdir()
  self.file=folder/'0.png';self.file.write_bytes(image_fixtures.PNG)
  (folder/'.jarvis-job.json').write_text(json.dumps({'id':self.job,'status':'completed','urls':[image_fixtures.PATH]}))
  self.bridge=brain.Bridge({**CFG,'artifact_root':str(self.root)})
  brain.validated_png_file.cache_clear()
  self.addCleanup(brain.validated_png_file.cache_clear)
 async def test_repeat_cache_lookup_validates_once_and_changed_file_invalidates(self):
  with patch.object(brain,'validate_png',wraps=brain.validate_png) as validate:
   for _ in range(3):self.assertIsNotNone(self.bridge.cached_image_job(self.job))
   self.assertEqual(validate.call_count,1)
   old=image_fixtures.PNG;self.file.write_bytes(old[:40]+bytes([old[40]^1])+old[41:])
   self.assertIsNone(self.bridge.cached_image_job(self.job));self.assertEqual(validate.call_count,2)
 async def test_http_and_mcp_cache_validation_run_outside_event_loop(self):
  server=await asyncio.start_server(self.bridge.client,'127.0.0.1',0);port=server.sockets[0].getsockname()[1]
  loop_thread=threading.get_ident();threads=[];original=brain.validate_png
  def validate(data):threads.append(threading.get_ident());return original(data)
  try:
   with patch.object(brain,'validate_png',side_effect=validate):
    for method in ('GET','POST'):
     brain.validated_png_file.cache_clear()
     body=json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'get_job','arguments':{'id':self.job}}}).encode() if method=='POST' else b''
     path='/mcp' if method=='POST' else '/v1/jobs/'+self.job
     reader,writer=await asyncio.open_connection('127.0.0.1',port)
     writer.write(f'{method} {path} HTTP/1.1\r\nHost: local\r\nContent-Length: {len(body)}\r\n\r\n'.encode()+body);await writer.drain()
     raw=await asyncio.wait_for(reader.read(),2);writer.close();await writer.wait_closed()
     self.assertIn(b'200',raw.split(b'\r\n')[0])
   self.assertEqual(len(threads),2);self.assertTrue(all(thread!=loop_thread for thread in threads))
  finally:server.close();await server.wait_closed()

if __name__=='__main__':unittest.main()
