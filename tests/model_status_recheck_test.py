import asyncio,copy,json,unittest
from model_status_test import brain,Status,RPC,CFG

class StatusReview(unittest.TestCase):
 def test_creative_description_does_not_trigger_lookup(self):
  for q in ['帮我生成一张色彩正常的图片','生成一段人物正常走路的视频','制作一段汽车正在运行的视频','能不能生成一张猫的图片？','把这张图片的背景换成纯白，人物清晰正常','帮我看看这张图片','图片里面有多少棵树']:
   self.assertFalse(brain.model_status_requested({'messages':[{'role':'user','content':q}]}),q)
 def test_common_state_questions_do_trigger_lookup(self):
  for q in ['视频模型启动了吗？','现在生图还行吗？','语音正常吗？','视频生成会不会影响语音？','现在图片可以用吗？','现在能生成图片吗？']:
   self.assertTrue(brain.model_status_requested({'messages':[{'role':'user','content':q}]}),q)
 def test_malformed_and_empty_audio_rosters_fail_closed(self):
  for bad in [[],[None],[{}],[{'kind':'transcription'}],[{'id':'x','kind':'image'}],[{'id':'x','kind':[]}],[{'id':{},'kind':'transcription'}]]:
   b,_=Status().make()
   async def fetch(remote,path,port=None,**kwargs):
    return {'data':bad} if port==18795 else {'data':[{'id':'drama','kind':'speech'}]}
   b.fetch_json=fetch
   for op in ('load_model','unload_model','reserve_for'):
    reason=asyncio.run(b.model_control_refusal({'name':op,'arguments':{'model':'future-asr'}}))
    self.assertIn('无法确认模型归属',reason,(bad,op))
 def test_known_audio_id_is_blocked_even_if_other_entry_malformed(self):
  b,_=Status().make()
  async def fetch(remote,path,port=None,**kwargs):return {'data':[None,{'id':'future-asr','kind':'transcription'}]} if port==18795 else {'data':[{'id':'drama','kind':'speech'}]}
  b.fetch_json=fetch
  self.assertIn('独立进程',asyncio.run(b.model_control_refusal({'name':'load_model','arguments':{'model':'future-asr'}})))
 def test_old_video_topology_uses_actual_independent_services(self):
  b,_=Status().make();b.config=dict(b.config);b.config.pop('image_worker_port')
  state=json.loads(asyncio.run(b.model_list(copy.deepcopy(RPC)))['result']['content'][0]['text']);names={m['kind']:m['id'] for m in state['models']}
  self.assertEqual(names['chat'],'actual-brain');self.assertEqual(names['speech'],'drama');self.assertEqual(names['transcription'],'qwen-asr');self.assertEqual(names['video'],'vid')
 def test_independent_audio_without_remote_video_is_supported(self):
  b,calls=Status().make();b.config=dict(b.config);b.config.pop('image_worker_port');b.config.pop('video_worker_port')
  state=json.loads(asyncio.run(b.model_list(copy.deepcopy(RPC)))['result']['content'][0]['text']);names={m['kind']:m['id'] for m in state['models']}
  self.assertEqual(names['speech'],'drama');self.assertEqual(names['transcription'],'qwen-asr');self.assertNotIn(8196,calls)

class AudioOnlyHttp(unittest.IsolatedAsyncioTestCase):
 async def test_control_guard_applies_even_without_video_worker(self):
  touched=[]
  async def backend(reader,writer):
   touched.append(True);writer.close();await writer.wait_closed()
  server=await asyncio.start_server(backend,'127.0.0.1',0);head=server.sockets[0].getsockname()[1]
  config={k:v for k,v in CFG.items() if k not in ('image_worker_port','video_worker_port')};b=brain.Bridge(config,head)
  bridge=await asyncio.start_server(b.client,'127.0.0.1',0);port=bridge.sockets[0].getsockname()[1]
  try:
   body=json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'unload_model','arguments':{'model':'qwen3-asr-1.7b'}}}).encode()
   r,w=await asyncio.open_connection('127.0.0.1',port);w.write(b'POST /mcp HTTP/1.1\r\nHost: local\r\nContent-Length: '+str(len(body)).encode()+b'\r\n\r\n'+body);await w.drain();raw=await asyncio.wait_for(r.read(),5);w.close();await w.wait_closed()
   payload=json.loads(raw.split(b'\r\n\r\n',1)[1]);self.assertTrue(payload['result']['isError']);self.assertEqual(touched,[])
  finally:
   bridge.close();server.close();await bridge.wait_closed();await server.wait_closed()
 async def test_audio_only_video_job_query_is_forwarded_to_head(self):
  touched=[]
  async def backend(reader,writer):
   head=await reader.readuntil(b'\r\n\r\n');size=next(int(x.split(b':',1)[1]) for x in head.split(b'\r\n') if x.lower().startswith(b'content-length:'))
   touched.append(json.loads(await reader.readexactly(size)));body=b'{"jsonrpc":"2.0","id":1,"result":{"content":[]}}'
   writer.write(b'HTTP/1.1 200 OK\r\nContent-Length: '+str(len(body)).encode()+b'\r\n\r\n'+body);await writer.drain();writer.close();await writer.wait_closed()
  server=await asyncio.start_server(backend,'127.0.0.1',0);head=server.sockets[0].getsockname()[1]
  config={k:v for k,v in CFG.items() if k not in ('image_worker_port','video_worker_port')};b=brain.Bridge(config,head)
  bridge=await asyncio.start_server(b.client,'127.0.0.1',0);port=bridge.sockets[0].getsockname()[1]
  try:
   body=json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'get_job','arguments':{'id':'video_123'}}}).encode()
   r,w=await asyncio.open_connection('127.0.0.1',port);w.write(b'POST /mcp HTTP/1.1\r\nHost: local\r\nContent-Length: '+str(len(body)).encode()+b'\r\n\r\n'+body);await w.drain();raw=await asyncio.wait_for(r.read(),5);w.close();await w.wait_closed()
   self.assertIn(b'200',raw.split(b'\r\n')[0]);self.assertEqual(touched[0]['params']['name'],'get_job')
  finally:
   bridge.close();server.close();await bridge.wait_closed();await server.wait_closed()
