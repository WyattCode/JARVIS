import '../model/conversation.dart';
import '../model/media.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../state/jarvis_controller.dart';
import 'page_palette.dart';
import 'picker_sheet.dart';
import 'settings_widgets.dart';

/// The voices of the speech engine in use, as a sheet: choose one, hear it,
/// close. It opens at half the window's height and can be drawn up to the
/// whole of it (the iOS sheet's medium and large detents).
Future<void> showVoicePicker(BuildContext context, JarvisController c) async {
  unawaited(c.refreshVoiceCatalog());
  try {
    await showPickerSheet<void>(
      context: context,
      builder: (context, scroll) => ListenableBuilder(
        listenable: Listenable.merge([c, c.voice]),
        builder: (context, _) => VoicePickerBody(c: c, scroll: scroll),
      ),
    );
  } finally {
    if (c.voice.previewing) unawaited(c.voice.stopPreview());
  }
}

/// What the voice sheet holds: a grabber, the title, the engine (when there is
/// more than one) and the voices of the engine in one card.
class VoicePickerBody extends StatelessWidget {
  const VoicePickerBody({super.key, required this.c, required this.scroll});
  final JarvisController c;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final p = PagePalette.of(context);
    final engines = c.models.where((m) => m.kind == 'speech').toList();
    final selected = engines
        .where((m) => m.id == c.settings.speechModel)
        .firstOrNull;
    final error = c.voice.error;
    return ListView(
      key: const Key('voice-picker'),
      controller: scroll,
      // Draggable even when the voices are few (or the sheet cannot be pulled
      // down to close).
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      children: [
        const PickerGrabber(),
        const PickerTitle('选择音色'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (engines.isEmpty)
                Text(
                  '请在设置中选择可用语音引擎',
                  style: TextStyle(color: p.onSurfaceVariant),
                )
              else ...[
                if (engines.length > 1) ...[
                  PageCard(
                    key: const Key('voice-engine-row'),
                    child: PickerRow<String>(
                      label: '语音引擎',
                      value: selected?.id,
                      options: [
                        for (final m in engines)
                          (m.id, displayModelName(m.name)),
                      ],
                      onSelected: (id) {
                        final engine = engines.firstWhere((m) => m.id == id);
                        c.changeSettings((s) {
                          s.speechModel = id;
                          s.voices.putIfAbsent(id, () => engine.defaultVoice);
                        });
                      },
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                if (selected == null)
                  Text(
                    '请在设置中选择可用语音引擎',
                    style: TextStyle(color: p.onSurfaceVariant),
                  )
                else
                  PageCard(
                    key: const Key('voice-list'),
                    child: Column(
                      children: [
                        for (var i = 0; i < selected.voices.length; i++) ...[
                          if (i > 0)
                            Divider(
                              height: .7,
                              thickness: .7,
                              indent: 16,
                              color: p.divider,
                            ),
                          VoiceRow(
                            key: ValueKey('voice-${selected.voices[i].id}'),
                            voice: selected.voices[i],
                            selected:
                                c.settings.voices[selected.id] ==
                                selected.voices[i].id,
                            loading:
                                c.voice.previewing &&
                                c.voice.previewVoice == selected.voices[i].id &&
                                !c.voice.speaking,
                            playing:
                                c.voice.previewing &&
                                c.voice.previewVoice == selected.voices[i].id &&
                                c.voice.speaking,
                            select: () => c.changeSettings(
                              (s) =>
                                  s.voices[selected.id] = selected.voices[i].id,
                            ),
                            play: () =>
                                c.voice.previewing &&
                                    c.voice.previewVoice ==
                                        selected.voices[i].id
                                ? c.voice.stopPreview()
                                : c.voice.playPreview(
                                    selected.voices[i],
                                    selected.id,
                                  ),
                          ),
                        ],
                      ],
                    ),
                  ),
                if (error != null && selected != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Text(
                      error,
                      key: const Key('voice-picker-error'),
                      style: TextStyle(fontSize: 13, color: p.error),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A voice in the card: a gutter with a check for the voice in use, its name
/// over its description, and a round button to hear it.
class VoiceRow extends StatelessWidget {
  const VoiceRow({
    super.key,
    required this.voice,
    required this.selected,
    required this.loading,
    required this.playing,
    required this.select,
    required this.play,
  });
  final VoiceInfo voice;
  final bool selected, loading, playing;
  final VoidCallback select;
  final VoidCallback play;

  @override
  Widget build(BuildContext context) {
    final p = PagePalette.of(context);
    final stopping = playing || loading;
    return Semantics(
      container: true,
      selected: selected,
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: select,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 15, 0, 15),
                child: Row(
                  children: [
                    SizedBox(
                      width: 32,
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 200),
                        opacity: selected ? 1 : 0,
                        child: Icon(
                          Icons.check,
                          key: ValueKey('voice-check-${voice.id}'),
                          size: 16,
                          color: p.accent,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            voice.name,
                            style: TextStyle(fontSize: 16, color: p.onSurface),
                          ),
                          if (voice.description.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              voice.description,
                              style: TextStyle(
                                fontSize: 13,
                                color: p.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Tooltip(
              message: stopping ? '停止试听 ${voice.name}' : '试听 ${voice.name}',
              child: Material(
                color: p.accent.withValues(alpha: .14),
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkResponse(
                  key: ValueKey('voice-preview-${voice.id}'),
                  onTap: play,
                  child: SizedBox.square(
                    dimension: 44,
                    child: Center(
                      child: loading
                          ? SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: p.accent,
                              ),
                            )
                          : Icon(
                              playing
                                  ? Icons.stop_rounded
                                  : Icons.play_arrow_rounded,
                              size: 20,
                              color: p.accent,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
