import importlib.util
import json
from pathlib import Path
import struct
import wave
import tempfile
import threading
import unittest
from unittest import mock
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

spec=importlib.util.spec_from_file_location('proxy_worker',Path(__file__).parents[1]/'deploy/jarvis/proxy_worker.py')
worker=importlib.util.module_from_spec(spec);spec.loader.exec_module(worker)

class Handler(BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    mode='ok'
    def log_message(self,*args):pass
    def do_POST(self):
        self.rfile.read(int(self.headers['Content-Length']))
        self.send_response(200);self.send_header('Transfer-Encoding','chunked');self.send_header('x-sample-rate','24000');self.send_header('x-channels','1');self.end_headers()
        if self.mode=='truncated':
            self.wfile.write(b'10\r\nshort');self.wfile.flush();self.close_connection=True;return
        if self.mode=='empty':
            self.wfile.write(b'0\r\n\r\n');self.wfile.flush();return
        pcm=struct.pack('<4h',100,200,300,400)
        self.wfile.write(f'{len(pcm):x}\r\n'.encode()+pcm+b'\r\n0\r\nx-finish-reason: length\r\n\r\n');self.wfile.flush()

class ProxyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=cls.server.serve_forever,daemon=True).start()
    @classmethod
    def tearDownClass(cls):cls.server.shutdown();cls.server.server_close()
    def config(self):return{'id':'speech','options':{'upstream_port':self.server.server_port}}
    def command(self,folder):return{'dir':folder,'request':{'speech':{'input':'hello','stream':True}}}
    def test_stream_is_incremental_canonical_wav_and_preserves_trailer(self):
        Handler.mode='ok'
        with tempfile.TemporaryDirectory() as folder:
            out=worker.run_job(self.command(folder),self.config());data=(Path(folder)/'speech.wav').read_bytes()
            self.assertTrue(out['ok']);self.assertEqual(out['finish_reason'],'length');self.assertEqual(data[:4],b'RIFF');self.assertEqual(len(data),52);self.assertEqual(struct.unpack('<I',data[40:44])[0],8)
    def test_truncated_stream_is_not_a_success(self):
        Handler.mode='truncated'
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises((EOFError,RuntimeError)):worker.run_job(self.command(folder),self.config())
    def test_transcription_forwards_language_and_vocabulary(self):
        calls=[]
        def remote(port,method,path,body=None,**kwargs):
            calls.append((method,path,body));return {'text':'你好，贾维斯','language':'zh'}
        with tempfile.TemporaryDirectory() as folder,mock.patch.object(worker,'json_call',side_effect=remote):
            with wave.open(str(Path(folder)/'audio.wav'),'wb') as wav:
                wav.setparams((1,2,16000,0,'NONE','not compressed'));wav.writeframes(bytes(32000))
            command={'dir':folder,'request':{'transcription':{'audio':'audio.wav','language':'zh','prompt':'贾维斯，TensorFold','seed':42}}}
            out=worker.run_job(command,self.config())
            self.assertTrue(out['ok'])
            self.assertEqual(json.loads((Path(folder)/'transcript.json').read_text())['language'],'zh')
        method,path,body=calls[0]
        self.assertEqual((method,path),('POST','/v1/audio/transcriptions'))
        self.assertEqual(body['language'],'zh');self.assertEqual(body['prompt'],'贾维斯，TensorFold')
    def test_empty_pcm_is_not_a_success(self):
        Handler.mode='empty'
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(RuntimeError):worker.run_job(self.command(folder),self.config())
    def test_video_body_uses_string_seconds_and_preserves_other_fields(self):
        posted=[]
        def remote(port,method,path,body=None,**kwargs):
            posted.append(body);return {'id':'video-ok','status':'completed'}
        with tempfile.TemporaryDirectory() as folder,mock.patch.object(worker,'json_call',side_effect=remote),mock.patch.object(worker,'exchange',return_value=b'video'):
            cmd={'dir':folder,'request':{'video':{'prompt':'a scene','width':768,'height':448,'seconds':3,'fps':24,'audio':True,'seed':123}}}
            result=worker.run_job(cmd,self.config());self.assertTrue(result['ok'])
        self.assertEqual(posted[0]['seconds'],'3');self.assertEqual(posted[0]['fps'],24);self.assertIs(posted[0]['audio'],True);self.assertEqual(posted[0]['size'],'768x448')
    def test_poll_failure_cancels_remote_video(self):
        calls=[]
        def remote(port,method,path,body=None,**kwargs):
            if method=='POST':return {'id':'vid-test','status':'in_progress'}
            raise RuntimeError('poll connection failed')
        def cleanup(port,method,path,body=None,**kwargs):calls.append((method,path));return b'{}'
        with tempfile.TemporaryDirectory() as folder, mock.patch.object(worker,'json_call',side_effect=remote),mock.patch.object(worker,'exchange',side_effect=cleanup),mock.patch.object(worker.time,'sleep'):
            cmd={'dir':folder,'request':{'video':{'prompt':'x','width':256,'height':256,'seconds':1}}}
            with self.assertRaisesRegex(RuntimeError,'poll connection failed'):worker.run_job(cmd,self.config())
        self.assertEqual(calls,[('DELETE','/v1/videos/vid-test')])
    def test_completed_video_is_not_cancelled_if_download_fails(self):
        calls=[]
        def remote(*args,**kwargs):return {'id':'vid-complete','status':'completed'}
        def download(port,method,path,body=None,**kwargs):
            calls.append((method,path))
            raise RuntimeError('download failed')
        with tempfile.TemporaryDirectory() as folder,mock.patch.object(worker,'json_call',side_effect=remote),mock.patch.object(worker,'exchange',side_effect=download):
            cmd={'dir':folder,'request':{'video':{'prompt':'x','width':256,'height':256,'seconds':1}}}
            with self.assertRaisesRegex(RuntimeError,'download failed'):worker.run_job(cmd,self.config())
        self.assertEqual(calls,[('GET','/v1/videos/vid-complete/content')])
    def test_cancel_while_creating_video_captures_id_and_ignores_repeated_cancel_during_cleanup(self):
        calls=[]
        def create(*args,**kwargs):
            worker.cancel()
            return {'id':'video-cancel-race','status':'in_progress'}
        def cleanup(port,method,path,**kwargs):
            worker.cancel();calls.append((method,path));return b'{}'
        worker.GENERATING=True
        try:
            with tempfile.TemporaryDirectory() as folder,mock.patch.object(worker,'json_call',side_effect=create),mock.patch.object(worker,'exchange',side_effect=cleanup):
                cmd={'dir':folder,'request':{'video':{'prompt':'x','width':256,'height':256}}}
                with self.assertRaises(worker.Cancelled):worker.run_job(cmd,self.config())
            self.assertEqual(calls,[('DELETE','/v1/videos/video-cancel-race')])
            self.assertFalse(worker.DEFER_CANCEL)
        finally:worker.GENERATING=False;worker.CANCEL_PENDING=False;worker.DEFER_CANCEL=False
    def test_cancel_during_generate_is_a_distinct_outcome(self):
        worker.GENERATING=True
        try:
            with self.assertRaises(worker.Cancelled):worker.cancel()
        finally:worker.GENERATING=False
        worker.cancel()

if __name__=='__main__':unittest.main()
