import asyncio,copy,json,sys,time,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'deploy/jarvis'))
from voice_output_policy import SpokenText,VoiceStream,simplified,speech_input,voice_messages,is_voice
from chat_stream_guard import guarded_stream

def chunk(text=None,finish=None,calls=None):
    delta={}
    if text is not None:delta['content']=text
    if calls is not None:delta['tool_calls']=calls
    return b'data: '+json.dumps({'choices':[{'index':0,'delta':delta,'finish_reason':finish}]}).encode()+b'\n\n'
DONE=b'data: [DONE]\n\n'

class PolicyTests(unittest.TestCase):
    def filtered(self,text,user='请生成图片',parts=None,systems=()):
        filt=SpokenText(user,systems)
        return ''.join(filt.feed(x) for x in (parts if parts is not None else [text]))+filt.feed(last=True)
    def test_urls_removed_at_every_split(self):
        for url in ['https://jarvis.odn.cc/media/a.png?x=1&y=2','http://192.168.10.124/v1/files/img_a/0.png','/v1/files/img_a/0.png','www.example.com/a']:
            text='圖片已生成。'+url+'，請點擊查看。'
            for cut in range(len(text)+1):
                out=self.filtered(text,parts=[text[:cut],text[cut:]])
                self.assertNotIn(url,out);self.assertIn('图片已生成。',out);self.assertIn('请点击查看。',out)
    def test_character_fragmented_link(self):
        text='圖片：[點擊查看](https://a.test/a.png)。'
        out=self.filtered(text,parts=list(text));self.assertNotIn('https',out);self.assertIn('点击查看',out)
    def test_huge_url_does_not_escape_or_accumulate(self):
        filt=SpokenText('生成图片');out=filt.feed('https://example.com/')
        for _ in range(100):
            out+=filt.feed('a'*1000);self.assertLess(len(filt.pending)+len(filt.lex),1024)
        out+=filt.feed('。圖片已生成。',last=True);self.assertEqual(out,'')
    def test_explicit_url_reading_remains_possible(self):
        self.assertIn('https://example.com',self.filtered('https://example.com',user='请逐字读出这个网址 https://example.com'))
    def test_simplified_chinese_and_names(self):
        self.assertEqual(self.filtered('圖片與視頻已生成，請使用 Chrome 和 Qwen 查看。'),'图片与视频已生成，请使用 Chrome 和 Qwen 查看。')
    def test_internal_english_never_published_at_any_split(self):
        for leaked in ['We need to use generate_image.','The user wants an image.','You are Jarvis, a helpful assistant.','For image generation use 1024x1024 by default.']:
            text=leaked+' 圖片已經生成。'
            for cut in range(len(text)+1):
                out=self.filtered(text,parts=[text[:cut],text[cut:]])
                self.assertNotIn(leaked,out);self.assertIn('图片已经生成。',out)
    def test_arbitrary_system_sentence_is_suppressed(self):
        leaked='Never announce these internal routing parameters to the user.'
        self.assertNotIn(leaked,self.filtered(leaked+' 好了。',systems=[leaked]))
    def test_unrequested_english_prose_is_suppressed(self):
        out=self.filtered('The image has now been generated successfully. 圖片完成。')
        self.assertNotIn('generated',out);self.assertIn('图片完成',out)
    def test_english_translation_and_names_preserved(self):
        for user in ['请用英文回答','请翻译成英文','Please answer in English']:
            self.assertIn('image has',self.filtered('The image has now been generated successfully.',user=user))
        self.assertIn('Chrome',self.filtered('使用 Chrome 打开即可。'))
    def test_negative_english_instruction_wins(self):
        self.assertEqual(self.filtered('The image has now been generated successfully.',user='不要用英文回答，只用中文'),'')
    def test_user_supplied_quote_preserved(self):
        text='We need to use generate_image.'
        self.assertEqual(self.filtered(text,user='朗读这句话：'+text),text)
        self.assertEqual(self.filtered(text,user='请翻译成英文：我们需要使用生成图片工具。'),text)
    def test_nonvoice_and_voice_alias_detection(self):
        self.assertFalse(is_voice({'model':'chat'},{'model':'chat'}))
        for effort in ['none','low','medium','high']:self.assertTrue(is_voice({'model':'chat--jarvis-'+effort},{'model':'chat'}))
    def test_media_receipt_is_reduced_without_mutation(self):
        messages=[{'role':'assistant','tool_calls':[{'id':'a','function':{'name':'generate_image','arguments':'{"prompt":"English prompt"}'}}]},
                  {'role':'tool','tool_call_id':'a','content':json.dumps({'status':'completed','urls':['http://secret/a.png'],'prompt':'English prompt'})}]
        original=copy.deepcopy(messages);out=voice_messages(messages)
        self.assertEqual(messages,original);self.assertNotIn('http',out[-1]['content']);self.assertNotIn('English prompt',out[-1]['content']);self.assertIn('completed',out[-1]['content'])
    def test_failed_and_pending_receipts_never_claim_success(self):
        for status in ['failed','in_progress','queued','cancelled','timeout']:
            m=[{'role':'assistant','tool_calls':[{'id':'x','function':{'name':'generate_video'}}]}, {'role':'tool','tool_call_id':'x','content':json.dumps({'status':status})}]
            out=voice_messages(m);self.assertNotIn('已生成',out[-1]['content'])
    def test_nonmedia_tool_results_and_arguments_unchanged(self):
        messages=[{'role':'assistant','tool_calls':[{'id':'x','function':{'name':'list_models','arguments':'{}'}}]}, {'role':'tool','tool_call_id':'x','content':'{"models":["English"]}'}]
        self.assertEqual(voice_messages(messages),messages)
    def test_completed_without_artifact_does_not_claim_generation(self):
        messages=[{'role':'assistant','tool_calls':[{'id':'x','function':{'name':'generate_image'}}]}, {'role':'tool','tool_call_id':'x','content':'{"status":"completed","urls":[]}'}]
        out=voice_messages(messages);self.assertNotIn('已生成',out[-1]['content']);self.assertIn('未收到',out[-1]['content'])
    def test_direct_speech_defence(self):
        self.assertNotIn('http',speech_input('圖片已生成 https://a.test/v1/files/img_x/0.png'))
        self.assertEqual(speech_input('Hello world, how are you today?'),'Hello world, how are you today?')
        self.assertEqual(speech_input('We need to use generate_image.'),'We need to use generate_image.')

