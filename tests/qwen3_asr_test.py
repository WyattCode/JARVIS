import base64
import importlib.util
import io
from pathlib import Path
import socket
import unittest
import wave
import torch

spec=importlib.util.spec_from_file_location('qwen_asr_server',Path(__file__).parents[1]/'tools/speech/qwen3_asr/server.py')
server=importlib.util.module_from_spec(spec);spec.loader.exec_module(server)

def wav(rate=16000,channels=1,count=16000):
    stream=io.BytesIO()
    with wave.open(stream,'wb') as w:
        w.setparams((channels,2,rate,0,'NONE','not compressed'));w.writeframes(b'\x00\x00'*count*channels)
    return base64.b64encode(stream.getvalue()).decode()

class ASRTests(unittest.TestCase):
    def test_pcm_input(self):
        samples=server.audio_samples(wav());self.assertEqual(samples.shape,(16000,));self.assertTrue((samples==0).all())
    def test_wrong_audio_format_is_rejected(self):
        for data in [wav(24000),wav(channels=2),'not base64',None,wav(count=10)]:
            with self.subTest(data=str(data)[:30]),self.assertRaises(ValueError):server.audio_samples(data)
    def test_truncated_audio_is_rejected(self):
        raw=base64.b64decode(wav())[:-10]
        with self.assertRaises(ValueError):server.audio_samples(base64.b64encode(raw).decode())
    def test_language_and_vocabulary(self):
        self.assertEqual(server.options({'language':'zh','prompt':' 贾维斯，DGX Spark '}),('zh','贾维斯，DGX Spark'))
        self.assertEqual(server.options({}),('',''))
    def test_bad_options_do_not_reach_model(self):
        for body in [{'model':'whisper'},{'language':'xx'},{'language':[]},{'prompt':'a'*501},{'temperature':.9},{'response_format':'srt'}]:
            with self.subTest(body=body),self.assertRaises((ValueError,TypeError)):server.options(body)
    def test_client_cancellation_is_detected(self):
        a,b=socket.socketpair()
        try:
            watch=server.PeerClosed(a);ids=torch.zeros((1,1),dtype=torch.long)
            self.assertFalse(bool(watch(ids,None)[0]));b.close();self.assertTrue(bool(watch(ids,None)[0]))
        finally:a.close();b.close()

if __name__=='__main__':unittest.main()
