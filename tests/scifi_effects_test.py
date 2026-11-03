from pathlib import Path
import sys,unittest,socket,time
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools/speech/drama3'))
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'deploy/jarvis'))
from speech_effects import stream_audio,file_audio
from drama3_worker import wav_header,canonical_wav
from math import sin,pi
from array import array
class Response:
 headers={'x-sample-rate':'44100','x-channels':'1'}
 trailers={'x-finish-reason':'stop'}
 def __init__(self,pcm):self.pcm=pcm;self.closed=False
 def chunks(self):
  for i in range(0,len(self.pcm),35280):yield self.pcm[i:i+35280]
 def close(self):self.closed=True
class Tests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):cls.pcm=array('h',(int(7000*sin(2*pi*110*i/44100)) for i in range(88200))).tobytes()
 def test_files_and_streams_identical_all_presets(self):
  for name in ['sterling','nexus','titan']:
   with self.subTest(name=name):
    response=Response(self.pcm);data=b''.join(stream_audio(response,name).chunks())
    file=file_audio(wav_header(44100,len(self.pcm))+self.pcm,name)
    self.assertIsNotNone(canonical_wav(file));self.assertEqual(file[44:],data);self.assertTrue(response.closed)
 def test_existing_voice_unmodified(self):
  r=Response(self.pcm);self.assertIs(stream_audio(r,'Rowan'),r);self.assertIs(file_audio(self.pcm,'Rowan'),self.pcm)
 def test_upstream_error_cannot_be_success(self):
  class Bad(Response):
   def chunks(self):
    yield self.pcm
    raise OSError('simulated truncated speech')
  r=Bad(self.pcm)
  with self.assertRaisesRegex(RuntimeError,'upstream failed'):list(stream_audio(r,'nexus').chunks())
  self.assertTrue(r.closed)
 def test_cancel_unblocks_stalled_socket(self):
  left,right=socket.socketpair();self.addCleanup(left.close);self.addCleanup(right.close)
  class Stalled(Response):
   sock=left
   def chunks(self):
    yield self.pcm
    left.recv(1)
  r=Stalled(self.pcm);it=stream_audio(r,'nexus').chunks();next(it)
  before=time.monotonic();it.close();self.assertLess(time.monotonic()-before,1);self.assertTrue(r.closed)
 def test_invalid_sample_rate(self):
  r=Response(self.pcm);r.headers={'x-sample-rate':'0'}
  with self.assertRaises(ValueError):list(stream_audio(r,'nexus').chunks())
if __name__=='__main__':unittest.main()
