import sys,unittest,asyncio,json,time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'deploy/jarvis'))
from voice_output_policy import SpokenText,VoiceStream,speech_input,voice_messages
from chat_stream_guard import guarded_stream,speakable

class MarkdownGuard(unittest.TestCase):
 def filtered(self,user,text,cut):
  f=SpokenText(user);return f.feed(text[:cut])+f.feed(text[cut:])+f.feed(last=True)
 def test_unicode_punctuation_inside_hidden_url_never_leaks(self):
  for char in '，。：！？；、）】':
   text='图片 https://example.com/照片'+char+'私密?token=SECRET123。'
   for i in range(len(text)+1):
    out=self.filtered('生成图片',text,i)
    self.assertNotIn('私密',out);self.assertNotIn('SECRET123',out)
 def test_hidden_markdown_link_leaves_clean_label(self):
  text='图片已完成，[点击查看](https://example.com/image.png)。'
  for i in range(len(text)+1):
   out=self.filtered('生成图片',text,i)
   self.assertIn('点击查看',out);self.assertNotIn('https',out);self.assertNotIn('[',out);self.assertNotIn('](',out)
   self.assertNotIn('[',speech_input(speakable(out)))
 def test_markdown_label_survives_character_fragmentation_and_boundary(self):
  for text in ['说明：['+'a'*145+'。查看](https://example.com/a)。','甲'*159+'[点击。查看](https://example.com/a)。']:
   f=SpokenText('生成图片');out=''.join(f.feed(c) for c in text)+f.feed(last=True)
   self.assertIn('查看',out);self.assertNotIn('[',out);self.assertNotIn('](',out);self.assertNotIn('https',out)
 def test_authorized_markdown_link_is_readable(self):
  url='https://example.com/a'; text='[链接]('+url+')。'
  for i in range(len(text)+1):
   out=self.filtered('请朗读这个链接：'+url,text,i)
   self.assertIn(url,out);self.assertNotIn('[',out);self.assertNotIn('](',out);self.assertNotIn(url+')',out)
 def test_other_link_after_authorized_link_is_hidden(self):
  a='https://a.example/test';b='https://b.example/secret?token=SECRET123';text=a+'，'+b+'。'
  for i in range(len(text)+1):
   out=self.filtered('请朗读这个链接：'+a,text,i)
   self.assertIn(a,out);self.assertNotIn('SECRET123',out)
 def test_two_user_urls_without_spaces_do_not_grant_both(self):
  a='https://www.example.com/a';b='https://second.example/b'
  f=SpokenText('请朗读这个链接：'+a+'，'+b)
  self.assertEqual(f.allowed_urls,set());self.assertNotIn(b,f.feed(b,last=True))
  self.assertEqual(SpokenText('请朗读这个链接：'+a).allowed_urls,{a})
 def test_user_provided_url_can_include_chinese_punctuation(self):
  from urllib.parse import unquote
  url='https://example.com/圖片，私密.png';text='[链接]('+url+')。'
  for i in range(len(text)+1):
   out=self.filtered('请朗读这个链接：'+url,text,i)
   self.assertIn(url,unquote(out));self.assertNotIn('](',out)
 def test_media_completion_fallback_is_truthful(self):
  async def run():
   msgs=voice_messages([{'role':'user','content':'生成图片'},{'role':'assistant','tool_calls':[{'id':'x','function':{'name':'generate_image'}}]},{'role':'tool','tool_call_id':'x','content':'{"status":"completed","urls":["https://example.com/a.png"]}'}])
   reader=asyncio.StreamReader();text='https://example.com/a.png。图片已生成。'
   for c in text:reader.feed_data(('data: '+json.dumps({'choices':[{'index':0,'delta':{'content':c},'finish_reason':None}]},ensure_ascii=False)+'\n\n').encode())
   reader.feed_data(b'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');reader.feed_eof();out=[]
   async def publish(b):out.append(b)
   ok=await guarded_stream(reader,{},publish,{'_started':time.monotonic()},VoiceStream({'messages':msgs}))
   body=b''.join(out).decode();self.assertTrue(ok);self.assertIn('图片已生成，请在界面查看',body);self.assertNotIn('https://example.com/a.png',body)
  asyncio.run(run())
if __name__=='__main__':unittest.main()
