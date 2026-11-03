from pathlib import Path
import unittest,tempfile,sys,json,importlib.util,fcntl,subprocess
from unittest.mock import patch
T=Path(__file__).resolve().parents[1]/'deploy/jarvis/release_templates/video-15s-local-20261103'

def load(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
d=load('candidate_restore',T/'durable_restore.py');sys.modules['durable_restore']=d
new=load('candidate_chain',T/'rollback-chain.py');leaf=load('candidate_leaf',T/'release.py');locked=load('candidate_locked',T/'locked-release.py')
class Checks(unittest.TestCase):
 def fixture(self,root):
  m={'artifacts':{},'guards':{},'items':[]};raw=json.dumps(m).encode();(root/'manifest.json').write_bytes(raw);return d.sha(raw)
 def simulate_chain(self,controller):
  with tempfile.TemporaryDirectory() as td:
   U=Path(td);R=U/'release';R.mkdir();L=U/'image-remote-20261027';L.mkdir();lockpath=L/'release.lock';available=[]
   def run(*args,**kwargs):
    with lockpath.open('a') as other:
     try:fcntl.flock(other,fcntl.LOCK_EX|fcntl.LOCK_NB);available.append(True)
     except BlockingIOError:available.append(False)
    if controller is new:self.assertEqual(len(kwargs['pass_fds']),1)
   with patch.object(controller,'R',R),patch.object(controller,'roots',return_value=[R,R]),patch.object(controller,'verify_chain'),patch.object(controller,'verify_controller',create=True),patch.object(controller.subprocess,'run',side_effect=run),patch.object(sys,'argv',['rollback-chain.py']):controller.main()
   return available
 def test_fixed_chain_holds_global_lock_for_all_layers(self):self.assertEqual(self.simulate_chain(new),[False,False])
 def test_dry_run_never_starts_leaf(self):
  with tempfile.TemporaryDirectory() as td:
   U=Path(td);R=U/'release';R.mkdir();(U/'image-remote-20261027').mkdir()
   with patch.object(new,'R',R),patch.object(new,'roots',return_value=[R]),patch.object(new,'verify_chain'),patch.object(new,'verify_controller'),patch.object(new.subprocess,'run') as run,patch.object(sys,'argv',['rollback-chain.py','--check']):new.main()
   run.assert_not_called()
 def test_inherited_lock_works_and_remains_held_after_leaf_returns(self):
  with tempfile.TemporaryDirectory() as td:
   root=Path(td);lockpath=root/'lock';marker=root/'ran';(root/'release.py').write_text('from pathlib import Path\nimport fcntl\nLOCK=Path('+repr(str(lockpath))+')\ndef main():\n with LOCK.open("a") as f:\n  fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)\n  Path('+repr(str(marker))+').write_text("ran")\n')
   with lockpath.open('a') as held:
    fcntl.flock(held,fcntl.LOCK_EX|fcntl.LOCK_NB)
    with patch.object(locked,'allowed_roots',return_value={root}),patch.object(sys,'argv',[]):locked.execute(root,held.fileno())
    self.assertTrue(marker.exists())
    with lockpath.open('a') as competitor:
     with self.assertRaises(BlockingIOError):fcntl.flock(competitor,fcntl.LOCK_EX|fcntl.LOCK_NB)
    subprocess.run([sys.executable,'-c','import sys,fcntl;fcntl.flock(int(sys.argv[1]),fcntl.LOCK_EX|fcntl.LOCK_NB)',str(held.fileno())],pass_fds=(held.fileno(),),check=True,timeout=5)
 def test_wrong_inherited_file_and_unallowed_root_refused(self):
  with tempfile.TemporaryDirectory() as td:
   root=Path(td);p=root/'lock';p.touch()
   with (root/'wrong').open('a') as wrong:
    with self.assertRaises(RuntimeError):locked.validate_lock(wrong.fileno(),p)
    with patch.object(locked,'allowed_roots',return_value=set()):
     with self.assertRaises(RuntimeError):locked.execute(root,wrong.fileno())
 def test_all_bad_journal_shapes_are_rejected_by_composite(self):
  for filename in ('deploy-state.json','restore-state.json'):
   for value in ({},[],None,False,0,''):
    with self.subTest(filename=filename,value=value),tempfile.TemporaryDirectory() as td:
     root=Path(td);self.fixture(root);(root/filename).write_text(json.dumps(value))
     with self.assertRaises(RuntimeError):new.verify_chain([root])
 def test_restore_rejects_bad_shape_without_callbacks(self):
  for value in ({},[],None,False,0,''):
   with tempfile.TemporaryDirectory() as td:
    root=Path(td);(root/'restore-state.json').write_text(json.dumps(value))
    with patch.object(leaf,'quiesce') as stop:
     with self.assertRaises(ValueError):d.restore(root,[],'fp',stop,quiesce=stop)
     stop.assert_not_called()
 def test_deployment_reader_rejects_nonobject_and_empty_journals(self):
  for value in ({},[],None,False,0,''):
   with tempfile.TemporaryDirectory() as td:
    root=Path(td);(root/'deploy-state.json').write_text(json.dumps(value))
    with patch.object(leaf,'R',root):
     with self.assertRaises(ValueError):leaf.read_deployment('fp')
 def test_controller_artifact_change_is_rejected(self):
  with tempfile.TemporaryDirectory() as td:
   root=Path(td);names=('rollback-chain.py','locked-release.py','durable_restore.py')
   for name in names:(root/name).write_bytes(b'valid')
   (root/'manifest.json').write_text(json.dumps({'artifacts':{n:d.sha(b'valid') for n in names}}))
   with patch.object(new,'R',root):
    new.verify_controller();(root/'locked-release.py').write_bytes(b'foreign')
    with self.assertRaises(RuntimeError):new.verify_controller()
if __name__=='__main__':unittest.main(verbosity=2)
