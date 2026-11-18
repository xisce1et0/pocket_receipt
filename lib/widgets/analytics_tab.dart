import 'package:material_ui/material_ui.dart';
import '../models/receipt.dart';
import '../utils/price_analytics.dart';
import 'filter_pickers.dart';
import 'glass_ui.dart';
import 'price_history_sheet.dart';

class AnalyticsTab extends StatefulWidget {
  final List<Receipt> receipts;

  const AnalyticsTab({super.key, required this.receipts});

  @override
  State<AnalyticsTab> createState() => _AnalyticsTabState();
}

class _AnalyticsTabState extends State<AnalyticsTab> {
  final _searchController = TextEditingController();
  StatsPeriod _selectedPeriod = StatsPeriod.all;
  String _searchQuery = '';
  final Set<String> _selectedGroupKeys = {};
  final Set<String> _selectedBrandKeys = {};
  final Set<String> _checkedKeys = {};
  ProductTarget? _desktopFocusedTarget;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _pickGroups(List<String> groups) async {
    final chosen = await showMultiFilterPicker(
      context: context,
      title: 'Группы товаров',
      resetLabel: 'Все группы',
      showAllLabel: 'Показать все группы',
      options: groups,
      initialSelectedKeys: _selectedGroupKeys,
    );
    if (chosen != null && mounted) {
      setState(() {
        _selectedGroupKeys
          ..clear()
          ..addAll(chosen);
      });
    }
  }

  Future<void> _pickBrands(List<String> brands) async {
    final chosen = await showMultiFilterPicker(
      context: context,
      title: 'Производители',
      resetLabel: 'Все бренды',
      showAllLabel: 'Показать все бренды',
      options: brands,
      initialSelectedKeys: _selectedBrandKeys,
    );
    if (chosen != null && mounted) {
      setState(() {
        _selectedBrandKeys
          ..clear()
          ..addAll(chosen);
      });
    }
  }

  void _toggleChecked(String key) {
    setState(() {
      if (_checkedKeys.contains(key)) {
        _checkedKeys.remove(key);
      } else {
        _checkedKeys.add(key);
      }
    });
  }

