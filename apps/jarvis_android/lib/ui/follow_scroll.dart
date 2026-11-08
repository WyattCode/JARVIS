import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/widgets.dart';

/// Follow newly laid-out content (including decoded images), until the user
/// scrolls away. Programmatic/layout changes must not count as user scrolling.
class FollowScrollController extends ScrollController {
  FollowScrollController({this.onFollowingChanged});
  final ValueChanged<bool>? onFollowingChanged;
  final following = ValueNotifier<bool>(true);
  bool get isFollowing => _following;
  bool _following = true, _scheduled = false, _closed = false;

  int _keyboardRevision = 0, _interactionRevision = 0;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _TailPosition(
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    shouldFollow: () => _following && !_closed,
  );

  /// Follow the tail through IME changes; keep historical reading offsets fixed.
  void keyboardChanged() {
    if (_closed || !hasClients || !position.hasContentDimensions) return;
    final oldOffset = offset;
    final keyboardRevision = ++_keyboardRevision;
    final interactionRevision = _interactionRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_closed ||
          !hasClients ||
          keyboardRevision != _keyboardRevision ||
          interactionRevision != _interactionRevision) {
        return;
      }
      final target = _following ? position.maxScrollExtent : oldOffset;
      jumpTo(target.clamp(position.minScrollExtent, position.maxScrollExtent));
    });
  }

  void _setFollowing(bool value) {
    if (_following == value) return;
    _following = value;
    onFollowingChanged?.call(value);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_closed) following.value = _following;
    });
  }

  void pauseFollowing() => _setFollowing(false);

  void resumeFollowing() {
    _setFollowing(true);
    followLatest();
  }

  /// The way back to the newest words: it runs there over a quarter of a
  /// second instead of jumping.
  Future<void> animateToLatest() async {
    _setFollowing(true);
    if (_closed || !hasClients) return;
    await animateTo(
      position.maxScrollExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
    followLatest();
  }

  void followLatest() {
    if (_closed || !_following || _scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_closed && _following && hasClients) {
        jumpTo(position.maxScrollExtent);
      }
    });
  }

  bool _scroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _interactionRevision++;
    }
    if (n is UserScrollNotification && n.direction == ScrollDirection.forward) {
      _setFollowing(false);
    } else if (n is ScrollUpdateNotification && n.dragDetails != null) {
      _setFollowing((n.scrollDelta ?? 0) >= 0 && n.metrics.extentAfter < 64);
    } else if (n is UserScrollNotification &&
        n.direction == ScrollDirection.idle &&
        n.metrics.extentAfter < 64) {
      _setFollowing(true);
    }
    return false;
  }

  Widget wrap(Widget child) => NotificationListener<ScrollMetricsNotification>(
    onNotification: (n) {
      if (n.depth == 0) followLatest();
      return false;
    },
    child: NotificationListener<ScrollNotification>(
      onNotification: _scroll,
      child: child,
    ),
  );

  @override
  void dispose() {
    _closed = true;
    following.dispose();
    super.dispose();
  }
}

class _TailPosition extends ScrollPositionWithSingleContext {
  _TailPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    super.initialPixels,
    super.keepScrollOffset,
    required this.shouldFollow,
  });
  final bool Function() shouldFollow;
  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final accepted = super.applyContentDimensions(
      minScrollExtent,
      maxScrollExtent,
    );
    if (shouldFollow() && hasPixels && (pixels - maxScrollExtent).abs() > .01) {
      correctPixels(maxScrollExtent);
      return false;
    }
    return accepted;
  }
}
