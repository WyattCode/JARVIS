#!/usr/bin/env python3
"""Rollback the voice layers, optionally continuing through the previous topology layers."""
from pathlib import Path
import argparse,json,sys,subprocess,importlib.util,fcntl
R=Path(__file__).resolve().parent;U=R.parent
C=U/'voice-cancel-20261102-r2';F=U/'flash-next-local-media-20261031';P=U/'single-host-trial-20261031'
sys.path.insert(0,str(R))
from durable_restore import current

def module(root):
 spec=importlib.util.spec_from_file_location('release_'+root.name.replace('-','_'),root/'release.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m

def roots(updates_only):
 if (P/'restore-state.json').exists():chain=[P]
 elif (F/'restore-state.json').exists():chain=[F,P]
 elif (C/'restore-state.json').exists():chain=[C,F,P]
 elif (R/'deploy-state.json').exists():chain=[R,C,F,P]
 elif (C/'deploy-state.json').exists():chain=[C,F,P]
 else:chain=[F,P]
 return [root for root in chain if root in (R,C)] if updates_only else chain

def verify_chain(chain):
 projected={}
 for root in chain:
  m=module(root);manifest,fingerprint=m.verify()
  j=root/'restore-state.json';state=json.loads(j.read_text()) if j.exists() else None
  if state and (state.get('manifest_sha256')!=fingerprint or state.get('phase') not in ('restoring','restarting','complete')):raise RuntimeError('Invalid restore journal: '+str(root))
  for item in manifest['items']:
   path=item['path'];actual=projected[path] if path in projected else current(Path(path))
   allowed=[item['before_sha256']] if state and state['phase']=='complete' else [item['after_sha256'],item['before_sha256']] if state else [item['after_sha256']]
   if actual not in allowed:raise RuntimeError('Rollback chain target changed: '+path)
   projected[path]=item['before_sha256']
 return projected

def main():
 p=argparse.ArgumentParser();p.add_argument('--check',action='store_true');p.add_argument('--force',action='store_true');p.add_argument('--updates-only',action='store_true');a=p.parse_args()
 with (U/'image-remote-20261027/release.lock').open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);chain=roots(a.updates_only);verify_chain(chain)
 print('Verified rollback chain: '+(' -> '.join(x.name for x in chain) or 'new voice layers not deployed'),flush=True)
 if a.check:return
 for root in chain:
  cmd=[sys.executable,str(root/'release.py'),'rollback']
  if a.force:cmd.append('--force')
  subprocess.run(cmd,check=True)
if __name__=='__main__':main()
