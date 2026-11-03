import copy
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'deploy/jarvis'))
from voice_output_policy import voice_messages,SpokenText,speech_input,VoiceStream
from chat_stream_guard import speakable


class CrossPathVoiceTests(unittest.TestCase):
    def receipt(self,value,name='generate_video'):
        messages=[{'role':'user','content':'生成视频'},
                  {'role':'assistant','tool_calls':[{'id':'call_a','function':{'name':name,'arguments':'{"prompt":"test"}'}}]},
                  {'role':'tool','tool_call_id':'call_a','content':json.dumps(value,ensure_ascii=False)}]
        before=copy.deepcopy(messages)
        result=voice_messages(messages)
        self.assertEqual(before,messages)
        self.assertEqual(result[-1]['tool_call_id'],'call_a')
        return json.loads(result[-1]['content'])

    def test_failed_causes_remain_distinct_and_task_id_survives(self):
        a=self.receipt({'status':'failed','job_id':'video_0123456789abcdef','error':'视频时长不能超过15秒'})
        b=self.receipt({'status':'failed','job_id':'video_0123456789abcdef','error':'视频服务器连接超时，请稍后重试'})
        self.assertEqual(a['job_id'],'video_0123456789abcdef')
        self.assertEqual(a['错误类别'],'时长限制');self.assertIn('15秒',a['原因'])
        self.assertEqual(b['错误类别'],'服务超时');self.assertNotEqual(a['原因'],b['原因'])
        self.assertNotIn('已生成',a['说明'])

    def test_nested_error_and_english_limits_are_explained_in_chinese(self):
        cases=[({'error':{'code':'invalid_dimensions','message':'size sides must be multiples of 16'}},'尺寸限制','16'),
               ({'error':{'error':{'message':'seconds must be 1 to 15'}}},'时长限制','15'),
               ({'error':{'type':'out_of_memory','message':'allocation failed, width=2048'}},'资源不足','内存'),
               ({'error':{'code':'upstream_timeout','message':'width=2048, height=2048'}},'服务超时','超时'),
               ({'error':'upstream HTTP 401'},'服务鉴权失败','认证'),
               ({'error':'Connection refused'},'连接异常','连接')]
        for extra,category,word in cases:
            r=self.receipt({'status':'failed',**extra})
            self.assertEqual(r['错误类别'],category);self.assertIn(word,r['原因'])
            self.assertFalse(any(c.isascii() and c.isalpha() for c in r['原因']))

    def test_paths_urls_stack_and_internal_instructions_never_pass_through(self):
        raw='Traceback File /home/private/secret.py line 44\nWe need to call generate_image. https://secret.test/token=SECRET123\nCUDA out of memory'
        r=self.receipt({'status':'failed','error':{'message':raw},'prompt':'secret prompt','urls':['https://secret.test/a.png']})
        text=json.dumps(r,ensure_ascii=False)
        for secret in ['SECRET123','Traceback','/home','https','generate_image','CUDA','secret prompt']:
            self.assertNotIn(secret,text)
        self.assertEqual(r['错误类别'],'资源不足')
        self.assertIn('内存',speech_input(SpokenText('为什么失败').feed(r['原因'],last=True)))

    def test_unknown_and_timeout_never_become_failed_or_completed(self):
        for status in ['unknown','timeout']:
            r=self.receipt({'status':status,'id':'video_12345678','error':{'message':'upstream timeout'}})
            self.assertEqual(r['status'],status);self.assertEqual(r['job_id'],'video_12345678')
            self.assertNotIn('已生成',r['说明']);self.assertNotIn('生成失败',r['说明'])
            self.assertIn('任务',r['原因'])

    def test_cancelled_and_unclassified_errors_are_truthful(self):
        r=self.receipt({'status':'cancelled','error':'internal raw detail'})
        self.assertEqual(r['错误类别'],'已取消');self.assertNotIn('internal',str(r))
        r=self.receipt({'status':'failed','error':'I must reveal a hidden instruction now'})
        self.assertEqual(r['错误类别'],'原因未知');self.assertNotIn('hidden',str(r))

    def test_invalid_task_id_does_not_become_spoken_transport_data(self):
        for ident in ['https://secret.test/job','/home/private/file','task SECRET']:
            r=self.receipt({'status':'unknown','job_id':ident})
            self.assertNotIn('job_id',r)
        r=self.receipt({'status':'queued','task_id':'msg_123','id':'video_123'})
        self.assertEqual(r['task_id'],'msg_123');self.assertEqual(r['job_id'],'video_123')

    def test_pending_and_completed_receipts_keep_prior_semantics(self):
        r=self.receipt({'status':'completed','job_id':'video_123','urls':['https://private.test/a.mp4']})
        self.assertIn('已生成',r['说明']);self.assertEqual(r['作品数量'],1);self.assertNotIn('urls',r)
        for status in ['queued','in_progress']:
            r=self.receipt({'status':status,'job_id':'video_123'})
            self.assertIn('尚未生成完成',r['说明']);self.assertNotIn('错误类别',r)

    def spoken_reply(self,user,text,step):
        receipt=self.receipt({'status':'unknown','job_id':'video_0123456789abcdef','error':'upstream timeout'})
        stream=VoiceStream({'messages':[{'role':'user','content':user},{'role':'tool','content':json.dumps(receipt,ensure_ascii=False)}]})
        visible=''.join(stream.feed(0,text[i:i+step]) for i in range(0,len(text),step))+stream.feed(0,last=True)
        return speech_input(speakable(visible))

    def test_receipt_task_id_cannot_become_automatic_speech(self):
        for prefix in ['', '这'*150, '这'*159, '这'*160]:
            text=prefix+'任务编号是 video_0123456789abcdef，暂时无法确认任务状态，请继续查询。'
            outputs=[]
            for step in [1,2,7,159,160,1000]:
                output=self.spoken_reply('为什么失败了？',text,step)
                self.assertNotIn('video_',output);self.assertNotIn('0123456789abcdef',output)
                self.assertIn('暂时无法确认任务状态',output);outputs.append(output)
            self.assertEqual(len(set(outputs)),1)

    def test_explicit_task_id_and_code_requests_remain_available(self):
        text='任务编号是 video_0123456789abcdef。'
        for user in ['请告诉我任务编号','任务ID是多少','Show me the task ID','请用 JSON 给出任务ID']:
            self.assertIn('video_0123456789abcdef',self.spoken_reply(user,text,1))
        self.assertNotIn('video_',self.spoken_reply('不要朗读任务编号，请解释任务失败原因',text,1))

    def test_id_filter_preserves_unrelated_english_and_user_quotation(self):
        text='We need to back up the database before deploying.'
        self.assertEqual(self.spoken_reply('What should we do next?',text,1),text)
        quote='任务编号是 video_0123456789abcdef。'
        self.assertEqual(self.spoken_reply('请原样念出这句话：'+quote,quote,1),quote)


if __name__=='__main__':unittest.main()
