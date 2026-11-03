import sys,unittest,tempfile
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'deploy/jarvis'))
import durable_restore as d
class Tests(unittest.TestCase):
 def fixture(self,r):
  result=[]
  for n in range(3):
   p=r/str(n);p.write_bytes(b'new');result.append({'path':str(p),'before':b'old' if n<2 else None,'before_sha256':d.sha(b'old') if n<2 else None,'after_sha256':d.sha(b'new')})
  return result
 def test_failure_at_each_write_and_delete_resumes(self):
  for stop in range(3):
   with self.subTest(stop=stop),tempfile.TemporaryDirectory() as t:
    r=Path(t);items=self.fixture(r);real=d.atomic
    def injected(p,data):
     if str(p)==items[stop]['path']:raise OSError('write failed')
     return real(p,data)
    with patch.object(d,'atomic',injected):
     with self.assertRaises(OSError):d.restore(r,items,'release',lambda:None)
    self.assertIn('resume',d.restore(r,items,'release',lambda:None,check=True))
    d.restore(r,items,'release',lambda:None)
    self.assertEqual(d.restore(r,items,'release',lambda:None),'Rollback already complete')
 def test_restart_failure_and_crash_after_actual_write_resume(self):
  with tempfile.TemporaryDirectory() as t:
   r=Path(t);items=self.fixture(r);real=d.atomic
   def crash(p,data):
    real(p,data)
    if str(p)==items[0]['path']:raise SystemExit('crash')
   with patch.object(d,'atomic',crash):
    with self.assertRaises(SystemExit):d.restore(r,items,'release',lambda:None)
   def failed():raise RuntimeError('restart failed')
   with self.assertRaises(RuntimeError):d.restore(r,items,'release',failed)
   d.restore(r,items,'release',lambda:None)
 def test_foreign_mutation_and_wrong_journal_are_rejected(self):
  with tempfile.TemporaryDirectory() as t:
   r=Path(t);items=self.fixture(r);Path(items[0]['path']).write_bytes(b'foreign')
   with self.assertRaises(ValueError):d.restore(r,items,'release',lambda:None)
   Path(items[0]['path']).write_bytes(b'new')
   d.restore(r,items,'release',lambda:None)
   with self.assertRaises(ValueError):d.restore(r,items,'different',lambda:None)
if __name__=='__main__':unittest.main()
