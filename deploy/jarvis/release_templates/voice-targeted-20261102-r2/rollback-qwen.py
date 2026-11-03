from pathlib import Path
import argparse,importlib.util,sys,subprocess,fcntl
R=Path(__file__).resolve().parent;F=R.parent/'flash-next-local-media-20261031'
spec=importlib.util.spec_from_file_location('voice_chain',R/'rollback-chain.py');chain=importlib.util.module_from_spec(spec);spec.loader.exec_module(chain)
p=argparse.ArgumentParser();p.add_argument('--check',action='store_true');p.add_argument('--force',action='store_true');a=p.parse_args()
with (R.parent/'image-remote-20261027/release.lock').open('a') as lock:
 fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);roots=chain.roots(True)+[F];chain.verify_chain(roots)
print('Verified voice updates -> original single-host Qwen27 rollback',flush=True)
if not a.check:
 cmd=[sys.executable,str(R/'rollback-chain.py'),'--updates-only']
 if a.force:cmd.append('--force')
 subprocess.run(cmd,check=True)
 cmd=[sys.executable,str(F/'release.py'),'rollback']
 if a.force:cmd.append('--force')
 subprocess.run(cmd,check=True)
