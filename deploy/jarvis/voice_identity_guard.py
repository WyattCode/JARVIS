"""Detect large pitch-register departures before publishing each speech block.

This is an acoustic outlier check, not a biometric speaker classifier. Profiles
are calibrated from the selected voice's own preview; retries keep that voice.
"""
from array import array
from functools import lru_cache
from pathlib import Path
import hashlib
import json
import math
import os
import statistics
import sys
import time


class VoiceMismatch(RuntimeError):
    pass


def pitch_stats(pcm, rate):
    if len(pcm) % 2 or not 8000 <= rate <= 192000:raise ValueError('invalid voice PCM')
    samples = array('h');samples.frombytes(pcm)
    if sys.byteorder != 'little':samples.byteswap()
    step = rate / 4000
    y = []
    for n in range(int(len(samples)/step)):
        at=n*step;i=int(at);f=at-i
        y.append((samples[i]*(1-f)+samples[min(i+1,len(samples)-1)]*f)/32768)
    pitches=[]
    for at in range(0,len(y)-160,80):
        frame=y[at:at+160];mean=sum(frame)/160;z=[v-mean for v in frame]
        energy=sum(v*v for v in z)
        if energy/160 < .015**2:continue
        products=[sum(z[i]*z[i+lag] for i in range(160-lag)) for lag in range(103)]
        ac=[value/energy for value in products]
        peaks=[i for i in range(11,73) if ac[i]>ac[i-1] and ac[i]>=ac[i+1]]
        cutoff=max(.4,max((ac[i] for i in peaks),default=0)*.9)
        valid=[i for i in peaks if ac[i]>=cutoff]
        # The original, preview-calibrated range is retained for ordinary speech.
        # Outside it, require strong overlap-normalized periodicity: otherwise a
        # 400 Hz tone aliases to its 200 Hz subharmonic, and 40 Hz loses confidence
        # solely because fewer samples overlap. Cover the catalog's 40..700 Hz
        # range plus high outliers without promoting weak fricative/formant peaks.
        squares=[0.0]
        for sample in z:squares.append(squares[-1]+sample*sample)
        def correlation(lag):
            overlap=squares[160-lag]*(squares[160]-squares[lag])
            return products[lag]/math.sqrt(overlap) if overlap>0 else 0
        edge={i:correlation(i) for i in [*range(3,12),*range(72,103)]}
        def interpolated(lag):
            denominator=edge[lag-1]-2*edge[lag]+edge[lag+1]
            shift=.5*(edge[lag-1]-edge[lag+1])/denominator if denominator else 0
            shift=max(-.5,min(.5,shift))
            return shift,edge[lag]-.25*(edge[lag-1]-edge[lag+1])*shift
        def fractional_correlation(lag):
            base=int(lag);fraction=lag-base
            left=z[:159-base]
            right=[z[i+base]*(1-fraction)+z[i+base+1]*fraction for i in range(len(left))]
            overlap=sum(v*v for v in left)*sum(v*v for v in right)
            return sum(a*b for a,b in zip(left,right))/math.sqrt(overlap) if overlap>0 else 0
        # A strong upper harmonic is not a new fundamental. Compare against the
        # best full-period peak; fractional comparison avoids penalizing a real
        # high tone whose period falls between integer samples (e.g. 900 Hz).
        best_period=max((correlation(i) for i in peaks),default=0)
        high=[i for i in range(4,11) if edge[i]>edge[i-1] and edge[i]>=edge[i+1] and
              fractional_correlation(i+interpolated(i)[0])>=max(.9,best_period*.97)]
        low=[i for i in range(73,102) if edge[i]>edge[i-1] and edge[i]>=edge[i+1] and interpolated(i)[1]>=.95] if not valid else []
        if high or low:
            lag=(high or low)[0]
            shift,_=interpolated(lag)
            pitches.append(4000/(lag+shift))
        elif valid:pitches.append(4000/valid[0])
    return {'median_hz':round(statistics.median(pitches),1) if pitches else None,'voiced_frames':len(pitches)}


