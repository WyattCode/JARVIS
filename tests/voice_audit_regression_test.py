import sys, unittest, asyncio, json, time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'deploy/jarvis'))
from voice_output_policy import SpokenText, speech_input, VoiceStream
from chat_stream_guard import guarded_stream

class Regression(unittest.TestCase):
    def filter(self, user, text, split):
        f=SpokenText(user)
        return ''.join(f.feed(part) for part in (text[:split],text[split:]))+f.feed(last=True)
    def test_translation_to_chinese_blocks_internal_english(self):
        text='We need to use generate_image. 图片已做好。'
        for cut in range(len(text)+1):
            out=self.filter('请把这句话翻译成中文',text,cut)
            self.assertNotIn('We need',out);self.assertIn('图片已做好',out)
    def test_chinese_text_adjacent_to_url_is_preserved(self):
        text='图片地址https://example.com/a.png请点击查看。'
        for cut in range(len(text)+1):
            out=self.filter('你好',text,cut)
            self.assertNotIn('https',out);self.assertIn('请点击查看',out)
    def test_requested_artifact_url_reaches_tts(self):
        url='https://jarvis.odn.cc/v1/files/img_x/0.png'
        text='链接是'+url+'。'
        for cut in range(len(text)+1):
            out=self.filter('请朗读这个链接：'+url,text,cut)
            spoken=speech_input(out)
            self.assertIn('img_x',spoken);self.assertIn('v1斜杠files',spoken)
    def test_requested_url_char_by_char(self):
        url='https://jarvis.odn.cc/v1/files/img_x/0.png'
        f=SpokenText('请朗读这个链接：'+url)
        result=''.join(f.feed(c) for c in url)+f.feed(last=True)
        self.assertIn('img_x',speech_input(result))
    def test_ordinary_generated_artifact_still_removed(self):
        out=self.filter('图片生成好了没','好了 https://jarvis.odn.cc/v1/files/img_x/0.png。',10)
        self.assertNotIn('img_x',out)
    def test_explicit_english_translation_still_allowed(self):
        out=self.filter('请翻译成英文','The image is ready to view.',5)
        self.assertIn('image is ready',out)
    def test_fragmented_chat_stream_through_speech_filter(self):
        async def run():
            url='https://jarvis.odn.cc/v1/files/img_x/0.png'
            reader=asyncio.StreamReader()
            for char in '链接是'+url+'。':
                reader.feed_data(('data: '+json.dumps({'choices':[{'index':0,'delta':{'content':char},'finish_reason':None}]},ensure_ascii=False)+'\n\n').encode())
            reader.feed_data(b'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');reader.feed_eof()
            published=[]
            async def publish(data):published.append(data)
            ok=await guarded_stream(reader,{},publish,{'_started':time.monotonic()},VoiceStream({'messages':[{'role':'user','content':'请朗读这个链接：'+url}]}))
            values=[json.loads(line[5:]) for line in b''.join(published).splitlines() if line.startswith(b'data:') and line[5:].strip()!=b'[DONE]']
            visible=''.join(c.get('delta',{}).get('content','') for v in values for c in v.get('choices',[]))
            self.assertTrue(ok);self.assertIn('img_x',speech_input(visible))
        asyncio.run(run())
if __name__=='__main__': unittest.main()
