#!/usr/bin/env python3
"""Remote Flash-Next with local speech/media; guarded rollback to single host."""
from pathlib import Path
import argparse,fcntl,json,subprocess,time,urllib.request
from durable_restore import sha,current,atomic,restore
R=Path(__file__).resolve().parent
LOCK=R.parent/'image-remote-20261027/release.lock'
UNITS=['jarvis-remote-voice.service','jarvis-remote-brain.service','localrouter-jarvis.service','jarvis-asr.service']
def system(*args,timeout=240):
 subprocess.run(['systemctl','--user',*args],check=True,timeout=timeout)
def fetch(port,path='/v1/tools'):
 with urllib.request.urlopen(f'http://127.0.0.1:{port}{path}',timeout=4) as f:return json.load(f)
def verify():
 raw=(R/'manifest.json').read_bytes();m=json.loads(raw)
 for rel,digest in m['artifacts'].items():
  if current(R/rel)!=digest:raise ValueError('Release artifact changed: '+rel)
 for path,digest in m['guards'].items():
  if current(Path(path))!=digest:raise ValueError('Dependency changed: '+path)
 for i in m['items']:
  if current(R/i['after'])!=i['after_sha256']:raise ValueError('Stage changed')
  if (current(R/i['before']) if i['before'] else None)!=i['before_sha256']:raise ValueError('Backup changed')
 return m,sha(raw)
def idle():
 for port in [8190,8194]: # Remote standby services are never stopped by this release.
  d=fetch(port)
  if d.get('voice_sessions',0) or any(t.get('state') in ('busy','loading') for t in d.get('data',[])):
   raise RuntimeError(f'Port {port} has an active call or model job; wait for it to finish')
 d=fetch(18193,'/__jarvis_brain/status')
 if any(x.get('status')=='active' for x in d.get('recent',[])):raise RuntimeError('Chat request active; wait for it to finish')
def wait_gpu(single):
 required={'fishaudio/drama-3','whisper-large-v3-turbo','qwen-image-2.1-turbo'}
 deadline=time.monotonic()+300
 last='warming'
 while time.monotonic()<deadline:
  try:
   d=fetch(8190);ready={t['id'] for t in d['data'] if t['state']=='ready'}
   if required<=ready:
    print('GPU models ready: '+', '.join(sorted(required)),flush=True);return
   last=str([(t['id'],t['state'],t.get('last_error','')) for t in d['data']])
  except Exception as e:last=type(e).__name__
  time.sleep(2)
 raise RuntimeError('GPU readiness timed out: '+last)
def quiesce():
 # Stop consumers before backends and before restoring any configuration file.
 system('stop','jarvis-remote-voice.service','jarvis-remote-brain.service')
 system('stop','localrouter-jarvis.service','jarvis-asr.service')
def services_ready(single):
 items=fetch(18193,'/v1/models')['data']
 expected='qwen3.8-flash-next-iq3_s'
 if not any(x.get('id')==expected and x.get('running') is True and x.get('state') in ('ready','busy') for x in items):return False
 if not any(x.get('kind')=='speech' and x.get('default_voice')=='Ezra' for x in items):return False
 if single and not any(t.get('kind')=='chat' and t.get('state')=='unloaded' for t in fetch(8190)['data']):return False
 v=fetch(8194)
 required={'fishaudio/drama-3','whisper-large-v3-turbo'}
 return required<={x['id'] for x in v['data'] if x.get('state')=='ready'}
def restart(single):
 quiesce()
 system('daemon-reload',timeout=20)
 system('start','localrouter-jarvis.service',timeout=20)
 wait_gpu(single)
 # Both configurations use local Whisper.
 system('start','jarvis-remote-brain.service','jarvis-remote-voice.service',timeout=30)
 deadline=time.monotonic()+90
 while time.monotonic()<deadline:
  try:
   if services_ready(single):
    print('Public backend and voice coordinator ready',flush=True);return
  except (OSError,ValueError,KeyError,TypeError,AttributeError,StopIteration):pass
  time.sleep(1)
 raise RuntimeError('Bridge or voice readiness failed')
def restoration(m,fingerprint,check=False):
 items=[{**i,'before':(R/i['before']).read_bytes() if i['before'] else None} for i in m['items']]
 return restore(R,items,fingerprint,lambda:restart(False),check=check,quiesce=quiesce)
def main():
 p=argparse.ArgumentParser();p.add_argument('action',choices=['deploy','rollback']);p.add_argument('--check',action='store_true');p.add_argument('--force',action='store_true',help='Rollback only: interrupt calls/jobs if a backend is stuck; hashes are still checked');a=p.parse_args()
 if a.force and a.action!='rollback':p.error('--force is only valid with rollback')
 with LOCK.open('a') as f:
  fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
  m,fingerprint=verify()
  journal=R/'deploy-state.json'
  if a.action=='rollback':
   print(restoration(m,fingerprint,check=True),flush=True)
   if a.check:return
   if not (R/'restore-state.json').exists() and not a.force:idle()
   if a.force:print('Emergency rollback: interrupting local calls/jobs; backup and target checks remain enforced',flush=True)
   print(restoration(m,fingerprint),flush=True);return
  if (R/'restore-state.json').exists():raise RuntimeError('Rollback started; create a new release to redeploy')
  state=json.loads(journal.read_text()) if journal.exists() else None
  if state and state['manifest_sha256']!=fingerprint:raise RuntimeError('Manifest differs from journal')
  for i in m['items']:
   allowed=[i['before_sha256'],i['after_sha256']] if state else [i['before_sha256']]
   if current(Path(i['path'])) not in allowed:raise RuntimeError('Live target changed: '+i['path'])
  if state and state['phase']=='complete':
   for i in m['items']:
    if current(Path(i['path']))!=i['after_sha256']:raise RuntimeError('Completed deployment changed')
   print('Voice update already deployed');return
  if not state:idle()
  if a.check:print('Deploy preflight passed');return
  def save(phase):atomic(journal,(json.dumps({'manifest_sha256':fingerprint,'phase':phase})+'\n').encode())
  save('stopping')
  try:
   print('Stopping local consumers and GPU backend for topology change',flush=True)
   system('stop','jarvis-remote-voice.service','jarvis-remote-brain.service')
   system('stop','localrouter-jarvis.service','jarvis-asr.service')
   save('writing')
   for i in m['items']:
    if current(Path(i['path'])) not in (i['before_sha256'],i['after_sha256']):raise RuntimeError('Target changed during deployment')
    atomic(Path(i['path']),(R/i['after']).read_bytes())
   save('restarting');restart(True);save('complete')
   print('Voice update deployed; rollback preserved',flush=True)
  except Exception:
   save('failed')
   # Mark an interrupted deployment so known before/after states can be restored.
   atomic(R/'restore-state.json',(json.dumps({'manifest_sha256':fingerprint,'phase':'restoring'})+'\n').encode())
   print('Voice update failed; restoring previous binaries',flush=True)
   print(restoration(m,fingerprint),flush=True)
   raise
if __name__=='__main__':main()
