"""Invoke an existing guarded release while retaining the coordinator's shared lock."""
from pathlib import Path
import argparse,os,fcntl,importlib.util,sys
R=Path(__file__).resolve().parent

def allowed_roots():
 return {R,R.parent/'voice-targeted-20261102-r2',R.parent/'voice-cancel-20261102-r2',R.parent/'flash-next-local-media-20261031',R.parent/'single-host-trial-20261031'}

def validate_lock(fd,path):
 actual=os.fstat(fd);expected=os.stat(path)
 if (actual.st_dev,actual.st_ino)!=(expected.st_dev,expected.st_ino):raise RuntimeError('Wrong inherited release lock')
 fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)

class InheritedLock:
 def __init__(self,fd):self.fd=fd
 def open(self,*args,**kwargs):return os.fdopen(os.dup(self.fd),'a')

def execute(root,fd,force=False):
 root=root.resolve()
 if root not in {p.resolve() for p in allowed_roots()}:raise RuntimeError('Release root is not allowed')
 sys.path.insert(0,str(root))
 s=importlib.util.spec_from_file_location('locked_release',root/'release.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
 validate_lock(fd,m.LOCK);m.LOCK=InheritedLock(fd)
 sys.argv=[str(root/'release.py'),'rollback']+(['--force'] if force else [])
 m.main()

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--root',type=Path,required=True);p.add_argument('--lock-fd',type=int,required=True);p.add_argument('--force',action='store_true');a=p.parse_args();execute(a.root,a.lock_fd,a.force)
