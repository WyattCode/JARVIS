"""Resumable restore under the caller's release lock; no production-specific paths."""
from pathlib import Path
import hashlib,json,os,tempfile

def sha(data):return hashlib.sha256(data).hexdigest()
def current(path):return sha(path.read_bytes()) if path.exists() else None

def atomic(path,data):
 path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
 if data is None:path.unlink(missing_ok=True)
 else:
  mode=path.stat().st_mode & 0o777 if path.exists() else 0o644
  fd,name=tempfile.mkstemp(dir=path.parent,prefix='.restore-')
  try:
   with os.fdopen(fd,'wb') as f:f.write(data);f.flush();os.fsync(f.fileno())
   os.chmod(name,mode);os.replace(name,path)
  finally:
   if os.path.exists(name):os.unlink(name)
 fd=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY)
 try:os.fsync(fd)
 finally:os.close(fd)

def restore(root,items,fingerprint,restart,check=False,quiesce=None):
 root=Path(root);journal=root/'restore-state.json'
 state=json.loads(journal.read_text()) if journal.exists() else None
 if state and (state.get('manifest_sha256')!=fingerprint or state.get('phase') not in ('restoring','restarting','complete')):
  raise ValueError('invalid restore journal')
 # Every backup is validated before any target is touched, including resumed runs.
 for item in items:
  data=item['before']
  if (sha(data) if data is not None else None)!=item['before_sha256']:raise ValueError('backup changed')
  allowed=[item['before_sha256']] if state and state['phase']=='complete' else [item['after_sha256'],item['before_sha256']] if state else [item['after_sha256']]
  if current(Path(item['path'])) not in allowed:raise ValueError('target changed: '+str(item['path']))
 if check:return 'Rollback preflight passed' + (' (resume)' if state else '')
 if state and state['phase']=='complete':return 'Rollback already complete'
 def save(phase):atomic(journal,(json.dumps({'manifest_sha256':fingerprint,'phase':phase})+'\n').encode())
 save('restoring') # Durable intent before the first change; a crash at any later write is resumable.
 if quiesce is not None:quiesce() # Stop consumers before changing any live configuration, also on resume.
 for item in items:
  p=Path(item['path'])
  if current(p)==item['before_sha256']:continue
  if current(p)!=item['after_sha256']:raise ValueError('target changed during restore: '+str(p))
  atomic(p,item['before'])
 save('restarting');restart()
 if any(current(Path(i['path']))!=i['before_sha256'] for i in items):raise ValueError('target changed during readiness')
 save('complete');return 'Rollback complete; service ready'