if __name__=='__main__':unittest.main()

class IntentHttp(unittest.IsolatedAsyncioTestCase):
 async def test_real_bridge_injects_only_for_status_questions(self):
  from unittest.mock import AsyncMock
  received=[]
  async def upstream(reader,writer):
   head=await reader.readuntil(b'\r\n\r\n');headers={}
   for line in head.split(b'\r\n')[1:]:
    if b':' in line:
     k,v=line.split(b':',1);headers[k.lower()]=v.strip()
   received.append(json.loads(await reader.readexactly(int(headers[b'content-length']))))
   body=b'{"choices":[{"message":{"content":"ok"}}]}'
   writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '+str(len(body)).encode()+b'\r\nConnection: close\r\n\r\n'+body);await writer.drain();writer.close();await writer.wait_closed()
  upstream_server=await asyncio.start_server(upstream,'127.0.0.1',0);up=upstream_server.sockets[0].getsockname()[1]
  config={**CFG,'base_url':f'http://127.0.0.1:{up}/v1','api_key':'test-key'};b=brain.Bridge(config)
  mock_roster={'result':{'content':[{'text':json.dumps({'models':[{'kind':'video','id':'v','state':'ready'}],'memory':{}},ensure_ascii=False)}]}}
  b.model_list=AsyncMock(return_value=mock_roster)
  server=await asyncio.start_server(b.client,'127.0.0.1',0);port=server.sockets[0].getsockname()[1]
  async def send(text):
   body=json.dumps({'model':'actual-brain','stream':False,'messages':[{'role':'user','content':text}]},ensure_ascii=False).encode()
   reader,writer=await asyncio.open_connection('127.0.0.1',port);writer.write(b'POST /v1/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: '+str(len(body)).encode()+b'\r\n\r\n'+body);await writer.drain();raw=await asyncio.wait_for(reader.read(),5);writer.close();await writer.wait_closed();self.assertIn(b'200',raw.split(b'\r\n')[0])
  try:
   await send('生成一段人物正常走路的视频');self.assertEqual(b.model_list.await_count,0);self.assertFalse(any('实时查询快照' in str(m.get('content')) for m in received[-1]['messages']))
   await send('视频模型启动了吗？');self.assertEqual(b.model_list.await_count,1);self.assertTrue(any('实时查询快照' in str(m.get('content')) for m in received[-1]['messages']))
   await send('生成一段视频，同时检查视频能不能用');self.assertEqual(b.model_list.await_count,2);self.assertTrue(any('实时查询快照' in str(m.get('content')) for m in received[-1]['messages']))
  finally:
   server.close();upstream_server.close();await server.wait_closed();await upstream_server.wait_closed()

class MixedIntent(unittest.TestCase):
 def test_creative_plus_explicit_status_still_queries(self):
  for q in ['生成一段视频，同时检查语音有没有暂停','制作一张图片，并检查视频模型状态','生成一段视频，并告诉我语音是否暂停']:
   self.assertTrue(brain.model_status_requested({'messages':[{'role':'user','content':q}]}),q)
 def test_creative_scene_words_remain_unclassified(self):
  for q in ['生成一段人物正常走路的视频','制作一段汽车正在运行的视频','生成一段含语音暂停的喜剧视频']:
   self.assertFalse(brain.model_status_requested({'messages':[{'role':'user','content':q}]}),q)
