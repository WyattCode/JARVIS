from pathlib import Path
import sys,argparse,importlib.util,json,fcntl,subprocess
R=Path(__file__).resolve().parent;P=R.parent/'voice-targeted-20261102-r2'
sys.path.insert(0,str(R));from durable_restore import current,sha
s=importlib.util.spec_from_file_location('voice_chain',P/'rollback-chain.py');old=importlib.util.module_from_spec(s);s.loader.exec_module(old)
def verify_chain(chain,projected=None):
 projected=dict(projected or {})
 for root in chain:
  raw=(root/'manifest.json').read_bytes();m=json.loads(raw);fp=sha(raw)
  for rel,d in m['artifacts'].items():
   if current(root/rel)!=d:raise RuntimeError('Artifact changed: '+str(root/rel))
  for path,d in m['guards'].items():
   if (projected[path] if path in projected else current(Path(path)))!=d:raise RuntimeError('Dependency changed: '+path)
  deployment=root/'deploy-state.json';deploy=json.loads(deployment.read_text()) if deployment.exists() else None
  if deployment.exists() and (not isinstance(deploy,dict) or deploy.get('manifest_sha256')!=fp or deploy.get('phase') not in ('stopping','writing','restarting','failed','complete')):raise RuntimeError('Invalid deployment journal: '+str(root))
  mixed=bool(deploy and deploy['phase']!='complete' and m.get('rollback_partial_deploy') is True)
  journal=root/'restore-state.json';state=json.loads(journal.read_text()) if journal.exists() else None
  if journal.exists() and (not isinstance(state,dict) or state.get('manifest_sha256')!=fp or state.get('phase') not in ('restoring','restarting','complete')):raise RuntimeError('Invalid journal: '+str(root))
  for item in m['items']:
   if current(root/item['after'])!=item['after_sha256'] or (current(root/item['before']) if item['before'] else None)!=item['before_sha256']:raise RuntimeError('Backup or stage changed')
   path=item['path'];actual=projected[path] if path in projected else current(Path(path))
   allowed=[item['before_sha256']] if state and state['phase']=='complete' else [item['before_sha256'],item['after_sha256']] if state or mixed else [item['after_sha256']]
   if actual not in allowed:raise RuntimeError('Target changed: '+path)
   projected[path]=item['before_sha256']
 return projected

def roots(target):
 older=any((p/'restore-state.json').exists() for p in (P,old.C,old.F,old.P))
 prefix=[R] if (R/'deploy-state.json').exists() and not older else []
 if target=='five':return prefix
 if target=='qwen':return prefix+old.roots(True)+[old.F]
 return prefix+old.roots(target=='voice-updates')

def verify_controller():
 m=json.loads((R/'manifest.json').read_text())
 for name in ('rollback-chain.py','locked-release.py','durable_restore.py'):
  if current(R/name)!=m['artifacts'][name]:raise RuntimeError('Rollback control changed: '+name)

def main():
 p=argparse.ArgumentParser();p.add_argument('--target',choices=['five','voice-updates','distributed','qwen'],default='five');p.add_argument('--check',action='store_true');p.add_argument('--force',action='store_true');a=p.parse_args()
 with (R.parent/'image-remote-20261027/release.lock').open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);verify_controller();chain=roots(a.target);verify_chain(chain)
  print('Verified rollback: '+(' -> '.join(x.name for x in chain) or 'video layer already absent'),flush=True)
  if a.check:return
  for root in chain:
   cmd=[sys.executable,str(R/'locked-release.py'),'--root',str(root),'--lock-fd',str(lock.fileno())]
   if a.force:cmd.append('--force')
   subprocess.run(cmd,check=True,pass_fds=(lock.fileno(),))
if __name__=='__main__':main()
