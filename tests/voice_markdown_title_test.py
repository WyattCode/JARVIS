import asyncio,json,sys,time,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'deploy/jarvis'))
from voice_output_policy import SpokenText,VoiceStream,speech_input
from chat_stream_guard import guarded_stream,speakable

class MarkdownTitles(unittest.TestCase):
 def all_splits(self,user,text):
  for cut in range(len(text)+1):
   f=SpokenText(user);yield f.feed(text[:cut])+f.feed(text[cut:])+f.feed(last=True)
  f=SpokenText(user);yield ''.join(f.feed(c) for c in text)+f.feed(last=True)
 def test_hidden_title_with_spacing(self):
  for title in ['"秘密标记"',"'秘密标记'",'(秘密标记)','"秘密)标记"','"秘密\\"标记"']:
   text='完成：[查看]( https://example.com/a.png '+title+' )。继续正常说明。'
   for out in self.all_splits('生成图片',text):
    self.assertIn('查看',out);self.assertIn('继续正常说明',out)
    for bad in ['https','秘密','[','](',')']:self.assertNotIn(bad,out)
    self.assertNotIn('秘密',speech_input(speakable(out)))
 def test_authorized_link_with_spacing_and_title(self):
  url='https://example.com/a';text='链接是 [查看]( '+url+' "秘密标题" )。继续说明。'
  for out in self.all_splits('请朗读这个链接：'+url,text):
   self.assertIn(url,out);self.assertIn('继续说明',out)
   for bad in ['秘密标题','[','](',')']:self.assertNotIn(bad,out)
 def test_no_title_followed_by_spaced_prose_is_preserved(self):
  url='https://example.com/a';text='[查看]('+url+') 后面是正常说明。'
  for user in ['生成图片','请朗读这个链接：'+url]:
   for out in self.all_splits(user,text):
    self.assertIn('后面是正常说明',out);self.assertNotIn('](',out)
 def test_parentheses_in_url_do_not_end_link_title_early(self):
  url='https://example.com/a(b)';text='[查看]('+url+' "秘密标题" )。继续说明。'
  for user in ['生成图片','请朗读这个链接：'+url]:
   for out in self.all_splits(user,text):
    self.assertNotIn('秘密标题',out);self.assertIn('继续说明',out)
 def test_user_supplies_markdown_with_spacing(self):
  url='https://example.com/a'
  for user in ['请朗读这个链接：[查看]( '+url+' )','请朗读这个链接：[查看]('+url+' "标题")']:
   for out in self.all_splits(user,'[查看]( '+url+' )。'):
    self.assertIn(url,out);self.assertNotIn('[',out)
 def test_unclosed_or_excessively_long_title_never_leaks(self):
  for suffix in [' "秘密标记', ' "'+('a'*9000)+'秘密标记']:
   f=SpokenText('生成图片');text='[查看](https://example.com/a'+suffix
   out=''.join(f.feed(c) for c in text)+f.feed(last=True)
   self.assertNotIn('秘密标记',out);self.assertNotIn('https',out)
   self.assertLessEqual(len(f.lex),32)
 def test_title_text_is_not_published_in_sse(self):
  async def run():
   text='完成：[查看]( https://example.com/a "秘密标题" )。已完成。'
   reader=asyncio.StreamReader()
   for c in text:reader.feed_data(('data: '+json.dumps({'choices':[{'index':0,'delta':{'content':c},'finish_reason':None}]},ensure_ascii=False)+'\n\n').encode())
   reader.feed_data(b'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');reader.feed_eof();out=[]
   async def publish(x):out.append(x)
   self.assertTrue(await guarded_stream(reader,{},publish,{'_started':time.monotonic()},VoiceStream({'messages':[{'role':'user','content':'生成图片'}]})))
   v=''.join(c.get('delta',{}).get('content','') for line in b''.join(out).splitlines() if line.startswith(b'data:') and line[5:].strip()!=b'[DONE]' for c in json.loads(line[5:]).get('choices',[]))
   self.assertIn('已完成',v);self.assertNotIn('秘密',v);self.assertNotIn('https',v);self.assertNotIn(']',v)
  asyncio.run(run())
if __name__=='__main__':unittest.main()
