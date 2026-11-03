import asyncio,json,sys,time,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'deploy/jarvis'))
from voice_output_policy import SpokenText,VoiceStream,speech_input
from chat_stream_guard import guarded_stream, SpeechChunks, speakable

class Review(unittest.TestCase):
 def run_filter(self,user,text,cut):
  p=SpokenText(user);return p.feed(text[:cut])+p.feed(text[cut:])+p.feed(last=True)
 def test_negative_form_never_allows_link(self):
  url='https://example.com/v1/files/img_a.png'
  for user in ['我不想听你朗读链接','我不希望你朗读链接','我不愿意让你朗读链接',"I don't want you to read the link aloud"]:
   for i in range(len(url)+1):self.assertNotIn('img_a',self.run_filter(user,url,i))
 def test_single_quote_and_brackets_in_url_are_hidden(self):
  for url in ["https://example.com/a'b?token=SECRET123",'https://example.com/a)b?token=SECRET123','https://example.com/a]b?token=SECRET123']:
   for i in range(len(url)+1):
    out=self.run_filter('生成图片','完成 '+url+'。',i)
    self.assertNotIn('SECRET123',out);self.assertNotIn('token',out)
    self.assertNotIn('SECRET123',speech_input('图片 '+url+' /v1/files/xyz'))
 def test_only_the_user_supplied_link_is_allowed(self):
  a='https://a.example/test';b='https://b.example/v1/files/private?token=SECRET123'
  text=a+'，'+b+'。'
  for i in range(len(text)+1):
   out=self.run_filter('请朗读这个链接：'+a,text,i)
   self.assertIn(a,out);self.assertNotIn('SECRET123',out);self.assertNotIn('private',out)
 def test_long_url_not_silently_truncated(self):
  url='https://example.com/'+('alpha-bravo-charlie-delta-echo-'*12)+'finalpart'
  for i in range(len(url)+1):self.assertEqual(self.run_filter('请朗读这个网址：'+url,url,i),url)
 def test_last_user_link_supported_in_voice_stream(self):
  async def run():
   url='https://example.com/'+('alpha-bravo-charlie-delta-echo-'*12)+'finalpart'
   messages=[{'role':'user','content':url},{'role':'assistant','content':'好的'},{'role':'user','content':'请朗读这个链接'}]
   reader=asyncio.StreamReader()
   for c in url:
    reader.feed_data(('data: '+json.dumps({'choices':[{'index':0,'delta':{'content':c},'finish_reason':None}]})+'\n\n').encode())
   reader.feed_data(b'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');reader.feed_eof();out=[]
   async def publish(data):out.append(data)
   ok=await guarded_stream(reader,{},publish,{'_started':time.monotonic()},VoiceStream({'messages':messages}))
   values=[json.loads(x[5:]) for x in b''.join(out).splitlines() if x.startswith(b'data:') and x[5:].strip()!=b'[DONE]']
   actual=''.join(c.get('delta',{}).get('content','') for v in values for c in v.get('choices',[]))
   self.assertTrue(ok);self.assertEqual(actual,url);self.assertEqual(speech_input(actual),url)
   chunks=SpeechChunks().feed(actual,last=True)
   self.assertEqual(''.join(speech_input(speakable(part)) for part in chunks),url)
  asyncio.run(run())
 def test_no_user_url_does_not_authorize_generated_url(self):
  self.assertEqual(self.run_filter('请朗读这个网址','https://example.com/private',5),'')
 def test_multiple_user_urls_do_not_authorize_all_of_them(self):
  a='https://example.com/a';b='https://example.com/b'
  f=SpokenText('请朗读这个链接 '+a+'，另一个是 '+b)
  self.assertEqual(f.allowed_urls,set());self.assertNotIn(b,f.feed(b,last=True))
 def test_artifact_url_does_not_count_as_two_nested_urls(self):
  url='https://example.com/v1/files/abc.png'
  f=SpokenText('请朗读这个链接 '+url)
  self.assertEqual(f.allowed_urls,{url});self.assertIn('abc.png',f.feed(url,last=True))
if __name__=='__main__':unittest.main()