  Widget _buildLeftList({
    required AutocompleteCatalog catalog,
    required List<ProductSummary> filtered,
    required double filteredSpent,
    required int filteredPurchases,
    required bool hasFilter,
    required bool isDesktop,
    required List<ProductTarget> selectedTargets,
  }) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 100),
            children: [
              const SizedBox(height: 10),
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: TextField(
                  controller: _searchController,
                  style: const TextStyle(color: GlassColors.textPrimary),
                  onChanged: (value) => setState(() => _searchQuery = value),
                  decoration: InputDecoration(
                    labelText: 'Поиск товара, бренда или группы',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                  ),
                ),
              ),
              if (catalog.groups.isNotEmpty || catalog.brands.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      if (catalog.groups.isNotEmpty)
                        Expanded(
                          child: GlassCard(
                            borderRadius: 14,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            useBlur: false,
                            onTap: () => _pickGroups(catalog.groups),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.category_outlined,
                                  size: 17,
                                  color: GlassColors.accentLuminous,
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    formatMultiFilterLabel(
                                      singularPrefix: 'Группа',
                                      pluralPrefix: 'Группы',
                                      selectedKeys: _selectedGroupKeys,
                                      allOptions: catalog.groups,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: GlassColors.textPrimary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (catalog.groups.isNotEmpty &&
                          catalog.brands.isNotEmpty)
                        const SizedBox(width: 8),
                      if (catalog.brands.isNotEmpty)
                        Expanded(
                          child: GlassCard(
                            borderRadius: 14,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            useBlur: false,
                            onTap: () => _pickBrands(catalog.brands),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.factory_outlined,
                                  size: 17,
                                  color: GlassColors.accentLuminous,
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    formatMultiFilterLabel(
                                      singularPrefix: 'Бренд',
                                      pluralPrefix: 'Бренды',
                                      selectedKeys: _selectedBrandKeys,
                                      allOptions: catalog.brands,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: GlassColors.textPrimary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              GlassCard(
                margin: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 16,
                ),
                tintColor: GlassColors.heroTint,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Потрачено • ${_selectedPeriod.label}',
                          style: const TextStyle(
                            fontSize: 13,
                            color: GlassColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${filteredSpent.toStringAsFixed(2)} ₽',
                          style: const TextStyle(
                            fontSize: 24,
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
                          'Позиций: ${filtered.length}',
                          style: const TextStyle(
                            fontSize: 13,
                            color: GlassColors.textSecondary,
                          ),
                        ),
                        Text(
                          'Покупок: $filteredPurchases',
                          style: const TextStyle(
                            fontSize: 13,
                            color: GlassColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 6, 12, 4),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Отметьте товары для сравнения',
                        style: TextStyle(
                          color: GlassColors.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    if (hasFilter && filtered.isNotEmpty)
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () {
                          setState(() {
                            for (final s in filtered) {
                              _checkedKeys.add(s.target.key);
                            }
                          });
                        },
                        child: const Text('Выбрать все'),
                      ),
                    if (_checkedKeys.isNotEmpty)
                      TextButton(
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () {
                          setState(() => _checkedKeys.clear());
                        },
                        child: const Text('Сбросить'),
                      ),
                  ],
                ),
              ),
              if (filtered.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(
                    child: Text(
                      'За этот период ничего не найдено',
                      style: TextStyle(color: GlassColors.textSecondary),
                    ),
                  ),
                )
              else
                ...filtered.map((summary) {
                  final checked = _checkedKeys.contains(summary.target.key);
                  final isFocused = isDesktop &&
                      _checkedKeys.isEmpty &&
                      _desktopFocusedTarget?.key == summary.target.key;
                  final brandLabel =
                      summary.brand.isEmpty ? 'Без бренда' : summary.brand;
                  final tags = [brandLabel, ...summary.groups].join(' • ');
                  final subtitle =
                      '$tags\nПокупок: ${summary.purchaseCount} • Сумма: ${summary.totalSpent.toStringAsFixed(2)} ₽';

                  return GlassCard(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 11,
                    ),
                    borderRadius: 18,
                    useBlur: false,
                    tintColor:
                        isFocused || checked ? GlassColors.selectedTint : null,
                    onTap: () {
                      if (isDesktop) {
                        setState(() {
                          _desktopFocusedTarget = summary.target;
                        });
                      } else {
                        showPriceHistorySheet(
                          context: context,
                          initialTargets: [summary.target],
                          allReceipts: widget.receipts,
                          initialPeriod: _selectedPeriod,
                        );
                      }
                    },
                    child: Row(
                      children: [
                        GlassCheckbox(
                          value: checked,
                          onChanged: (_) => _toggleChecked(summary.target.key),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                summary.displayName,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 15,
                                  color: GlassColors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                subtitle,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: GlassColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '${summary.medianPrice.toStringAsFixed(2)} ₽',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                                color: GlassColors.textPrimary,
                              ),
                            ),
                            const Text(
                              'медиана',
                              style: TextStyle(
                                fontSize: 11,
                                color: GlassColors.textSecondary,
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
        if (!isDesktop && selectedTargets.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                onPressed: () => showPriceHistorySheet(
                  context: context,
                  initialTargets: selectedTargets,
                  allReceipts: widget.receipts,
                  initialPeriod: _selectedPeriod,
                ),
                icon: const Icon(Icons.show_chart),
                label: Text('Сравнить выбранные (${selectedTargets.length})'),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final catalog = buildAutocompleteCatalog(widget.receipts);
    final periodReceipts = filterReceiptsByPeriod(
      widget.receipts,
      _selectedPeriod,
    );
    final allSummaries = buildProductSummaries(periodReceipts);

    final filtered = allSummaries.where((s) {
      if (_selectedGroupKeys.isNotEmpty) {
        final itemGroupKeys = s.groups.map(normalizeProductName).toSet();
        if (!itemGroupKeys.any(_selectedGroupKeys.contains)) {
          return false;
        }
      }
      if (_selectedBrandKeys.isNotEmpty &&
          !_selectedBrandKeys.contains(normalizeProductName(s.brand))) {
        return false;
      }
      if (_searchQuery.trim().isNotEmpty) {
        final q = normalizeProductName(_searchQuery);
        final matchesText = normalizeProductName(s.displayName).contains(q) ||
            normalizeProductName(s.brand).contains(q) ||
            normalizeProductName(s.productGroup).contains(q);
        if (!matchesText && !isFuzzyProductMatch(_searchQuery, s.displayName)) {
          return false;
        }
      }
      return true;
    }).toList();

    double filteredSpent = 0;
    int filteredPurchases = 0;
    for (final s in filtered) {
      filteredSpent += s.totalSpent;
      filteredPurchases += s.purchaseCount;
    }

    final hasFilter = _selectedGroupKeys.isNotEmpty ||
        _selectedBrandKeys.isNotEmpty ||
        _searchQuery.trim().isNotEmpty;

    final selectedTargets = allSummaries
        .where((s) => _checkedKeys.contains(s.target.key))
        .map((s) => s.target)
        .toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= 900;

        if (!isDesktop) {
          return _buildLeftList(
            catalog: catalog,
            filtered: filtered,
            filteredSpent: filteredSpent,
            filteredPurchases: filteredPurchases,
            hasFilter: hasFilter,
            isDesktop: false,
            selectedTargets: selectedTargets,
          );
        }

        final desktopTargets = selectedTargets.isNotEmpty
            ? selectedTargets
            : (_desktopFocusedTarget != null
                ? [_desktopFocusedTarget!]
                : (filtered.isNotEmpty
                    ? [filtered.first.target]
                    : const <ProductTarget>[]));

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 440,
              child: _buildLeftList(
                catalog: catalog,
                filtered: filtered,
                filteredSpent: filteredSpent,
                filteredPurchases: filteredPurchases,
                hasFilter: hasFilter,
                isDesktop: true,
                selectedTargets: selectedTargets,
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 16, 16),
                child: GlassCard(
                  borderRadius: 24,
                  child: PriceHistoryContent(
                    initialTargets: desktopTargets,
                    allReceipts: widget.receipts,
                    initialPeriod: _selectedPeriod,
                    showCloseButton: false,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}