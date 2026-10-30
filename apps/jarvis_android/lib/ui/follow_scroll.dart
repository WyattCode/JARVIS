import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart' show SchedulerPhase;
import 'package:flutter/widgets.dart';

import 'motion.dart';

/// Further than this from the tail, the "back to bottom" button is worth showing even when nothing is being written.
const farFromTail = 400.0;

/// Follow newly laid-out content (including decoded images), until the user
/// scrolls away. Programmatic/layout changes must not count as user scrolling.
class FollowScrollController extends ScrollController {
  bool _following = true, _scheduled = false, _closed = false;

  int _keyboardRevision = 0, _interactionRevision = 0;

  /// True while the view has been left behind the tail (the user scrolled up, or opened something below the fold).
  final away = ValueNotifier<bool>(false);

  /// True while the view is more than [farFromTail] above the tail (kept up to date as the list scrolls).
  final far = ValueNotifier<bool>(false);

  void _setFar(bool value) {
    if (_closed || far.value == value) return;
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_closed) far.value = value;
      });
    } else {
      far.value = value;
    }
  }

  void _setFollowing(bool value) {
    _following = value;
    if (_closed) return;
    // A user-scroll notification can arrive in the middle of layout, where listeners must not rebuild.
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_closed) away.value = !_following;
      });
    } else {
      away.value = !value;
    }
  }

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
      // iOS: dragging the list also hides the keyboard; jumping on every frame of that animation would fight the
      // finger, so leave the position alone while the user is scrolling.
      if (defaultTargetPlatform == TargetPlatform.iOS &&
          position.isScrollingNotifier.value) {
        return;
      }
      final target = _following ? position.maxScrollExtent : oldOffset;
      jumpTo(target.clamp(position.minScrollExtent, position.maxScrollExtent));
    });
  }

  /// The text is about to re-wrap to another width: keep the same share of the conversation in view instead of the
  /// same pixel offset, which would land somewhere else once the heights have changed. (Following the tail needs no
  /// help, it stays at the tail.)
  void keepReadingPlace() {
    if (_closed ||
        _following ||
        !hasClients ||
        !position.hasContentDimensions) {
      return;
    }
    final extent = position.maxScrollExtent;
    if (extent <= 0) return;
    final share = (offset / extent).clamp(0.0, 1.0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_closed || !hasClients || _following) return;
      jumpTo(
        (share * position.maxScrollExtent).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        ),
      );
    });
  }

  void resumeFollowing() {
    _setFollowing(true);
    followLatest();
  }

  /// Glides to the tail (250 ms) and then follows it again. Motion reduced ([context]) or no list yet: straight there.
  Future<void> animateToTail(BuildContext context) async {
    final duration = motion(context, 250);
    if (_closed || !hasClients || duration == Duration.zero) {
      resumeFollowing();
      return;
    }
    await animateTo(
      position.maxScrollExtent,
      duration: duration,
      curve: Curves.easeOutCubic,
    );
    // The user may have grabbed the list meanwhile (the animation then ends where it was): only a finish near the tail
    // (it moved on while streaming) goes back to following.
    if (_closed || !hasClients) return;
    if (position.maxScrollExtent - position.pixels < 200) resumeFollowing();
  }

  /// Leave the view where it is, e.g. when the user expands a section at the tail: following would pin the viewport to
  /// the new bottom and scroll the start of that section out of sight.
  void stopFollowing() => _setFollowing(false);

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
    _setFar(n.metrics.extentAfter > farFromTail);
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
    away.dispose();
    far.dispose();
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
