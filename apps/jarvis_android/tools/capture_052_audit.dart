import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/media_widgets.dart';
import 'package:jarvis_android/ui/settings_page.dart';
import 'package:jarvis_android/ui/voice_page.dart';
import '../test/support.dart';
import '../test/voice_support.dart';
void main(){testWidgets('Capture current UI audit steps',(t) async{
 final phase=Platform.environment['AUDIT_PHASE']??'before';
 final out=Directory('/home/user/.local/state/jarvis-052-audit')..createSync(recursive:true);
 await t.runAsync(() async{for(final f in [('Roboto','/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'),('MaterialIcons','/home/user/.local/opt/jarvis-flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')]){final loader=FontLoader(f.$1)..addFont(Future.value(ByteData.sublistView(await File(f.$2).readAsBytes())));await loader.load();}});
 t.view.devicePixelRatio=1;addTearDown(t.view.resetDevicePixelRatio);addTearDown(t.view.resetPhysicalSize);
 final seed=JarvisController(FakeApi(),MemoryVault());await t.pumpWidget(JarvisApp(controller:seed));await t.pump();final theme=t.widget<MaterialApp>(find.byType(MaterialApp)).darkTheme!;await t.pumpWidget(const SizedBox());
 for(final step in ['login','undo','inner','inner-open','settings','voice','works']){
  final size=step.startsWith('inner')?const Size(860,608):step=='login'||step=='settings'?const Size(425,623):const Size(400,869);
  t.view.physicalSize=size;final c=JarvisController(FakeApi(),MemoryVault(),audioDevice:FakeAudio());await c.initialize();
  if(step=='login')c.error='登录已过期，请重新登录';
  if(step=='voice'){c.voice.owner=c.current;c.voice.open=true;c.voice.ready=true;c.voice.status='已就绪';c.voice.hint='按住按钮开始说话';}
  final key=GlobalKey();Widget page=switch(step){'login'=>LoginPage(controller:c),'settings'=>SettingsPage(controller:c),'voice'=>VoicePage(controller:c),_=>JarvisHome(controller:c)};
  await t.pumpWidget(RepaintBoundary(key:key,child:MaterialApp(debugShowCheckedModeBanner:false,theme:theme,home:page)));await t.pump();await t.pump(const Duration(milliseconds:600));
  if(step=='inner'){await t.tap(find.byTooltip('收起会话'));await t.pump();await t.pump(const Duration(milliseconds:300));}
  if(step=='works'){c.current.tasks.add(MediaTask(id:'audit-result',kind:'video',prompt:'测试作品：一段星空视频',args:{},status:'completed',urls:['https://example.test/audit.mp4']));c.notifyDraftSuggestion();await t.pump(const Duration(milliseconds:150));await t.pump(const Duration(milliseconds:350));}
  if(step=='undo'){showNotice(t.element(find.byKey(const Key('chat-input'))),'会话已删除',compact:true,verticalOffset:5,duration:const Duration(milliseconds:1500),action:SnackBarAction(label:'撤销',onPressed:(){}));await t.pump();await t.pump(const Duration(milliseconds:300));}
  await t.runAsync(() async{final boundary=key.currentContext!.findRenderObject()! as RenderRepaintBoundary;final image=await boundary.toImage();final bytes=await image.toByteData(format:ui.ImageByteFormat.png);File('${out.path}/$phase-$step.png').writeAsBytesSync(bytes!.buffer.asUint8List());image.dispose();});
  expect(t.takeException(),isNull);await t.pumpWidget(const SizedBox());c.dispose();
 }
});}
