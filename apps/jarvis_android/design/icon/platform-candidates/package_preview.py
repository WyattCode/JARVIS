from pathlib import Path
from PIL import Image
import json, shutil, zipfile, hashlib
root=Path(__file__).resolve().parent
web=Path('/home/user/jarvis/icon-preview')
selection=json.loads((root/'selection.json').read_text())
readme='''# Jarvis 平台图标候选

两款尚未替换生产应用图标。三角款移除外圈和三角之间的三条连接线，保留原内外三角；双线线圈保持选定图形。

Android：android/res 为自适应图标资源，包含独立背景、108dp 前景和 monochrome 图层；主体位于中心 66dp 安全区。五档 PNG 为旧版启动器兼容资源，play-store-512.png 为完整正方形商店素材。AndroidManifest.xml 是资源验证示例，集成已有应用时请仅合并资源及 icon/roundIcon 引用，勿覆盖应用 manifest。已使用 Android SDK 36 aapt2 编译和链接验证；未执行真机安装验证。

macOS 27：macos/*.icon 为分层 Icon Composer 工程候选，1024×1024 SVG 图层不含烘焙圆角、阴影或高光。请在 Mac 上用 Icon Composer 2 打开，核查图层、默认/深色/单色外观及 27 渲染，再导入 Xcode 27 的目标工程编译验证。当前 Linux 主机无法运行这些 Apple 工具，故原生校验尚未完成，不作已符合全部 macOS 27 要求的声明。兼容目录提供实际 ICNS、十尺寸 iconset 和 AppIcon.appiconset，可用于传统图标接入；不能替代现代分层工程的校验。

preview 下 PNG 为平台外形/材质模拟，非 Apple 原生截图，不应当作 Icon Composer 的源图层。Android 的最终遮罩、主题色和动态效果由启动器决定。

官方依据：
- https://developer.apple.com/design/human-interface-guidelines/app-icons
- https://developer.apple.com/icon-composer/
- https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer
- https://developer.android.google.cn/develop/ui/compose/system/icon_design_adaptive
'''
for key,item in selection.items():
 out=root/key;name=item['name'];compat=out/'macos/compatibility';iconset=compat/f'{name}.iconset'
 imgs=[Image.open(iconset/f'icon_{n}x{n}.png').convert('RGBA') for n in [32,128,256,512]]
 imgs += [Image.open(iconset/'icon_32x32@2x.png').convert('RGBA'),Image.open(iconset/'icon_512x512@2x.png').convert('RGBA')]
 master=Image.open(iconset/'icon_512x512@2x.png').convert('RGBA')
 master.save(compat/f'{name}.icns',format='ICNS',append_images=imgs)
 icns=Image.open(compat/f'{name}.icns');icns.load();assert icns.size==(1024,1024)
 appicon=compat/'Assets.xcassets/AppIcon.appiconset';appicon.mkdir(parents=True,exist_ok=True)
 entries=[]
 for size in [16,32,128,256,512]:
  for scale in [1,2]:
   filename=f'icon_{size}x{size}'+('@2x' if scale==2 else '')+'.png'
   image=Image.open(iconset/filename);assert image.size==(size*scale,size*scale)
   shutil.copy2(iconset/filename,appicon/filename)
   entries.append({'idiom':'mac','size':f'{size}x{size}','scale':f'{scale}x','filename':filename})
 (appicon/'Contents.json').write_text(json.dumps({'images':entries,'info':{'author':'xcode','version':1}},indent=2)+'\n')
 (out/'README.md').write_text(readme)
 manifest=json.loads((out/'macos'/f'{name}.icon/icon.json').read_text())
 for group in manifest['groups']:
  for layer in group['layers']:assert (out/'macos'/f'{name}.icon/Assets'/layer['image-name']).is_file()
 for layer in ['structure','core']:
  image=Image.open(out/f'macos/layers/{layer}-1024.png');assert image.size==(1024,1024) and image.getextrema()[-1][0]==0
 if key=='triangle':assert all(p['type']!='line' for p in item['parts'])
 (out/'validation.json').write_text(json.dumps({'android_aapt2_compile_and_link':True,'android_device_install_test':False,'macos_native_composer_xcode_validation':False,'icns_decode':True,'iconset_dimensions':True,'layer_references_exist':True,'triangle_connectors_removed':key=='triangle'},indent=2)+'\n')
 dest=web/'platform-icons'/key
 if dest.exists():shutil.copytree(out,dest,dirs_exist_ok=True)
 else:shutil.copytree(out,dest)
 archive=web/f'{name}-Platform-Icons.zip'
 with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
  for f in sorted(out.rglob('*')):
   if f.is_file():z.write(f,Path(name)/f.relative_to(out))
 with zipfile.ZipFile(archive) as z:assert z.testzip() is None
 print(key,archive.stat().st_size,hashlib.sha256(archive.read_bytes()).hexdigest())
