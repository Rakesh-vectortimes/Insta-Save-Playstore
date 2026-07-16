import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/constants.dart';

class RollingDisclaimer extends StatefulWidget {
  const RollingDisclaimer({super.key});

  @override
  State<RollingDisclaimer> createState() => _RollingDisclaimerState();
}

class _RollingDisclaimerState extends State<RollingDisclaimer>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _offset = 0;
  double _unitWidth = 0;
  Duration _lastElapsed = Duration.zero;

  // Scrolling speed in logical pixels per second.
  static const double _pixelsPerSecond = 55;

  static const String _separator = '        •        ';

  static const _messages = [
    'Only media from public accounts can be downloaded',
    'Stories are not available',
    'Respect copyright — use downloads for personal use only',
  ];

  String get _unitText => _messages.join(_separator) + _separator;

  final _textStyle = GoogleFonts.poppins(
    color: AppColors.textSecondary,
    fontSize: 12.5,
    height: 1.3,
  );

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    final deltaSeconds =
        (elapsed - _lastElapsed).inMicroseconds / Duration.microsecondsPerSecond;
    _lastElapsed = elapsed;

    if (_unitWidth <= 0) return;

    setState(() {
      _offset += deltaSeconds * _pixelsPerSecond;
      // Wrap seamlessly: once we've scrolled one full unit, subtract it.
      if (_offset >= _unitWidth) {
        _offset -= _unitWidth;
      }
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  double _measureUnitWidth() {
    final painter = TextPainter(
      text: TextSpan(text: _unitText, style: _textStyle),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout();
    return painter.width;
  }

  @override
  Widget build(BuildContext context) {
    _unitWidth = _measureUnitWidth();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.darkBorder),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: AppColors.accent, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRect(
              child: SizedBox(
                height: 18,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Two copies side by side create a seamless loop.
                    Positioned(
                      left: -_offset,
                      top: 0,
                      bottom: 0,
                      child: Row(
                        children: [
                          Text(_unitText, maxLines: 1, style: _textStyle),
                          Text(_unitText, maxLines: 1, style: _textStyle),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
