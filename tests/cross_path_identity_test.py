import hashlib
import json
import math
from pathlib import Path
import struct
import sys
import unittest
import wave

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'deploy/jarvis'))
import voice_identity_guard as g


def tone(hz,rate=8000,seconds=.4):
    return b''.join(struct.pack('<h',int(12000*math.sin(2*math.pi*hz*i/rate))) for i in range(int(rate*seconds)))


class Response:
    def __init__(self,data,rate=8000):
        self.data=data;self.headers={'x-sample-rate':str(rate),'x-channels':'1'}
    def chunks(self):
        for i in range(0,len(self.data),1601):yield self.data[i:i+1601]
    def close(self):pass


def offline_validation():
    root=Path('/home/wyatt/jarvis')
    path=root/'updates/media-voice-lock-20261027/voice-lock-catalog.json'
    voice_catalog=root/'voices/zh-v1/catalog.json'
    if not path.exists() or not voice_catalog.exists():return None
    # Loading the catalog performs the normal reference digest checks.
    profiles=g.catalog(str(path))['voices'];c=json.loads(voice_catalog.read_text())
    selected=[(v['id'],Path(v['preview_file']),False,v.get('preview_sha256')) for v in c['voices']]
    selected.extend((k,Path(v['preview_file']),False,v.get('preview_sha256')) for k,v in c['previews'].items())
    for voice in ['zh-xingheng','zh-jingchuan','zh-qinglan','zh-yuexi']:
        for kind in ['reading','mixed']:
            p=root/'voices/zh-v1'/(voice+'-'+kind)/'speech.wav'
            if p.exists():selected.append((voice,p,False,None))
    evidence=root/'updates/media-voice-lock-20261027/evidence'
    selected.extend(('Ezra',p,p.name=='speech_94d4af31d6282b3a.wav',None) for p in sorted(evidence.glob('speech_*.wav')))
    rows=[]
    for voice,p,bad,digest in selected:
        actual=hashlib.sha256(p.read_bytes()).hexdigest()
        if digest and actual!=digest:raise ValueError('preview digest changed: '+voice)
        with wave.open(str(p),'rb') as w:
            if w.getnchannels()!=1 or w.getsampwidth()!=2:raise ValueError('unsupported preview format')
            rate=w.getframerate();pcm=w.readframes(w.getnframes())
        row={'voice':voice,'file':str(p),'sha256':actual,'expected':'blocked' if bad else 'passed'}
        try:
            response,stats=g.gate(Response(pcm,rate),profiles[voice])
            output=b''.join(response.chunks())
            row.update(result='passed' if output==pcm else 'changed',stats=stats)
        except (g.VoiceMismatch,RuntimeError) as error:
            row.update(result='blocked',error=type(error).__name__)
        rows.append(row)
    return {'catalog_sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'rows':rows}


class CrossPathIdentityTests(unittest.TestCase):
    def test_frequency_range_including_previously_aliased_high_tones(self):
        for rate in [8000,24000,44100]:
            for hz in [40,45,50,100,250,400,450,550,650,700,800,900,1000]:
                stats=g.pitch_stats(tone(hz,rate),rate)
                self.assertGreaterEqual(stats['voiced_frames'],8)
                self.assertAlmostEqual(stats['median_hz'],hz,delta=max(3,hz*.04),msg=f'{hz} Hz at {rate}')

    def test_upper_harmonic_is_not_promoted_over_a_stronger_full_period(self):
        pcm=b''.join(struct.pack('<h',int(10000*(.5*math.sin(2*math.pi*100*i/8000)+math.sin(2*math.pi*400*i/8000)))) for i in range(3200))
        self.assertAlmostEqual(g.pitch_stats(pcm,8000)['median_hz'],100,delta=5)
        out,_=g.gate(Response(pcm),{'low_hz':60,'high_hz':190})
        self.assertEqual(b''.join(out.chunks()),pcm)

    def test_high_tones_cannot_hide_in_male_or_female_calibration_ranges(self):
        for hz,profile in [(400,{'low_hz':66.7,'high_hz':211.1}),
                           (400,{'low_hz':63.2,'high_hz':200.1}),
                           (800,{'low_hz':120,'high_hz':380}),
                           (900,{'low_hz':40,'high_hz':700}),
                           (40,{'low_hz':60,'high_hz':190})]:
            with self.assertRaises(g.VoiceMismatch):g.gate(Response(tone(hz,seconds=1.2)),profile)

    def test_real_previews_and_historical_normal_audio_are_unchanged(self):
        report=offline_validation()
        if report is None:self.skipTest('private calibration audio is not installed')
        self.assertEqual(set(r['voice'] for r in report['rows']),{'Mae','Arlo','Ezra','Nora','Theo','Wren','zh-xingheng','zh-jingchuan','zh-qinglan','zh-yuexi'})
        for row in report['rows']:
            self.assertEqual(row['result'],row['expected'],msg=row['voice']+' '+row['file'])


if __name__=='__main__':unittest.main()
