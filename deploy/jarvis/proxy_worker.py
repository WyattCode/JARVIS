#!/usr/bin/env python3
"""CPU-only cmd adapter: delegate model jobs to an existing loopback HTTP endpoint.

Used by the isolated voice coordinator; never launches or loads a GPU model.
The speech HTTP parser and canonical WAV writer are reused from the qualified Drama adapter.
"""
import base64
import json
import os
from pathlib import Path
import signal
import sys
import time
import urllib.parse
import mmap
import math
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'tools/speech/drama3'))
from drama3_worker import Http, Worker as DramaWorker, canonical_wav
from voice_catalog import speech_body

GENERATING = False
DEFER_CANCEL = False
CANCEL_PENDING = False


class Cancelled(Exception):
    pass


def cancel(*_):
    global CANCEL_PENDING
    if GENERATING:
        if DEFER_CANCEL:
            CANCEL_PENDING = True
        else:
            raise Cancelled()


def send(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def exchange(port, method, path, body=None, timeout=3600):
    r = Http(port, method, path, None if body is None else json.dumps(body).encode(), timeout=timeout)
    try:
        if r.status != 200:
            raise RuntimeError(f'upstream HTTP {r.status}: {r.error_message()}')
        return r.body()
    finally:
        r.close()


def json_call(port, method, path, body=None, timeout=3600):
    return json.loads(exchange(port, method, path, body, timeout=timeout))


def upstream_port(cfg):
    """Video placement is read for each job/load; speech and images keep their configured endpoint."""
    port = int(cfg['options']['upstream_port'])
    if cfg.get('kind') == 'video':
        route = Path(cfg['options'].get('video_route_file', Path.home() / 'jarvis/remote-brain/video-route.json'))
        if route.exists():
            value = json.loads(route.read_text())['upstream_port']
            if type(value) is not int or not 0 < value < 65536:
                raise ValueError('invalid video upstream port')
            port = value
    return port


def run_job(cmd, cfg):
    global DEFER_CANCEL, CANCEL_PENDING
    CANCEL_PENDING = False
    port = upstream_port(cfg); model = cfg['id']
    directory = Path(cmd['dir']); req = cmd['request']; started = time.monotonic()
    video_id = None
    try:
        if 'speech' in req:
            v = req['speech']; body = {k: v[k] for k in ('input', 'voice', 'speed', 'preset', 'seed') if k in v and v[k] != ''}
            body.update(model=model, stream=bool(v.get('stream')), response_format='pcm' if v.get('stream') else 'wav')
            if v.get('references'):
                body['references'] = json.loads((directory / v['references']).read_text())
            body = speech_body(body, cfg.get('options', {}).get('voice_catalog'))
            response = Http(port, 'POST', '/v1/audio/speech', json.dumps(body).encode())
            try:
                if response.status != 200:
                    raise RuntimeError(f'speech upstream HTTP {response.status}: {response.error_message()}')
                if body['stream']:
                    DramaWorker._stream_to(response, str(directory / 'speech.wav'))
                else:
                    (directory / 'speech.wav').write_bytes(response.body())
                fields = response.trailers if body['stream'] else response.headers
                audio = directory / 'speech.wav'
                if audio.stat().st_size <= 44:
                    raise RuntimeError('upstream returned empty PCM audio')
                with audio.open('rb') as file:
                    with mmap.mmap(file.fileno(), 0, access=mmap.ACCESS_READ) as wav:
                        if canonical_wav(wav) is None:
                            raise RuntimeError('upstream returned invalid canonical mono PCM audio')
                files = ['speech.wav']
                extra = {'finish_reason': fields.get('x-finish-reason', 'stop')}
            finally:
                response.close()
        elif 'transcription' in req:
            v = req['transcription']; body = {k: v[k] for k in ('language','prompt','temperature','seed') if k in v}
            audio=(directory/v['audio']).read_bytes()
            # Diagnose missing microphone audio without logging or retaining the user's words.
            import io
            with wave.open(io.BytesIO(audio),'rb') as wav:
                duration=wav.getnframes()/wav.getframerate()
                pcm=memoryview(wav.readframes(wav.getnframes())).cast('h')[::16]
                peak=max((abs(x) for x in pcm),default=0)/32768
                rms=math.sqrt(sum(float(x)*x for x in pcm)/max(1,len(pcm)))/32768
            print(f'asr.input job={directory.name} model={model} seconds={duration:.3f} rms={rms:.6f} peak={peak:.6f}',file=sys.stderr,flush=True)
            body.update(model=model, file=base64.b64encode(audio).decode(), response_format='verbose_json')
            result = json_call(port, 'POST', '/v1/audio/transcriptions', body)
            print(f"asr.result job={directory.name} language={result.get('language','')} chars={len(result.get('text','').strip())}",file=sys.stderr,flush=True)
            (directory/'transcript.json').write_text(json.dumps(result, ensure_ascii=False));files=['transcript.json'];extra={}
        elif 'image' in req:
            v=req['image'];body={k:v[k] for k in ('prompt','negative_prompt','n','seed','steps','guidance') if k in v}
            if v.get('references'):
                raise ValueError('voice proxy image references are not supported; use the main image API')
            body.update(model=model,size=f"{v['width']}x{v['height']}",response_format='b64_json')
            result=json_call(port,'POST','/v1/images/generations',body);files=[];extra={}
            for i,image in enumerate(result['data']):
                filename=f'image-{i}.png';(directory/filename).write_bytes(base64.b64decode(image['b64_json'],validate=True));files.append(filename)
        elif 'video' in req:
            v=req['video'];body={k:v[k] for k in ('prompt','negative_prompt','seconds','fps','seed','steps','guidance','audio') if k in v}
            body['seconds'] = str(v.get('seconds', 5))
            body.update(model=model,size=f"{v['width']}x{v['height']}")
            # Capture the remote ID before delivering cancellation; otherwise the remote GPU job is orphaned.
            DEFER_CANCEL = True
            try:
                result=json_call(port,'POST','/v1/videos',body,timeout=15)
                video_id=result['id']
            finally:
                DEFER_CANCEL = False
            if CANCEL_PENDING:
                raise Cancelled()
            endpoint='/v1/videos/'+urllib.parse.quote(video_id,safe='')
            while result['status'] in ('queued','in_progress'):
                send({'progress':{'phase':'remote-video','step':result.get('progress',0),'of':100}})
                time.sleep(.5);result=json_call(port,'GET',endpoint)
            video_id = None # terminal upstream jobs must retain their output on download failures
            if result['status']!='completed':raise RuntimeError(str(result.get('error')or result['status']))
            (directory/'video.mp4').write_bytes(exchange(port,'GET',endpoint+'/content'));files=['video.mp4'];extra={}
        else:
            raise ValueError('unsupported proxy request kind')
        return {'ok':True,'files':files,'seed':next(iter(req.values())).get('seed',0),'ms':round((time.monotonic()-started)*1000),**extra}
    except Exception:
        if video_id:
            DEFER_CANCEL = True
            try: exchange(port,'DELETE','/v1/videos/'+urllib.parse.quote(video_id,safe=''),timeout=5)
            except Exception as cleanup:
                print(f'proxy: video cancellation not confirmed for {video_id}: {type(cleanup).__name__}',file=sys.stderr,flush=True)
            finally: DEFER_CANCEL = False
        raise


def main():
    global GENERATING
    cfg=json.loads(os.environ['LOCALROUTER_TOOL'])
    signal.signal(signal.SIGUSR1,cancel)
    for line in sys.stdin:
        cmd=json.loads(line)
        try:
            if cmd['op']=='exit':return
            if cmd['op']=='load':
                state=json_call(upstream_port(cfg),'GET','/v1/tools')
                found=next((x for x in state['data']if x['id']==cfg['id']),None)
                if not found:raise RuntimeError('upstream does not offer '+cfg['id'])
                if cfg['kind'] in ('speech','transcription') and found['state'] not in ('ready','busy'):
                    raise RuntimeError('upstream model is '+found['state'])
                reply={'ok':True,'resident':0,'cancel':'signal'}
            elif cmd['op']=='generate':
                try:
                    GENERATING=True
                    reply=run_job(cmd,cfg)
                finally:GENERATING=False
            else:raise ValueError('unsupported operation')
        except Cancelled:reply={'ok':False,'type':'cancelled','error':'cancelled'}
        except Exception as e:reply={'ok':False,'type':'server_error','error':str(e)}
        send(reply)


if __name__=='__main__':main()
