#!/usr/bin/env python3
"""Loopback-only Qwen3-ASR service using the official native Transformers checkpoint.
Accepts the LocalRouter proxy's base64 WAV JSON contract; no remote model code or runtime downloads.
"""
import argparse
import base64
import binascii
import io
import json
import logging
from pathlib import Path
import select
import socket
import sys
import threading
import time
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import numpy as np
import torch
from transformers import AutoProcessor, AutoModelForMultimodalLM, StoppingCriteria, StoppingCriteriaList

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'whisper'))
from whisper_core import load_vad, speech_intervals

MODEL_ID = 'qwen3-asr-1.7b'
MAX_BODY = 24 * 1024 * 1024
LANGUAGES = {'zh':'Chinese','en':'English','yue':'Cantonese','ar':'Arabic','de':'German','fr':'French','es':'Spanish','pt':'Portuguese','id':'Indonesian','it':'Italian','ko':'Korean','ru':'Russian','th':'Thai','vi':'Vietnamese','ja':'Japanese','tr':'Turkish','hi':'Hindi','ms':'Malay','nl':'Dutch','sv':'Swedish','da':'Danish','fi':'Finnish','pl':'Polish','cs':'Czech','fil':'Filipino','fa':'Persian','el':'Greek','hu':'Hungarian','mk':'Macedonian','ro':'Romanian'}


def audio_samples(encoded):
    try:
        raw = base64.b64decode(encoded, validate=True)
        with wave.open(io.BytesIO(raw), 'rb') as wav:
            if wav.getnchannels()!=1 or wav.getsampwidth()!=2 or wav.getframerate()!=16000 or wav.getcomptype()!='NONE':
                raise ValueError('audio must be 16 kHz mono PCM16 WAV')
            count=wav.getnframes()
            if count<160 or count>16000*120:raise ValueError('audio must be between 0.01 and 120 seconds')
            frames=wav.readframes(count)
            if len(frames)!=count*2:raise ValueError('truncated audio')
        return np.frombuffer(frames,dtype='<i2').astype(np.float32)/32768.0
    except (binascii.Error, wave.Error, EOFError, TypeError) as e:
        raise ValueError('invalid base64 PCM WAV') from e


def options(body):
    if body.get('model',MODEL_ID)!=MODEL_ID:raise ValueError('unknown transcription model')
    language=body.get('language')
    if language is None:language=''
    if not isinstance(language,str) or language not in LANGUAGES and language!='':raise ValueError('unsupported language')
    prompt=body.get('prompt')
    if prompt is None:prompt=''
    if not isinstance(prompt,str) or len(prompt)>500:raise ValueError('prompt must be at most 500 characters')
    if body.get('response_format','verbose_json') not in ('json','verbose_json'):raise ValueError('response_format must be json or verbose_json')
    if body.get('temperature',0) not in (None,0,0.0):raise ValueError('only deterministic temperature 0 is supported')
    return language,prompt.strip()


class PeerClosed(StoppingCriteria):
    def __init__(self, peer):self.peer=peer;self.closed=False
    def __call__(self,input_ids,scores,**kwargs):
        try:
            if select.select([self.peer],[],[],0)[0] and self.peer.recv(1,socket.MSG_PEEK|socket.MSG_DONTWAIT)==b'':self.closed=True
        except (OSError,ValueError):self.closed=True
        return torch.full((input_ids.shape[0],),self.closed,dtype=torch.bool,device=input_ids.device)


