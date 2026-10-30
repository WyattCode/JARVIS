import 'dart:io';
import 'dart:ui' as ui;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/model/conversation.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/settings_page.dart';
import '../test/support.dart';
class CatalogApi extends FakeApi {
 @override Future<List<ModelInfo>> models()async=>[
  ModelInfo('chat','Qwen3.8-Flash-Next'),
  ModelInfo.fromJson({'id':'fishaudio/drama-3','name':'Drama 3','kind':'speech','default_voice':'Mae','voices':[
   for(final v in [('Mae','Mae'),('Arlo','Arlo'),('Ezra','Ezra'),('Nora','Nora'),('Theo','Theo'),('Wren','Wren'),('zh-xingheng','Atlas'),('zh-jingchuan','Rowan'),('zh-qinglan','Iris'),('zh-yuexi','Luna')])
    {'id':v.$1,'name':v.$2,'description':'固定音色 · 保留用户选择'},
  ]}),
 ];
}
void main(){testWidgets('Capture all redesigned settings sections',(t)async{
 final output=Directory('/home/user/.local/state/jarvis-audit-032-current/settings-final')..createSync(recursive:true);
 await t.runAsync(()async{for(final f in [('Roboto','/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc'),('MaterialIcons','/home/user/.local/opt/jarvis-flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')]){final font=FontLoader(f.$1)..addFont(Future.value(ByteData.sublistView(await File(f.$2).readAsBytes())));await font.load();}});
 t.view.devicePixelRatio=1;addTearDown(t.view.resetDevicePixelRatio);addTearDown(t.view.resetPhysicalSize);
 Future<void> frames([int n=35])async{for(var i=0;i<n;i++){await t.pump(const Duration(milliseconds:16));}}
 final seed=JarvisController(FakeApi(),MemoryVault());await t.pumpWidget(JarvisApp(controller:seed));await frames();final theme=t.widget<MaterialApp>(find.byType(MaterialApp)).darkTheme!;await t.pumpWidget(const SizedBox());
 final notes=<Map<String,dynamic>>[];
 for(final profile in [('ultra',400.0,869.0),('outer',425.0,623.0),('inner',860.0,608.0)]){
  for(final scale in [1.0,2.5]){
   t.view.physicalSize=Size(profile.$2,profile.$3);final key=GlobalKey();final c=JarvisController(CatalogApi(),MemoryVault());await c.initialize();await c.login('Audit','test');
   await t.pumpWidget(RepaintBoundary(key:key,child:MaterialApp(theme:theme,debugShowCheckedModeBanner:false,builder:(context,child)=>MediaQuery(data:MediaQuery.of(context).copyWith(textScaler:TextScaler.linear(scale),disableAnimations:true),child:child!),home:SettingsPage(controller:c))));await frames();
   final name='${profile.$1}-${(scale*100).round()}';
   Future<void> margin()async{final scroll=t.state<ScrollableState>(find.descendant(of:find.byKey(const Key('settings-scroll')),matching:find.byType(Scrollable)).first);scroll.position.jumpTo((scroll.position.pixels-24*scale).clamp(0.0,scroll.position.maxScrollExtent));await frames(3);}

   Future<void> capture(String step)async{
    final errors=<String>[];Object? e;while((e=t.takeException())!=null){errors.add(e.toString());}notes.add({'case':name,'step':step,'errors':errors});
    await t.runAsync(()async{final img=await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary).toImage();final data=await img.toByteData(format:ui.ImageByteFormat.png);File('${output.path}/$name-$step.png').writeAsBytesSync(data!.buffer.asUint8List());img.dispose();});
   }
   await capture('01-top');await t.ensureVisible(find.text('Atlas'));await frames();await margin();await capture('02-voices');
   final field=find.byWidgetPredicate((w)=>w is TextField&&w.decoration?.labelText=='回复长度上限（Token）');
   await t.ensureVisible(field);await frames();await t.enterText(field,'1');await frames();await margin();await capture('03-validation');await t.enterText(field,'');await frames();
   await t.ensureVisible(find.text('退出登录'));await frames();await margin();await capture('04-advanced');
   await t.pumpWidget(const SizedBox());c.dispose();
  }
 }
 File('${output.path}/metrics.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(notes));
});}
