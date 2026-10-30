from pathlib import Path
import math,json,copy
root=Path(__file__).parent
source=json.loads((root.parent/'arc-reactor/derivatives/schemes.json').read_text())
triangle=copy.deepcopy(source['D-A']);triangle['parts']=[p for p in triangle['parts'] if p['type']!='line']
assert len(triangle['parts'])==3 and sum(p['type']=='polygon' for p in triangle['parts'])==2
items={
 'triangle':{'name':'JarvisTriangle','title':'三角环核','source':'D-A，去掉圆与三角之间三条连接线','parts':triangle['parts']},
 'coil':{'name':'JarvisCoil','title':'双线线圈','source':'用户选定的 B1／上一页 A-B 双线线圈','parts':copy.deepcopy(source['A-B']['parts'])}
}
WHITE='#ECF8FC';BLUE='#8FDCEB'
def path_d(p):
 if p['type']=='circle':
  r=p['r'];return f'M{54+r},54 A{r},{r} 0 1 0 {54-r},54 A{r},{r} 0 1 0 {54+r},54 Z'
 if p['type']=='line':return f'M{p["x1"]:.5f},{p["y1"]:.5f} L{p["x2"]:.5f},{p["y2"]:.5f}'
 if p['type']=='polygon':return 'M'+' L'.join(f'{x},{y}' for x,y in p['points'])+' Z'
 a,b=math.radians(p['start']),math.radians(p['end']);r=p['r'];large=int(p['end']-p['start']>180)
 return f'M{54+r*math.cos(a):.5f},{54+r*math.sin(a):.5f} A{r},{r} 0 {large} 1 {54+r*math.cos(b):.5f},{54+r*math.sin(b):.5f}'
def svg(parts,canvas=108,scale=1,mono=False):
 n=canvas/108*scale;shape=[]
 for p in parts:
  color='#FFFFFF' if mono else p['color']
  shape.append(f'<path fill="none" stroke="{color}" stroke-width="{p["width"]}" stroke-linecap="round" stroke-linejoin="round" d="{path_d(p)}"/>')
 return f'<svg xmlns="http://www.w3.org/2000/svg" width="{canvas}" height="{canvas}" viewBox="0 0 {canvas} {canvas}"><g transform="translate({canvas/2} {canvas/2}) scale({n}) translate(-54 -54)">'+''.join(shape)+'</g></svg>\n'
def vector(parts,extent=108,mono=False,bg=False):
 s=f'<?xml version="1.0" encoding="utf-8"?>\n<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="108dp" android:height="108dp" android:viewportWidth="{extent}" android:viewportHeight="{extent}">\n'
 if bg:s+='<path android:fillColor="#000000" android:pathData="M0,0H72V72H0Z"/>\n<group android:translateX="-18" android:translateY="-18">\n'
 for p in parts:
  color='#FFFFFF' if mono else p['color'];s+=f'<path android:fillColor="@android:color/transparent" android:strokeColor="{color}" android:strokeWidth="{p["width"]}" android:strokeLineCap="round" android:strokeLineJoin="round" android:pathData="{path_d(p)}"/>\n'
 if bg:s+='</group>\n'
 return s+'</vector>\n'
for key,item in items.items():
 out=root/key;out.mkdir(exist_ok=True)
 (out/'geometry.json').write_text(json.dumps(item,ensure_ascii=False,indent=2)+'\n')
 (out/'foreground.svg').write_text(svg(item['parts']))
 # Android resources are full, unmasked 108dp layers.
 res=out/'android/res'
 for d in ['drawable','mipmap-anydpi','mipmap-anydpi-v26','values']:(res/d).mkdir(parents=True,exist_ok=True)
 (res/'drawable/ic_launcher_foreground.xml').write_text(vector(item['parts']))
 (res/'drawable/ic_launcher_monochrome.xml').write_text(vector(item['parts'],mono=True))
 (res/'drawable/ic_launcher_legacy.xml').write_text(vector(item['parts'],extent=72,bg=True))
 (res/'drawable/ic_launcher_background.xml').write_text('<?xml version="1.0" encoding="utf-8"?>\n<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle"><solid android:color="#000000"/></shape>\n')
 (res/'mipmap-anydpi-v26/ic_launcher.xml').write_text('<?xml version="1.0" encoding="utf-8"?>\n<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android"><background android:drawable="@drawable/ic_launcher_background"/><foreground android:drawable="@drawable/ic_launcher_foreground"/><monochrome android:drawable="@drawable/ic_launcher_monochrome"/></adaptive-icon>\n')
 (res/'mipmap-anydpi/ic_launcher.xml').write_text('<?xml version="1.0" encoding="utf-8"?>\n<inset xmlns:android="http://schemas.android.com/apk/res/android" android:drawable="@drawable/ic_launcher_legacy" android:inset="0dp"/>\n')
 (out/'android/AndroidManifest.xml').write_text(f'<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="ai.jarvis.app.icon.{key}"><uses-sdk android:minSdkVersion="24" android:targetSdkVersion="36"/><application android:label="Jarvis {item["title"]}" android:icon="@mipmap/ic_launcher" android:roundIcon="@mipmap/ic_launcher"/></manifest>\n')
 (out/'android/foreground.svg').write_text(svg(item['parts']))
 (out/'android/monochrome.svg').write_text(svg(item['parts'],mono=True))
 # Layered Apple source: no baked masks, shadows or specular effects in artwork.
 icon=out/'macos'/f'{item["name"]}.icon';assets=icon/'Assets';assets.mkdir(parents=True,exist_ok=True)
 white=[p for p in item['parts'] if p['color']==WHITE];core=[p for p in item['parts'] if p['color']==BLUE]
 (assets/'01-Structure.svg').write_text(svg(white,1024,1.18))
 (assets/'02-Core.svg').write_text(svg(core,1024,1.18))
 groups=[]
 for number,name in [(1,'Structure'),(2,'Core')]:
  groups.append({'name':f'{number:02} {name}','layers':[{'fill':'none','glass':True,'hidden':False,'image-name':f'{number:02}-{name}.svg','name':name,'position':{'scale':1,'translation-in-points':[0,0]}}],'shadow':{'kind':'neutral','opacity':0.22},'translucency':{'enabled':False,'value':0.5}})
 cfg={'fill':{'solid':'srgb:0,0,0,1'},'color-space-for-untagged-svg-colors':'srgb','groups':groups,'supported-platforms':{'circles':[],'squares':'shared'}}
 (icon/'icon.json').write_text(json.dumps(cfg,indent=2)+'\n')
 (out/'macos/VALIDATION_PENDING.txt').write_text('Icon Composer source prepared on Linux. macOS 27 / Icon Composer 2.0 native open, export and Xcode compilation remain pending; this is not a native Apple-rendered validation result.\n')
(root/'selection.json').write_text(json.dumps(items,ensure_ascii=False,indent=2)+'\n')
print('Prepared two selections, native Android vectors and layered Icon Composer source packages')
