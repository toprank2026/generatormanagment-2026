import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

/// Pure-CustomPainter chart widgets for the monthly reports screen.
/// No external chart packages — only flutter/material + intl (already a dep).

const Color _kTrackColor = Color(0xFFECEFF4);

// v19: force comma grouping ('en_US') so chart values (incl. money in the
// compare bars) match the app-wide thousands-separated format, independent of
// the active locale.
String _formatNumber(num value) =>
    NumberFormat.decimalPattern('en_US').format(value);

// v23: the GaugeChart (semi-circular collection-rate gauge) + its _GaugePainter
// were removed here — dead code since v14 (the reports screen dropped it) with
// zero references anywhere in lib/.

// ---------------------------------------------------------------------------
// DonutChart — donut with small gaps between segments + legend underneath.
// ---------------------------------------------------------------------------

class DonutSegment {
  final String label;
  final double value;
  final Color color;

  const DonutSegment({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DonutSegment &&
          other.label == label &&
          other.value == value &&
          other.color == color;

  @override
  int get hashCode => Object.hash(label, value, color);
}

class DonutChart extends StatelessWidget {
  final List<DonutSegment> segments;
  final double size;
  final String? centerText;

  const DonutChart({
    super.key,
    required this.segments,
    this.size = 150,
    this.centerText,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _DonutPainter(
              segments: segments,
              trackColor: _kTrackColor,
            ),
            child: centerText == null
                ? null
                : Center(
                    child: Padding(
                      padding: EdgeInsets.all(size * 0.22),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          centerText!,
                          style: TextStyle(
                            fontSize: size * 0.13,
                            fontWeight: FontWeight.bold,
                            color: const Color(0xFF263238),
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 14,
          runSpacing: 6,
          children: [
            for (final seg in segments)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: seg.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    seg.label,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF607D8B),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _formatNumber(seg.value),
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF263238),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

class _DonutPainter extends CustomPainter {
  final List<DonutSegment> segments;
  final Color trackColor;

  const _DonutPainter({required this.segments, required this.trackColor});

  @override
  void paint(Canvas canvas, Size size) {
    final double strokeWidth = size.shortestSide * 0.16;
    final double radius = (size.shortestSide - strokeWidth) / 2;
    if (radius <= 0) return;
    final Offset center = size.center(Offset.zero);
    final Rect rect = Rect.fromCircle(center: center, radius: radius);

    final Paint trackPaint = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = trackColor;
    canvas.drawCircle(center, radius, trackPaint);

    double total = 0;
    int visible = 0;
    for (final seg in segments) {
      if (seg.value > 0) {
        total += seg.value;
        visible++;
      }
    }
    if (total <= 0 || visible == 0) return;

    // Small gap (in radians) between segments; none when a single segment.
    final double gap = visible > 1 ? 0.05 : 0.0;
    final double available = 2 * math.pi - gap * visible;

    double start = -math.pi / 2;
    for (final seg in segments) {
      if (seg.value <= 0) continue;
      final double sweep = (seg.value / total) * available;
      final Paint segPaint = Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.butt
        ..color = seg.color;
      canvas.drawArc(rect, start + gap / 2, sweep, false, segPaint);
      start += sweep + gap;
    }
  }

  @override
  bool shouldRepaint(_DonutPainter oldDelegate) =>
      oldDelegate.trackColor != trackColor ||
      !listEquals(oldDelegate.segments, segments);
}

// ---------------------------------------------------------------------------
// BarCompareChart — vertical bars scaled to max(|value|), value label on top.
// ---------------------------------------------------------------------------

class BarItem {
  final String label;
  final double value;
  final Color color;

  const BarItem({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BarItem &&
          other.label == label &&
          other.value == value &&
          other.color == color;

  @override
  int get hashCode => Object.hash(label, value, color);
}

class BarCompareChart extends StatelessWidget {
  final List<BarItem> items;
  final double height;

  const BarCompareChart({
    super.key,
    required this.items,
    this.height = 150,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return SizedBox(height: height);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: _BarsPainter(items: items, trackColor: _kTrackColor),
          ),
        ),
        const SizedBox(height: 6),
        // v34 FIX: the bars above are PAINTED in fixed canvas (LTR)
        // coordinates, so the label row MUST lay out LTR as well — under the
        // app's RTL locale a plain Row reverses, putting the OUTER labels
        // under the wrong bars (the صافي الربح/الوارد الكلي mix-up the owner
        // kept seeing regardless of which key the code used).
        Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            children: [
              for (final item in items)
                Expanded(
                  child: Text(
                    item.label,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF607D8B),
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BarsPainter extends CustomPainter {
  final List<BarItem> items;
  final Color trackColor;

  const _BarsPainter({required this.items, required this.trackColor});

  @override
  void paint(Canvas canvas, Size size) {
    if (items.isEmpty) return;

    double maxAbs = 0;
    for (final item in items) {
      maxAbs = math.max(maxAbs, item.value.abs());
    }

    const double labelSpace = 20.0; // room for the value label above the bar
    final double chartHeight = math.max(size.height - labelSpace, 0);
    final double slotWidth = size.width / items.length;
    final double barWidth = math.min(slotWidth * 0.5, 44.0);
    final double baseline = size.height;

    // Baseline (zero line).
    final Paint basePaint = Paint()
      ..isAntiAlias = true
      ..strokeWidth = 1.5
      ..color = trackColor;
    canvas.drawLine(
      Offset(0, baseline - 0.75),
      Offset(size.width, baseline - 0.75),
      basePaint,
    );

    for (int i = 0; i < items.length; i++) {
      final BarItem item = items[i];
      final double cx = slotWidth * i + slotWidth / 2;

      // Display is clamped at 0 (negatives draw a small stub), but the
      // label always shows the signed number.
      final double fraction = (maxAbs <= 0 || item.value <= 0)
          ? 0.0
          : (item.value / maxAbs).clamp(0.0, 1.0);
      final double barHeight = math.max(fraction * chartHeight, 3.0);

      final Paint barPaint = Paint()
        ..isAntiAlias = true
        ..color = item.color;
      final RRect bar = RRect.fromRectAndCorners(
        Rect.fromLTWH(cx - barWidth / 2, baseline - barHeight, barWidth,
            barHeight),
        topLeft: const Radius.circular(5),
        topRight: const Radius.circular(5),
      );
      canvas.drawRRect(bar, barPaint);

      final TextPainter textPainter = TextPainter(
        text: TextSpan(
          text: _formatNumber(item.value),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: Color(0xFF263238),
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: slotWidth);
      final double textY =
          math.max(baseline - barHeight - textPainter.height - 3, 0);
      textPainter.paint(
        canvas,
        Offset(cx - textPainter.width / 2, textY),
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter oldDelegate) =>
      oldDelegate.trackColor != trackColor ||
      !listEquals(oldDelegate.items, items);
}
