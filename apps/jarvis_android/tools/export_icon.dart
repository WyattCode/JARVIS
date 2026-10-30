// Canonical export follows the user-approved B1 coil. Historical alternatives
// remain in export_minimal_icon.dart and are not the production entry point.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'render_platform_icons.dart' as platform;
import 'export_startup_reactor.dart' as startup;

void main() {
  platform.main();
  startup.main();
  test('Apply approved B1 platform resources', () async {
    final result = await Process.run('python3', ['tools/apply_coil_icon.py']);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
}
