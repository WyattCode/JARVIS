import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The App Store facts live in project files that no widget test exercises; these keep them from drifting back.
void main() {
  final plist = File('ios/Runner/Info.plist').readAsStringSync();
  final project = File('ios/Runner.xcodeproj/project.pbxproj')
      .readAsStringSync();

  test('the app targets iPhone only', () {
    final families = RegExp(r'TARGETED_DEVICE_FAMILY = ([^;]+);')
        .allMatches(project)
        .map((m) => m[1])
        .toSet();
    expect(families, {'1'});
    expect(plist, isNot(contains('UISupportedInterfaceOrientations~ipad')));
    expect(plist, contains('UIInterfaceOrientationPortrait'));
    expect(plist, contains('UIInterfaceOrientationLandscapeLeft'));
    expect(plist, contains('UIInterfaceOrientationLandscapeRight'));
  });

  test('Chinese is the development language and English is offered', () {
    expect(
      plist,
      contains(
        '<key>CFBundleDevelopmentRegion</key>\n\t<string>zh-Hans</string>',
      ),
    );
    expect(plist, contains('<key>CFBundleLocalizations</key>'));
    expect(project, contains('developmentRegion = "zh-Hans"'));
    expect(project, contains('"zh-Hans",\n\t\t\t\ten,'));
    expect(project, contains('InfoPlist.strings in Resources'));
  });

  test('each language names the app and explains the permissions', () {
    final zh = File('ios/Runner/zh-Hans.lproj/InfoPlist.strings')
        .readAsStringSync();
    final en = File('ios/Runner/en.lproj/InfoPlist.strings').readAsStringSync();
    for (final text in [zh, en]) {
      expect(text, contains('"CFBundleDisplayName" = "JARVIS";'));
      expect(text, contains('"NSMicrophoneUsageDescription"'));
      expect(text, contains('"NSPhotoLibraryAddUsageDescription"'));
    }
    expect(zh, contains('麦克风'));
    expect(en, contains('microphone'));
    // The base strings stay in Info.plist.
    expect(plist, contains('NSMicrophoneUsageDescription'));
    expect(plist, contains('NSPhotoLibraryAddUsageDescription'));
  });

  test('the only background mode is the voice call audio', () {
    final modes = RegExp(
      r'<key>UIBackgroundModes</key>\s*<array>(.*?)</array>',
      dotAll: true,
    ).firstMatch(plist)![1]!;
    expect(
      RegExp(r'<string>(.*?)</string>').allMatches(modes).map((m) => m[1]),
      ['audio'],
    );
  });
}
