import asyncio
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
def module(name,file):
 s=importlib.util.spec_from_file_location(name,ROOT/file);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
brain=module('offload_brain','deploy/jarvis/remote_brain.py')
proxy=module('offload_proxy','deploy/jarvis/proxy_worker.py')
CFG={'base_url':'http://127.0.0.1:9999/v1','model':'brain','name':'Brain','api_key':'test-only','video_backend_port':8194,'video_worker_port':8196,'video_worker_machine':'standby'}

class OffloadTests(unittest.TestCase):
 def setUp(self):self.b=brain.Bridge(CFG)
 def test_creation_never_falls_back_to_head_gpu(self):
  self.assertEqual(self.b.video_ports('/v1/videos','POST'),[8194])
  self.assertEqual(self.b.video_ports('/v1/audio/speech','POST'),[8190])
 def test_queries_preserve_old_head_and_direct_worker_job_ids(self):
  for p in ['/v1/videos/video_x','/v1/jobs/video_x','/v1/videos/video_x/content','/v1/files/video_x/video.mp4']:
   self.assertEqual(self.b.video_ports(p,'GET'),[8194,8190,8196])
 def test_video_operator_load_controls_go_to_worker(self):
  self.assertEqual(self.b.video_ports('/v1/tools/minimax-h3/load','POST'),[8196])
  self.assertEqual(self.b.video_ports('/v1/tools/fishaudio/drama-3/unload','POST'),[8190])
 def test_mcp_video_and_memory_management_are_routed(self):
  for name,args in [('generate_video',{}),('reserve_for',{'model':'video'}),('load_model',{'model':'minimax-h3'}),('unload_model',{'model':'video'}),('get_job',{'id':'video_x'})]:
   self.assertEqual(self.b.mcp_ports({'method':'tools/call','params':{'name':name,'arguments':args}}),[8196])
  self.assertEqual(self.b.mcp_ports({'method':'tools/call','params':{'name':'reserve_for','arguments':{'model':'image'}}}),[8190])
 def test_existing_single_head_configuration_is_unchanged(self):
  c={k:v for k,v in CFG.items() if not k.startswith('video_')};b=brain.Bridge(c)
  self.assertEqual(b.video_ports('/v1/videos','POST'),[8190]);self.assertEqual(b.mcp_ports({'method':'tools/call','params':{'name':'generate_video'}}),[8190])
 def test_video_proxy_reads_placement_but_speech_does_not(self):
  with tempfile.TemporaryDirectory() as folder:
   p=Path(folder)/'route.json';p.write_text('{"upstream_port":8196}')
   cfg={'kind':'video','options':{'upstream_port':8190,'video_route_file':str(p)}}
   self.assertEqual(proxy.upstream_port(cfg),8196);cfg['kind']='speech';self.assertEqual(proxy.upstream_port(cfg),8190)
 def test_invalid_placement_does_not_fall_back_to_head(self):
  with tempfile.TemporaryDirectory() as folder:
   p=Path(folder)/'route.json';p.write_text('{"upstream_port":-1}')
   with self.assertRaises(ValueError):proxy.upstream_port({'kind':'video','options':{'upstream_port':8190,'video_route_file':str(p)}})
 def test_chunked_rpc_body_is_decoded_and_ambiguous_framing_refused(self):
  async def run():
   r=asyncio.StreamReader();r.feed_data(b'3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n');r.feed_eof();self.assertEqual(await self.b.request_payload(r,{b'transfer-encoding':b'chunked'}),b'abcde')
   with self.assertRaises(ValueError):await self.b.request_payload(r,{b'transfer-encoding':b'chunked',b'content-length':b'5'})
  asyncio.run(run())
 def test_model_list_merges_video_without_losing_head_memory(self):
  def result(models,memory):return{'result':{'content':[{'type':'text','text':json.dumps({'models':models,'memory':memory})}]}}
  head=result([{'id':'image','kind':'image'},{'id':'minimax-h3','kind':'video'}],{'free':42})
  worker=result([{'id':'minimax-h3','kind':'video','state':'busy'}],{'free':78})
  with mock.patch.object(self.b,'local_rpc',mock.AsyncMock(side_effect=[head,worker])):
   x=asyncio.run(self.b.model_list({}));value=json.loads(x['result']['content'][0]['text'])
  self.assertEqual(value['memory'],{'free':42});self.assertEqual(value['models'][1]['machine'],'standby');self.assertEqual(value['video_worker_memory'],{'free':78})
 def test_missing_or_malformed_worker_stays_visible_and_queries_are_bounded(self):
  def result(models):return {'result':{'content':[{'text':json.dumps({'models':models,'memory':{'free':42}})}]}}
  for remote in [OSError('offline'), {'result':{'content':[]}}, result([]), result([None])]:
   rpc=mock.AsyncMock(side_effect=[result([{'id':'image','kind':'image'}]),remote])
   with mock.patch.object(self.b,'local_rpc',rpc):
    out=asyncio.run(self.b.model_list({}))
   models=json.loads(out['result']['content'][0]['text'])['models']
   self.assertEqual(models[-1]['id'],'minimax-h3');self.assertEqual(models[-1]['state'],'failed')
   self.assertEqual(rpc.call_args.kwargs,{'timeout':1.5})
 def test_metadata_worker_offline_without_head_video_registration(self):
  async def fetch(remote,path,port=None,timeout=8):
   if port:raise OSError('offline')
   return {'data':[{'id':'brain'}] if remote else [{'id':'image','kind':'image'}]}
  with mock.patch.object(self.b,'fetch_json',side_effect=fetch):
   for path in ['/models','/tools']:
    data=asyncio.run(self.b.metadata(path))['data']
    self.assertEqual(data[-1]['id'],'minimax-h3');self.assertEqual(data[-1]['state'],'failed')
 def test_chunked_small_chunks_work_but_oversized_trailers_are_rejected(self):
  async def run():
   r=asyncio.StreamReader();r.feed_data(b'1\r\na\r\n'*10000+b'0\r\n\r\n');r.feed_eof()
   self.assertEqual(await self.b.request_payload(r,{b'transfer-encoding':b'chunked'}),b'a'*10000)
   r=asyncio.StreamReader();r.feed_data(b'0\r\n'+b'x: '+b'a'*8200+b'\r\n\r\n');r.feed_eof()
   with self.assertRaisesRegex(ValueError,'trailers'):await self.b.request_payload(r,{b'transfer-encoding':b'chunked'})
  asyncio.run(run())

