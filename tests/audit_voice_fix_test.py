import asyncio
import json
from pathlib import Path
import sys
import time
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'deploy/jarvis'))
from voice_output_policy import SpokenText, VoiceStream, supplied_urls
from chat_stream_guard import guarded_stream


class VoiceAuditFixTests(unittest.TestCase):
    def splits(self,user,text):
        for cut in range(len(text)+1):
            f=SpokenText(user)
            yield f.feed(text[:cut])+f.feed(text[cut:])+f.feed(last=True)
        f=SpokenText(user)
        yield ''.join(f.feed(c) for c in text)+f.feed(last=True)

    def test_hidden_link_preserves_failure_notice_at_every_split(self):
        for url in ['https://example.com/a.png','https://example.com/a(b(c)d)e.png',r'https://example.com/a\)b.png']:
            text='[查看图片]('+url+')，但视频生成失败，请重新提交。'
            for out in self.splits('请生成图片和视频',text):
                self.assertEqual(out,'查看图片，但视频生成失败，请重新提交。')

    def test_explicit_read_preserves_following_prose(self):
        for url in ['https://example.com/a.png','https://example.com/a(b(c)d)e.png']:
            text='[查看]('+url+')，但视频生成失败，请重新提交。'
            for out in self.splits('请朗读这个链接：'+url,text):
                self.assertEqual(out,'查看：'+url+'，但视频生成失败，请重新提交。')

    def test_titles_remain_hidden_with_nested_and_escaped_targets(self):
        for url in ['https://example.com/a(b)c',r'https://example.com/a\)b']:
            text='[查看]('+url+' "内部秘密)标题" )，任务失败。'
            for out in self.splits('生成图片',text):
                self.assertEqual(out,'查看，任务失败。')

    def test_authorized_escaped_markdown_target_and_title(self):
        url='https://example.com/a)b'
        target=r'https://example.com/a\)b'
        for user in ['请朗读这个链接：'+url,'请朗读这个链接：[查看]('+target+')']:
            for title in ['', ' "内部秘密)标题" ']:
                for out in self.splits(user,'[查看]('+target+title+')，任务失败。'):
                    self.assertEqual(out,'查看：'+url+'，任务失败。')

    def test_user_markdown_nested_target_with_title(self):
        url='https://example.com/a(b)'
        user='请朗读这个链接：[查看]('+url+' "标题")'
        for out in self.splits(user,'[查看]('+url+' "内部标题")，任务失败。'):
            self.assertEqual(out,'查看：'+url+'，任务失败。')

    def test_unrequested_internal_english_hidden_in_english_conversation(self):
        for user in ['OK','Okay.','Please generate an image']:
            for out in self.splits(user,'We need to call generate_image. 图片已经生成。'):
                self.assertNotIn('generate_image',out)
                self.assertIn('图片已经生成。',out)

    def test_legitimate_english_quote_and_translation_remain(self):
        text='We need to call generate_image.'
        for user in ['请朗读这句话：'+text,'请翻译成英文：我们需要调用生成图片工具。','Translate into English: 我们需要调用生成图片工具。']:
            for out in self.splits(user,text):
                self.assertEqual(out,text)
        for out in self.splits('Please answer in English','The image is ready for you to view.'):
            self.assertEqual(out,'The image is ready for you to view.')

    def test_natural_english_suggestion_is_preserved(self):
        text='We need to back up the database before deploying.'
        for out in self.splits('What should our team do before deploying?',text):
            self.assertEqual(out,text)

    def test_translation_is_not_blanket_internal_permission(self):
        for user in ['Translate this to Chinese: hello','请解释 translate 的含义','Translate into English','Translate into English: 你好','请翻译成英文：你好','不要翻译成英文：我们需要调用生成图片工具。']:
            for out in self.splits(user,'We need to call generate_image. Analysis: plan。你好。'):
                self.assertNotIn('generate_image',out)
                self.assertNotIn('Analysis',out)
                self.assertIn('你好。',out)

    def test_translated_label_requires_matching_source_label(self):
        for out in self.splits('请翻译成英文：分析：计划。','Analysis: plan.'):
            self.assertEqual(out,'Analysis: plan.')

    def test_adjacent_user_markdown_links_are_both_counted(self):
        a='https://a.test/1';b='https://b.test/2'
        user='请朗读这个链接：[甲]('+a+')[乙]('+b+')'
        self.assertEqual(supplied_urls(user),[a,b])
        self.assertEqual(SpokenText(user).allowed_urls,set())
        for out in self.splits(user,'[甲]('+a+')[乙]('+b+')，请指定一个。'):
            self.assertNotIn('https',out)
            self.assertIn('请指定一个',out)

    def test_ok_inherits_language_without_inheriting_url_permission(self):
        for history,english in [(['请用中文回答','OK'],False),(['Please answer in English','OK'],True),(['请用中文回答','okay','OK'],False)]:
            p=VoiceStream({'messages':[{'role':'user','content':s} for s in history]})
            p.feed(0,'完成。',last=True)
            self.assertEqual(p.filters[0].english,english)
        p=VoiceStream({'messages':[{'role':'user','content':'请朗读这个链接：https://example.com/a'},{'role':'user','content':'OK'}]})
        p.feed(0,'https://example.com/a',last=True)
        self.assertFalse(p.filters[0].read_url)

    def test_real_stream_wrapper_preserves_failure_and_suppresses_internal(self):
        async def run(user,text):
            reader=asyncio.StreamReader()
            for c in text:
                reader.feed_data(('data: '+json.dumps({'choices':[{'index':0,'delta':{'content':c}}]})+'\n\n').encode())
            reader.feed_data(b'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');reader.feed_eof();out=[]
            async def publish(value):out.append(value)
            self.assertTrue(await guarded_stream(reader,{},publish,{'_started':time.monotonic()},VoiceStream({'messages':[{'role':'user','content':user}]})))
            return ''.join(c.get('delta',{}).get('content','') for line in b''.join(out).splitlines() if line.startswith(b'data:') and line[5:].strip()!=b'[DONE]' for c in json.loads(line[5:]).get('choices',[]))
        self.assertEqual(asyncio.run(run('生成图片和视频','[查看图片](https://example.com/a.png)，但视频生成失败，请重新提交。')),'查看图片，但视频生成失败，请重新提交。')
        self.assertEqual(asyncio.run(run('OK','We need to call generate_image. 图片已经生成。')).strip(),'图片已经生成。')


if __name__=='__main__':unittest.main()
