import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/model/media.dart';
import 'package:jarvis_android/state/jarvis_controller.dart';
import 'package:jarvis_android/ui/media_widgets.dart';

import 'support.dart';

void main() {
  cardTests();
  Future<JarvisController> controller() async {
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    addTearDown(c.dispose);
    return c;
  }

  test(
    'a video call stays a video when job events carry no ids or kind',
    () async {
      final c = await controller();
      final owner = c.current;
      c.voiceTask(owner, {
        'type': 'call',
        'call_id': 'call_1',
        'name': 'generate_video',
        'arguments': '{"prompt":"一只猫"}',
      });
      c.voiceTask(owner, {
        'type': 'localrouter.job.created',
        'job_id': 'job_9',
      });
      c.voiceTask(owner, {
        'type': 'localrouter.job.done',
        'job_id': 'job_9',
        'status': 'completed',
      });
      expect(owner.tasks, hasLength(1));
      final task = owner.tasks.single;
      expect(task.kind, 'video');
      expect(task.status, 'completed');
      expect(task.urls, ['/v1/videos/job_9/content']);
    },
  );

  test('an unnamed task is recognised as video from its result address', () {
    final task = MediaTask(
      id: 't',
      kind: 'image',
      prompt: '',
      args: {},
      urls: ['/v1/videos/abc/content'],
    )..settleKind();
    expect(task.kind, 'video');
    final stored = MediaTask.fromJson({...task.toJson(), 'kind': 'image'});
    expect(stored.kind, 'video');
    expect(
      (MediaTask(
        id: 'i',
        kind: 'image',
        prompt: '',
        args: {},
        urls: ['/v1/files/x.png'],
      )..settleKind()).kind,
      'image',
    );
  });
}

void cardTests() {
  testWidgets('a finished video card shows a play cover and labelled actions', (
    t,
  ) async {
    final c = JarvisController(FakeApi(), MemoryVault());
    await c.initialize();
    addTearDown(c.dispose);
    final task = MediaTask(
      id: 'v',
      kind: 'video',
      prompt: '一只猫',
      args: {},
      status: 'completed',
      urls: ['/v1/videos/job_9/content'],
    );
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaCard(task: task, controller: c),
        ),
      ),
    );
    await t.pump();
    expect(find.byType(VideoCover), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    expect(find.text('图片任务'), findsNothing);
    expect(find.text('复制提示词'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
    final copy = t.getTopLeft(find.text('复制提示词')).dx;
    final save = t.getTopLeft(find.text('下载')).dx;
    expect(copy, lessThan(save));
  });
}