class Recognizer:
    def __init__(self, checkpoint, vad_path):
        torch.set_num_threads(4)
        self.lock=threading.Lock();self.busy=False
        self.vad=load_vad(vad_path)
        self.processor=AutoProcessor.from_pretrained(checkpoint,local_files_only=True,trust_remote_code=False)
        self.model=AutoModelForMultimodalLM.from_pretrained(checkpoint,local_files_only=True,trust_remote_code=False,dtype=torch.bfloat16,attn_implementation='sdpa').to('cuda').eval()
        logging.info('Qwen3-ASR loaded; cuda allocated %.2f GiB',torch.cuda.memory_allocated()/2**30)

    def recognize(self, body, peer):
        lang,prompt=options(body);samples=audio_samples(body.get('file'));started=time.monotonic()
        if not self.lock.acquire(timeout=20):raise TimeoutError('transcription queue is busy')
        self.busy=True
        try:
            # Reject silence before the language model can hallucinate a transcript.
            if not speech_intervals(self.vad,samples):return {'text':'','language':lang,'duration':len(samples)/16000,'segments':[]}
            inputs=self.processor.apply_transcription_request(audio=samples,language=lang or None,prompt=prompt or None,processor_kwargs={'audio_kwargs':{'sampling_rate':16000}}).to(self.model.device,self.model.dtype)
            disconnected=PeerClosed(peer)
            with torch.inference_mode():
                ids=self.model.generate(**inputs,max_new_tokens=1024,do_sample=False,stopping_criteria=StoppingCriteriaList([disconnected]))
            if disconnected.closed:raise ConnectionAbortedError('client disconnected')
            generated=ids[:,inputs['input_ids'].shape[1]:]
            eos=self.model.generation_config.eos_token_id
            endings=[eos] if isinstance(eos,int) else eos or []
            if generated.shape[1]>=1024 and int(generated[0,-1]) not in endings:raise RuntimeError('transcription exceeded output limit')
            parsed=self.processor.decode(generated,return_format='parsed')[0]
            name=parsed.get('language') or LANGUAGES.get(lang,'')
            detected=next((k for k,v in LANGUAGES.items() if v.lower()==name.lower()),lang)
            text=parsed.get('transcription','').strip()
            elapsed=time.monotonic()-started
            logging.info('transcription language=%s audio=%.2fs elapsed=%.3fs chars=%d',detected,len(samples)/16000,elapsed,len(text))
            return {'text':text,'language':detected,'duration':len(samples)/16000,'segments':[],'model':MODEL_ID,'processing_ms':round(elapsed*1000)}
        finally:self.busy=False;self.lock.release()


class Handler(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args):pass
    def reply(self,status,data):
        body=json.dumps(data,ensure_ascii=False).encode()
        self.send_response(status);self.send_header('Content-Type','application/json; charset=utf-8');self.send_header('Content-Length',str(len(body)));self.send_header('Connection','close');self.end_headers();self.wfile.write(body);self.close_connection=True
    def do_GET(self):
        if self.path=='/health':return self.reply(200,{'ok':True,'model':MODEL_ID})
        if self.path=='/v1/models':return self.reply(200,{'data':[{'id':MODEL_ID,'kind':'transcription','name':'Qwen3-ASR 1.7B','running':True,'capabilities':['speech_to_text'],'default_for':['speech_to_text'],'max_audio_s':120}]})
        if self.path=='/v1/tools':return self.reply(200,{'data':[{'id':MODEL_ID,'kind':'transcription','state':'busy' if self.server.recognizer.busy else 'ready','keep_loaded':True}]})
        self.reply(404,{'error':{'message':'not found'}})
    def do_POST(self):
        if self.path!='/v1/audio/transcriptions':return self.reply(404,{'error':{'message':'not found'}})
        try:
            if self.headers.get('Transfer-Encoding'):raise ValueError('Content-Length required')
            size=int(self.headers.get('Content-Length','0'))
            if not 0<size<=MAX_BODY:return self.reply(413,{'error':{'message':'request is too large'}})
            if self.headers.get_content_type()!='application/json':raise ValueError('application/json required')
            self.connection.settimeout(30)
            raw=self.rfile.read(size)
            if len(raw)!=size:raise ValueError('truncated request')
            body=json.loads(raw)
            if not isinstance(body,dict):raise ValueError('request must be an object')
            self.reply(200,self.server.recognizer.recognize(body,self.connection))
        except (BrokenPipeError,ConnectionResetError,ConnectionAbortedError):pass
        except (ValueError,TypeError) as e:self.reply(400,{'error':{'message':str(e)}})
        except TimeoutError as e:self.reply(503,{'error':{'message':str(e)}})
        except Exception:
            logging.exception('transcription failed');self.reply(500,{'error':{'message':'transcription failed; see service log'}})


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--checkpoint',required=True);parser.add_argument('--vad',required=True);parser.add_argument('--port',type=int,default=18795);a=parser.parse_args()
    logging.basicConfig(level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s')
    recognizer=Recognizer(a.checkpoint,a.vad)
    server=ThreadingHTTPServer(('127.0.0.1',a.port),Handler);server.recognizer=recognizer
    logging.info('ASR_READY port=%d model=%s',a.port,MODEL_ID);server.serve_forever()

if __name__=='__main__':main()
