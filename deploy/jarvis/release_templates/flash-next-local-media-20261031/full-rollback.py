#!/usr/bin/env python3
"""Restore pre-trial distributed topology through both guarded release layers."""
from pathlib import Path
import argparse,sys,subprocess,importlib.util
R=Path(__file__).resolve().parent
P=R.parent/'single-host-trial-20261031'
def run(root,check=False,force=False):
 args=[sys.executable,str(root/'release.py'),'rollback']
 if check:args.append('--check')
 if force:args.append('--force')
 subprocess.run(args,check=True)
def main():
 p=argparse.ArgumentParser();p.add_argument('--check',action='store_true');p.add_argument('--force',action='store_true');a=p.parse_args()
 # Once parent restoration began, its journal owns resumption and final checks.
 if (P/'restore-state.json').exists():run(P,a.check,a.force);return
 run(R,True,a.force)
 sys.path.insert(0,str(P));spec=importlib.util.spec_from_file_location('parent_release',P/'release.py');parent=importlib.util.module_from_spec(spec);spec.loader.exec_module(parent)
 pm,_=parent.verify()
 import json
 cm=json.loads((R/'manifest.json').read_text());child={i['path']:i for i in cm['items']}
 for item in pm['items']:
  actual=child[item['path']]['before_sha256'] if item['path'] in child else parent.current(Path(item['path']))
  if actual!=item['after_sha256']:raise RuntimeError('Release chain mismatch: '+item['path'])
 if a.check:print('Both rollback layers and projected parent state verified');return
 run(R,False,a.force)
 run(P,True,a.force)
 run(P,False,a.force)
if __name__=='__main__':main()
