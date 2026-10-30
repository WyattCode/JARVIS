"""Apply the user-approved B1 artwork; preserve manifest and app identity."""
from pathlib import Path
from PIL import Image, ImageDraw
import shutil
import xml.etree.ElementTree as ET
LAUNCHER_SCALE = 0.84
ANDROID = "http://schemas.android.com/apk/res/android"
ET.register_namespace("android", ANDROID)
AAPT = "http://schemas.android.com/aapt"
ET.register_namespace("aapt", AAPT)
def plate(size):
 image = Image.new('RGBA', (size, size));draw = ImageDraw.Draw(image)
 for y in range(size):
  t = y / max(1, size-1)
  color = tuple(round(a+(b-a)*t) for a,b in zip((36,36,38),(8,8,10))) + (255,)
  draw.line((0,y,size,y), fill=color)
 return image
root=Path(__file__).resolve().parent.parent
source=root/'design/icon/platform-candidates/coil/android'
res=root/'android/app/src/main/res'
for kind in ['foreground','monochrome','legacy']:
 tree = ET.parse(source/f'res/drawable/ic_launcher_{kind}.xml')
 node = tree.getroot()
 if kind == 'legacy':
  background = node.find('path');background.attrib.pop(f'{{{ANDROID}}}fillColor', None)
  attr = ET.SubElement(background, f'{{{AAPT}}}attr', {'name':'android:fillColor'})
  ET.SubElement(attr, 'gradient', {f'{{{ANDROID}}}startX':'0', f'{{{ANDROID}}}startY':'0', f'{{{ANDROID}}}endX':'0', f'{{{ANDROID}}}endY':'72', f'{{{ANDROID}}}startColor':'#242426', f'{{{ANDROID}}}endColor':'#08080A', f'{{{ANDROID}}}type':'linear'})
 # The legacy icon has an outer crop translation and a full-size black plate.
 target = node.find('group') if kind == 'legacy' else node
 assert target is not None
 children = list(target)
 group = ET.Element('group', {f'{{{ANDROID}}}pivotX': '54', f'{{{ANDROID}}}pivotY': '54', f'{{{ANDROID}}}scaleX': str(LAUNCHER_SCALE), f'{{{ANDROID}}}scaleY': str(LAUNCHER_SCALE)})
 for child in children:
  target.remove(child);group.append(child)
 target.append(group)
 tree.write(res/f'drawable/jarvis_launcher_{kind}.xml', encoding='utf-8', xml_declaration=True)
# Native launch art is exported separately by export_startup_reactor.dart.
# Changing the desktop icon must not replace the in-app reactor artwork.
for qualifier in ['mipmap-anydpi', 'mipmap-anydpi-v26']:
 target=res/qualifier.replace('mipmap-', 'mipmap-night-');target.mkdir(exist_ok=True)
 shutil.copy2(res/qualifier/'ic_launcher.xml',target/'ic_launcher.xml')
(res/'drawable/jarvis_launcher_background.xml').write_text('<?xml version="1.0" encoding="utf-8"?><shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle"><gradient android:angle="270" android:startColor="#242426" android:endColor="#08080A"/></shape>')
for qualifier in ['mipmap-anydpi-v26', 'mipmap-night-anydpi-v26']:
 p=res/qualifier/'ic_launcher.xml'
 p.write_text(p.read_text().replace('@color/jarvis_icon_background','@drawable/jarvis_launcher_background'))
with Image.open(source/'foreground-432.png').convert('RGBA') as fg:
 art = fg.crop((72,72,360,360))
 for density, size in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
  pixels=round(size*LAUNCHER_SCALE);scaled=art.resize((pixels,pixels),Image.Resampling.LANCZOS)
  for prefix in ['mipmap','mipmap-night']:
   background=plate(size);background.alpha_composite(scaled,((size-pixels)//2,(size-pixels)//2))
   background.save(res/f'{prefix}-{density}/ic_launcher.png')
 # A full-square publication master, without a baked launcher mask or shadow.
 pixels=round(512*LAUNCHER_SCALE);scaled=art.resize((pixels,pixels),Image.Resampling.LANCZOS)
 background=plate(512);background.alpha_composite(scaled,((512-pixels)//2,(512-pixels)//2))
 background.save(root/'design/icon/launcher-B1-027.png')
with Image.open(source/'foreground-432.png') as image:
 image.crop((72,72,360,360)).resize((512,512),Image.Resampling.LANCZOS).save(root/'assets/jarvis-icon-night.png')
shutil.copy2(root/'assets/jarvis-icon-night.png',root/'assets/jarvis-icon-day.png')
for name in ['drawable/jarvis_brand.png','drawable-nodpi/jarvis_icon_art.png','drawable-night-nodpi/jarvis_icon_art.png']:
 shutil.copy2(root/'assets/jarvis-icon-night.png',res/name)
print('Applied user-selected B1 double coil to Android launcher, splash and brand assets')
