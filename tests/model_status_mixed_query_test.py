import asyncio,copy,json,unittest
from model_status_test import brain,Status,RPC,envelope

class MixedQueries(unittest.TestCase):
 def query(self,s):return brain.model_status_requested({'messages':[{'role':'user','content':s}]})
 def test_mixed_requests_retain_live_status(self):
  for s in ['生成一段视频，顺便查一下图片现在能不能用','生成一段视频，同时检查视频能不能用','生成一张图片，顺便看看视频模型是否正常','制作一个视频，看看图片服务器是不是在线','生成一段视频并检查视频能不能用','画一张图，然后确认视频模型有没有加载','制作一个视频，查一下能不能用']:
   self.assertTrue(self.query(s),s)
 def test_ordinary_creative_requests_do_not_trigger(self):
  for s in ['生成一段人物正常走路的视频','制作一段汽车正在运行的视频','能不能生成一张猫的图片？','帮我看看这张图片','生成一张图片，人物色彩正常','生成一张图片，背景是一台模型正在运行','生成一段含语音暂停的喜剧视频']:
   self.assertFalse(self.query(s),s)
 def test_unknown_services_are_not_reported_as_stopped(self):
  for broken,kind in [('brain','chat'),('transcription','transcription')]:
   b,_=Status().make(broken);snapshot=json.loads(asyncio.run(b.model_list(copy.deepcopy(RPC)))['result']['content'][0]['text'])
   model=next(m for m in snapshot['models'] if m['kind']==kind)
   self.assertEqual(model['state'],'unavailable');self.assertIsNone(model['running']);self.assertIn('无法查询',model['last_error'])
 def test_malformed_service_model_id_is_unknown(self):
  b,_=Status().make();original=b.fetch_json
  async def bad(remote,path,port=None,**kwargs):
   if port==18795:return {'data':[{'id':None,'kind':'transcription','state':'ready'}]}
   return await original(remote,path,port,**kwargs)
  b.fetch_json=bad;snapshot=json.loads(asyncio.run(b.model_list(copy.deepcopy(RPC)))['result']['content'][0]['text']);m=next(m for m in snapshot['models'] if m['kind']=='transcription')
  self.assertEqual(m['state'],'unavailable');self.assertIsNone(m['running'])
 def test_malformed_voice_memory_is_unknown_not_exception(self):
  b,_=Status().make();original=b.local_rpc
  async def bad(port,value,timeout=15):
   if port==8194:return {'result':{'content':[{'text':'[]'}]}}
   return await original(port,value,timeout=timeout)
  b.local_rpc=bad;snapshot=json.loads(asyncio.run(b.model_list(copy.deepcopy(RPC)))['result']['content'][0]['text'])
  self.assertIsNone(snapshot['voice_coordinator_memory']);self.assertIsNone(snapshot['memory']['voice_paused'])
if __name__=='__main__':unittest.main()
