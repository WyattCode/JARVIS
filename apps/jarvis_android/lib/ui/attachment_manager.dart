import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../state/attachments.dart';
import '../state/jarvis_controller.dart';
import 'media_widgets.dart';

/// Owns feedback above the modal barrier, including asynchronous picker failures.
class AttachmentManager extends StatefulWidget {
  const AttachmentManager({
    super.key,
    required this.controller,
    required this.ownerId,
    required this.onAdd,
    required this.onDetachedError,
  });
  final JarvisController controller;
  final String ownerId;
  final Future<void> Function() onAdd;
  final ValueChanged<Object> onDetachedError;
  @override
  State<AttachmentManager> createState() => _AttachmentManagerState();
}

class _AttachmentManagerState extends State<AttachmentManager> {
  String? error;
  bool busy = false;

  Future<void> add() async {
    if (busy || widget.controller.current.id != widget.ownerId) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.onAdd();
    } catch (e) {
      if (mounted) {
        setState(() => error = attachmentErrorMessage(e));
      } else {
        widget.onDetachedError(e);
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: math.min(MediaQuery.sizeOf(context).height * .65, 440),
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final current = widget.controller.current;
          final sameOwner = current.id == widget.ownerId;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '已选附件',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: sameOwner && !busy ? add : null,
                    icon: const Icon(Icons.add, size: 18),
                    label: Text(busy ? '正在添加' : '添加附件'),
                  ),
                ],
              ),
              if (error != null && sameOwner)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Semantics(
                    liveRegion: true,
                    child: Material(
                      key: const Key('attachment-error'),
                      borderRadius: BorderRadius.circular(12),
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              error!,
                              style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onErrorContainer,
                              ),
                            ),
                            TextButton(
                              onPressed: busy ? null : add,
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (!sameOwner)
                const Padding(padding: EdgeInsets.all(20), child: Text('会话已切换'))
              else if (current.pendingAttachments.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text('没有已选附件'),
                )
              else
                for (final item in current.pendingAttachments)
                  AttachmentCard(
                    key: ValueKey('selected-${item.id}'),
                    controller: widget.controller,
                    item: item,
                    removable: true,
                    expanded: true,
                    onError: (value) => setState(() => error = value),
                  ),
            ],
          );
        },
      ),
    ),
  );
}
