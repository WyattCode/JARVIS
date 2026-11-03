"""CPU-only voice boundary regressions; mock HTTP never contacts a model."""
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock
import wave

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'deploy/jarvis'))
import voice_identity_guard as g
from cross_path_identity_test import tone,offline_validation


class Response:
    status=200
    def __init__(self,data,rate=8000,step=1601):
        self.data=data;self.rate=rate;self.step=step;self.consumed=0;self.closed=False
        self.headers={'x-sample-rate':str(rate),'x-channels':'1'};self.trailers={}
    def chunks(self):
        for start in range(0,len(self.data),self.step):
            piece=self.data[start:start+self.step];self.consumed+=len(piece);yield piece
        self.trailers={'x-finish-reason':'stop'}
    def close(self):self.closed=True


def sparse(hz,rate=8000):
    voiced=tone(hz,rate,seconds=.12)
    return voiced+bytes(int(rate*.4)*2-len(voiced))


class BoundaryIdentityTests(unittest.TestCase):
    profile={'low_hz':60,'high_hz':190}

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        root=Path(self.temp.name);ref=root/'reference.json'
        ref.write_text(json.dumps({'format':'drama3-voice/1','source':{'kind':'model-invented'},'text':'reference','vq_codes':[[1]]*10}))
        self.log=root/'audit.jsonl';self.catalog=root/'catalog.json'
        self.catalog.write_text(json.dumps({'format':'jarvis-voice-lock/1','voices':{'Ezra':{
            **self.profile,'reference_file':str(ref),'reference_sha256':hashlib.sha256(ref.read_bytes()).hexdigest()}},'audit_file':str(self.log)}))
        self.body={'model':'speech','voice':'Ezra','input':'不能记录的测试文本','stream':True,'response_format':'pcm'}

    def unchanged(self,data,step=1601):
        response=Response(data,step=step);out,_=g.gate(response,self.profile)
        self.assertEqual(b''.join(out.chunks()),data)

    def test_intermittent_high_pitch_blocks_before_prefix_publication(self):
        for rate in (8000,44100):
            block=sparse(250,rate)
            self.assertLess(g.pitch_stats(block,rate)['voiced_frames'],8)
            for step in (1,1601,1000000):
                for offset in (0,.06,.2):
                    data=bytes(int(rate*offset)*2)+block*6
                    with self.subTest(rate=rate,step=step,offset=offset):
                        with self.assertRaises(g.VoiceMismatch):g.gate(Response(data,rate,step),self.profile)

    def test_prefix_aggregate_is_checked_even_when_last_block_has_normal_median(self):
        second=tone(250,seconds=.04)+tone(100,seconds=.06)+bytes(4800)
        self.assertEqual(g.pitch_stats(second,8000)['median_hz'],100)
        with self.assertRaises(g.VoiceMismatch) as caught:g.gate(Response(sparse(250)+second),self.profile)
        stats=json.loads(str(caught.exception))
        self.assertEqual(stats['decision_reason'],'severe_prefix_window')
        self.assertGreaterEqual(stats['voiced_frames'],8)

    def test_later_intermittent_voice_stops_at_confirmation_without_retry(self):
        data=tone(100,seconds=1.2)+sparse(250)*6
        response=Response(data);http=Mock(return_value=response)
        out=g.locked_speech(http,1,self.body,'Ezra',self.catalog,'boundary-test')
        published=[]
        with self.assertRaisesRegex(RuntimeError,'后续语音'):
            for block in out.chunks():published.append(block)
        self.assertEqual(b''.join(published),data[:int(8000*1.6)*2])
        self.assertEqual(http.call_count,1);self.assertTrue(response.closed)
        records=[json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(records[-1]['result'],'later_pitch_outlier')
        self.assertEqual(records[-1]['decision_reason'],'intermittent_severe_window')
        self.assertEqual(records[-1]['at_audio_ms'],1600)

    def test_normal_intermittent_audio_does_not_add_startup_buffer(self):
        data=sparse(100)*8;response=Response(data,step=1)
        out,stats=g.gate(response,self.profile)
        self.assertEqual(response.consumed,int(8000*.8)*2)
        self.assertGreaterEqual(stats['voiced_frames'],8)
        self.assertEqual(stats['decision_reason'],'within_pitch_range')
        self.assertEqual(b''.join(out.chunks()),data)

    def test_normal_voiced_evidence_clears_sparse_history(self):
        self.unchanged(tone(100,seconds=1.2)+(sparse(250)+sparse(100))*6)

    def test_sparse_history_expires_after_three_blocks(self):
        self.unchanged(tone(100,seconds=1.2)+sparse(250)+bytes(8000*2*2)+sparse(250))

    def test_two_weak_outliers_separated_by_one_silent_block_are_confirmed(self):
        data=tone(100,seconds=1.2)+sparse(250)+bytes(6400)+sparse(250)
        out,_=g.gate(Response(data),self.profile)
        with self.assertRaisesRegex(RuntimeError,'后续语音'):list(out.chunks())

    def test_existing_borderline_tolerance_and_silence_remain_intact(self):
        self.unchanged(tone(100,seconds=1.2)+tone(200)+tone(100))
        self.unchanged(tone(200)+bytes(12800)+tone(100))
        self.unchanged(bytes(16000))

    def test_audit_records_bounds_and_reasons_without_raw_content(self):
        for data in (tone(100,seconds=1.2),sparse(250)*6):
            http=Mock(side_effect=lambda *args:Response(data))
            try:
                out=g.locked_speech(http,1,self.body,'Ezra',self.catalog,'boundary-test')
                list(out.chunks())
            except RuntimeError:pass
        records=[json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual([r['result'] for r in records],['prefix_accepted','pitch_outlier','pitch_outlier'])
        for record in records:
            self.assertEqual(record['pitch_range_hz'],[60,190])
            self.assertTrue(record['decision_reason'])
            self.assertNotIn(self.body['input'],json.dumps(record,ensure_ascii=False))
            self.assertNotIn('pcm',record);self.assertNotIn('audio',record)

    def test_all_real_references_and_original_fault_keep_expected_results(self):
        report=offline_validation()
        if report is None:self.skipTest('private calibration audio is not installed')
        self.assertEqual(sum(r['result']=='passed' for r in report['rows']),31)
        self.assertEqual(sum(r['result']=='blocked' for r in report['rows']),1)
        for row in report['rows']:self.assertEqual(row['result'],row['expected'],row['file'])
        faulty=next(row for row in report['rows'] if row['expected']=='blocked')
        with wave.open(faulty['file'],'rb') as audio:
            rate=audio.getframerate();pcm=audio.readframes(audio.getnframes())
        piece=pcm[int(rate*.12)*2:int(rate*.24)*2]
        block=piece+bytes(int(rate*.4)*2-len(piece))
        with self.assertRaises(g.VoiceMismatch):g.gate(Response(block*6,rate),self.profile)


if __name__=='__main__':unittest.main()
