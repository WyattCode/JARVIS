import base64
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC")
import asyncio,json,tempfile,unittest,sys
from pathlib import Path
from unittest.mock import AsyncMock
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'deploy/jarvis'))
import remote_brain as brain

class ChatAdapter(unittest.IsolatedAsyncioTestCase):
 async def asyncSetUp(self):
  self.calls=[];self.status=200;self.framing='length';self.result={'choices':[{'message':{'role':'assistant','content':'答复。'},'finish_reason':'stop'}]}
  async def upstream(reader,writer):
   try:
    head=await reader.readuntil(b'\r\n\r\n');fields={k.lower():v.strip() for k,v in (x.split(b':',1) for x in head.split(b'\r\n')[1:] if b':' in x)}
    value=json.loads(await reader.readexactly(int(fields[b'content-length'])));self.calls.append(value)
    data=json.dumps(self.result,ensure_ascii=False).encode();headers=b'';body=data
    if self.framing=='length':headers=f'Content-Length: {len(data)}\r\n'.encode()
    elif self.framing=='truncated':headers=f'Content-Length: {len(data)+10}\r\n'.encode()
    elif self.framing=='chunked':headers=b'Transfer-Encoding: chunked\r\n';body=f'{len(data):x}\r\n'.encode()+data+b'\r\n0\r\n\r\n'
    elif self.framing=='ambiguous':headers=b'Content-Length: 1\r\nTransfer-Encoding: chunked\r\n'
    writer.write(f'HTTP/1.1 {self.status} Test\r\nContent-Type: application/json\r\n'.encode()+headers+b'Connection: close\r\n\r\n'+body);await writer.drain()
   finally:writer.close();await writer.wait_closed()
  self.up=await asyncio.start_server(upstream,'127.0.0.1',0)
  self.cfg={'base_url':f'http://127.0.0.1:{self.up.sockets[0].getsockname()[1]}/v1','model':'current-model','name':'Current Model','api_key':'test','speech_backend_port':1}
  self.bridge=brain.Bridge(self.cfg,backend=1)
  self.bridge.model_list=AsyncMock(return_value={'result':{'content':[{'text':json.dumps({'models':[{'id':'v','kind':'video','state':'ready'}]})}]}})
  self.server=await asyncio.start_server(self.bridge.client,'127.0.0.1',0);self.port=self.server.sockets[0].getsockname()[1]
 async def asyncTearDown(self):
  self.server.close();self.up.close();await self.server.wait_closed();await self.up.wait_closed()
 async def send(self,args,path='/mcp'):
  value={'jsonrpc':'2.0','id':'my-id','method':'tools/call','params':{'name':'chat','arguments':args}} if path=='/mcp' else args
  r,w=await asyncio.open_connection('127.0.0.1',self.port);data=json.dumps(value).encode();w.write(f'POST {path} HTTP/1.1\r\nHost: test\r\nContent-Length: {len(data)}\r\n\r\n'.encode()+data);await w.drain();raw=await asyncio.wait_for(r.read(),3);w.close();await w.wait_closed();head,body=raw.split(b'\r\n\r\n',1);return int(head.split()[1]),json.loads(body)
 async def test_default_uses_current_gateway_clock_and_reasoning(self):
  code,value=await self.send({'prompt':'你好','reasoning':False})
  self.assertEqual(code,200);self.assertEqual(value['id'],'my-id');self.assertFalse(value['result']['isError']);self.assertEqual(value['result']['content'][0]['text'],'答复。')
  request=self.calls[0];self.assertEqual(request['model'],'current-model');self.assertFalse(request['stream']);self.assertEqual(request['reasoning_effort'],'none');self.assertIn('Asia/Shanghai',str(request['messages']))
 async def test_status_snapshot_same_as_http(self):
  await self.send({'system':'简洁','messages':[{'role':'user','content':'你好'}],'prompt':'视频模型，启动了吗？'})
  self.assertEqual(self.bridge.model_list.await_count,1);self.assertIn('实时查询快照',str(self.calls[0]['messages']))
 async def test_unmanaged_remote_bridge_also_routes_chat(self):
  self.bridge.config.pop('speech_backend_port');code,v=await self.send({'prompt':'hello'});self.assertFalse(v['result']['isError']);self.assertEqual(len(self.calls),1)
 async def test_supported_response_framing(self):
  for framing in ('length','chunked','eof'):
   self.framing=framing;code,v=await self.send({'prompt':'hi'});self.assertEqual(code,200);self.assertFalse(v['result']['isError'],framing)
 async def test_bad_response_framing_fails_cleanly(self):
  for framing in ('truncated','ambiguous'):
   self.framing=framing;code,v=await self.send({'prompt':'hi'});self.assertEqual(code,200);self.assertTrue(v['result']['isError'],framing)
 async def test_upstream_failure_returns_tool_error(self):
  for status in (401,429,503):
   self.status=status;code,v=await self.send({'prompt':'hi'});self.assertEqual(code,200);self.assertTrue(v['result']['isError']);self.assertEqual(v['id'],'my-id')
 async def test_invalid_arguments_and_unknown_model_never_reach_upstream(self):
  for args in (None,{}, {'messages':'wrong'}, {'prompt':{}},{'prompt':'hi','reasoning':'false'},{'prompt':'hi','model':'old-model'}):
   code,v=await self.send(args);self.assertEqual(code,200);self.assertTrue(v['result']['isError'])
  self.assertFalse(self.calls)
 async def test_tool_calls_preserved(self):
  calls=[{'id':'one','type':'function','function':{'name':'generate_image','arguments':'{"prompt":"cat"}'}}]
  self.result={'choices':[{'message':{'role':'assistant','content':None,'tool_calls':calls},'finish_reason':'tool_calls'}]}
  _,v=await self.send({'prompt':'画猫','tools':[]});self.assertEqual(json.loads(v['result']['content'][0]['text']),calls)
 async def test_empty_completion_is_error(self):
  self.result={'choices':[{'message':{'content':''},'finish_reason':'stop'}]};_,v=await self.send({'prompt':'hi'});self.assertTrue(v['result']['isError'])
 async def test_truncated_or_filtered_completion_is_not_success(self):
  for reason in ('length','content_filter'):
   self.result={'choices':[{'message':{'role':'assistant','content':'不完整答复'},'finish_reason':reason}]}
   code,value=await self.send({'prompt':'hi'})
   self.assertEqual(code,200);self.assertEqual(value['id'],'my-id');self.assertTrue(value['result']['isError'])
 async def test_voice_alias_obeys_output_policy(self):
  self.result={'choices':[{'message':{'content':'**Analysis:** We need to call generate_image.\n圖片已生成。','reasoning_content':'private'},'finish_reason':'stop'}]}
  _,v=await self.send({'prompt':'OK','model':'current-model--jarvis-none'});self.assertFalse(v['result']['isError']);self.assertEqual(v['result']['content'][0]['text'].strip(),'图片已生成。');self.assertNotIn('private',str(v))
 async def test_disconnect_while_status_waits_never_submits_chat(self):
  waiting=asyncio.Event();release=asyncio.Event()
  async def slow(*a):waiting.set();await release.wait();return {'result':{'content':[{'text':'{"models":[]}'}]}}
  self.bridge.model_list=slow
  r,w=await asyncio.open_connection('127.0.0.1',self.port);body=json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'chat','arguments':{'prompt':'视频模型启动了吗'}}}).encode();w.write(f'POST /mcp HTTP/1.1\r\nContent-Length: {len(body)}\r\n\r\n'.encode()+body);await w.drain();await waiting.wait();w.close();await w.wait_closed();await asyncio.sleep(.02);release.set();await asyncio.sleep(.03);self.assertFalse(self.calls)

