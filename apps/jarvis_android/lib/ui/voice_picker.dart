import '../model/conversation.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../state/jarvis_controller.dart';

Future<void> showVoicePicker(BuildContext context, JarvisController c) async {
  unawaited(c.refreshVoiceCatalog());
  try {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) {
            final engines = c.models.where((m) => m.kind == 'speech').toList();
            final selected = engines
                .where((m) => m.id == c.settings.speechModel)
                .firstOrNull;
            final rows = selected?.voices.length ?? 1;
            final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
            final desired =
                76 + (engines.length > 1 ? 92 : 0) + rows * 80 * scale;
            return SizedBox(
              height: math.min(
                MediaQuery.sizeOf(context).height * .78,
                desired,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    child: Text(
                      '选择音色',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (engines.length > 1)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: DropdownButtonFormField<String>(
                        style: Theme.of(context).textTheme.bodyLarge,
                        borderRadius: BorderRadius.circular(16),
                        dropdownColor: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHigh,
                        initialValue: selected?.id,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: '语音引擎'),
                        items: [
                          for (final m in engines)
                            DropdownMenuItem(
                              value: m.id,
                              child: Text(
                                displayModelName(m.name),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (id) {
                          if (id == null) return;
                          final engine = engines.firstWhere((m) => m.id == id);
                          c.changeSettings((s) {
                            s.speechModel = id;
                            s.voices.putIfAbsent(id, () => engine.defaultVoice);
                          });
                        },
                      ),
                    ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                      children: [
                        if (selected == null)
                          const ListTile(title: Text('请在设置中选择可用语音引擎')),
                        if (selected != null)
                          for (final v in selected.voices)
                            ListTile(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              selected: c.settings.voices[selected.id] == v.id,
                              selectedColor: Theme.of(context)
                                  .colorScheme
                                  .onSurface,
                              selectedTileColor: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHigh,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              leading: SizedBox.square(
                                dimension: 48,
                                child: Center(
                                  child: Icon(
                                    c.settings.voices[selected.id] == v.id
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_off,
                                    size: 22,
                                  ),
                                ),
                              ),
                              title: Text(v.name),
                              subtitle: v.description.isEmpty
                                  ? null
                                  : Text(v.description),
                              onTap: () => c.changeSettings(
                                (s) => s.voices[selected.id] = v.id,
                              ),
                              trailing: IconButton(
                                tooltip:
                                    c.voice.previewing &&
                                        c.voice.previewVoice == v.id
                                    ? '停止试听'
                                    : '试听 ${v.name}',
                                icon: Icon(
                                  c.voice.previewing &&
                                          c.voice.previewVoice == v.id
                                      ? Icons.stop_circle_outlined
                                      : Icons.volume_up_outlined,
                                  size: 22,
                                ),
                                onPressed: () =>
                                    c.voice.previewing &&
                                        c.voice.previewVoice == v.id
                                    ? c.voice.stopPreview()
                                    : c.voice.playPreview(v, selected.id),
                              ),
                            ),
                        if (c.voice.error != null)
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              c.voice.error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  } finally {
    if (c.voice.previewing) unawaited(c.voice.stopPreview());
  }
}
