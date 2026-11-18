import 'dart:math' as math;
import 'package:material_ui/material_ui.dart';
import '../utils/price_analytics.dart';
import 'glass_ui.dart';

class PriceLineChart extends StatelessWidget {
  final List<PricePoint> points;
  final double median;

  const PriceLineChart({
    super.key,
    required this.points,
    required this.median,
  });

  @override
  Widget build(BuildContext context) {
    if (points.isEmpty) {
      return const SizedBox(
        height: 160,
        child: Center(
          child: Text(
            'Нет данных для графика',
            style: TextStyle(color: GlassColors.textSecondary),
          ),
        ),
      );
    }

    final chronological = List<PricePoint>.from(points)
      ..sort((a, b) => a.date.compareTo(b.date));

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    color: GlassColors.accentLuminous,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                const Text(
                  'Цена',
                  style: TextStyle(
                    fontSize: 12,
                    color: GlassColors.textPrimary,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Container(
                  width: 14,
                  height: 2,
                  color: GlassColors.chartMedian,
                ),
                const SizedBox(width: 6),
                Text(
                  'Медиана: ${median.toStringAsFixed(2)} ₽',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: GlassColors.chartMedian,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 165,
          width: double.infinity,
          child: CustomPaint(
            painter: _PriceChartPainter(
              points: chronological,
              median: median,
              lineColor: GlassColors.accentLuminous,
              medianColor: GlassColors.chartMedian,
              textColor: GlassColors.textSecondary,
              gridColor: GlassColors.chartGrid,
              dotRingColor: GlassColors.chartDotRing,
            ),
          ),
        ),
      ],
    );
  }
}

class _PriceChartPainter extends CustomPainter {
  final List<PricePoint> points;
  final double median;
  final Color lineColor;
  final Color medianColor;
  final Color textColor;
  final Color gridColor;
  final Color dotRingColor;

  _PriceChartPainter({
    required this.points,
    required this.median,
    required this.lineColor,
    required this.medianColor,
    required this.textColor,
    required this.gridColor,
    required this.dotRingColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 48.0;
    const rightPad = 14.0;
    const topPad = 12.0;
    const bottomPad = 24.0;

    final chartWidth = size.width - leftPad - rightPad;
    final chartHeight = size.height - topPad - bottomPad;
    if (chartWidth <= 0 || chartHeight <= 0) return;

    double minPrice = points.first.price;
    double maxPrice = points.first.price;
    for (final p in points) {
      if (p.price < minPrice) minPrice = p.price;
      if (p.price > maxPrice) maxPrice = p.price;
    }

    final range = maxPrice - minPrice;
    final padding = range == 0 ? math.max(1.0, minPrice * 0.1) : range * 0.15;
    final minY = math.max(0.0, minPrice - padding);
    final maxY = maxPrice + padding;
    final ySpan = maxY - minY;

    double priceToY(double price) {
      if (ySpan == 0) return topPad + chartHeight / 2;
      final normalized = (price - minY) / ySpan;
      return topPad + chartHeight - (normalized * chartHeight);
    }

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;

    final maxYPos = priceToY(maxPrice);
    canvas.drawLine(
      Offset(leftPad, maxYPos),
      Offset(leftPad + chartWidth, maxYPos),
      gridPaint,
    );
    _drawText(
      canvas,
      maxPrice.toStringAsFixed(0),
      Offset(2, maxYPos - 7),
      textColor,
      11,
    );

    if (maxPrice != minPrice) {
      final minYPos = priceToY(minPrice);
      canvas.drawLine(
        Offset(leftPad, minYPos),
        Offset(leftPad + chartWidth, minYPos),
        gridPaint,
      );
      if ((minYPos - maxYPos).abs() > 18) {
        _drawText(
          canvas,
          minPrice.toStringAsFixed(0),
          Offset(2, minYPos - 7),
          textColor,
          11,
        );
      }
    }

    final medianY = priceToY(median);
    final medianPaint = Paint()
      ..color = medianColor
      ..strokeWidth = 1.5;

    for (double x = leftPad; x < leftPad + chartWidth; x += 10) {
      final endX = math.min(x + 5, leftPad + chartWidth);
      canvas.drawLine(Offset(x, medianY), Offset(endX, medianY), medianPaint);
    }

    final offsets = <Offset>[];
    for (int i = 0; i < points.length; i++) {
      final double x;
      if (points.length == 1) {
        x = leftPad + chartWidth / 2;
      } else {
        x = leftPad + (i / (points.length - 1)) * chartWidth;
      }
      offsets.add(Offset(x, priceToY(points[i].price)));
    }

    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    if (offsets.length > 1) {
      final path = Path()..moveTo(offsets.first.dx, offsets.first.dy);
      for (int i = 1; i < offsets.length; i++) {
        path.lineTo(offsets[i].dx, offsets[i].dy);
      }
      canvas.drawPath(path, linePaint);
    }

    final dotFillPaint = Paint()..color = lineColor;
    final dotBorderPaint = Paint()..color = dotRingColor;

    for (final offset in offsets) {
      canvas.drawCircle(offset, 5.5, dotBorderPaint);
      canvas.drawCircle(offset, 4.0, dotFillPaint);
    }

    _drawText(
      canvas,
      formatDate(points.first.date),
      Offset(leftPad, topPad + chartHeight + 6),
      textColor,
      10,
    );
    if (points.length > 1) {
      final lastLabel = formatDate(points.last.date);
      _drawText(
        canvas,
        lastLabel,
        Offset(leftPad + chartWidth - 58, topPad + chartHeight + 6),
        textColor,
        10,
      );
    }
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset offset,
    Color color,
    double fontSize,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: fontSize),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _PriceChartPainter oldDelegate) {
    return oldDelegate.points != points || oldDelegate.median != median;
  }
}