import 'package:material_ui/material_ui.dart';
import '../models/receipt.dart';
import '../services/database_service.dart';
import '../services/excel_export_service.dart';
import '../services/share_service.dart';
import '../utils/price_analytics.dart';
import '../widgets/analytics_tab.dart';
import '../widgets/filter_pickers.dart';
import '../widgets/glass_ui.dart';
import '../widgets/receipt_detail_content.dart';
import 'add_receipt_screen.dart';
import 'receipt_detail_screen.dart';
import 'sync_screen.dart';

class HomeScreen extends StatefulWidget {
  final List<Receipt>? initialReceipts;

  const HomeScreen({super.key, this.initialReceipts});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Receipt> _receipts = [];
  bool _isLoading = true;
  StatsPeriod _selectedPeriod = StatsPeriod.all;
  final Set<String> _selectedGroupKeys = {};
  final Set<String> _selectedBrandKeys = {};
  int _currentTab = 0;

  bool _isSelectionMode = false;
  final Set<String> _selectedReceiptIds = {};
  String? _desktopSelectedReceiptId;

  @override
  void initState() {
    super.initState();
    if (widget.initialReceipts != null) {
      _receipts = widget.initialReceipts!;
      _isLoading = false;
    } else {
      _initApp();
    }
  }

  Future<void> _initApp() async {
    await _loadReceipts();
    ShareService.listenForSharedImages((paths) {
      if (mounted) {
        _openAddReceipt(initialPhotoPaths: paths);
      }
    });
    final initialPaths = await ShareService.getInitialSharedImages();
    if (initialPaths.isNotEmpty && mounted) {
      await _openAddReceipt(initialPhotoPaths: initialPaths);
    }
  }

  Future<void> _loadReceipts() async {
    final loaded = await DatabaseService.instance.getAllReceipts();
    if (!mounted) return;
    setState(() {
      _receipts = loaded;
      _isLoading = false;
      if (_desktopSelectedReceiptId != null &&
          !_receipts.any((r) => r.id == _desktopSelectedReceiptId)) {
        _desktopSelectedReceiptId =
            _receipts.isNotEmpty ? _receipts.first.id : null;
      }
    });
  }