class StreamTests(unittest.TestCase):
    def run_policy(self,data,messages=None):
        async def run():
            reader=asyncio.StreamReader();reader.feed_data(data);reader.feed_eof();out=[]
            async def publish(value):out.append(value)
            ok=await guarded_stream(reader,{},publish,{'_started':time.monotonic()},VoiceStream({'messages':messages or [{'role':'user','content':'请生成图片'}]}))
            values=[json.loads(x[5:]) for x in b''.join(out).splitlines() if x.startswith(b'data:') and x[5:].strip()!=b'[DONE]']
            text=''.join(c.get('delta',{}).get('content','') for v in values for c in v.get('choices',[]))
            return ok,text,values
        return asyncio.run(run())
    def test_inline_and_plain_reasoning_both_filtered(self):
        data=chunk('<think>hidden English</think>We need to call generate_image. 圖片完成。')+chunk(finish='stop')+DONE
        ok,text,_=self.run_policy(data);self.assertTrue(ok);self.assertNotIn('hidden',text);self.assertNotIn('We need',text);self.assertIn('图片完成',text)
    def test_fragmented_voice_stream_url_removed(self):
        raw='圖片已生成：https://a.test/0.png，請查看。'
        ok,text,_=self.run_policy(b''.join(chunk(x) for x in raw)+chunk(finish='stop')+DONE)
        self.assertTrue(ok);self.assertNotIn('http',text);self.assertIn('请查看',text)
    def test_tool_arguments_opaque_and_unmodified(self):
        calls=[{'index':0,'id':'a','type':'function','function':{'name':'generate_image','arguments':'{"prompt":"English http://a.test"}'}}]
        ok,_,values=self.run_policy(chunk(calls=calls)+chunk(finish='tool_calls')+DONE)
        self.assertTrue(ok);self.assertEqual(next(c['delta']['tool_calls'] for v in values for c in v['choices'] if c['delta'].get('tool_calls')),calls)
    def test_media_only_link_has_truthful_fallback(self):
        m=voice_messages([{'role':'user','content':'生成图片'}, {'role':'assistant','tool_calls':[{'id':'a','function':{'name':'generate_image'}}]}, {'role':'tool','tool_call_id':'a','content':'{"status":"completed","urls":["http://a.test/a.png"]}'}])
        ok,text,_=self.run_policy(chunk('https://a.test/a.png')+chunk(finish='stop')+DONE,m)
        self.assertTrue(ok);self.assertIn('图片已生成',text);self.assertNotIn('http',text)
        ok,text,_=self.run_policy(chunk('https://a.test/a.png。')+chunk(finish='stop')+DONE,m)
        self.assertTrue(ok);self.assertIn('图片已生成',text)
    def test_empty_without_success_evidence_never_fabricates_completion(self):
        self.assertFalse(self.run_policy(chunk('https://a.test/a.png')+chunk(finish='stop')+DONE)[0])
    def test_done_flush_when_provider_omits_finish(self):
        self.assertIn('你好',self.run_policy(chunk('你好')+DONE)[1])
    def test_broken_transport_still_errors(self):
        with self.assertRaises(OSError):self.run_policy(chunk('你好'))

if __name__=='__main__':unittest.main()
