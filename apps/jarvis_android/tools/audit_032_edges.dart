import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/voice_page.dart';
import 'package:jarvis_android/ui/settings_page.dart';
import '../test/support.dart';
import '../test/voice_support.dart';
import '../test/voice_layout_test.dart' show LayoutApi;
void main(){testWidgets('Audit large-font controls and transcript geometry',(t)async{
 final out=Directory(Platform.environment['JARVIS_EDGE_AUDIT_DIR']??'/home/user/.local/state/jarvis-035-review/edge-captures')..createSync(recursive:true);
 await t.runAsync(()async{for(final f in [('Roboto','/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'),('MaterialIcons','/home/user/.local/opt/jarvis-flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')]){final font=FontLoader(f.$1)..addFont(Future.value(ByteData.sublistView(await File(f.$2).readAsBytes())));await font.load();}});
 t.view.devicePixelRatio=1;addTearDown(t.view.resetDevicePixelRatio);addTearDown(t.view.resetPhysicalSize);
 Future<void> frames([int n=40]) async {for(var i=0;i<n;i++){await t.pump(const Duration(milliseconds:16));}}
 final seed=JarvisController(FakeApi(),MemoryVault());await t.pumpWidget(JarvisApp(controller:seed));await frames();final theme=t.widget<MaterialApp>(find.byType(MaterialApp)).darkTheme!;await t.pumpWidget(const SizedBox());
 final notes=<Map<String,dynamic>>[];
 for(final size in [const Size(360,540),const Size(400,869),const Size(425,623),const Size(623,425),const Size(608,860),const Size(860,608)]){
  for(final scale in [1.0,1.5,2.0,2.5]){
   t.view.physicalSize=size;
   final c=JarvisController(LayoutApi(),MemoryVault(),audioDevice:FakeAudio());await c.initialize();await c.login('Audit','test');
   await t.runAsync(()=>c.voice.start(c.current));
   c.settings.messageFontSize=24;c.voice.lastYou='这是我的提问';c.voice.lastBot='这是一段用于审查字体与阅读区域的测试回答。';c.voice.error='麦克风暂时被其他应用占用，请恢复语音后继续对话';
   final key=GlobalKey();
   Widget screen(Widget child)=>RepaintBoundary(key:key,child:MaterialApp(theme:theme,debugShowCheckedModeBanner:false,builder:(context,child)=>MediaQuery(data:MediaQuery.of(context).copyWith(disableAnimations:true,textScaler:TextScaler.linear(scale)),child:child!),home:child));
   await t.pumpWidget(screen(VoicePage(controller:c)));await frames();
   final errors=<String>[];Object? error;while((error=t.takeException())!=null){errors.add(error.toString());}
   final transcript=t.getRect(find.byKey(const Key('voice-transcript')));
   final rows=t.widgetList<SelectableText>(find.byType(SelectableText)).map((w)=>{'font':w.style?.fontSize,'text':w.data}).toList();
   final name='${size.width.toInt()}x${size.height.toInt()}-${(scale*100).round()}';
   notes.add({'case':name,'transcript_height':transcript.height,'errors':errors,'fonts':rows.map((x)=>x['font']).toList()});
   if(scale==2.5||errors.isNotEmpty||transcript.height<24){await t.runAsync(()async{final image=await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();final data=await image.toByteData(format:ui.ImageByteFormat.png);File('${out.path}/voice-$name.png').writeAsBytesSync(data!.buffer.asUint8List());image.dispose();});}
   if(scale==2.0){await t.pumpWidget(screen(SettingsPage(controller:c)));await frames();while((error=t.takeException())!=null){notes.last['settings_error']=error.toString();}}
   await t.pumpWidget(const SizedBox());await t.runAsync(c.voice.stop);c.dispose();
  }
 }
 File('${out.path}/metrics.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(notes));
});}
