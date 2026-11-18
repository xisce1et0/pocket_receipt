import 'dart:io';
import 'package:material_ui/material_ui.dart';
import '../models/receipt.dart';
import '../services/database_service.dart';
import '../services/excel_export_service.dart';
import '../utils/price_analytics.dart';
import 'glass_ui.dart';
import 'multi_group_input.dart';
import 'price_history_sheet.dart';

class ReceiptDetailContent extends StatefulWidget {
  final String receiptId;
  final VoidCallback? onDataChanged;
  final VoidCallback? onDeleted;
  final bool showInlineToolbar;

  const ReceiptDetailContent({
    super.key,
    required this.receiptId,
    this.onDataChanged,
    this.onDeleted,
    this.showInlineToolbar = false,
  });

  @override
  State<ReceiptDetailContent> createState() => ReceiptDetailContentState();
}

class ReceiptDetailContentState extends State<ReceiptDetailContent> {
  Receipt? _receipt;
  List<Receipt> _allReceipts = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    reloadData();
  }

  @override
  void didUpdateWidget(covariant ReceiptDetailContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.receiptId != widget.receiptId) {
      _isLoading = true;
      reloadData();
    }
  }

  Future<void> reloadData() async {
    final receipt =
        await DatabaseService.instance.getReceiptById(widget.receiptId);
    final all = await DatabaseService.instance.getAllReceipts();
    if (!mounted) return;
    setState(() {
      _receipt = receipt;
      _allReceipts = all;
      _isLoading = false;
    });
  }

  Receipt? get currentReceipt => _receipt;

  void _openPhotoViewer(String path) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
            title: const Text('Фото чека'),
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: Image.file(File(path)),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> editReceiptInfo() async {
    final receipt = _receipt;
    if (receipt == null) return;
    final catalog = buildAutocompleteCatalog(_allReceipts);
    final result = await showDialog<({String storeName, DateTime date})>(
      context: context,
      builder: (context) => _EditReceiptDialog(
        initialStoreName: receipt.storeName,
        initialDate: receipt.date,
        existingStoreNames: catalog.stores,
      ),
    );

    if (result != null) {
      await DatabaseService.instance.updateReceiptInfo(
        receipt.id,
        result.storeName,
        result.date,
      );
      await reloadData();
      widget.onDataChanged?.call();
    }
  }

  Future<void> _editItem(ReceiptItem item) async {
    final catalog = buildAutocompleteCatalog(_allReceipts);
    final result = await showDialog<({ReceiptItem? item, bool deleted})>(
      context: context,
      builder: (context) => _EditItemDialog(
        item: item,
        catalog: catalog,
      ),
    );

    if (result == null) return;
    if (result.deleted) {
      await DatabaseService.instance.deleteReceiptItem(item.id);
      await reloadData();
      widget.onDataChanged?.call();
      return;
    }
    if (result.item != null) {
      await DatabaseService.instance.updateReceiptItem(result.item!);
      await reloadData();
      widget.onDataChanged?.call();
    }
  }

  Future<void> deleteReceipt() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: GlassColors.sheetBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: const BorderSide(color: GlassColors.cardBorder),
        ),
        title: const Text(
          'Удалить чек?',
          style: TextStyle(color: GlassColors.textPrimary),
        ),
        content: const Text(
          'Чек, его товары и сохраненные фото будут удалены безвозвратно.',
          style: TextStyle(color: GlassColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await DatabaseService.instance.deleteReceipt(widget.receiptId);
      if (mounted) {
        widget.onDeleted?.call();
      }
    }
  }

  void exportCurrentToExcel() {
    final receipt = _receipt;
    if (receipt == null) return;
    ExcelExportService.exportReceipts(context, [receipt]);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final receipt = _receipt;
    if (receipt == null) {
      return const Center(
        child: Text(
          'Чек не найден',
          style: TextStyle(color: GlassColors.textSecondary),
        ),
      );
    }

    final existingPhotos = receipt.photoPaths
        .where((path) => File(path).existsSync())
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassCard(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          padding: const EdgeInsets.all(16),
          tintColor: GlassColors.heroTint,
          onTap: editReceiptInfo,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.showInlineToolbar) ...[
                      Text(
                        receipt.storeName,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: GlassColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                    ],
                    Row(
                      children: [
                        Text(
                          'Дата: ${formatDate(receipt.date)}',
                          style: const TextStyle(
                            fontSize: 14,
                            color: GlassColors.textSecondary,
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Icon(
                          Icons.edit_outlined,
                          size: 15,
                          color: GlassColors.textSecondary,
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Итого: ${receipt.totalAmount.toStringAsFixed(2)} ₽',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: GlassColors.accentHeroText,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.showInlineToolbar) ...[
                IconButton(
                  onPressed: exportCurrentToExcel,
                  icon: const Icon(
                    Icons.table_view_outlined,
                    color: GlassColors.textPrimary,
                  ),
                  tooltip: 'Сохранить чек в Excel',
                ),
                IconButton(
                  onPressed: editReceiptInfo,
                  icon: const Icon(
                    Icons.edit_outlined,
                    color: GlassColors.textPrimary,
                  ),
                  tooltip: 'Изменить магазин или дату',
                ),
                IconButton(
                  onPressed: deleteReceipt,
                  icon: const Icon(
                    Icons.delete_outline,
                    color: GlassColors.negative,
                  ),
                  tooltip: 'Удалить чек',
                ),
              ],
            ],
          ),
        ),
        if (existingPhotos.isNotEmpty)
          SizedBox(
            height: 92,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
              itemCount: existingPhotos.length,
              separatorBuilder: (context, index) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final path = existingPhotos[index];
                return GestureDetector(
                  onTap: () => _openPhotoViewer(path),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: GlassColors.cardBorder,
                        width: 1.2,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(11),
                      child: Image.file(
                        File(path),
                        width: 72,
                        height: 80,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 18, vertical: 6),
          child: Text(
            'Нажмите на товар для графика цен или на карандаш для правки',
            style: TextStyle(color: GlassColors.textSecondary, fontSize: 12),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 20),
            itemCount: receipt.items.length,
            itemBuilder: (context, index) {
              final item = receipt.items[index];
              final tags = [
                if (item.brand.isNotEmpty) item.brand,
                ...item.groupList,
              ].join(' • ');
              final subtitle = tags.isEmpty
                  ? '${item.quantity} шт × ${item.price.toStringAsFixed(2)} ₽'
                  : '$tags • ${item.quantity} шт × ${item.price.toStringAsFixed(2)} ₽';

              return GlassCard(
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                borderRadius: 16,
                useBlur: false,
                onTap: () => showPriceHistorySheet(
                  context: context,
                  initialTargets: [
                    ProductTarget(name: item.name, brand: item.brand),
                  ],
                  allReceipts: _allReceipts,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.name,
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
                    Text(
                      '${item.total.toStringAsFixed(2)} ₽',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: GlassColors.textPrimary,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.edit_outlined,
                        size: 20,
                        color: GlassColors.textSecondary,
                      ),
                      onPressed: () => _editItem(item),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _EditReceiptDialog extends StatefulWidget {
  final String initialStoreName;
  final DateTime initialDate;
  final List<String> existingStoreNames;

  const _EditReceiptDialog({
    required this.initialStoreName,
    required this.initialDate,
    required this.existingStoreNames,
  });

  @override
  State<_EditReceiptDialog> createState() => _EditReceiptDialogState();
}

class _EditReceiptDialogState extends State<_EditReceiptDialog> {
  TextEditingController? _storeController;
  late DateTime _selectedDate = widget.initialDate;

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null && mounted) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: GlassColors.sheetBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: GlassColors.cardBorder),
      ),
      scrollable: true,
      title: const Text(
        'Редактировать чек',
        style: TextStyle(color: GlassColors.textPrimary),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Autocomplete<String>(
            initialValue: TextEditingValue(text: widget.initialStoreName),
            optionsMaxHeight: 140,
            optionsBuilder: (textEditingValue) {
              final query = normalizeProductName(textEditingValue.text);
              if (query.isEmpty) return widget.existingStoreNames;
              return widget.existingStoreNames.where(
                (option) => normalizeProductName(option).contains(query),
              );
            },
            fieldViewBuilder: (
              context,
              textEditingController,
              focusNode,
              onFieldSubmitted,
            ) {
              _storeController = textEditingController;
              return TextField(
                controller: textEditingController,
                focusNode: focusNode,
                style: const TextStyle(color: GlassColors.textPrimary),
                decoration: const InputDecoration(labelText: 'Магазин'),
              );
            },
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _pickDate,
            icon: const Icon(Icons.calendar_today, size: 18),
            label: Text('Дата: ${formatDate(_selectedDate)}'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () {
            final storeName = (_storeController?.text ?? '').trim();
            if (storeName.isEmpty) return;
            Navigator.pop(context, (storeName: storeName, date: _selectedDate));
          },
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

class _EditItemDialog extends StatefulWidget {
  final ReceiptItem item;
  final AutocompleteCatalog catalog;

  const _EditItemDialog({
    required this.item,
    required this.catalog,
  });

  @override
  State<_EditItemDialog> createState() => _EditItemDialogState();
}

class _EditItemDialogState extends State<_EditItemDialog> {
  TextEditingController? _nameController;
  TextEditingController? _brandController;
  final _groupInputController = TextEditingController();
  late List<String> _selectedGroups = parseGroupList(widget.item.productGroup);

  late final _priceController = TextEditingController(
    text: widget.item.price.toString(),
  );
  late final _qtyController = TextEditingController(
    text: widget.item.quantity.toString(),
  );

  @override
  void dispose() {
    _groupInputController.dispose();
    _priceController.dispose();
    _qtyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: GlassColors.sheetBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: const BorderSide(color: GlassColors.cardBorder),
      ),
      scrollable: true,
      title: const Text(
        'Редактировать товар',
        style: TextStyle(color: GlassColors.textPrimary),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Autocomplete<String>(
            initialValue: TextEditingValue(text: widget.item.name),
            optionsMaxHeight: 140,
            optionsBuilder: (textEditingValue) {
              final query = normalizeProductName(textEditingValue.text);
              if (query.isEmpty) return widget.catalog.products;
              return widget.catalog.products.where(
                (option) => normalizeProductName(option).contains(query),
              );
            },
            fieldViewBuilder: (
              context,
              textEditingController,
              focusNode,
              onFieldSubmitted,
            ) {
              _nameController = textEditingController;
              return TextField(
                controller: textEditingController,
                focusNode: focusNode,
                style: const TextStyle(color: GlassColors.textPrimary),
                decoration: const InputDecoration(labelText: 'Название'),
              );
            },
          ),
          const SizedBox(height: 8),
          Autocomplete<String>(
            initialValue: TextEditingValue(text: widget.item.brand),
            optionsMaxHeight: 120,
            optionsBuilder: (textEditingValue) {
              final query = normalizeProductName(textEditingValue.text);
              if (query.isEmpty) return widget.catalog.brands;
              return widget.catalog.brands.where(
                (option) => normalizeProductName(option).contains(query),
              );
            },
            fieldViewBuilder: (
              context,
              textEditingController,
              focusNode,
              onFieldSubmitted,
            ) {
              _brandController = textEditingController;
              return TextField(
                controller: textEditingController,
                focusNode: focusNode,
                style: const TextStyle(color: GlassColors.textPrimary),
                decoration: const InputDecoration(labelText: 'Бренд (необяз.)'),
              );
            },
          ),
          const SizedBox(height: 12),
          MultiGroupInput(
            selectedGroups: _selectedGroups,
            availableGroups: widget.catalog.groups,
            textController: _groupInputController,
            onChanged: (groups) {
              setState(() => _selectedGroups = groups);
            },
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _priceController,
            style: const TextStyle(color: GlassColors.textPrimary),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Цена ₽'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _qtyController,
            style: const TextStyle(color: GlassColors.textPrimary),
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Количество'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(context, (item: null, deleted: true)),
          style: TextButton.styleFrom(foregroundColor: GlassColors.negative),
          child: const Text('Удалить'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () {
            final name = (_nameController?.text ?? '').trim();
            final brand = (_brandController?.text ?? '').trim();
            final draftGroup = _groupInputController.text.trim();
            final combinedGroups = draftGroup.isEmpty
                ? _selectedGroups
                : [..._selectedGroups, draftGroup];
            final groupStr = joinGroupList(combinedGroups);

            final price = double.tryParse(
              _priceController.text.trim().replaceAll(',', '.'),
            );
            final qty = int.tryParse(_qtyController.text.trim());

            if (name.isEmpty ||
                price == null ||
                price <= 0 ||
                qty == null ||
                qty <= 0) {
              return;
            }

            Navigator.pop(
              context,
              (
                item: widget.item.copyWith(
                  name: name,
                  brand: brand,
                  productGroup: groupStr,
                  price: price,
                  quantity: qty,
                ),
                deleted: false,
              ),
            );
          },
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}