old=web/'reactor-six.html'
if not old.exists():shutil.copy2(web/'index.html',old)
head='''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark"><title>Jarvis · 两款平台图标</title><style>
*{box-sizing:border-box}body{margin:0;background:#080e17;color:#edf6fc;font:15px/1.6 system-ui,-apple-system,sans-serif}main{max-width:1100px;margin:auto;padding:40px 22px 60px}header p{color:#a5b6c8;max-width:820px}h1{font-size:clamp(26px,4vw,40px);letter-spacing:-1px;margin:0}h2{margin:0;font-size:23px}.eyebrow{color:#8fdceb;font-size:12px;letter-spacing:3px}.grid{display:grid;grid-template-columns:1fr 1fr;gap:24px;margin-top:26px}article{border:1px solid #263444;background:#101a27;border-radius:24px;overflow:hidden}.intro{padding:24px 24px 0}.muted{color:#a5b6c8;font-size:13px}.hero{display:flex;justify-content:center;padding:30px 20px 24px;background:radial-gradient(ellipse at center,#23405755,transparent 68%)}.hero img{width:230px;max-width:70%;height:auto;filter:drop-shadow(0 20px 16px #0005)}.sizes{display:flex;justify-content:center;align-items:center;gap:26px;height:98px;background:#ffffff05}.sizes figure{margin:0;text-align:center}.sizes img{display:block;margin:auto}.sizes figcaption{color:#90a6bb;font-size:10px;margin-top:3px}.controls{display:flex;flex-wrap:wrap;gap:6px;margin:24px 0 10px}button,a.link{border:1px solid #324559;border-radius:11px;padding:9px 13px;font:inherit;color:#c7dbea;background:#121f2f;cursor:pointer}button[aria-pressed=true]{background:#d0f3fb;color:#0b1b29;border-color:#d0f3fb}a{color:#9cdeef}a.link{display:inline-block;text-decoration:none}.downloads{padding:20px 24px;display:flex;gap:10px;flex-wrap:wrap}.dock{display:flex;align-items:center;justify-content:center;gap:18px;border:1px solid #ffffff20;border-radius:22px;padding:13px;margin:12px auto 26px;width:max-content;background:#ffffff0a}.dock img{width:62px;height:62px}.dummy{width:50px;height:50px;border-radius:13px;background:linear-gradient(150deg,#496a7a,#1c2c40);display:grid;place-items:center;color:#d8eef9;font-size:24px}.notes{margin-top:28px;padding:20px;border:1px solid #263444;border-radius:16px;color:#9cafc1}footer{margin-top:22px;font-size:13px;color:#96a8ba}@media(max-width:650px){main{padding:26px 16px}.grid{grid-template-columns:1fr;gap:18px}.hero{padding:22px}.hero img{width:210px}.intro{padding:20px 20px 0}button{font-size:13px}.dock img{width:55px;height:55px}}
</style><main><header><div class="eyebrow">JARVIS / APP ICONS</div><h1>从线稿，到真正的应用图标。</h1><p>保留你选定的两个方向，放进平台图标外形与桌面场景，并提供可接入项目的文件。黑色底板、冷白结构、冰蓝核心。</p></header><div class="controls" role="group" aria-label="平台预览"><button data-mode="macos" aria-pressed="true">macOS</button><button data-mode="android-rounded" aria-pressed="false">Android 圆角</button><button data-mode="android-circle" aria-pressed="false">Android 圆形</button><button data-mode="android-themed" aria-pressed="false">Android 主题色</button></div><p id="caption" class="muted">macOS 27 材质效果模拟 · 原生 Icon Composer / Xcode 校验待完成</p><div class="grid">'''
cards=[]
for key,item in selection.items():
 base=f'platform-icons/{key}';name=item['name']
 desc='去掉圆与大三角之间三条连接线，保留内外三角。' if key=='triangle' else '保留 B1（上一页 A-B）双线线圈与圆形核心。'
 sizes=''.join(f'<figure><img class="icon" data-key="{key}" data-size="{n}" src="{base}/preview/macos-{n}.png" width="{n}" height="{n}" alt="{n}像素图标"><figcaption>{n} px</figcaption></figure>' for n in [48,96])
 cards.append(f'''<article><div class="intro"><div class="eyebrow">{'A / TRIANGLE' if key=='triangle' else 'B / DOUBLE COIL'}</div><h2>{item['title']}</h2><p class="muted">{desc}</p></div><div class="hero"><img class="icon" data-key="{key}" data-size="512" src="{base}/preview/macos-512.png" width="512" height="512" alt="{item['title']}应用图标"></div><div class="sizes">{sizes}</div><p class="muted" style="text-align:center">桌面 / Dock 场景示意</p><div class="dock"><span class="dummy" aria-hidden="true">⌘</span><img class="icon" data-key="{key}" data-size="96" src="{base}/preview/macos-96.png" alt="Jarvis 图标"><span class="dummy" aria-hidden="true">＋</span></div><div class="downloads"><a class="link" href="{name}-Platform-Icons.zip" download>下载完整图标包</a><a class="link" href="{base}/macos/compatibility/{name}.icns" download>ICNS</a><a class="link" href="{base}/android/play-store-512.png" download>512 PNG</a></div></article>''')