@lru_cache(maxsize=4)
def catalog(path):
    value=json.loads(Path(path).read_text())
    if value.get('format')!='jarvis-voice-lock/1':raise ValueError('invalid voice lock catalog')
    for ident,p in value['voices'].items():
        data=Path(p['reference_file']).read_bytes()
        if hashlib.sha256(data).hexdigest()!=p['reference_sha256']:raise ValueError('voice reference changed')
        ref=json.loads(data)
        if len(data)>4*1024*1024 or ref.get('format')!='drama3-voice/1' or not isinstance(ref.get('text'),str) or not ref['text'].strip():raise ValueError('invalid voice reference')
        if ref.get('source',{}).get('kind')!='model-invented':raise ValueError('unsupported voice reference source')
        codes=ref.get('vq_codes')
        if not isinstance(codes,list) or len(codes)!=10 or not codes[0] or any(len(row)!=len(codes[0]) for row in codes):raise ValueError('invalid voice reference grid')
        if any(type(c) is not int or not 0<=c<4096 for row in codes for c in row):raise ValueError('invalid voice reference codes')
        if not 40<=p['low_hz']<p['high_hz']<=700:raise ValueError('invalid voice pitch bounds')
        p['reference']={'text':ref['text'],'vq_codes':codes}
    return value


def audit(config, record):
    path=config.get('audit_file')
    if not path:return
    try:
        raw=(json.dumps({'time':time.time(),**record},ensure_ascii=False)+'\n').encode()
        fd=os.open(path,os.O_WRONLY|os.O_APPEND|os.O_CREAT,0o600)
        try:
            if os.write(fd,raw)!=len(raw):raise OSError('short audit write')
        finally:os.close(fd)
    except OSError as err:
        print('voice identity audit unavailable: '+type(err).__name__,file=sys.stderr,flush=True)


class GatedResponse:
    def __init__(self,response,prefix,chunks,profile,rate):
        self.response=response;self.prefix=prefix;self.rest=chunks
        self.profile=profile;self.rate=rate;self.on_failure=None
    def __getattr__(self,name):return getattr(self.response,name)
    def chunks(self):
        offset=len(self.prefix)
        try:
            yield self.prefix
            while True:
                try:block=next(self.rest)
                except StopIteration:break
                except VoiceMismatch as err:
                    stats=json.loads(str(err))
                    if self.on_failure:self.on_failure({'result':'later_pitch_outlier','at_audio_ms':round(offset/self.rate/2*1000),'decision_reason':stats.get('decision_reason','pitch_outlier'),'stats':stats})
                    # Audio was already published: never retry or replay the sentence.
                    raise RuntimeError('后续语音明显偏离所选音色，已停止播放，请重试') from err
                yield block
                offset+=len(block)
        except BaseException:
            self.close();raise
    def close(self):self.response.close()


def pcm_blocks(chunks, size):
    """Bound inspection memory and latency, regardless of HTTP packet boundaries."""
    pending=bytearray()
    for piece in chunks:
        view=memoryview(piece)
        while view:
            take=min(size-len(pending),len(view))
            pending.extend(view[:take]);view=view[take:]
            if len(pending)==size:
                yield bytes(pending);pending.clear()
    if len(pending)%2:raise RuntimeError('voice stream ended inside a PCM sample')
    if pending:yield bytes(pending)


def check_window(pcm,rate,profile):
    stats=pitch_stats(pcm,rate)
    if stats['voiced_frames']>=8 and not profile['low_hz']<=stats['median_hz']<=profile['high_hz']:
        raise VoiceMismatch(json.dumps(stats))
    return stats


def severe_pitch(hz,profile):
    return hz is not None and (hz>profile['high_hz']*1.15 or hz<profile['low_hz']/1.15)


def reject_pitch(stats,reason):
    raise VoiceMismatch(json.dumps({**stats,'decision_reason':reason}))


