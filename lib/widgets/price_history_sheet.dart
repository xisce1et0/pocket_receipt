import 'package:material_ui/material_ui.dart';
import '../models/receipt.dart';
import '../utils/price_analytics.dart';
import 'glass_ui.dart';
import 'price_line_chart.dart';

void showPriceHistorySheet({
  required BuildContext context,
  required List<ProductTarget> initialTargets,
  required List<Receipt> allReceipts,
  StatsPeriod initialPeriod = StatsPeriod.all,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      return SafeArea(
        child: Container(
          height: MediaQuery.of(sheetContext).size.height * 0.86,
          decoration: BoxDecoration(
            color: GlassColors.sheetBg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
            border: Border.all(color: GlassColors.cardBorder),
          ),
          clipBehavior: Clip.antiAlias,
          child: PriceHistoryContent(
            initialTargets: initialTargets,
            allReceipts: allReceipts,
            initialPeriod: initialPeriod,
            showCloseButton: true,
          ),
        ),
      );
    },
  );
}

class PriceHistoryContent extends StatefulWidget {
  final List<ProductTarget> initialTargets;
  final List<Receipt> allReceipts;
  final StatsPeriod initialPeriod;
  final bool showCloseButton;

  const PriceHistoryContent({
    super.key,
    required this.initialTargets,
    required this.allReceipts,
    this.initialPeriod = StatsPeriod.all,
    this.showCloseButton = false,
  });

  @override
  State<PriceHistoryContent> createState() => _PriceHistoryContentState();
}

class _PriceHistoryContentState extends State<PriceHistoryContent> {
  late StatsPeriod _selectedPeriod = widget.initialPeriod;
  late List<ProductTarget> _activeTargets =
      List<ProductTarget>.from(widget.initialTargets);
  late List<ProductTarget> _similarSuggestions = _computeSimilar();

  List<ProductTarget> _computeSimilar() {
    if (widget.initialTargets.length != 1) return const [];
    return findSimilarProductTargets(
      widget.initialTargets.first,
      widget.allReceipts,
    );
  }

  @override
  void didUpdateWidget(covariant PriceHistoryContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldKeys = oldWidget.initialTargets.map((t) => t.key).join('|');
    final newKeys = widget.initialTargets.map((t) => t.key).join('|');
    if (oldKeys != newKeys ||
        oldWidget.allReceipts.length != widget.allReceipts.length) {
      _activeTargets = List<ProductTarget>.from(widget.initialTargets);
      _similarSuggestions = _computeSimilar();
    }
    if (oldWidget.initialPeriod != widget.initialPeriod) {
      _selectedPeriod = widget.initialPeriod;
    }
  }

  bool _isTargetActive(ProductTarget target) {
    return _activeTargets.any((t) => t.key == target.key);
  }

  void _toggleSimilarTarget(ProductTarget target) {
    setState(() {
      if (_isTargetActive(target)) {
        _activeTargets.removeWhere((t) => t.key == target.key);
      } else {
        _activeTargets.add(target);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_activeTargets.isEmpty) {
      return const Center(
        child: Text(
          'Выберите товар слева для просмотра динамики цен',
          style: TextStyle(color: GlassColors.textSecondary, fontSize: 15),
        ),
      );
    }

    final periodReceipts = filterReceiptsByPeriod(
      widget.allReceipts,
      _selectedPeriod,
    );
    final stats = buildMultiProductStats(_activeTargets, periodReceipts);
    final titleText = _activeTargets.length == 1
        ? _activeTargets.first.label
        : 'Сравнение (${_activeTargets.length}): '
            '${_activeTargets.map((t) => t.label).join(', ')}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titleText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: GlassColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Найдено покупок: ${stats.history.length}',
                      style: const TextStyle(
                        color: GlassColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.showCloseButton)
                IconButton(
                  icon: const Icon(Icons.close, color: GlassColors.textPrimary),
                  onPressed: () => Navigator.pop(context),
                ),
            ],
          ),
        ),
        const Divider(height: 1, color: GlassColors.divider),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: StatsPeriod.values.map((period) {
                    return GlassPillChip(
                      label: period.label,
                      compact: true,
                      selected: _selectedPeriod == period,
                      onTap: () => setState(() => _selectedPeriod = period),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 12),
              GlassCard(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(14),
                useBlur: false,
                child: PriceLineChart(
                  points: stats.history,
                  median: stats.median,
                ),
              ),
              if (_similarSuggestions.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: Text(
                    'Другие бренды и похожие товары:',
                    style: TextStyle(
                      fontSize: 12,
                      color: GlassColors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: _similarSuggestions.map((sim) {
                      return GlassPillChip(
                        label: sim.label,
                        compact: true,
                        selected: _isTargetActive(sim),
                        onTap: () => _toggleSimilarTarget(sim),
                      );
                    }).toList(),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (stats.history.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      'За выбранный период покупок нет',
                      style: TextStyle(color: GlassColors.textSecondary),
                    ),
                  ),
                )
              else
                ...stats.history.map((point) {
                  final diff = point.price - stats.median;
                  final diffText = diff == 0
                      ? 'как медиана'
                      : diff > 0
                          ? '+${diff.toStringAsFixed(2)} ₽'
                          : '${diff.toStringAsFixed(2)} ₽';
                  final diffColor = diff > 0
                      ? GlassColors.negative
                      : diff < 0
                          ? GlassColors.positive
                          : GlassColors.textSecondary;

                  final itemTitle = _activeTargets.length > 1
                      ? (point.brand.isNotEmpty
                          ? '${point.itemName} (${point.brand})'
                          : point.itemName)
                      : point.storeName;
                  final itemSubtitle = _activeTargets.length > 1
                      ? '${point.storeName} • ${formatDate(point.date)}'
                      : formatDate(point.date);

                  return GlassCard(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    borderRadius: 16,
                    useBlur: false,
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: GlassColors.heroTint,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.storefront_rounded,
                            size: 18,
                            color: GlassColors.accentLuminous,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                itemTitle,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14,
                                  color: GlassColors.textPrimary,
                                ),
                              ),
                              Text(
                                itemSubtitle,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: GlassColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '${point.price.toStringAsFixed(2)} ₽',
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: GlassColors.textPrimary,
                              ),
                            ),
                            Text(
                              diffText,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: diffColor,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                }),
            ],
          ),
        ),
        GlassCard(
          margin: const EdgeInsets.all(14),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          borderRadius: 18,
          tintColor: GlassColors.heroTint,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Медиана цены',
                    style: TextStyle(
                      fontSize: 12,
                      color: GlassColors.textSecondary,
                    ),
                  ),
                  Text(
                    '${stats.median.toStringAsFixed(2)} ₽',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: GlassColors.accentHeroText,
                    ),
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'Мин: ${stats.minPrice.toStringAsFixed(2)} ₽',
                    style: const TextStyle(
                      fontSize: 13,
                      color: GlassColors.textPrimary,
                    ),
                  ),
                  Text(
                    'Макс: ${stats.maxPrice.toStringAsFixed(2)} ₽',
                    style: const TextStyle(
                      fontSize: 13,
                      color: GlassColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}