class CachedHead(unittest.IsolatedAsyncioTestCase):
 async def test_head_matches_get_without_remote_and_without_body(self):
  with tempfile.TemporaryDirectory() as directory:
   root=Path(directory);job=root/'img_0123456789abcdef';job.mkdir();(job/'0.png').write_bytes(PNG)
   b=brain.Bridge({'base_url':'http://127.0.0.1:1/v1','model':'m','name':'m','artifact_root':directory,'image_worker_port':1,'image_worker_machine':'remote'},backend=1)
   server=await asyncio.start_server(b.client,'127.0.0.1',0)
   try:
    replies=[]
    for method in ('GET','HEAD'):
     r,w=await asyncio.open_connection('127.0.0.1',server.sockets[0].getsockname()[1]);w.write(f'{method} /v1/files/img_0123456789abcdef/0.png HTTP/1.1\r\nHost: test\r\n\r\n'.encode());await w.drain();replies.append((await r.read()).split(b'\r\n\r\n',1));w.close();await w.wait_closed()
    self.assertEqual(replies[0][0],replies[1][0]);self.assertIn(b'200 OK',replies[1][0]);self.assertEqual(replies[1][1],b'');self.assertEqual(replies[0][1],PNG)
   finally:server.close();await server.wait_closed()
if __name__=='__main__':unittest.main()