class OffloadHttpTests(unittest.IsolatedAsyncioTestCase):
 async def asyncSetUp(self):
  self.calls=[];self.servers=[]
  async def backend(reader,writer,role):
   try:
    head=await reader.readuntil(b'\r\n\r\n');lines=head.decode().split('\r\n');method,path,_=lines[0].split();headers=dict(x.split(': ',1) for x in lines[1:] if ': ' in x)
    body=await reader.readexactly(int(headers.get('Content-Length','0')))
    self.calls.append((role,method,path,body))
    status=404 if role=='coordinator' and method=='GET' else 200
    data=json.dumps({'role':role}).encode()
    writer.write(f'HTTP/1.1 {status} Test\r\nContent-Length: {len(data)}\r\nConnection: close\r\n\r\n'.encode()+data);await writer.drain()
   finally:writer.close();await writer.wait_closed()
  ports={}
  for role in ['head','worker','coordinator']:
   server=await asyncio.start_server(lambda r,w,role=role:backend(r,w,role),'127.0.0.1',0);self.servers.append(server);ports[role]=server.sockets[0].getsockname()[1]
  self.b=brain.Bridge(dict(CFG,video_worker_port=ports['worker'],video_backend_port=ports['coordinator']),ports['head'])
  self.server=await asyncio.start_server(self.b.client,'127.0.0.1',0);self.servers.append(self.server);self.port=self.server.sockets[0].getsockname()[1]
 async def asyncTearDown(self):
  for s in self.servers:s.close()
  for s in self.servers:await s.wait_closed()
 async def request(self,data):
  reader,writer=await asyncio.open_connection('127.0.0.1',self.port);writer.write(data);await writer.drain();out=await asyncio.wait_for(reader.read(),3);writer.close();await writer.wait_closed();return out
 async def test_chunked_video_creation_hits_only_coordinator_with_decoded_body(self):
  out=await self.request(b'POST /v1/videos HTTP/1.1\r\nHost: local\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n')
  self.assertIn(b'200',out.split(b'\r\n')[0]);self.assertEqual(self.calls,[('coordinator','POST','/v1/videos',b'{}')])
 async def test_old_video_get_falls_back_to_head_only_after_404(self):
  out=await self.request(b'GET /v1/videos/video_unknown HTTP/1.1\r\nHost: local\r\n\r\n')
  self.assertIn(b'200',out.split(b'\r\n')[0]);self.assertEqual([x[0] for x in self.calls],['coordinator','head'])
 async def test_creation_outage_never_falls_back_to_head(self):
  self.servers[2].close();await self.servers[2].wait_closed()
  out=await self.request(b'POST /v1/videos HTTP/1.1\r\nHost: local\r\nContent-Length: 2\r\n\r\n{}')
  self.assertIn(b'503',out.split(b'\r\n')[0]);self.assertEqual(self.calls,[])

if __name__=='__main__':unittest.main()
