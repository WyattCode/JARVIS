import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/main.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/jarvis_app.dart';
import 'package:jarvis_android/ui/media_widgets.dart';
import '../test/support.dart';
void main(){testWidgets('Capture compact undo notice on phone and inner screen',(t) async{
 final out=Directory('/home/user/.local/state/jarvis-051-notice')..createSync(recursive:true);
 await t.runAsync(() async {final f=FontLoader('Roboto')..addFont(Future.value(ByteData.sublistView(await File('/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc').readAsBytes())));await f.load();});
 t.view.devicePixelRatio=1;addTearDown(t.view.resetDevicePixelRatio);addTearDown(t.view.resetPhysicalSize);
 final seed=JarvisController(FakeApi(),MemoryVault());await t.pumpWidget(JarvisApp(controller:seed));await t.pump();final theme=t.widget<MaterialApp>(find.byType(MaterialApp)).darkTheme!;await t.pumpWidget(const SizedBox());
 for(final size in [const Size(400,869),const Size(860,608)]){
  t.view.physicalSize=size;final c=JarvisController(FakeApi(),MemoryVault());await c.initialize();final key=GlobalKey();
  await t.pumpWidget(RepaintBoundary(key:key,child:MaterialApp(theme:theme,home:JarvisHome(controller:c))));await t.pump();
  showNotice(t.element(find.byKey(const Key('chat-input'))),'会话已删除',compact:true,verticalOffset:size.width<600?5:0,duration:const Duration(milliseconds:1500),action:SnackBarAction(label:'撤销',onPressed:(){}));
  await t.pump();await t.pump(const Duration(milliseconds:300));
  await t.runAsync(() async{final boundary=key.currentContext!.findRenderObject()! as RenderRepaintBoundary;final image=await boundary.toImage();final bytes=await image.toByteData(format:ui.ImageByteFormat.png);File('${out.path}/notice-${size.width.toInt()}.png').writeAsBytesSync(bytes!.buffer.asUint8List());image.dispose();});
  await t.pumpWidget(const SizedBox());c.dispose();
 }
});}
