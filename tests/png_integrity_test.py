import importlib.util,struct,unittest,zlib
from pathlib import Path
spec=importlib.util.spec_from_file_location('png_integrity',Path(__file__).resolve().parents[1]/'deploy/jarvis/png_integrity.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
SIG=b'\x89PNG\r\n\x1a\n'
def chunk(tag,data):return struct.pack('>I',len(data))+tag+data+struct.pack('>I',zlib.crc32(data,zlib.crc32(tag))&0xffffffff)
def make(raw=b'\x00\xff\x00\x00',width=1,height=1,depth=8,color=2,interlace=0,compressed=None):
 return SIG+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,depth,color,0,0,interlace))+chunk(b'IDAT',zlib.compress(raw) if compressed is None else compressed)+chunk(b'IEND',b'')
class PngIntegrityTests(unittest.TestCase):
 def test_valid_native_rgb(self):self.assertEqual(module.validate_png(make()),(1,1))
 def test_valid_native_rgba(self):self.assertEqual(module.validate_png(make(raw=b'\x00\xff\x00\x00\xff',color=6)),(1,1))
 def test_valid_gray_and_adam7(self):
  self.assertEqual(module.validate_png(make(raw=b'\x00\x80',color=0,depth=1)),(1,1));self.assertEqual(module.validate_png(make(interlace=1)),(1,1))
 def test_every_truncated_prefix_is_rejected(self):
  png=make()
  for i in range(len(png)):
   with self.subTest(i=i),self.assertRaises(ValueError):module.validate_png(png[:i])
 def test_crc_corruption_rejected(self):
  png=bytearray(make());png[40]^=1
  with self.assertRaises(ValueError):module.validate_png(png)
 def test_truncated_zlib_with_valid_chunk_crc_rejected(self):
  with self.assertRaises(ValueError):module.validate_png(make(compressed=zlib.compress(b'\x00\xff\x00\x00')[:-1]))
 def test_extra_compressed_data_rejected(self):
  with self.assertRaises(ValueError):module.validate_png(make(compressed=zlib.compress(b'\x00\xff\x00\x00')+b'extra'))
 def test_invalid_filter_rejected(self):
  with self.assertRaises(ValueError):module.validate_png(make(raw=b'\x05\xff\x00\x00'))
 def test_decoded_row_length_mismatch_rejected(self):
  with self.assertRaises(ValueError):module.validate_png(make(raw=b'\x00\xff'))
 def test_decompression_bomb_is_bounded(self):
  with self.assertRaises(ValueError):module.validate_png(make(compressed=zlib.compress(bytes(1024*1024))))
 def test_dimensions_exceeding_configuration_rejected(self):
  for w,h in [(2753,1),(2752,2752),(0,1)]:
   with self.subTest(w=w,h=h),self.assertRaises(ValueError):module.validate_png(make(width=w,height=h))
 def test_noncontiguous_image_chunks_rejected(self):
  header=chunk(b'IHDR',struct.pack('>IIBBBBB',1,1,8,2,0,0,0));compressed=zlib.compress(b'\x00\xff\x00\x00')
  with self.assertRaises(ValueError):module.validate_png(SIG+header+chunk(b'IDAT',compressed[:2])+chunk(b'tEXt',b'x\x00y')+chunk(b'IDAT',compressed[2:])+chunk(b'IEND',b''))
 def test_trailing_bytes_rejected(self):
  with self.assertRaises(ValueError):module.validate_png(make()+b'extra')
if __name__=='__main__':unittest.main()