  Future<void> _openSyncScreen() async {
    final didSync = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (context) => const SyncScreen()),
    );
    if (didSync == true && mounted) {
      await _loadReceipts();
    }
  }

  Future<void> _openAddReceipt({
    List<String> initialPhotoPaths = const [],
  }) async {
    if (initialPhotoPaths.isNotEmpty) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    }

    final newReceipt = await Navigator.push<Receipt>(
      context,
      MaterialPageRoute(
        builder: (context) => AddReceiptScreen(
          allReceipts: _receipts,
          initialPhotoPaths: initialPhotoPaths,
        ),
      ),
    );

    if (newReceipt != null) {
      await DatabaseService.instance.insertReceipt(newReceipt);
      _desktopSelectedReceiptId = newReceipt.id;
      await _loadReceipts();
    }
  }

  Future<void> _pickGroups(List<String> groups) async {
    final chosen = await showMultiFilterPicker(
      context: context,
      title: 'Фильтр по группам',
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
      title: 'Фильтр по брендам',
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

  Future<void> _openExportMenu(List<Receipt> filteredReceipts) async {
    final isWide = MediaQuery.of(context).size.width >= 700;
    String? choice;

    if (isWide) {
      choice = await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          return Dialog(
            backgroundColor: GlassColors.sheetBg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(22),
              side: const BorderSide(color: GlassColors.cardBorder),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Padding(
                      padding: EdgeInsets.fromLTRB(20, 8, 20, 12),
                      child: Text(
                        'Экспорт в Excel (.xlsx)',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: GlassColors.textPrimary,
                        ),
                      ),
                    ),
                    const Divider(height: 1, color: GlassColors.divider),
                    ListTile(
                      leading: const Icon(
                        Icons.select_all,
                        color: GlassColors.accentLuminous,
                      ),
                      title: const Text(
                        'Выбрать чеки галочками (1 или несколько)',
                        style: TextStyle(color: GlassColors.textPrimary),
                      ),
                      onTap: () => Navigator.pop(dialogContext, 'select'),
                    ),
                    ListTile(
                      leading: const Icon(
                        Icons.table_view,
                        color: GlassColors.accentLuminous,
                      ),
                      title: Text(
                        'Выгрузить все текущие (${filteredReceipts.length})',
                        style: const TextStyle(color: GlassColors.textPrimary),
                      ),
                      onTap: () => Navigator.pop(dialogContext, 'all'),
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Отмена'),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
    } else {
      choice = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: GlassColors.sheetBg,
        builder: (sheetContext) {
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Text(
                    'Экспорт в Excel (.xlsx)',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: GlassColors.textPrimary,
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(
                    Icons.select_all,
                    color: GlassColors.accentLuminous,
                  ),
                  title: const Text(
                    'Выбрать чеки галочками (1 или несколько)',
                    style: TextStyle(color: GlassColors.textPrimary),
                  ),
                  onTap: () => Navigator.pop(sheetContext, 'select'),
                ),
                ListTile(
                  leading: const Icon(
                    Icons.table_view,
                    color: GlassColors.accentLuminous,
                  ),
                  title: Text(
                    'Выгрузить все текущие (${filteredReceipts.length})',
                    style: const TextStyle(color: GlassColors.textPrimary),
                  ),
                  onTap: () => Navigator.pop(sheetContext, 'all'),
                ),
              ],
            ),
          );
        },
      );
    }

    if (!mounted || choice == null) return;
    if (choice == 'select') {
      setState(() {
        _isSelectionMode = true;
        _selectedReceiptIds.clear();
      });
    } else if (choice == 'all') {
      await ExcelExportService.exportReceipts(context, filteredReceipts);
    }
  }

  Future<void> _exportSelectedReceipts() async {
    final selected = _receipts
        .where((r) => _selectedReceiptIds.contains(r.id))
        .toList();
    await ExcelExportService.exportReceipts(context, selected);
    if (mounted) {
      setState(() {
        _isSelectionMode = false;
        _selectedReceiptIds.clear();
      });
    }
  }

  List<Receipt> _getFilteredReceipts() {
    final periodReceipts = filterReceiptsByPeriod(_receipts, _selectedPeriod);
    final hasItemFilter =
        _selectedGroupKeys.isNotEmpty || _selectedBrandKeys.isNotEmpty;

    if (!hasItemFilter) return periodReceipts;
    return periodReceipts.where((r) {
      return r.items.any(
        (item) => itemMatchesFilters(
          item,
          selectedGroupKeys: _selectedGroupKeys,
          selectedBrandKeys: _selectedBrandKeys,
        ),
      );
    }).toList();
  }

  Widget _buildReceiptsList({
    required List<Receipt> filteredReceipts,
    required bool isDesktop,
    required String? activeDesktopId,
  }) {
    final catalog = buildAutocompleteCatalog(_receipts);
    final hasItemFilter =
        _selectedGroupKeys.isNotEmpty || _selectedBrandKeys.isNotEmpty;

    double totalSpent = 0;
    for (final receipt in filteredReceipts) {
      totalSpent += receiptFilteredTotal(
        receipt,
        selectedGroupKeys: _selectedGroupKeys,
        selectedBrandKeys: _selectedBrandKeys,
      );
    }

    return ListView(
      padding: EdgeInsets.only(bottom: isDesktop ? 24 : 96),
      children: [
        GlassCard(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          padding: const EdgeInsets.all(20),
          tintColor: GlassColors.heroTint,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                hasItemFilter
                    ? 'По фильтру • ${_selectedPeriod.label}'
                    : 'Всего по чекам • ${_selectedPeriod.label}',
                style: const TextStyle(
                  fontSize: 13,
                  color: GlassColors.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${totalSpent.toStringAsFixed(2)} ₽',
                style: const TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: GlassColors.accentHeroText,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Чеков: ${filteredReceipts.length}',
                style: const TextStyle(
                  fontSize: 13,
                  color: GlassColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
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
        if (catalog.groups.isNotEmpty || catalog.brands.isNotEmpty) ...[
          const SizedBox(height: 10),
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
                if (catalog.groups.isNotEmpty && catalog.brands.isNotEmpty)
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
                if (hasItemFilter)
                  IconButton(
                    onPressed: () {
                      setState(() {
                        _selectedGroupKeys.clear();
                        _selectedBrandKeys.clear();
                      });
                    },
                    icon: const Icon(
                      Icons.filter_alt_off_outlined,
                      color: GlassColors.textSecondary,
                    ),
                    tooltip: 'Сбросить фильтры',
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 10),
        if (filteredReceipts.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(
              child: Text(
                'По выбранным фильтрам чеков нет',
                style: TextStyle(color: GlassColors.textSecondary),
              ),
            ),
          )
        else
          ...filteredReceipts.map((receipt) {
            final filteredSum = receiptFilteredTotal(
              receipt,
              selectedGroupKeys: _selectedGroupKeys,
              selectedBrandKeys: _selectedBrandKeys,
            );
            final isChecked = _selectedReceiptIds.contains(receipt.id);
            final isSelectedDesktop =
                isDesktop && !_isSelectionMode && activeDesktopId == receipt.id;

            return GlassCard(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              borderRadius: 18,
              useBlur: false,
              tintColor: isSelectedDesktop || isChecked
                  ? GlassColors.selectedTint
                  : null,
              onLongPress: () {
                setState(() {
                  _isSelectionMode = true;
                  _selectedReceiptIds.add(receipt.id);
                });
              },
              onTap: () async {
                if (_isSelectionMode) {
                  setState(() {
                    if (isChecked) {
                      _selectedReceiptIds.remove(receipt.id);
                    } else {
                      _selectedReceiptIds.add(receipt.id);
                    }
                  });
                  return;
                }
                if (isDesktop) {
                  setState(() {
                    _desktopSelectedReceiptId = receipt.id;
                  });
                  return;
                }
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ReceiptDetailScreen(
                      receiptId: receipt.id,
                    ),
                  ),
                );
                if (mounted) {
                  await _loadReceipts();
                }
              },
              child: Row(
                children: [
                  if (_isSelectionMode) ...[
                    GlassCheckbox(
                      value: isChecked,
                      onChanged: (val) {
                        setState(() {
                          if (val) {
                            _selectedReceiptIds.add(receipt.id);
                          } else {
                            _selectedReceiptIds.remove(receipt.id);
                          }
                        });
                      },
                    ),
                    const SizedBox(width: 10),
                  ] else ...[
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: GlassColors.heroTint,
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: const Icon(
                        Icons.receipt_long_rounded,
                        color: GlassColors.accentLuminous,
                        size: 21,
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          receipt.storeName,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                            color: GlassColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${formatDate(receipt.date)} • Товаров: ${receipt.items.length}',
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
                        '${filteredSum.toStringAsFixed(2)} ₽',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: GlassColors.textPrimary,
                        ),
                      ),
                      if (hasItemFilter)
                        Text(
                          'чек: ${receipt.totalAmount.toStringAsFixed(2)} ₽',
                          style: const TextStyle(
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
    );
  }

  Widget _buildDesktopLayout(List<Receipt> filteredReceipts) {
    final activeDesktopId = (_desktopSelectedReceiptId != null &&
            filteredReceipts.any((r) => r.id == _desktopSelectedReceiptId))
        ? _desktopSelectedReceiptId
        : (filteredReceipts.isNotEmpty ? filteredReceipts.first.id : null);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Row(
          children: [
            SizedBox(
              width: 245,
              child: GlassCard(
                margin: const EdgeInsets.fromLTRB(16, 16, 8, 16),
                padding: const EdgeInsets.all(16),
                borderRadius: 24,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(11),
                            child: Image.asset(
                              'assets/icon/app_icon.png',
                              width: 38,
                              height: 38,
                              fit: BoxFit.cover,
                            ),
                          ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Карманный чек',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: GlassColors.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    _DesktopNavTile(
                      icon: Icons.receipt_long_rounded,
                      label: 'Чеки',
                      selected: _currentTab == 0,
                      onTap: () {
                        setState(() => _currentTab = 0);
                      },
                    ),
                    const SizedBox(height: 6),
                    _DesktopNavTile(
                      icon: Icons.show_chart_rounded,
                      label: 'Цены и сравнение',
                      selected: _currentTab == 1,
                      onTap: () {
                        setState(() {
                          _currentTab = 1;
                          _isSelectionMode = false;
                          _selectedReceiptIds.clear();
                        });
                      },
                    ),
                    const Spacer(),
                    const Divider(height: 24, color: GlassColors.divider),
                    SizedBox(
                      height: 44,
                      child: FilledButton.icon(
                        onPressed: () => _openAddReceipt(),
                        icon: const Icon(Icons.add),
                        label: const Text('Новый чек'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_currentTab == 0 && filteredReceipts.isNotEmpty) ...[
                      if (_isSelectionMode) ...[
                        SizedBox(
                          height: 42,
                          child: FilledButton.tonalIcon(
                            onPressed: _selectedReceiptIds.isNotEmpty
                                ? _exportSelectedReceipts
                                : null,
                            icon: const Icon(Icons.table_view),
                            label: Text(
                              'В Excel (${_selectedReceiptIds.length})',
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: TextButton(
                                onPressed: () {
                                  setState(() {
                                    for (final r in filteredReceipts) {
                                      _selectedReceiptIds.add(r.id);
                                    }
                                  });
                                },
                                child: const Text('Все'),
                              ),
                            ),
                            Expanded(
                              child: TextButton(
                                onPressed: () {
                                  setState(() {
                                    _isSelectionMode = false;
                                    _selectedReceiptIds.clear();
                                  });
                                },
                                child: const Text('Отмена'),
                              ),
                            ),
                          ],
                        ),
                      ] else
                        OutlinedButton.icon(
                          onPressed: () => _openExportMenu(filteredReceipts),
                          icon: const Icon(Icons.table_view_outlined, size: 18),
                          label: const Text('Экспорт Excel'),
                        ),
                      const SizedBox(height: 8),
                    ],
                    OutlinedButton.icon(
                      onPressed: _openSyncScreen,
                      icon: const Icon(Icons.sync, size: 18),
                      label: const Text('Wi-Fi Синхр.'),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _currentTab == 0
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: 420,
                              child: _buildReceiptsList(
                                filteredReceipts: filteredReceipts,
                                isDesktop: true,
                                activeDesktopId: activeDesktopId,
                              ),
                            ),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  4,
                                  16,
                                  16,
                                  16,
                                ),
                                child: GlassCard(
                                  borderRadius: 24,
                                  child: activeDesktopId == null
                                      ? const Center(
                                          child: Text(
                                            'Выберите чек слева или создайте новый',
                                            style: TextStyle(
                                              color: GlassColors.textSecondary,
                                              fontSize: 15,
                                            ),
                                          ),
                                        )
                                      : ReceiptDetailContent(
                                          receiptId: activeDesktopId,
                                          showInlineToolbar: true,
                                          onDataChanged: _loadReceipts,
                                          onDeleted: _loadReceipts,
                                        ),
                                ),
                              ),
                            ),
                          ],
                        )
                      : AnalyticsTab(receipts: _receipts),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileLayout(List<Receipt> filteredReceipts) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    _isSelectionMode = false;
                    _selectedReceiptIds.clear();
                  });
                },
              )
            : null,
        title: Text(
          _isSelectionMode
              ? 'Выбрано: ${_selectedReceiptIds.length}'
              : (_currentTab == 0 ? 'Карманный чек' : 'Цены и сравнение'),
        ),
        actions: [
          if (_currentTab == 0 && _isSelectionMode)
            IconButton(
              icon: const Icon(Icons.select_all),
              tooltip: 'Выбрать все',
              onPressed: () {
                setState(() {
                  for (final r in filteredReceipts) {
                    _selectedReceiptIds.add(r.id);
                  }
                });
              },
            )
          else if (!_isSelectionMode) ...[
            if (_currentTab == 0 && filteredReceipts.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.table_view_outlined),
                tooltip: 'Экспорт в Excel',
                onPressed: () => _openExportMenu(filteredReceipts),
              ),
            IconButton(
              icon: const Icon(Icons.sync),
              tooltip: 'Синхронизация по Wi-Fi',
              onPressed: _openSyncScreen,
            ),
          ],
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _currentTab == 0
              ? _buildReceiptsList(
                  filteredReceipts: filteredReceipts,
                  isDesktop: false,
                  activeDesktopId: null,
                )
              : AnalyticsTab(receipts: _receipts),
      floatingActionButton: _currentTab == 0
          ? (_isSelectionMode
              ? (_selectedReceiptIds.isNotEmpty
                  ? FloatingActionButton.extended(
                      backgroundColor: GlassColors.accent,
                      foregroundColor: Colors.white,
                      onPressed: _exportSelectedReceipts,
                      icon: const Icon(Icons.table_view),
                      label: Text('В Excel (${_selectedReceiptIds.length})'),
                    )
                  : null)
              : FloatingActionButton.extended(
                  backgroundColor: GlassColors.accent,
                  foregroundColor: Colors.white,
                  onPressed: () => _openAddReceipt(),
                  icon: const Icon(Icons.add),
                  label: const Text('Чек'),
                ))
          : null,
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          child: GlassCard(
            borderRadius: 26,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            tintColor: GlassColors.dockFill,
            child: Row(
              children: [
                Expanded(
                  child: _MobileNavButton(
                    icon: Icons.receipt_long_rounded,
                    label: 'Чеки',
                    selected: _currentTab == 0,
                    onTap: () => setState(() => _currentTab = 0),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MobileNavButton(
                    icon: Icons.show_chart_rounded,
                    label: 'Цены',
                    selected: _currentTab == 1,
                    onTap: () {
                      setState(() {
                        _currentTab = 1;
                        _isSelectionMode = false;
                        _selectedReceiptIds.clear();
                      });
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredReceipts = _getFilteredReceipts();

    return GlassBackground(
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= 960) {
            return _buildDesktopLayout(filteredReceipts);
          }
          return _buildMobileLayout(filteredReceipts);
        },
      ),
    );
  }
}

class _DesktopNavTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _DesktopNavTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: selected ? GlassColors.selectedTint : GlassColors.cardFill,
            border: Border.all(
              color: selected
                  ? GlassColors.accentLuminous.withAlpha(140)
                  : GlassColors.cardBorder,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: selected
                    ? GlassColors.accentHeroText
                    : GlassColors.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? GlassColors.textPrimary
                        : GlassColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileNavButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _MobileNavButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: selected ? GlassColors.selectedTint : Colors.transparent,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 20,
                color: selected
                    ? GlassColors.accentLuminous
                    : GlassColors.textSecondary,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? GlassColors.textPrimary
                      : GlassColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}