def checked_blocks(chunks,rate,profile):
    # A slight, isolated pitch rise is normal prosody. Hold it until the next
    # voiced block confirms or clears it; a large departure still fails at once.
    pending=[];sparse=[]
    for block in chunks:
        stats=pitch_stats(block,rate);hz=stats['median_hz']
        outside=stats['voiced_frames']>=8 and not profile['low_hz']<=hz<=profile['high_hz']
        # Brief voiced syllables can each fall below the per-block confidence
        # threshold. Combine only recent, weak outliers and intervening silence,
        # never the whole utterance. Normal voiced evidence clears the window.
        # This adds no buffering: a later confirmed departure stops the current
        # block before publication; the already-held prefix is still 0.8..1.2 s.
        if stats['voiced_frames']>=8 or (hz is not None and profile['low_hz']<=hz<=profile['high_hz']):
            sparse=[]
        elif sparse or hz is not None:
            sparse.append(block);sparse=sparse[-3:]
            if hz is not None and len(sparse)>1:
                combined=pitch_stats(b''.join(sparse),rate)
                if combined['voiced_frames']>=8 and severe_pitch(combined['median_hz'],profile):
                    reject_pitch(combined,'intermittent_severe_window')
        if outside:
            severe=severe_pitch(hz,profile)
            if severe or pending:reject_pitch(stats,'severe_block' if severe else 'sustained_borderline_blocks')
            pending.append(block)
        elif pending:
            pending.append(block)
            if stats['voiced_frames']>=8 or len(pending)>=3:
                yield from pending;pending=[]
        else:yield block
    yield from pending


def gate(response, profile):
    rate=int(response.headers.get('x-sample-rate','0'))
    if not 8000<=rate<=192000 or response.headers.get('x-channels','1')!='1':raise RuntimeError('invalid voice stream format')
    chunks=iter(checked_blocks(pcm_blocks(response.chunks(),int(rate*.4)*2),rate,profile));prefix=bytearray();ended=False
    for target in [.8,1.2]:
        while len(prefix)<int(rate*2*target):
            try:piece=next(chunks)
            except StopIteration:ended=True;break
            prefix.extend(piece)
        stats=pitch_stats(bytes(prefix),rate)
        if stats['voiced_frames']>=8 and severe_pitch(stats['median_hz'],profile):
            reject_pitch(stats,'severe_prefix_window')
        if stats['voiced_frames']>=8 or ended:break
    stats['decision_reason']=('insufficient_voiced_frames' if stats['voiced_frames']<8 else
                              'within_pitch_range' if profile['low_hz']<=stats['median_hz']<=profile['high_hz'] else
                              'isolated_borderline_tolerated')
    return GatedResponse(response,bytes(prefix),chunks,profile,rate),stats


def locked_speech(http, port, body, requested, path, job_id):
    """Retry only while no prefix has been handed to the WAV writer."""
    config=catalog(str(path));profile=config['voices'].get(requested)
    if profile is None:
        raise ValueError('selected voice has no validated identity profile: '+str(requested))
    snapshot=dict(body)
    chinese_anchor=not body.get('references') and any('\u3400'<=c<='\u9fff' for c in body['input'])
    if chinese_anchor:snapshot['references']=[profile['reference']]
    stamp={'job_id':job_id,'requested_voice':requested,'effective_voice':body.get('voice'),'input_sha256':hashlib.sha256(body['input'].encode()).hexdigest(),'input_chars':len(body['input'])}
    stamp['reference_mode']='same_voice_chinese' if chinese_anchor else 'existing_or_default'
    stamp['pitch_range_hz']=[profile['low_hz'],profile['high_hz']]
    for attempt in range(2):
        response=http(port,'POST','/v1/audio/speech',json.dumps(snapshot).encode())
        try:
            if response.status!=200:raise RuntimeError(f'speech upstream HTTP {response.status}: {response.error_message()}')
            gated,stats=gate(response,profile)
            audit(config,{**stamp,'attempt':attempt+1,'result':'prefix_accepted',**stats})
            gated.on_failure=lambda record: audit(config,{**stamp,'attempt':attempt+1,**record})
            return gated
        except VoiceMismatch as err:
            stats=json.loads(str(err))
            audit(config,{**stamp,'attempt':attempt+1,'result':'pitch_outlier','decision_reason':stats.get('decision_reason','pitch_outlier'),'stats':stats})
            response.close()
            if attempt:raise RuntimeError('语音明显偏离所选音色，已阻止播放，请重试') from err
            # The extra reference belongs to the same named voice. Never change
            # voice/model, or append words to the text the user asked to hear.
            snapshot={**body,'references':[*snapshot.get('references',[]),profile['reference']]}
        except BaseException:
            response.close();raise
    raise RuntimeError('voice identity check failed')
