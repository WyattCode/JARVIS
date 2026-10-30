import 'dart:async';
import 'dart:math' as math;

import '../model/conversation.dart';

import 'package:flutter/material.dart';

import '../state/jarvis_controller.dart';
import 'design_tokens.dart';
import 'duo_layout.dart';
import 'settings_widgets.dart';

Future<void> showVoicePicker(BuildContext context, JarvisController c) async {
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      // The sheet draws its own surface and reads the call layout when it builds, so a fold change or a rotation while
      // it is open lays it out again instead of keeping what the window looked like at the tap.
      backgroundColor: Colors.transparent,
      elevation: 0,
      constraints: const BoxConstraints(maxWidth: double.infinity),
      builder: (context) => _PickerSheet(controller: c),
    );
  } finally {
    if (c.voice.previewing) unawaited(c.voice.stopPreview());
  }
}

/// The picker as a bottom sheet: centred (up to 640 wide) in the part of the window the content may use. That is the
/// window minus the system's vertical strip, or, half-folded in landscape, the part right of the fold.
class _PickerSheet extends StatelessWidget {
  const _PickerSheet({required this.controller});
  final JarvisController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller, colors = Theme.of(context).colorScheme;
    final duo = DuoLayoutScope.of(context);
    final size = MediaQuery.sizeOf(context),
        pad = MediaQuery.paddingOf(context);
    final pane = duo.sheetPane(size, pad);
    final width = math.min(640.0, pane.width);
    final left = pane.left + (pane.width - width) / 2;
    return Padding(
      padding: EdgeInsets.only(left: left, right: size.width - left - width),
      child: Material(
        color: colors.surface,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(Radii.sheet),
          ),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: duo.sheetMaxHeight(size, .78)),
          // The window's side insets belong to the pane above, not to the content. The home-indicator inset is the
          // list's bottom padding instead: the voices scroll on under the indicator rather than being cut at its line.
          child: SafeArea(
            top: false,
            left: false,
            right: false,
            bottom: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  label: '关闭音色选择',
                  button: true,
                  onTap: () => Navigator.of(context).pop(),
                  child: SizedBox(
                    width: 64,
                    height: 24,
                    child: Center(
                      child: Container(
                        width: 32,
                        height: 4,
                        decoration: BoxDecoration(
                          color: colors.onSurfaceVariant.withValues(alpha: .4),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
                // The title and the way out stay put while the voices scroll.
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    Metrics.pageMargin,
                    0,
                    8,
                    4,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(
                            '选择音色',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                      ),
                      TextButton(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(44, 44),
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('完成'),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: ListenableBuilder(
                    listenable: c,
                    builder: (context, _) => _voices(context),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _voices(BuildContext context) {
    final c = controller;
    final engines = c.models.where((m) => m.kind == 'speech').toList();
    final selected = engines
        .where((m) => m.id == c.settings.speechModel)
        .firstOrNull;
    final previewError = previewErrorOf(c.voice);
    // The same grouped card, engine row and voice rows as the settings page.
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.fromLTRB(
        Metrics.pageMargin,
        4,
        Metrics.pageMargin,
        20 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        if (selected == null)
          const SettingsGroup(
            children: [
              Padding(
                padding: EdgeInsets.all(16),
                child: Text('请在设置中选择可用语音引擎'),
              ),
            ],
          )
        else
          SettingsGroup(
            children: [
              if (engines.length > 1)
                PickerRow<String>(
                  label: '语音引擎',
                  value: selected.id,
                  options: [
                    for (final m in engines) (m.id, displayModelName(m.name)),
                  ],
                  onSelected: (id) {
                    final engine = engines.firstWhere((m) => m.id == id);
                    c.changeSettings((s) {
                      s.speechModel = id;
                      s.voices.putIfAbsent(id, () => engine.defaultVoice);
                    });
                  },
                ),
              for (final v in selected.voices)
                VoiceChoiceRow(
                  name: v.name,
                  description: v.description,
                  selected: c.settings.voices[selected.id] == v.id,
                  playing: VoicePreviewState.of(c.voice, v.id).playing,
                  loading: VoicePreviewState.of(c.voice, v.id).loading,
                  onSelect: () =>
                      c.changeSettings((s) => s.voices[selected.id] = v.id),
                  onPlay: () => VoicePreviewState.of(c.voice, v.id).stops
                      ? c.voice.stopPreview()
                      : c.voice.playPreview(v, selected.id),
                ),
            ],
          ),
        InlineError(
          previewError,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ],
    );
  }
}
