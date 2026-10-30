import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/voice_identity_stage.dart';
import 'package:jarvis_android/ui/login_art.dart';
void main(){testWidgets('Capture the single-reactor docking transition',(t)async{
 final output=Directory('/home/user/.local/state/jarvis-049-voice-motion')..createSync(recursive:true);
 await t.runAsync(() async {for(final f in [('Roboto','/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc')]){final font=FontLoader(f.$1)..addFont(Future.value(ByteData.sublistView(await File(f.$2).readAsBytes())));await font.load();}});
 t.view.devicePixelRatio=1;t.view.physicalSize=const Size(400,900);addTearDown(t.view.resetDevicePixelRatio);addTearDown(t.view.resetPhysicalSize);
 final compact=ValueNotifier(false),key=GlobalKey();
 await t.pumpWidget(RepaintBoundary(key:key,child:MaterialApp(debugShowCheckedModeBanner:false,theme:ThemeData.dark().copyWith(scaffoldBackgroundColor:const Color(0xff09090b)),home:Scaffold(body:Padding(padding:const EdgeInsets.all(20),child:ValueListenableBuilder(valueListenable:compact,builder:(_,value,_)=>VoiceIdentityStage(compact:value,windowHeight:900,identity:'demo',status:'正在聆听',hint:'按住按钮说话，松开发送',mode:ReactorMode.idle,onTap:(){},transcript:const Text('你好，我是贾维斯。'))))))));
 Future<void> capture(int i)async{await t.runAsync(()async{final b=key.currentContext!.findRenderObject()! as RenderRepaintBoundary;final image=await b.toImage();final data=await image.toByteData(format:ui.ImageByteFormat.png);File('${output.path}/frame-${i.toString().padLeft(2,'0')}.png').writeAsBytesSync(data!.buffer.asUint8List());image.dispose();});}
 await capture(0);compact.value=true;await t.pump();
 await t.pump(const Duration(milliseconds:240));await capture(1);await t.pump(const Duration(milliseconds:280));await capture(2);
 await t.pumpWidget(const SizedBox());compact.dispose();
});}
