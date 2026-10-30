import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/voice_page.dart';
import '../test/support.dart';
import '../test/voice_support.dart';
import '../test/voice_layout_test.dart' show LayoutApi;
void main(){testWidgets('Capture assistant expression in the production tall-phone voice page',(t)async{
 final out=Directory('/home/user/.local/state/jarvis-audit-032-current/expression')..createSync(recursive:true);
 await t.runAsync(()async{for(final f in [('Roboto','/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'),('MaterialIcons','/home/user/.local/opt/jarvis-flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')]){final font=FontLoader(f.$1)..addFont(Future.value(ByteData.sublistView(await File(f.$2).readAsBytes())));await font.load();}});
 t.view.devicePixelRatio=1;t.view.physicalSize=const Size(400,869);addTearDown(t.view.resetDevicePixelRatio);addTearDown(t.view.resetPhysicalSize);
 final seed=JarvisController(FakeApi(),MemoryVault());await t.pumpWidget(JarvisApp(controller:seed));await t.pump();final theme=t.widget<MaterialApp>(find.byType(MaterialApp)).darkTheme!;await t.pumpWidget(const SizedBox());
 final c=JarvisController(LayoutApi(),MemoryVault(),audioDevice:FakeAudio());await c.initialize();c.voice.ready=true;c.voice.lastYou='请介绍一下贾维斯。';c.voice.lastBot='我是贾维斯，可以陪你聊天，也可以帮助你分析问题、整理资料和创作内容。';c.voice.speaking=true;c.voice.status='正在说话';c.voice.hint='随时可以打断我';final key=GlobalKey();
 await t.pumpWidget(RepaintBoundary(key:key,child:MaterialApp(theme:theme,debugShowCheckedModeBanner:false,home:VoicePage(controller:c))));await t.pump(const Duration(milliseconds:500));
 for(var i=0;i<18;i++){await t.pump(const Duration(milliseconds:80));expect(t.takeException(),isNull);await t.runAsync(()async{final image=await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();final data=await image.toByteData(format:ui.ImageByteFormat.png);File('${out.path}/frame-${i.toString().padLeft(2,'0')}.png').writeAsBytesSync(data!.buffer.asUint8List());image.dispose();});}
 await t.pumpWidget(const SizedBox());c.dispose();
});}
