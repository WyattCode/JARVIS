import importlib.util
import hashlib
import io
import json
import math
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import Mock

P=Path(__file__).resolve().parents[1]/'deploy/jarvis/voice_identity_guard.py'
S=importlib.util.spec_from_file_location('voice_guard',P);g=importlib.util.module_from_spec(S);S.loader.exec_module(g)
def pcm(hz,seconds=1.5):return b''.join(struct.pack('<h',int(12000*math.sin(2*math.pi*hz*i/8000))) for i in range(int(8000*seconds)))
class Response:
    status=200
    def __init__(self,data,step=1600):self.data=data;self.step=step;self.headers={'x-sample-rate':'8000','x-channels':'1'};self.trailers={};self.closed=False
    def chunks(self):
        for i in range(0,len(self.data),self.step):yield self.data[i:i+self.step]
        self.trailers={'x-finish-reason':'stop'}
    def close(self):self.closed=True
    def error_message(self):return 'failed'
class GuardTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
        ref=self.root/'ref.json';ref.write_text(json.dumps({'format':'drama3-voice/1','text':'reference','vq_codes':[[1,2,3]]*10,'source':{'kind':'model-invented'}}))
        self.profile={'low_hz':60,'high_hz':190,'reference_file':str(ref),'reference_sha256':hashlib.sha256(ref.read_bytes()).hexdigest()}
        self.file=self.root/'catalog.json';self.config={'format':'jarvis-voice-lock/1','voices':{'Ezra':self.profile},'audit_file':str(self.root/'audit.jsonl')};self.file.write_text(json.dumps(self.config));g.catalog.cache_clear()
        self.body={'model':'speech','voice':'Ezra','input':'视频做好了','stream':True,'response_format':'pcm'}
    def test_pitch_distinguishes_registers(self):
        for hz in [100,250]:self.assertAlmostEqual(g.pitch_stats(pcm(hz),8000)['median_hz'],hz,delta=10)
    def test_valid_stream_bytes_and_trailers_preserved(self):
        response=Response(pcm(100));out,stats=g.gate(response,self.profile)
        self.assertEqual(b''.join(out.chunks()),response.data);self.assertEqual(out.trailers['x-finish-reason'],'stop');out.close();self.assertTrue(response.closed)
    def test_odd_network_chunks_are_reassembled(self):
        response=Response(pcm(100),1601);out,stats=g.gate(response,self.profile);self.assertEqual(b''.join(out.chunks()),response.data)
    def test_initial_half_sample_does_not_hold_whole_reply(self):
        class Split(Response):
            consumed=0
            def chunks(self):
                parts=[self.data[:1]]+[self.data[i:min(i+1600,len(self.data)-1)] for i in range(1,len(self.data)-1,1600)]+[self.data[-1:]]
                for piece in parts:self.consumed+=len(piece);yield piece
        r=Split(pcm(100,3));out,stats=g.gate(r,self.profile)
        self.assertLess(r.consumed,len(r.data));self.assertEqual(b''.join(out.chunks()),r.data)
    def test_final_partial_sample_fails(self):
        with self.assertRaises(RuntimeError):g.gate(Response(pcm(100,.2)+b'x'),self.profile)
    def test_bad_prefix_never_returned_to_writer(self):
        with self.assertRaises(g.VoiceMismatch):g.gate(Response(pcm(250)),self.profile)
    def test_retry_keeps_voice_model_text_and_uses_own_reference(self):
        bad,good=Response(pcm(250)),Response(pcm(100));http=Mock(side_effect=[bad,good]);out=g.locked_speech(http,1,self.body,'Ezra',self.file,'job')
        self.assertTrue(bad.closed);self.assertEqual(b''.join(out.chunks()),good.data)
        first=json.loads(http.call_args_list[0].args[3]);second=json.loads(http.call_args_list[1].args[3])
        for k in ['model','voice','input']:self.assertEqual(first[k],second[k])
        self.assertEqual(second['references'][0]['text'],'reference');self.assertNotIn('references',self.body)
    def test_two_bad_attempts_fail_and_close_without_publish(self):
        bad=[Response(pcm(250)),Response(pcm(250))];http=Mock(side_effect=bad)
        with self.assertRaisesRegex(RuntimeError,'阻止播放'):g.locked_speech(http,1,self.body,'Ezra',self.file,'job')
        self.assertEqual(http.call_count,2);self.assertTrue(all(r.closed for r in bad))
    def test_good_prefix_not_retried(self):
        http=Mock(return_value=Response(pcm(100)));g.locked_speech(http,1,self.body,'Ezra',self.file,'job');self.assertEqual(http.call_count,1)
    def test_unknown_selected_voice_fails_without_default_fallback(self):
        http=Mock()
        with self.assertRaises(ValueError):g.locked_speech(http,1,self.body,'unknown',self.file,'job')
        http.assert_not_called()
    def test_reference_digest_change_rejected_before_http(self):
        Path(self.profile['reference_file']).write_text('{}');http=Mock()
        with self.assertRaises(ValueError):g.locked_speech(http,1,self.body,'Ezra',self.file,'job')
        http.assert_not_called()
    def test_http_error_not_retried_as_voice_mismatch(self):
        r=Response(b'');r.status=503;http=Mock(return_value=r)
        with self.assertRaises(RuntimeError):g.locked_speech(http,1,self.body,'Ezra',self.file,'job')
        self.assertTrue(r.closed);self.assertEqual(http.call_count,1)
    def test_truncated_stream_not_retried(self):
        class Broken(Response):
            def chunks(self):yield bytes(100);raise EOFError('broken')
        r=Broken(b'');http=Mock(return_value=r)
        with self.assertRaises(EOFError):g.locked_speech(http,1,self.body,'Ezra',self.file,'job')
        self.assertTrue(r.closed);self.assertEqual(http.call_count,1)
    def test_audit_contains_no_plaintext(self):
        out=g.locked_speech(Mock(return_value=Response(pcm(100))),1,self.body,'Ezra',self.file,'job')
        raw=(self.root/'audit.jsonl').read_text();self.assertNotIn(self.body['input'],raw);self.assertEqual(json.loads(raw)['requested_voice'],'Ezra')
    def test_cancellation_closes_response_without_retry(self):
        class Cancelled(BaseException):pass
        class Cancelling(Response):
            def chunks(self):raise Cancelled();yield b''
        r=Cancelling(b'');http=Mock(return_value=r)
        with self.assertRaises(Cancelled):g.locked_speech(http,1,self.body,'Ezra',self.file,'job')
        self.assertTrue(r.closed);self.assertEqual(http.call_count,1)
    def test_retry_preserves_existing_reference_and_adds_same_profile(self):
        body={**self.body,'references':[{'text':'existing','vq_codes':[[2]]*10}]}
        http=Mock(side_effect=[Response(pcm(250)),Response(pcm(100))]);g.locked_speech(http,1,body,'Ezra',self.file,'job')
        retry=json.loads(http.call_args_list[1].args[3])
        self.assertEqual(retry['references'][0],body['references'][0]);self.assertEqual(len(retry['references']),2)
    def test_silence_is_inconclusive_not_wrong_voice(self):
        out,stats=g.gate(Response(bytes(16000)),self.profile);self.assertEqual(stats['voiced_frames'],0)
    def test_short_voiced_reply_still_checked(self):
        with self.assertRaises(g.VoiceMismatch):g.gate(Response(pcm(250,.3)),self.profile)
    def test_later_drift_stops_before_bad_block_and_never_retries(self):
        r=Response(pcm(100,1.2)+pcm(250,1.2));http=Mock(return_value=r)
        out=g.locked_speech(http,1,self.body,'Ezra',self.file,'job');published=[]
        with self.assertRaisesRegex(RuntimeError,'后续语音'):
            for block in out.chunks():published.append(block)
        self.assertEqual(b''.join(published),pcm(100,1.2));self.assertTrue(r.closed)
        self.assertEqual(http.call_count,1)
        records=[json.loads(line) for line in (self.root/'audit.jsonl').read_text().splitlines()]
        self.assertEqual(records[-1]['result'],'later_pitch_outlier')
        self.assertEqual(records[-1]['at_audio_ms'],1200)
        self.assertNotIn(self.body['input'],json.dumps(records,ensure_ascii=False))
    def test_unaligned_later_drift_is_detected(self):
        r=Response(pcm(100,1.5)+pcm(250,1.5));out,_=g.gate(r,self.profile);published=[]
        with self.assertRaisesRegex(RuntimeError,'后续语音'):
            for block in out.chunks():published.append(block)
        self.assertLessEqual(len(b''.join(published)),int(1.9*8000)*2)
    def test_single_large_http_packet_does_not_hide_later_drift(self):
        r=Response(pcm(100,1.2)+pcm(250,1.2),1000000)
        out,_=g.gate(r,self.profile)
        with self.assertRaisesRegex(RuntimeError,'后续语音'):list(out.chunks())
    def test_partial_tail_is_checked(self):
        out,_=g.gate(Response(pcm(100,1.2)+pcm(250,.3)),self.profile)
        with self.assertRaisesRegex(RuntimeError,'后续语音'):list(out.chunks())
    def test_large_packet_bad_then_good_prefix_is_rejected(self):
        with self.assertRaises(g.VoiceMismatch):g.gate(Response(pcm(250,.4)+pcm(100,2),1000000),self.profile)
    def test_silent_prefix_and_normal_pauses_remain_valid(self):
        data=bytes(16000)+pcm(100)+bytes(6400)+pcm(100,.5)
        out,_=g.gate(Response(data,1601),self.profile)
        self.assertEqual(b''.join(out.chunks()),data)
    def test_unvoiced_noise_is_not_mistaken_for_other_voice(self):
        import random
        rng=random.Random(42)
        noise=b''.join(struct.pack('<h',rng.randint(-100,100)) for _ in range(16000))
        data=pcm(100)+noise+pcm(100)
        out,_=g.gate(Response(data),self.profile);self.assertEqual(b''.join(out.chunks()),data)
    def test_later_partial_pcm_sample_fails(self):
        out,_=g.gate(Response(pcm(100,2)+b'x'),self.profile)
        with self.assertRaisesRegex(RuntimeError,'PCM sample'):list(out.chunks())
    def test_later_transport_failure_closes_without_retry(self):
        class Broken(Response):
            def chunks(self):yield pcm(100,1.2);raise EOFError('late failure')
        r=Broken(b'');http=Mock(return_value=r);out=g.locked_speech(http,1,self.body,'Ezra',self.file,'job')
        with self.assertRaises(EOFError):list(out.chunks())
        self.assertTrue(r.closed);self.assertEqual(http.call_count,1)
    def test_later_cancellation_closes_without_retry(self):
        class Cancelled(BaseException):pass
        class Cancelling(Response):
            def chunks(self):yield pcm(100,1.2);raise Cancelled()
        r=Cancelling(b'');http=Mock(return_value=r);out=g.locked_speech(http,1,self.body,'Ezra',self.file,'job')
        with self.assertRaises(Cancelled):list(out.chunks())
        self.assertTrue(r.closed);self.assertEqual(http.call_count,1)
    def test_isolated_borderline_pitch_is_cleared_by_next_normal_block(self):
        data=pcm(100,1.2)+pcm(200,.4)+pcm(100,.8)
        out,_=g.gate(Response(data),self.profile)
        self.assertEqual(b''.join(out.chunks()),data)
    def test_sustained_borderline_change_is_blocked_before_publish(self):
        out,_=g.gate(Response(pcm(100,1.2)+pcm(200,.8)),self.profile);published=[]
        with self.assertRaisesRegex(RuntimeError,'后续语音'):
            for block in out.chunks():published.append(block)
        self.assertEqual(b''.join(published),pcm(100,1.2))
    def test_borderline_then_silence_is_not_a_confirmed_voice_switch(self):
        data=pcm(100,1.2)+pcm(200,.4)+bytes(12800)+pcm(100,.4)
        out,_=g.gate(Response(data),self.profile);self.assertEqual(b''.join(out.chunks()),data)
    def test_large_departure_still_blocks_a_single_short_block(self):
        out,_=g.gate(Response(pcm(100,1.2)+pcm(250,.3)),self.profile)
        with self.assertRaisesRegex(RuntimeError,'后续语音'):list(out.chunks())
    def test_chinese_uses_own_chinese_reference_from_first_attempt(self):
        http=Mock(return_value=Response(pcm(100)));g.locked_speech(http,1,self.body,'Ezra',self.file,'job')
        sent=json.loads(http.call_args.args[3]);self.assertEqual(sent['references'][0]['text'],'reference')
        self.assertEqual(sent['input'],self.body['input']);self.assertEqual(sent['voice'],'Ezra')
    def test_english_keeps_native_reference_and_custom_reference_is_not_replaced(self):
        for body in [{**self.body,'input':'Hello world'}, {**self.body,'references':[{'text':'custom','vq_codes':[[2]]*10}]}]:
            http=Mock(return_value=Response(pcm(100)));g.locked_speech(http,1,body,'Ezra',self.file,'job')
            sent=json.loads(http.call_args.args[3]);self.assertEqual(sent.get('references'),body.get('references'))
if __name__=='__main__':unittest.main()
