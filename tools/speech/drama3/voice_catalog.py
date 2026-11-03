"""Fixed local Chinese voice references shared by HTTP previews and realtime speech.

Catalog paths come from operator configuration, never request paths. Model-invented
references stay outside the repository; hashes pin each reference to the catalog.
"""
import hashlib
import json
from pathlib import Path
from functools import lru_cache


@lru_cache(maxsize=4)
def load_catalog(path):
    catalog = json.loads(Path(path).read_text())
    if catalog.get('format') != 'jarvis-voices/1':
        raise ValueError('unsupported voice catalog')
    seen = set()
    for voice in catalog['voices']:
        ident = voice['id']
        if not isinstance(ident, str) or not ident or ident in seen:
            raise ValueError('duplicate or invalid voice id')
        seen.add(ident)
        data = Path(voice['reference_file']).read_bytes()
        if len(data) > 4 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != voice['reference_sha256']:
            raise ValueError('voice reference digest mismatch')
        reference = json.loads(data)
        if reference.get('format') != 'drama3-voice/1' or reference.get('source', {}).get('kind') != 'model-invented':
            raise ValueError('expected model-invented single-reference voice')
        rows = reference['vq_codes']
        if len(rows) != 10 or not rows[0] or any(len(row) != len(rows[0]) for row in rows):
            raise ValueError('invalid voice code shape')
        if any(type(code) is not int or not 0 <= code < 4096 for row in rows for code in row):
            raise ValueError('invalid voice codes')
        digest = hashlib.sha256(b''.join(code.to_bytes(4, 'little', signed=True) for row in rows for code in row)).hexdigest()
        if digest != reference['codes_sha256'] or not reference.get('text', '').strip():
            raise ValueError('invalid voice reference content')
        voice['reference'] = {'text': reference['text'], 'vq_codes': rows}
        if voice.get('preview_file'):
            preview = Path(voice['preview_file']).read_bytes()
            if len(preview) > 2 * 1024 * 1024 or not preview.startswith(b'RIFF') or hashlib.sha256(preview).hexdigest() != voice.get('preview_sha256'):
                raise ValueError('invalid voice preview')
            voice['preview_audio'] = preview
    previews = catalog.get('previews', {})
    for ident, item in previews.items():
        if ident not in catalog.get('display_labels', {}) or not isinstance(item, dict):
            raise ValueError('invalid original voice preview id')
        preview = Path(item['preview_file']).read_bytes()
        if len(preview) > 2 * 1024 * 1024 or not preview.startswith(b'RIFF') or hashlib.sha256(preview).hexdigest() != item.get('preview_sha256'):
            raise ValueError('invalid voice preview')
        item['preview_audio'] = preview
    return catalog


def speech_body(body, catalog_path):
    if not catalog_path:
        return body
    catalog = load_catalog(str(catalog_path))
    if body.get('model') != catalog['model']:
        return body
    preset = next((v for v in catalog['voices'] if v['id'] == body.get('voice')), None)
    if not preset:
        return body
    if body.get('references'):
        raise ValueError('fixed Chinese voices cannot be combined with other references')
    return dict(body, voice=preset['base_voice'], references=[preset['reference']])


def describe_voices(model, catalog_path):
    if not catalog_path:
        return model
    if 'voices' not in model:
        return model  # Status inventories are not voice-capability catalogs.
    catalog = load_catalog(str(catalog_path))
    if model.get('id') != catalog['model'] or model.get('kind') != 'speech':
        return model
    described = {v['id']: {k: v[k] for k in ('id', 'name', 'description')} for v in catalog['voices']}
    for ident, labels in catalog.get('display_labels', {}).items():
        described.setdefault(ident, {'id': ident}).update({
            key: labels[key] for key in ('name', 'description') if isinstance(labels.get(key), str)
        })
    for voice in [*catalog['voices'], *({'id': ident, **item} for ident, item in catalog.get('previews', {}).items())]:
        if voice.get('preview_audio'):
            described[voice['id']]['preview_url'] = '/v1/voice-previews/' + voice['id'] + '.wav'
    # Only advertise IDs the coordinator actually accepts, without exposing file paths or codes.
    voices = [described.get(v, v) if isinstance(v, str) else v for v in model.get('voices', [])]
    order = {ident: index for index, ident in enumerate(catalog.get('display_order', []))}
    if order:
        voices.sort(key=lambda voice: order.get(voice if isinstance(voice, str) else voice.get('id'), len(order)))
    default = catalog.get('default_voice', model.get('default_voice', ''))
    accepted = {v if isinstance(v, str) else v.get('id') for v in voices}
    if default and default not in accepted:
        raise ValueError('configured default voice is not available')
    revisions = {}
    for field in ('voice_catalog_revision', 'voice_default_revision'):
        revision = catalog.get(field)
        if revision is not None:
            if type(revision) is not int or not 0 < revision <= 9007199254740991:
                raise ValueError('invalid voice configuration revision')
            revisions[field] = revision
    return dict(model, voices=voices, default_voice=default, **revisions)


def preview_audio(catalog_path, voice_id):
    if not catalog_path:
        return None
    catalog = load_catalog(str(catalog_path))
    voice = next((v for v in catalog['voices'] if v['id'] == voice_id), None) or catalog.get('previews', {}).get(voice_id)
    return voice.get('preview_audio') if voice else None


def effect_preset(catalog_path, voice_id):
    if not catalog_path:
        return None
    voice = next((v for v in load_catalog(str(catalog_path))['voices'] if v['id'] == voice_id), None)
    preset = voice.get('effect_preset') if voice else None
    if preset not in (None, 'sterling', 'nexus', 'titan'):
        raise ValueError('invalid fixed voice effect preset')
    return preset
