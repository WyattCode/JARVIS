import asyncio
import json
from pathlib import Path
import sys
import time
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'deploy/jarvis'))
import voice_output_policy as p
from chat_stream_guard import guarded_stream, speakable


class RecoveryVoiceFixTests(unittest.TestCase):
    def splits(self,user,text,systems=()):
        for cut in range(len(text)+1):
            f=p.SpokenText(user,systems)
            yield f.feed(text[:cut])+f.feed(text[cut:])+f.feed(last=True)
        f=p.SpokenText(user,systems)
        yield ''.join(f.feed(c) for c in text)+f.feed(last=True)

    def test_markdown_internal_content_is_blocked_at_every_split(self):
        for internal in ['**Analysis:** We need to call generate_image.',
                         '__Analysis:__ We need to call generate_image.',
                         '- We need to call generate_image.',
                         '* We need to call generate_image.',
                         '## **Analysis:** We need to call generate_image.',
                         'We **need** to call `generate_image`.']:
            for out in self.splits('OK',internal+'\n图片已经生成。'):
                self.assertNotIn('generate_image',out)
                self.assertNotIn('Analysis',out)
                self.assertIn('图片已经生成。',out)

    def test_natural_english_retains_original_display_markup(self):
        text='**We need** to back up the database before deploying.'
        for out in self.splits('What should our team do before deploying?',text):
            self.assertEqual(out,text)

    def test_explicit_quoted_internal_sentence_remains_readable(self):
        text='**Analysis:** We need to call generate_image.'
        for user in ['请朗读这句话：'+text,'请朗读这句话：'+speakable(text)]:
            for out in self.splits(user,text):
                self.assertEqual(out,text)

    def test_explicit_translation_matches_normalized_decision_text(self):
        text='**We need** to call generate_image.'
        for out in self.splits('请翻译成英文：我们需要调用生成图片工具。',text):
            self.assertEqual(out,text)
        for out in self.splits('Translate this into Chinese: hello',text+'\n你好。'):
            self.assertNotIn('generate_image',out)

    def test_markdown_links_preserve_following_failure_notice(self):
        text='[查看图片](https://example.com/a.png)，但视频生成失败，请重新提交。'
        for out in self.splits('请生成图片和视频',text):
            self.assertEqual(out,'查看图片，但视频生成失败，请重新提交。')

    def test_formatted_system_excerpt_is_not_speakable(self):
        text='Keep **these internal routing parameters** private.'
        for out in self.splits('OK',text+'\n完成。',systems=[text]):
            self.assertNotIn('routing',out)
            self.assertIn('完成。',out)

    def test_each_choice_constructs_one_filter_and_visibility(self):
        f=p.VoiceStream({'messages':[{'role':'user','content':'请概括：'+('材料内容。'*4000)}]})
        factory=Mock(wraps=f.visibility_type);f.visibility_type=factory
        with patch.object(p,'SpokenText',wraps=p.SpokenText) as constructor:
            for _ in range(1000):f.feed(0,'好')
            f.feed(0,last=True)
            self.assertEqual(constructor.call_count,1)
            self.assertEqual(factory.call_count,1)
            f.feed(1,'完成。',last=True)
            self.assertEqual(constructor.call_count,2)
            self.assertEqual(factory.call_count,2)

    def test_full_stream_and_speech_input_do_not_reintroduce_internal_text(self):
        async def run():
            reader=asyncio.StreamReader()
            text='**Analysis:** We need to call generate_image.\n图片已经生成。'
            for c in text:
                reader.feed_data(('data: '+json.dumps({'choices':[{'index':0,'delta':{'content':c}}]})+'\n\n').encode())
            reader.feed_data(b'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n');reader.feed_eof();out=[]
            async def publish(value):out.append(value)
            self.assertTrue(await guarded_stream(reader,{},publish,{'_started':time.monotonic()},p.VoiceStream({'messages':[{'role':'user','content':'OK'}]})))
            visible=''.join(c.get('delta',{}).get('content','') for line in b''.join(out).splitlines() if line.startswith(b'data:') and line[5:].strip()!=b'[DONE]' for c in json.loads(line[5:]).get('choices',[]))
            self.assertEqual(visible,'图片已经生成。')
            self.assertEqual(p.speech_input(speakable(visible)),'图片已经生成。')
        asyncio.run(run())


if __name__=='__main__':unittest.main()
