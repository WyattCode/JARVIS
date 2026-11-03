import sys, unittest
from pathlib import Path
from urllib.parse import unquote
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'deploy/jarvis'))
from voice_output_policy import SpokenText,speech_input

class LinkGuard(unittest.TestCase):
 def filtered(self,user,text,split):
  p=SpokenText(user); return p.feed(text[:split])+p.feed(text[split:])+p.feed(last=True)
 def test_negative_instruction_does_not_grant_reading(self):
  text='图片好了：https://example.com/v1/files/img_x/0.png。'
  for user in ['不要朗读链接','请别读出这个网址','不要再念出链接']:
   for i in range(len(text)+1):
    out=self.filtered(user,text,i)
    self.assertNotIn('https',out);self.assertNotIn('img_x',out)
 def test_unescaped_chinese_path_and_secret_remain_hidden(self):
  for text in ['图片：https://example.com/私密文件?token=SECRET123。','图片：https://例子.测试/照片.png。','图片：https://example.com/abc.png?token=秘密123。']:
   for i in range(len(text)+1):
    out=self.filtered('生成图片',text,i)
    for forbidden in ['私密','SECRET','例子','照片','秘密','token']:self.assertNotIn(forbidden,out)
 def test_adjacent_common_hint_survives(self):
  text='图片地址https://example.com/a.png请点击查看。'
  for i in range(len(text)+1):self.assertIn('请点击查看',self.filtered('你好',text,i))
 def test_explicit_traditional_path_keeps_exact_characters(self):
  url='https://example.com/v1/files/圖片.png'
  for i in range(len(url)+1):
   out=self.filtered('请朗读这个链接：'+url,url,i)
   spoken=speech_input(out)
   self.assertIn('圖片.png',unquote(spoken));self.assertNotIn('图片.png',unquote(spoken))
 def test_hidden_url_remains_bounded(self):
  p=SpokenText('生成图片');p.feed('https://example.com/')
  for i in range(100):
   p.feed('秘密TOKEN'*1000);self.assertLessEqual(len(p.url_tail),32)
  self.assertEqual(p.feed('。',last=True),'')
if __name__=='__main__':unittest.main()

class IntentRegression(unittest.TestCase):
 def test_natural_word_order_and_negation(self):
  url='https://example.com/test'
  for user in ['请把链接读出来：'+url,'请把网址念出来：'+url]:
   f=SpokenText(user);self.assertTrue(f.read_url);self.assertIn('https',f.feed(url,last=True))
  for user in ['不要把网址读出来','别把这个链接念出来','不用把链接读出来']:
   f=SpokenText(user);self.assertFalse(f.read_url);self.assertNotIn('https',f.feed(url,last=True))
