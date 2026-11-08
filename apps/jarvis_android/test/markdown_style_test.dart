import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jarvis_android/ui/markdown_palette.dart';
import 'package:jarvis_android/ui/markdown_style.dart';

Widget host(
  String data, {
  Brightness brightness = Brightness.dark,
  bool selectable = false,
}) => MaterialApp(
  theme: ThemeData(brightness: brightness, useMaterial3: true),
  home: Scaffold(
    body: Builder(
      builder: (context) => Align(
        alignment: Alignment.topLeft,
        child: MarkdownBody(
          data: data,
          selectable: selectable,
          styleSheet: chatMarkdownStyle(context, 16),
          builders: chatMarkdownBuilders(16),
        ),
      ),
    ),
  ),
);

Future<MarkdownStyleSheet> sheet(WidgetTester t, Brightness brightness) async {
  late MarkdownStyleSheet out;
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness, useMaterial3: true),
      home: Builder(
        builder: (context) {
          out = chatMarkdownStyle(context, 16);
          return const SizedBox();
        },
      ),
    ),
  );
  return out;
}

/// The style of the span that holds exactly [text] (the Markdown package nests it under the paragraph's own span).
TextStyle? styleOf(WidgetTester t, String text) {
  TextStyle? found;
  void walk(InlineSpan span) {
    if (span is! TextSpan) return;
    if (span.text == text) found = span.style;
    span.children?.forEach(walk);
  }

  for (final rich in t.widgetList<RichText>(find.byType(RichText))) {
    walk(rich.text);
  }
  return found;
}

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('Style sheet follows the iOS palette ($brightness)', (t) async {
      final dark = brightness == Brightness.dark;
      final s = await sheet(t, brightness);
      final accent = dark ? const Color(0xff8fdceb) : const Color(0xff137589);
      final line = dark ? const Color(0xff303036) : const Color(0xffdce3e1);
      final muted = dark ? const Color(0xffa1a1aa) : const Color(0xff3f484b);
      // Links: the cyan, underlined in the same full colour.
      expect(s.a!.color, accent);
      expect(s.a!.decorationColor, accent);
      expect(s.a!.decoration, TextDecoration.underline);
      // Rules and the quote bar: a 1 pt hairline / 3 px bar at full alpha.
      final rule = (s.horizontalRuleDecoration! as BoxDecoration).border!;
      expect((rule as Border).top.width, 1);
      expect(rule.top.color, line);
      final bar = (s.blockquoteDecoration! as BoxDecoration).border! as Border;
      expect(bar.left.color, line);
      expect(bar.left.width, 3);
      expect(s.blockquotePadding, const EdgeInsets.only(left: 14));
      expect(s.blockquote!.color, muted);
      expect(s.listBullet!.color, muted);
      // Body 1.6; headings semibold at 1.5 / 1.3 / 1.15 / 1.0.
      expect(s.p!.height, 1.6);
      expect(s.p!.fontSize, 16);
      expect(s.h1!.fontSize, 24);
      expect(s.h2!.fontSize, closeTo(20.8, .001));
      expect(s.h3!.fontSize, closeTo(18.4, .001));
      expect(s.h4!.fontSize, 16);
      for (final h in [s.h1, s.h2, s.h3, s.h4, s.h5, s.h6]) {
        expect(h!.fontWeight, FontWeight.w600);
      }
      expect(s.h1Padding!.top, 12);
      expect(s.h2Padding!.top, 12);
      expect(s.h3Padding!.top, 10);
      // Tables: radius 10, 1 pt border, horizontal row lines only, x0.95 text.
      final border = s.tableBorder!;
      expect(border.borderRadius, BorderRadius.circular(10));
      expect(border.top.width, 1);
      expect(border.top.color, line);
      expect(border.horizontalInside.color, line);
      expect(border.verticalInside, BorderSide.none);
      expect(s.tableBody!.fontSize, closeTo(15.2, .001));
      expect(
        s.tableCellsPadding,
        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      );
      expect(s.tableColumnWidth, isA<ClampedIntrinsicColumnWidth>());
    });
  }

  testWidgets('A rendered link and quote use the new colours', (t) async {
    await t.pumpWidget(host('[docs](https://example.test)\n\n---\n\n> quoted'));
    final link = styleOf(t, 'docs')!;
    expect(link.color, const Color(0xff8fdceb));
    expect(link.decorationColor, const Color(0xff8fdceb));
    final rules = t
        .widgetList<Container>(find.byType(Container))
        .where(
          (c) =>
              c.decoration is BoxDecoration &&
              (c.decoration! as BoxDecoration).border is Border &&
              ((c.decoration! as BoxDecoration).border! as Border).top.width ==
                  1,
        );
    expect(rules, isNotEmpty);
    expect(styleOf(t, 'quoted')!.color, const Color(0xffa1a1aa));
    expect(t.takeException(), isNull);
  });

  testWidgets('Headings step up in size', (t) async {
    await t.pumpWidget(host('# One\n\n## Two\n\n### Three\n\n#### Four'));
    expect(styleOf(t, 'One')!.fontSize, 24);
    expect(styleOf(t, 'Two')!.fontSize, closeTo(20.8, .001));
    expect(styleOf(t, 'Three')!.fontSize, closeTo(18.4, .001));
    expect(styleOf(t, 'Four')!.fontSize, 16);
    expect(styleOf(t, 'One')!.fontWeight, FontWeight.w600);
    expect(t.takeException(), isNull);
  });

  testWidgets('Table columns fit their content between 64 and 280', (t) async {
    final long = List.filled(60, '很长的内容').join();
    await t.pumpWidget(
      host('| a | b | c |\n|---|---|---|\n| x | y | $long |\n| 1 | 2 | 3 |'),
    );
    expect(t.takeException(), isNull);
    final render = t.renderObject<RenderTable>(find.byType(Table));
    expect(render.columns, 3);
    expect(render.row(0).elementAt(0).size.width, 64);
    expect(render.row(0).elementAt(1).size.width, 64);
    expect(render.row(0).elementAt(2).size.width, 280);
    // The table is as wide as its columns and scrolls sideways when the screen is narrower.
    expect(t.getSize(find.byType(Table)).width, 64 + 64 + 280);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
    // The header row is tinted with the table's own corner radius.
    final head =
        t.widget<Table>(find.byType(Table)).children.first.decoration!
            as BoxDecoration;
    expect(head.color, const Color(0xff1c1c20));
    expect(
      head.borderRadius,
      const BorderRadius.vertical(top: Radius.circular(10)),
    );
  });

  testWidgets('Selectable tables (as in the chat) measure their columns too', (
    t,
  ) async {
    await t.pumpWidget(
      host('| a | b |\n|---|---|\n| x | 长长长长长长长长长长长长 |', selectable: true),
    );
    expect(t.takeException(), isNull);
    final render = t.renderObject<RenderTable>(find.byType(Table));
    expect(render.row(0).first.size.width, 64);
    expect(find.byType(SingleChildScrollView), findsWidgets);
  });

  testWidgets('A wide table scrolls instead of overflowing', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(300, 600);
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final cell = List.filled(40, '宽').join();
    await t.pumpWidget(host('| $cell | $cell |\n|---|---|\n| $cell | $cell |'));
    expect(t.takeException(), isNull);
    final scroll = t.widget<SingleChildScrollView>(
      find.byType(SingleChildScrollView),
    );
    expect(scroll.scrollDirection, Axis.horizontal);
    expect(t.getSize(find.byType(Table)).width, greaterThan(300));
  });

  testWidgets('Code block: iOS metrics and the accent colour after copying', (
    t,
  ) async {
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => null,
    );
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        home: const Scaffold(
          body: CodeBlock(code: 'a\nb', language: 'dart', fontSize: 14),
        ),
      ),
    );
    final box = t.widget<Container>(
      find
          .descendant(
            of: find.byType(CodeBlock),
            matching: find.byType(Container),
          )
          .first,
    );
    final deco = box.decoration! as BoxDecoration;
    expect(deco.borderRadius, BorderRadius.circular(10));
    expect(deco.color, const Color(0xff1c1c20));
    // Header: 36 high; language label 12 at x = 14.
    final header = find
        .ancestor(of: find.text('dart'), matching: find.byType(SizedBox))
        .first;
    expect(t.getSize(header).height, 36);
    final label = t.widget<Text>(find.text('dart'));
    expect(label.style!.fontSize, 12);
    expect(label.style!.color, const Color(0xffa1a1aa));
    expect(
      t.getTopLeft(find.text('dart')).dx -
          t.getTopLeft(find.byType(CodeBlock)).dx,
      14,
    );
    // Code: line height 1.25.
    expect(
      t.widget<SelectableText>(find.byType(SelectableText)).style!.height,
      1.25,
    );
    expect(find.text('复制'), findsOneWidget);
    Color? buttonColor() => t
        .widget<TextButton>(find.byType(TextButton))
        .style!
        .foregroundColor!
        .resolve({});
    expect(buttonColor(), const Color(0xffa1a1aa));
    await t.tap(find.text('复制'));
    await t.pump(const Duration(milliseconds: 200));
    expect(find.text('已复制'), findsOneWidget);
    expect(buttonColor(), const Color(0xff8fdceb));
    await t.pump(const Duration(milliseconds: 1700));
    expect(find.text('复制'), findsOneWidget);
    expect(buttonColor(), const Color(0xffa1a1aa));
  });

  testWidgets('Palette follows the theme brightness', (t) async {
    late ChatPalette light;
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.light),
        home: Builder(
          builder: (context) {
            light = ChatPalette.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    expect(light.accent, const Color(0xff137589));
    expect(light.outlineVariant, const Color(0xffdce3e1));
    expect(light.onSurfaceVariant, const Color(0xff3f484b));
    expect(light.card, const Color(0xffffffff));
    expect(light.containerHigh, const Color(0xffedf0ef));
  });
}
