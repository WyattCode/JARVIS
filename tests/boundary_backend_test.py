"""Native-shaped MCP ownership, file URLs and bounded HTTP framing using local fakes."""
import asyncio
import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('boundary_brain',ROOT/'deploy/jarvis/remote_brain.py')
brain=importlib.util.module_from_spec(spec);spec.loader.exec_module(brain)
from bounded_http import request_json, BoundedHTTPError
PNG=base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC')
JOB='img_0123456789abcdef';PATH='/v1/files/'+JOB+'/0.png'

class BackendBoundary(unittest.IsolatedAsyncioTestCase):
 async def asyncSetUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
  self.calls=[];self.errors=[];self.handlers=[];self.servers=[];self.owner='worker';self.state='queued';self.mode={};self.padding=0
  ports={}
  for role in ('head','worker'):
   server=await asyncio.start_server(lambda r,w,role=role:self.native(r,w,role),'127.0.0.1',0)
   self.servers.append(server);ports[role]=server.sockets[0].getsockname()[1]
  self.ports=ports
  self.bridge=brain.Bridge({'base_url':'http://127.0.0.1:1/v1','model':'test-chat','name':'test-chat','api_key':'test',
   'image_worker_port':ports['worker'],'image_worker_machine':'worker','speech_backend_port':ports['worker'],'artifact_root':self.tmp.name},ports['head'])
  async def client(reader,writer):
   self.handlers.append(asyncio.current_task())
   try:await self.bridge.client(reader,writer)
   except Exception as error:self.errors.append(type(error).__name__)
  server=await asyncio.start_server(client,'127.0.0.1',0);self.servers.append(server);self.port=server.sockets[0].getsockname()[1]
 async def asyncTearDown(self):
  for server in self.servers:server.close();await server.wait_closed()
  for task in self.handlers:
   if not task.done():task.cancel()
  await asyncio.gather(*self.handlers,return_exceptions=True)
 async def native(self,reader,writer,role):
  self.handlers.append(asyncio.current_task())
  try:
   head=await reader.readuntil(b'\r\n\r\n');method,path,_=head.split(b'\r\n',1)[0].decode().split(' ',2)
   fields={k.lower():v.strip() for k,v in (line.split(b':',1) for line in head.split(b'\r\n')[1:] if b':' in line)}
   if path==PATH:data=PNG;self.calls.append((role,'download',{}))
   elif path!='/mcp':data=b'{"ok":true}';self.calls.append((role,'metadata',{}))
   else:
    value=json.loads(await reader.readexactly(int(fields.get(b'content-length',b'0'))));name=value['params']['name'];args=value['params'].get('arguments',{})
    self.calls.append((role,name,args))
    if not isinstance(args.get('id'),str) and name in ('get_job','cancel_job'):
     result={'isError':True,'content':[{'type':'text','text':'invalid arguments: id required'}]}
    elif role!=self.owner:
     result={'isError':True,'content':[{'type':'text','text':'no such job'}]}
    else:
     ident=args.get('id',JOB);url='http://'+fields[b'host'].decode()+'/v1/files/'+ident+'/0.png'
     summary={'id':ident,'status':'cancelled' if name=='cancel_job' else self.state,'files':[url] if self.state=='completed' else []}
     content=[{'type':'text','text':json.dumps(summary)}]
     if self.state=='completed':content.append({'type':'resource_link','uri':url,'name':'0.png','mimeType':'image/png'})
     if self.padding:content.append({'type':'image','data':'a'*self.padding,'mimeType':'image/png'})
     result={'isError':False,'content':content}
    data=json.dumps({'jsonrpc':'2.0','id':value['id'],'result':result}).encode()
   mode=self.mode.get(role)
   if mode=='truncated':wire=b'Content-Length: 9999\r\n\r\n{}'
   elif mode=='bad-header':wire=b'Content-Length: 2\r\nContent-Length: 3\r\n\r\n{}'
   elif mode=='oversize':wire=b'Content-Length: 100663297\r\n\r\n'
   elif mode=='chunked':wire=b'Transfer-Encoding: chunked\r\n\r\n'+hex(len(data))[2:].encode()+b'\r\n'+data+b'\r\n0\r\nX-End: yes\r\n\r\n'
   elif mode=='eof':wire=b'Connection: close\r\n\r\n'+data
   elif mode=='truncated-chunk':wire=b'Transfer-Encoding: chunked\r\n\r\n10\r\n{}'
   elif mode=='slow':
    writer.write(b'HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n')
    for _ in range(50):writer.write(b' ');await writer.drain();await asyncio.sleep(.03)
    return
   else:wire=b'Content-Length: '+str(len(data)).encode()+b'\r\n\r\n'+data
   writer.write(b'HTTP/1.1 200 OK\r\n'+wire);await writer.drain()
  except (ConnectionError,asyncio.IncompleteReadError):pass
  finally:
   writer.close()
   try:await writer.wait_closed()
   except OSError:pass
 async def rpc(self,name,args):
  self.calls.clear();self.errors.clear();value={'jsonrpc':'2.0','id':7,'method':'tools/call','params':{'name':name,'arguments':args}}
  data=json.dumps(value).encode();r,w=await asyncio.open_connection('127.0.0.1',self.port)
  w.write(b'POST /mcp HTTP/1.1\r\nHost: public.example\r\nContent-Length: '+str(len(data)).encode()+b'\r\n\r\n'+data);await w.drain()
  raw=await asyncio.wait_for(r.read(),8);w.close();await w.wait_closed()
  head,body=raw.split(b'\r\n\r\n',1);return int(head.split()[1]),json.loads(body)
 async def test_job_alias_is_normalized_for_query_wait_and_cancel(self):
  for name,args in [('get_job',{'job_id':'speech_old','wait_s':0}),('get_job',{'job_id':'speech_old','wait_s':1}),('cancel_job',{'job_id':'speech_old'}),('cancel_job',{'id':'speech_old','job_id':'speech_old'})]:
   code,value=await self.rpc(name,args);self.assertEqual(code,200);self.assertFalse(value['result']['isError'])
   self.assertTrue(all(call[2].get('id')=='speech_old' and 'job_id' not in call[2] for call in self.calls))
 async def test_conflicting_and_invalid_identifiers_never_probe_or_cancel(self):
  for args in ({'id':'speech_a','job_id':'speech_b'},{'id':None,'job_id':'speech_a'},{'id':''},{'job_id':' '},{'job_id':123},{'id':'../secret'},{},[]):
   code,value=await self.rpc('cancel_job',args);self.assertEqual(code,200);self.assertTrue(value['result']['isError']);self.assertEqual(self.calls,[])
 async def test_incomplete_worker_probes_fall_back_to_confirmed_head(self):
  self.owner='head'
  for mode in ('truncated','truncated-chunk','bad-header','oversize'):
   self.mode={'worker':mode}
   for name in ('get_job','cancel_job'):
    code,value=await self.rpc(name,{'id':'speech_old'})
    self.assertEqual(code,200);self.assertFalse(value['result']['isError']);self.assertEqual(self.errors,[])
    self.assertEqual(self.calls[:2],[('worker','get_job',{'id':'speech_old','wait_s':0}),('head','get_job',{'id':'speech_old','wait_s':0})])
    self.assertEqual(sum(c[1]=='cancel_job' for c in self.calls),int(name=='cancel_job'))
 async def test_no_cancellation_when_all_probes_are_incomplete(self):
  self.mode={'worker':'truncated','head':'truncated'}
  code,value=await self.rpc('cancel_job',{'id':'speech_old'});self.assertEqual(code,200);self.assertTrue(value['result']['isError'])
  self.assertTrue(all(c[1]=='get_job' for c in self.calls));self.assertEqual(self.errors,[])
 async def test_unreadable_query_returns_explicit_503(self):
  self.mode={'worker':'truncated','head':'truncated'}
  code,value=await self.rpc('get_job',{'id':'speech_old','wait_s':1});self.assertEqual(code,503);self.assertIn('error',value);self.assertEqual(self.errors,[])
 async def test_probe_and_persistent_image_cache_export_same_gateway_paths(self):
  self.state='completed'
  for index in range(2):
   code,value=await self.rpc('get_job',{'id':JOB});self.assertEqual(code,200)
   summary=json.loads(value['result']['content'][0]['text']);self.assertEqual(summary['files'],[PATH])
   self.assertEqual([x['uri'] for x in value['result']['content'] if x['type']=='resource_link'],[PATH])
   if index:self.assertEqual(self.calls,[])
  disk=json.loads((Path(self.tmp.name)/JOB/'.jarvis-job.json').read_text());self.assertEqual(disk['files'],[PATH])
 async def test_forwarded_audio_waiting_query_normalizes_links_with_all_framings(self):
  self.state='completed'
  for mode in ('length','chunked','eof'):
   self.mode={'worker':mode};code,value=await self.rpc('get_job',{'job_id':'speech_old','wait_s':1});self.assertEqual(code,200)
   self.assertEqual(value['result']['content'][1]['uri'],'/v1/files/speech_old/0.png')
 async def test_large_inline_response_over_32_mib_is_preserved(self):
  self.padding=33*1024*1024
  code,value=await self.rpc('get_job',{'id':'speech_old'})
  self.assertEqual(code,200);self.assertEqual(len(value['result']['content'][-1]['data']),self.padding)
 async def test_json_transport_total_deadline_stops_trickling_response(self):
  self.mode={'worker':'slow'};start=asyncio.get_running_loop().time()
  with self.assertRaises(BoundedHTTPError):await request_json(f'http://127.0.0.1:{self.ports["worker"]}/v1/tools',timeout=.12)
  self.assertLess(asyncio.get_running_loop().time()-start,.5)
 async def test_metadata_response_limit_applies_before_body(self):
  self.mode={'worker':'oversize'}
  with self.assertRaises(BoundedHTTPError):await self.bridge.fetch_json(False,'/tools',self.ports['worker'])
 async def test_transport_cancel_closes_peer_without_executor_residue(self):
  self.mode={'worker':'slow'};task=asyncio.create_task(request_json(f'http://127.0.0.1:{self.ports["worker"]}/v1/tools',timeout=5))
  await asyncio.sleep(.04);task.cancel()
  with self.assertRaises(asyncio.CancelledError):await task
  await asyncio.sleep(.1)
  self.assertTrue(all(t.done() for t in self.handlers))

class FileNormalization(unittest.TestCase):
 def test_only_structured_generated_paths_are_rewritten(self):
  plain='Read http://127.0.0.1:8196/v1/files/img_abcdef12/0.png in this explanation.'
  value={'result':{'content':[{'type':'text','text':plain},{'type':'resource_link','uri':'https://example.test/manual.pdf'},{'type':'image','data':'unchanged'}]}}
  self.assertEqual(brain.normalize_mcp_files(value),value);self.assertEqual(value['result']['content'][0]['text'],plain)
  self.assertEqual(brain.canonical_job_file('http://worker/v1/files/img_abcdef12/../secret'),'http://worker/v1/files/img_abcdef12/../secret')
 def test_old_cached_files_cannot_override_canonical_urls(self):
  job={'id':JOB,'status':'completed','files':['http://127.0.0.1:8196'+PATH],'urls':[PATH]}
  result=brain.normalize_mcp_files(brain.Bridge.image_job_rpc(job,1))
  self.assertEqual(result['result']['content'][1]['uri'],PATH)
  self.assertEqual(json.loads(result['result']['content'][0]['text'])['files'],[PATH])

if __name__=='__main__':unittest.main()
