"""Android launcher icon, light (day) variant: vivid blue plate, white glyph. The dark (night) icon is unchanged.

Run with a Python that has Pillow:  python3 tools/render_android_light_icon.py
Writes the *_day vector drawables, points the default (non-night) launcher XML at them and renders the legacy
density PNGs. mipmap-night-* and the night drawables stay as they are.
"""
from pathlib import Path

import render_ios_icons as art

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / 'android/app/src/main/res'
LAUNCHER_SCALE = 0.84  # same glyph size as the dark icon
LIGHT_CYAN = '#D6FAFF'

# Vector drawables ---------------------------------------------------------------------------------------------------
background = (
    '<?xml version="1.0" encoding="utf-8"?><shape xmlns:android="http://schemas.android.com/apk/res/android" '
    'android:shape="rectangle"><gradient android:angle="315" android:startColor="#1860FF" '
    'android:endColor="#00CDF5"/></shape>'
)
(RES / 'drawable/jarvis_launcher_background_day.xml').write_text(background)

foreground = (RES / 'drawable/jarvis_launcher_foreground.xml').read_text()
assert '#8FDCEB' in foreground
(RES / 'drawable/jarvis_launcher_foreground_day.xml').write_text(foreground.replace('#8FDCEB', LIGHT_CYAN))

legacy = (RES / 'drawable/jarvis_launcher_legacy.xml').read_text()
assert '#242426' in legacy and '#08080A' in legacy and '#8FDCEB' in legacy
legacy = (
    legacy.replace('#242426', '#1860FF').replace('#08080A', '#00CDF5').replace('#8FDCEB', LIGHT_CYAN)
    .replace('android:endX="0" android:endY="72"', 'android:endX="72" android:endY="72"')
)
(RES / 'drawable/jarvis_launcher_legacy_day.xml').write_text(legacy)

# Launcher XML (default / day) ---------------------------------------------------------------------------------------
adaptive = RES / 'mipmap-anydpi-v26/ic_launcher.xml'
text = adaptive.read_text()
text = text.replace('@drawable/jarvis_launcher_background"', '@drawable/jarvis_launcher_background_day"')
text = text.replace('@drawable/jarvis_launcher_foreground"', '@drawable/jarvis_launcher_foreground_day"')
adaptive.write_text(text)
old = RES / 'mipmap-anydpi/ic_launcher.xml'
old.write_text(old.read_text().replace('@drawable/jarvis_launcher_legacy"', '@drawable/jarvis_launcher_legacy_day"'))

# Legacy PNGs --------------------------------------------------------------------------------------------------------
for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
    ring = round(size * 55.6 / 72 * LAUNCHER_SCALE)
    ink, cyan = art.masks(size, ring)
    art.vivid(ink, cyan).save(RES / f'mipmap-{density}/ic_launcher.png')
print('Android light launcher icon written')
