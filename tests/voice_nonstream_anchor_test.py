import importlib.util,io,json,sys,tempfile,unittest,wave
from pathlib import Path
from unittest import mock
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'deploy/jarvis'))
spec=importlib.util.spec_from_file_location('proxy_worker_anchor_test',root/'deploy/jarvis/proxy_worker.py')
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)

class AnchorTest(unittest.TestCase):
 def run_speech(self,text,voice='Ezra',references=None):
  b=io.BytesIO()
  with wave.open(b,'wb') as w:w.setparams((1,2,24000,0,'NONE','not compressed'));w.writeframes(b'\1\0'*24000)
  response=mock.Mock(status=200,headers={'x-finish-reason':'stop'});response.body.return_value=b.getvalue()
  ref={'text':'该音色自己的中文参考','vq_codes':[[1]]*10}
  cfg={'id':'speech','options':{'upstream_port':1234,'default_voice':'Ezra','voice_lock_catalog':'mock-catalog'}}
  with tempfile.TemporaryDirectory() as tmp, mock.patch.object(p,'Http',return_value=response) as http, mock.patch.object(p,'voice_lock_catalog',return_value={'voices':{'Ezra':{'reference':ref}}}) as catalog:
   speech={'input':text,'stream':False,'voice':voice}
   if references is not None:
    Path(tmp,'refs.json').write_text(json.dumps(references));speech['references']='refs.json'
   result=p.run_job({'dir':tmp,'request':{'speech':speech}},cfg)
   return result,json.loads(http.call_args.args[3]),ref,catalog.call_count
 def test_chinese_nonstream_uses_same_voice_reference(self):
  result,body,ref,calls=self.run_speech('链接开头是字母H。')
  self.assertTrue(result['ok']);self.assertEqual(body['references'],[ref]);self.assertEqual(body['voice'],'Ezra');self.assertEqual(calls,1)
 def test_english_nonstream_does_not_add_reference(self):
  _,body,_,calls=self.run_speech('Hello world.')
  self.assertNotIn('references',body);self.assertEqual(calls,0)
 def test_existing_reference_is_preserved(self):
  refs=[{'text':'user reference','vq_codes':[[2]]*10}]
  _,body,_,calls=self.run_speech('你好',references=refs)
  self.assertEqual(body['references'],refs);self.assertEqual(calls,0)
 def test_unknown_voice_is_rejected_before_upstream(self):
  with self.assertRaisesRegex(ValueError,'no validated identity profile'):self.run_speech('你好',voice='unknown')
if __name__=='__main__':unittest.main()
