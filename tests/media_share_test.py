import asyncio
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec=importlib.util.spec_from_file_location('media_share',Path(__file__).parents[1]/'deploy/jarvis/media_share.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

class Writer:
 def __init__(self):self.data=bytearray()
 def write(self,data):self.data.extend(data)
 async def drain(self):pass

class MediaShareTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
  self.job='video_0123456789abcdef';p=self.root/'jobs'/self.job;p.mkdir(parents=True);(p/'video.mp4').write_bytes(b'0123456789')
  cfg=self.root/'share.json';cfg.write_text(json.dumps({'roots':[str(self.root/'jobs')],'key_file':str(self.root/'key')}))
  self.share=m.MediaShare(cfg,'jarvis.test');self.cfg=cfg
 def response(self,url,method='GET',headers=None):
  w=Writer();asyncio.run(self.share.serve(w,method,url,headers or {}));head,body=bytes(w.data).split(b'\r\n\r\n',1);return head,body
 def test_persistent_https_capability_needs_no_login_and_is_file_scoped(self):
  url=self.share.url('/v1/videos/'+self.job+'/content');self.assertTrue(url.startswith('https://jarvis.test/media/'))
  self.assertEqual(url,m.MediaShare(self.cfg,'jarvis.test').url('/v1/files/'+self.job+'/video.mp4'))
  head,body=self.response(url);self.assertTrue(head.startswith(b'HTTP/1.1 200'));self.assertEqual(body,b'0123456789')
  self.assertEqual(self.share.url(url),url)
  bad=url.replace('/'+self.share.signature(self.job+'/video.mp4')+'/', '/'+('0'*64)+'/')
  self.assertTrue(self.response(bad)[0].startswith(b'HTTP/1.1 404'))
 def test_video_ranges_suffix_head_and_unsatisfiable(self):
  url=self.share.url('/v1/videos/'+self.job+'/content')
  for value,body in [('bytes=2-4',b'234'),('bytes=-3',b'789'),('bytes=8-',b'89')]:
   h,b=self.response(url,headers={b'range':[value]});self.assertIn(b'206 Partial Content',h);self.assertEqual(b,body)
  h,b=self.response(url,'HEAD');self.assertIn(b'Content-Length: 10',h);self.assertFalse(b)
  for value in ['bytes=99-','bytes=4-2','bytes=-0','bytes=0-1,3-4','garbage']:
   self.assertIn(b'416 Error',self.response(url,headers={b'range':[value]})[0])
 def test_no_remote_fetch_path_traversal_speech_or_symlink_escape(self):
  for path in ['https://evil.test/v1/files/'+self.job+'/video.mp4','//evil.test/v1/files/x/video.mp4','/v1/files/'+self.job+'/../secret.png','/v1/files/speech_0123456789abcdef/speech.wav','/v1/chat/completions','/v1/files/'+self.job+'/video.mp4?x=1']:
   with self.assertRaises(ValueError,msg=path):self.share.url(path)
  outside=self.root/'outside.png';outside.write_bytes(b'secret');(self.root/'jobs'/self.job/'image-0.png').symlink_to(outside)
  with self.assertRaises(FileNotFoundError):self.share.url('/v1/files/'+self.job+'/image-0.png')
 def test_rewrite_keeps_unready_jobs_and_unrelated_fields(self):
  result=self.share.rewrite({'urls':['/v1/files/'+self.job+'/video.mp4'],'id':self.job,'status':'completed','other':'/v1/chat/completions'})
  self.assertTrue(result['urls'][0].startswith('https://jarvis.test/media/'));self.assertEqual(result['other'],'/v1/chat/completions')
  self.assertEqual(self.share.rewrite('/v1/files/video_ffffffffffffffff/video.mp4'),'/v1/files/video_ffffffffffffffff/video.mp4')

if __name__=='__main__':unittest.main()