tail='''</div><div class="notes"><strong>文件已准备，平台校验进度分开列出</strong><p>Android：独立前景 / 背景 / 单色层、五档旧版 PNG，SDK 36 资源编译和链接已通过。最终遮罩与主题色由系统决定。</p><p>macOS：提供 1024 分层 .icon 工程候选、十尺寸 .iconset、兼容 .icns 与 AppIcon 资源目录。本机为 Linux，无法运行 Icon Composer 2 / Xcode 27；需要在 Mac 上完成原生打开、外观检查和编译。这里的材质与 Dock 为模拟预览，不是原生截图。</p><p>两款均未替换当前应用的启动图标。</p></div><footer><a href="reactor-six.html">回看上一轮六款</a> · <a href="https://developer.apple.com/design/human-interface-guidelines/app-icons">Apple 图标规范</a> · <a href="https://developer.apple.com/icon-composer/">Icon Composer</a> · <a href="https://developer.android.google.cn/develop/ui/compose/system/icon_design_adaptive">Android 自适应图标规范</a></footer></main><script>
const labels={macos:'macOS 27 材质效果模拟 · 原生 Icon Composer / Xcode 校验待完成','android-rounded':'Android 自适应图标 · 圆角遮罩示意','android-circle':'Android 自适应图标 · 圆形遮罩示意','android-themed':'Android 单色层 · 系统主题色示意'};
document.querySelectorAll('button[data-mode]').forEach(b=>b.addEventListener('click',()=>{const mode=b.dataset.mode;document.querySelectorAll('button[data-mode]').forEach(x=>x.setAttribute('aria-pressed',String(x===b)));document.querySelectorAll('img.icon').forEach(x=>{const size=mode==='android-themed'?512:x.dataset.size;x.src=`platform-icons/${x.dataset.key}/preview/${mode}-${size}.png`;});document.querySelector('#caption').textContent=labels[mode];}));
</script></html>'''
temp=web/'index.new.html';temp.write_text(head+''.join(cards)+tail);temp.replace(web/'index.html')
print('Published',web)
