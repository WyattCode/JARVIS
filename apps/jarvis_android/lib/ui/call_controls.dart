import 'package:flutter/material.dart';

const voiceWorksRouteName = '/jarvis/voice/works';

/// One destructive-action appearance and touch target in every call surface.
class HangupButton extends StatelessWidget {
  const HangupButton({super.key, required this.onPressed});
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: '结束语音通话',
    onPressed: onPressed,
    style: IconButton.styleFrom(
      backgroundColor: const Color(0xffaf3543),
      foregroundColor: Colors.white,
      minimumSize: const Size(40, 40),
      fixedSize: const Size(40, 40),
      side: BorderSide(color: Colors.white.withValues(alpha: .16)),
      shape: const CircleBorder(),
      tapTargetSize: MaterialTapTargetSize.padded,
    ),
    icon: const CallHandsetIcon(ended: true, size: 16),
  );
}

/// A small outlined receiver, shared by entering and ending a call.
class CallHandsetIcon extends StatelessWidget {
  const CallHandsetIcon({
    super.key,
    this.ended = false,
    this.size = 16,
    this.color,
  });
  final bool ended;
  final double size;
  final Color? color;
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _ReceiverPainter(
        ended,
        color ??
            IconTheme.of(context).color ??
            Theme.of(context).colorScheme.onSurface,
      ),
    ),
  );
}

class _ReceiverPainter extends CustomPainter {
  _ReceiverPainter(this.ended, this.color);
  final bool ended;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    if (!ended) {
      canvas.translate(12, 12);
      canvas.rotate(-2.35619449);
      canvas.translate(-12, -12);
    }
    final path = Path()
      ..moveTo(3.2, 12.8)
      ..cubicTo(3.2, 7.4, 20.8, 7.4, 20.8, 12.8)
      ..lineTo(20.8, 15.4)
      ..quadraticBezierTo(20.8, 16.4, 19.8, 16.1)
      ..lineTo(16.7, 15.4)
      ..quadraticBezierTo(15.9, 15.2, 15.9, 14.4)
      ..lineTo(15.9, 12.6)
      ..quadraticBezierTo(12, 11.3, 8.1, 12.6)
      ..lineTo(8.1, 14.4)
      ..quadraticBezierTo(8.1, 15.2, 7.3, 15.4)
      ..lineTo(4.2, 16.1)
      ..quadraticBezierTo(3.2, 16.4, 3.2, 15.4)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ReceiverPainter old) =>
      old.ended != ended || old.color != color;
}
