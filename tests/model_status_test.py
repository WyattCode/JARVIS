import asyncio,copy,importlib.util,json,sys,unittest
from pathlib import Path
from unittest.mock import AsyncMock
root=Path(__file__).resolve().parents[1];sys.path.insert(0,str(root/'deploy/jarvis'))
spec=importlib.util.spec_from_file_location('status_brain',root/'deploy/jarvis/remote_brain.py');brain=importlib.util.module_from_spec(spec);spec.loader.exec_module(brain)
CFG={'model':'actual-brain','name':'Actual Brain','base_url':'http://127.0.0.1:9000/v1','speech_backend_port':8194,'transcription_backend_port':18795,'image_worker_port':8196,'video_worker_port':8196,'image_worker_machine':'remote','video_worker_machine':'remote'}
RPC={'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'list_models','arguments':{}}}
def envelope(models):return {'jsonrpc':'2.0','id':1,'result':{'content':[{'type':'text','text':json.dumps({'models':models,'memory':{'budget_bytes':72}})}]}}
class Status(unittest.TestCase):
 def make(self,broken=None):
  b=brain.Bridge(CFG);calls=[]
  async def rpc(port,value,timeout=15):
   calls.append(port)
   if port==8190:return envelope([{'id':'old-chat','kind':'chat'},{'id':'whisper','kind':'transcription'},{'id':'old-speech','kind':'speech'},{'id':'old-image','kind':'image'},{'id':'old-video','kind':'video'}])
   if port==8194:
    if broken=='voice_status':raise OSError('voice status offline')
    v=envelope([]);state=json.loads(v['result']['content'][0]['text']);state['memory']['voice_paused']=True;v['result']['content'][0]['text']=json.dumps(state);return v
   if broken=='worker':raise OSError('worker offline')
   return envelope([{'id':'im','kind':'image','state':'ready','running':True,'keep_loaded':False},{'id':'vid','kind':'video','state':'unloaded','running':False,'keep_loaded':False}])
  async def fetch(remote,path,port=None,timeout=8):
   if remote:
    if broken=='brain':raise OSError('brain offline')
    return {'data':[{'id':'actual-brain','status':{'value':'loaded'}}]}
   if port==18795:
    if broken=='transcription':raise OSError('asr offline')
    return {'data':[{'id':'qwen-asr','kind':'transcription','state':'ready','keep_loaded':True}]}
   if port==8194:return {'data':[{'id':'drama','kind':'speech','state':'ready','keep_loaded':True}]}
   raise AssertionError(port)
  b.local_rpc=rpc;b.fetch_json=fetch;return b,calls
 def test_actual_roles_and_one_atomic_worker_snapshot(self):
  b,calls=self.make();o=asyncio.run(b.model_list(copy.deepcopy(RPC)));s=json.loads(o['result']['content'][0]['text']);models={x['kind']:x for x in s['models']}
  self.assertEqual({k:v['id'] for k,v in models.items()},{'chat':'actual-brain','speech':'drama','transcription':'qwen-asr','image':'im','video':'vid'})
  self.assertEqual(models['image']['machine'],'remote');self.assertEqual(models['image']['state'],'ready');self.assertFalse(models['video']['running'])
  self.assertEqual(calls.count(8196),1);self.assertEqual(s['image_worker_memory'],s['video_worker_memory'])
  self.assertTrue(s['memory']['voice_paused'])
 def test_unavailable_services_never_fall_back_to_wrong_model(self):
  for broken,kind in [('brain','chat'),('transcription','transcription'),('worker','image')]:
   b,_=self.make(broken);s=json.loads(asyncio.run(b.model_list(copy.deepcopy(RPC)))['result']['content'][0]['text']);m=next(x for x in s['models'] if x['kind']==kind)
   self.assertFalse(m['running']);self.assertIn('无法查询' if broken!='worker' else '暂不可查询',m['last_error']);self.assertNotEqual(m['id'],'whisper')
 def test_status_detection_and_ordinary_requests(self):
  for q in ['检查一下模型状态','视频模型常驻吗？','现在有哪些模型？','语音识别用的哪个模型？','查下贾维斯模型现在']:
   self.assertTrue(brain.model_status_requested({'messages':[{'role':'user','content':q}]}),q)
  for q in ['生成一张蓝天图片','给我讲一个故事']:
   self.assertFalse(brain.model_status_requested({'messages':[{'role':'user','content':q}]}),q)
 def test_unknown_voice_pause_is_not_reported_as_false(self):
  b,_=self.make('voice_status');s=json.loads(asyncio.run(b.model_list(copy.deepcopy(RPC)))['result']['content'][0]['text']);self.assertIsNone(s['memory']['voice_paused'])
 def test_guidance_does_not_claim_unconditional_restore(self):
  out=brain.chat_body({'messages':[{'role':'user','content':'模型状态'}]},CFG)
  self.assertIn('不保证立即自动恢复',out['messages'][0]['content'])
if __name__=='__main__':unittest.main()

class ChineseFacts(unittest.TestCase):
 def test_status_is_chinese_and_unavailable_is_not_called_unloaded(self):
  s={'models':[{'id':'qwen','kind':'transcription','state':'ready','machine':'head','running':True},{'id':'im','kind':'image','state':'unloaded','machine':'remote','resident_bytes':0},{'id':'video-unavailable','kind':'video','state':'unavailable','running':False}], 'memory':{'voice_paused':None},'image_worker_memory':{'budget_bytes':100}}
  out=brain.chinese_status_facts(s);text=json.dumps(out,ensure_ascii=False)
  self.assertNotIn('ready',text);self.assertNotIn('unloaded',text);self.assertIn('已加载且可用',text);self.assertIn('未加载',text);self.assertIn('无法查询',text)
  self.assertEqual(out['语音主机状态']['语音暂停'],'未知');self.assertEqual(out['图片服务器内存']['预算字节'],100)

class IntentCoverage(unittest.TestCase):
 def test_short_status_requests(self):
  for q in ['语音有没有暂停？','现在视频能用吗？','图片还在加载吗？','语音服务正常吗？','什么模型在听写？']:
   self.assertTrue(brain.model_status_requested({'messages':[{'role':'user','content':q}]}),q)
 def test_content_questions_do_not_trigger_status_lookup(self):
  for q in ['视频里面有什么动物？','生成一张蓝天图片','做一个视频，风吹过树林']:
   self.assertFalse(brain.model_status_requested({'messages':[{'role':'user','content':q}]}),q)

class VoiceMemoryTests(unittest.TestCase):
 def test_only_voice_host_reports_pause_and_booleans_are_chinese(self):
  for paused,expected in [(True,'是'),(False,'否'),(None,'未知')]:
   data={'models':[], 'memory':{'voice_paused':paused},'image_worker_memory':{'voice_paused':True},'video_worker_memory':{'voice_paused':False}}
   out=brain.chinese_status_facts(data);self.assertEqual(out['语音主机状态']['语音暂停'],expected)
   self.assertNotIn('语音暂停',out['图片服务器内存']);self.assertNotIn('语音暂停',out['视频服务器内存'])
