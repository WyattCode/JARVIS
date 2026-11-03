import asyncio,copy,json,unittest
from unittest.mock import AsyncMock
from model_status_test import brain,CFG,RPC,envelope,Status

class ReviewFix(unittest.TestCase):
 def test_coordinator_memory_and_pause_are_from_the_same_scheduler(self):
  b,_=Status().make()
  async def rpc(port,value,timeout=15):
   if port==8190:
    x=envelope([{'kind':'chat','id':'old'},{'kind':'transcription','id':'whisper'}]);v=json.loads(x['result']['content'][0]['text']);v['memory']={'reserve_bytes':3*2**30,'voice_paused':False};x['result']['content'][0]['text']=json.dumps(v);return x
   if port==8194:
    x=envelope([]);v=json.loads(x['result']['content'][0]['text']);v['memory']={'reserve_bytes':2**30,'voice_paused':True};x['result']['content'][0]['text']=json.dumps(v);return x
   return envelope([{'id':'im','kind':'image','state':'ready'},{'id':'vid','kind':'video','state':'unloaded'}])
  b.local_rpc=rpc;s=json.loads(asyncio.run(b.model_list(copy.deepcopy(RPC)))['result']['content'][0]['text'])
  self.assertEqual(s['memory']['reserve_bytes'],3*2**30)
  fact=brain.chinese_status_facts(s)['语音主机状态'];self.assertEqual(fact['预留字节'],2**30);self.assertEqual(fact['预留约合吉字节'],1);self.assertEqual(fact['语音暂停'],'是')
 def test_zero_budget_is_unset_and_not_zero_capacity(self):
  value=brain.chinese_status_facts({'models':[],'voice_coordinator_memory':{'budget_bytes':0,'reserve_bytes':2**30}})['语音主机状态']
  self.assertEqual(value['预算说明'],'未设置固定预算');self.assertNotIn('预算字节',value)
 def test_unknown_voice_memory_does_not_reuse_head_reserve(self):
  b,_=Status().make('voice_status');s=json.loads(asyncio.run(b.model_list(copy.deepcopy(RPC)))['result']['content'][0]['text'])
  self.assertIsNone(s['voice_coordinator_memory']);self.assertEqual(brain.chinese_status_facts(s)['语音主机状态'],{'语音暂停':'未知'})
 def test_status_requests_cover_natural_generation_questions(self):
  for q in ['现在能生成图片吗？','还能做视频吗？','能生图吗？','我可以生成图片吗？','语音主机的预留内存是多少？','图片模型占用多少显存？']:
   self.assertTrue(brain.model_status_requested({'messages':[{'role':'user','content':q}]}),q)
  for q in ['给我生成一张猫的图片','生成一个视频','视频里面有什么动物？','图片里面有多少棵树？']:
   self.assertFalse(brain.model_status_requested({'messages':[{'role':'user','content':q}]}),q)
 def test_timeout_or_invalid_media_state_is_unknown(self):
  b,_=Status().make('worker');s=json.loads(asyncio.run(b.model_list(copy.deepcopy(RPC)))['result']['content'][0]['text'])
  for m in s['models']:
   if m['kind'] in ('image','video'):
    self.assertEqual(m['state'],'unknown');self.assertIsNone(m['running']);self.assertIsNone(m['resident_bytes']);self.assertIn('暂不可查询',m['last_error']);self.assertNotIn('未连接',m['last_error'])
 def test_separate_services_refuse_control_without_routing(self):
  b,_=Status().make()
  for model in ['qwen3-asr-1.7b','transcription','fishaudio/drama-3','speech','actual-brain','chat','qwen-asr','drama']:
   for op in ['load_model','unload_model','reserve_for']:
    reason=asyncio.run(b.model_control_refusal({'name':op,'arguments':{'model':model}}))
    self.assertIn('独立',reason,model)
  for model in ['image','qwen-image-2.1-turbo','video','minimax-h3']:
   self.assertIsNone(asyncio.run(b.model_control_refusal({'name':'load_model','arguments':{'model':model}})))
 def test_service_query_failure_does_not_guess_model_ownership(self):
  b,_=Status().make('transcription')
  reason=asyncio.run(b.model_control_refusal({'name':'load_model','arguments':{'model':'future-model-id'}}))
  self.assertIn('无法确认模型归属',reason)
 def test_single_head_control_stays_compatible(self):
  b=brain.Bridge({k:v for k,v in CFG.items() if k not in ('speech_backend_port','transcription_backend_port')})
  self.assertIsNone(asyncio.run(b.model_control_refusal({'name':'load_model','arguments':{'model':'legacy-speech'}})))
if __name__=='__main__':unittest.main()
