"""Render private runtime configurations from one canonical voice catalog.

Writes a new staging directory only; use the regular immutable deployment and
rollback process to activate the generated files. Never writes credentials to stdout.
"""
import argparse
import copy
import fcntl
import hashlib
import tempfile
import json
import os
from pathlib import Path

def render(catalog, voice_config, upstream, catalog_path):
    catalog = copy.deepcopy(catalog)
    voice_config, upstream = copy.deepcopy(voice_config), copy.deepcopy(upstream)
    order = catalog.get('display_order', [])
    known = {v['id'] for v in catalog.get('voices', [])} | set(catalog.get('display_labels', {}))
    if not order or len(order) != len(set(order)) or not set(order) <= known:
        raise ValueError('display_order must list unique configured voice IDs')
    default = catalog.get('default_voice')
    if default not in order:
        raise ValueError('default_voice must be a configured choice')
    for key in ['voice_catalog_revision', 'voice_default_revision']:
        if type(catalog.get(key)) is not int or not 0 < catalog[key] <= 9007199254740991:
            raise ValueError('positive safe integer revisions are required')
    tool = next(t for t in voice_config['tools'] if t['id'] == catalog['model'] and t['kind'] == 'speech')
    tool['options'].update(voices=order, default_voice=default, voice_catalog=str(catalog_path))
    upstream['voice_catalog'] = str(catalog_path)
    return voice_config, upstream

def policy_hash(catalog, field):
    # Hash the complete catalog without revision numbers; the default revision
    # describes only the default, so ordinary catalog edits need not bump it.
    if field == 'voice_default_revision':
        value = {'model': catalog['model'], 'default_voice': catalog['default_voice']}
    else:
        value = {k: v for k, v in catalog.items() if k not in ('voice_catalog_revision', 'voice_default_revision')}
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()

def reserve_revisions(catalog, ledger_path, current_catalog=None):
    """Persist revision history outside release/rollback directories, under a lock."""
    ledger_path = Path(ledger_path)
    ledger_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = ledger_path.with_name(ledger_path.name + '.lock')
    with lock_path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        exists = ledger_path.exists()
        if exists:
            ledger = json.loads(ledger_path.read_text())
        else:
            if current_catalog is None:
                raise ValueError('revision ledger missing and active catalog unavailable')
            ledger = {'format': 1, 'models': {}}
        if ledger.get('format') != 1 or not isinstance(ledger.get('models'), dict):
            raise ValueError('invalid revision ledger')
        for entry in ([catalog] if exists else [current_catalog, catalog]):
            if entry is None: continue
            model = ledger['models'].setdefault(entry['model'], {})
            for field in ('voice_catalog_revision', 'voice_default_revision'):
                revision = entry.get(field)
                if type(revision) is not int or not 0 < revision <= 9007199254740991:
                    raise ValueError('positive safe integer revisions are required')
                history = model.setdefault(field, {})
                digest = policy_hash(entry, field)
                key = str(revision)
                if key in history and history[key] != digest:
                    raise ValueError(f'{field} {revision} was already used for different content')
                if history and revision < max(map(int, history)):
                    raise ValueError(f'{field} {revision} is below the recorded high-water mark')
                history[key] = digest
        fd, name = tempfile.mkstemp(prefix='.voice-revisions-', dir=ledger_path.parent)
        try:
            with os.fdopen(fd, 'w') as out:
                json.dump(ledger, out, sort_keys=True, indent=2)
                out.flush(); os.fsync(out.fileno())
            os.replace(name, ledger_path)
            parent = os.open(ledger_path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try: os.fsync(parent)
            finally: os.close(parent)
        finally:
            if os.path.exists(name): os.unlink(name)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['catalog','voice-config','upstream','output-dir']:
        parser.add_argument('--'+name, required=True, type=Path)
    parser.add_argument('--revision-ledger', type=Path, help='persistent ledger outside rollback releases')
    args=parser.parse_args()
    catalog=json.loads(args.catalog.read_text())
    current_voice=json.loads(args.voice_config.read_text())
    voice,upstream=render(catalog,current_voice,json.loads(args.upstream.read_text()),args.catalog.resolve())
    active_tool=next(t for t in current_voice['tools'] if t['id']==catalog['model'] and t['kind']=='speech')
    active_path=active_tool.get('options',{}).get('voice_catalog')
    active=json.loads(Path(active_path).read_text()) if active_path else None
    reserve_revisions(catalog,args.revision_ledger or args.voice_config.parent/'voice-revision-ledger.json',active)
    args.output_dir.mkdir(mode=0o700)  # Refuse overwriting an existing staging directory.
    for name,value in [('voice-config.json',voice),('upstream.json',upstream)]:
        path=args.output_dir/name
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'w') as output:json.dump(value,output,ensure_ascii=False,indent=2)
    print('Two private configurations rendered; no live files or services changed')
if __name__=='__main__':main()
