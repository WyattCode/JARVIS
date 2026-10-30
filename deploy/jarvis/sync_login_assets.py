#!/usr/bin/env python3
"""Build critical login assets into the first HTML response; no runtime fetch needed."""
import base64
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2] / 'src/voice'
path = ROOT / 'auth/login.html'
text = path.read_text()
for name in ('auth/brand-icon.webp', 'auth/jarvis-core.webp'):
    uri = 'data:image/webp;base64,' + base64.b64encode((ROOT / name).read_bytes()).decode()
    pattern = r'<img\b[^>]*data-inline-asset="' + re.escape(name) + r'"[^>]*>'
    text, count = re.subn(pattern, lambda match: re.sub(r'\bsrc="[^"]*"', lambda _: 'src="' + uri + '"', match.group()), text)
    if count != 1:
        raise ValueError('expected one inline image: ' + name)
source = (ROOT / 'auth/theme.js').read_text().split('const icons={', 1)[1].split('};', 1)[0]
icons = dict(re.findall(r"(light|dark|system):'([^']*)'", source))
control = '<div class="theme-switch" data-theme-control data-theme-prerender role="radiogroup" aria-label="外观">'
for mode, label in [('light', '白天'), ('dark', '黑夜'), ('system', '跟随系统')]:
    control += f'<button type="button" data-theme-choice-button="{mode}" role="radio" aria-label="{label}" title="{label}" aria-checked="{str(mode == "system").lower()}" tabindex="{0 if mode == "system" else -1}"><svg viewBox="0 0 24 24" aria-hidden="true">{icons[mode]}</svg></button>'
control += '</div>'
text, count = re.subn(r'<!--THEME_CONTROL_BEGIN-->.*?<!--THEME_CONTROL_END-->', lambda _: '<!--THEME_CONTROL_BEGIN-->' + control + '<!--THEME_CONTROL_END-->', text, flags=re.S)
if count != 1:
    raise ValueError('expected one pre-rendered theme control')
path.write_text(text)

# Shared sources must be byte-identical across login and the self-contained LAN UI.
for kind, asset, targets in [
    ('SURFACE_JS', 'surface.js', ['voice.html']),
    ('PWA_JS', 'pwa.js', ['voice.html']),
    ('THEME_JS', 'theme.js', ['voice.html']),
    ('THEME_CSS', 'theme.css', ['voice.html']),
    ('STELLAR_JS', 'stellar.js', ['voice.html', 'auth/login.js']),
    ('STELLAR_CSS', 'stellar.css', ['voice.html', 'auth/login.css']),
]:
    source = (ROOT / 'auth' / asset).read_text()
    for name in targets:
        target = ROOT / name
        begin, end = f'/* SHARED_{kind}_BEGIN */', f'/* SHARED_{kind}_END */'
        text, count = re.subn(re.escape(begin) + r'.*?' + re.escape(end),
                             lambda _: begin + '\n' + source + end,
                             target.read_text(), flags=re.S)
        if count != 1:
            raise ValueError('expected one shared block: ' + name + ' / ' + kind)
        target.write_text(text)
