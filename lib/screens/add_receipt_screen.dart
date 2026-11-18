import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import '../models/receipt.dart';
import '../services/database_service.dart';
import '../services/ocr_service.dart';
import '../utils/auto_grouper.dart';
import '../utils/price_analytics.dart';
import '../utils/receipt_parser.dart';
import '../widgets/glass_ui.dart';
import '../widgets/multi_group_input.dart';
import 'qr_scanner_screen.dart';

class AddReceiptScreen extends StatefulWidget {
  final List<Receipt> allReceipts;
  final List<String> initialPhotoPaths;

  const AddReceiptScreen({
    super.key,
    this.allReceipts = const [],
    this.initialPhotoPaths = const [],
  });

  @override
  State<AddReceiptScreen> createState() => _AddReceiptScreenState();
}

class _AddReceiptScreenState extends State<AddReceiptScreen> {
  final _itemPriceController = TextEditingController();
  final _itemQtyController = TextEditingController(text: '1');
  final _groupInputController = TextEditingController();

  TextEditingController? _storeController;
  TextEditingController? _itemNameController;
  TextEditingController? _brandController;

  late final AutocompleteCatalog _catalog =
      buildAutocompleteCatalog(widget.allReceipts);

  DateTime _selectedDate = DateTime.now();
  double? _expectedQrTotal;
  List<String> _selectedGroups = [];
  final List<String> _photoPaths = [];
  final List<String> _ocrTexts = [];
  bool _isRecognizingOcr = false;
  bool _isSaving = false;
  final List<ReceiptItem> _items = [];

  bool get _isMobilePlatform =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  bool get _isDesktopPlatform =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  @override
  void initState() {
    super.initState();
    if (widget.initialPhotoPaths.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _processNewPhotos(widget.initialPhotoPaths);
        }
      });
    }
  }

  @override
  void dispose() {
    _itemPriceController.dispose();
    _itemQtyController.dispose();
    _groupInputController.dispose();
    super.dispose();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2015),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null && mounted) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  Future<void> _scanQrCode() async {
    final scannedRaw = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => const QrScannerScreen(
          title: 'QR-код чека',
          hint: 'Поместите квадратный QR-код внизу чека внутрь рамки',
        ),
      ),
    );

    if (scannedRaw == null || !mounted) return;

    final qr = parseRussianFiscalQr(scannedRaw);
    if (qr == null) {
      _showMessage('Код считан, но это не фискальный QR чека');
      return;
    }

    setState(() {
      if (qr.date != null) _selectedDate = qr.date!;
      if (qr.totalSum != null) _expectedQrTotal = qr.totalSum;
    });

    final sumText = qr.totalSum != null
        ? ' • Сумма по чеку: ${qr.totalSum!.toStringAsFixed(2)} ₽'
        : '';
    _showMessage('QR распознан! Дата: ${formatDate(_selectedDate)}$sumText');
  }

  Future<void> _takeCameraPhoto() async {
    if (_isRecognizingOcr) return;
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.camera);
    if (picked == null || !mounted) return;
    await _processNewPhotos([picked.path]);
  }

  Future<void> _pickGalleryPhotos() async {
    if (_isRecognizingOcr) return;
    final picker = ImagePicker();
    final pickedList = await picker.pickMultiImage();
    if (pickedList.isEmpty || !mounted) return;
    await _processNewPhotos(pickedList.map((f) => f.path).toList());
  }

  Future<void> _processNewPhotos(List<String> newPaths) async {
    setState(() {
      _photoPaths.addAll(newPaths);
      _isRecognizingOcr = true;
    });

    int addedCount = 0;
    int skippedCount = 0;

    try {
      for (final path in newPaths) {
        final ocrText = await OcrService.recognizeReceiptText(path);
        if (!mounted) return;
        if (ocrText == null || ocrText.trim().isEmpty) continue;

        _ocrTexts.add(ocrText);
        final parsed = parseReceiptText(
          ocrText,
          existingReceipts: widget.allReceipts,
        );

        final dedup = deduplicateOverlapItems(
          existingItems: _items,
          incomingItems: parsed.items,
        );

        setState(() {
          if (parsed.storeName != null &&
              (_storeController?.text ?? '').trim().isEmpty) {
            _storeController?.text = parsed.storeName!;
          }
          if (parsed.date != null && _expectedQrTotal == null) {
            _selectedDate = parsed.date!;
          }
          if (parsed.totalSum != null && _expectedQrTotal == null) {
            _expectedQrTotal = parsed.totalSum;
          }
          _items.addAll(dedup.newItems);
        });

        addedCount += dedup.newItems.length;
        skippedCount += dedup.skippedDuplicates;
      }

      if (!mounted) return;
      setState(() => _isRecognizingOcr = false);

      if (addedCount > 0) {
        final dedupNote = skippedCount > 0
            ? ' (пропущено повторов на стыке: $skippedCount)'
            : '';
        _showMessage('Распознано товаров: $addedCount$dedupNote');
      } else {
        _showMessage(
          'Фото добавлено, но новые товары не определились (см. "Текст OCR")',
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isRecognizingOcr = false);
      _showMessage('Ошибка OCR: $e');
    }
  }

  void _showRawOcrDialog() {
    if (_ocrTexts.isEmpty) return;
    final combined = _ocrTexts.asMap().entries.map((e) {
      return '--- Фото ${e.key + 1} ---\n${e.value}';
    }).join('\n\n');

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: GlassColors.sheetBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: const BorderSide(color: GlassColors.cardBorder),
        ),
        scrollable: true,
        title: const Text(
          'Что увидел OCR',
          style: TextStyle(color: GlassColors.textPrimary),
        ),
        content: SelectableText(
          combined,
          style: const TextStyle(color: GlassColors.textPrimary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Future<void> _openPasteImportDialog() async {
    final rawText = await showDialog<String>(
      context: context,
      builder: (context) => const _PasteReceiptDialog(),
    );

    if (rawText == null || rawText.trim().isEmpty || !mounted) return;

    final parsed = parseReceiptText(
      rawText,
      existingReceipts: widget.allReceipts,
    );

    setState(() {
      if (parsed.storeName != null &&
          (_storeController?.text ?? '').trim().isEmpty) {
        _storeController?.text = parsed.storeName!;
      }
      if (parsed.date != null) {
        _selectedDate = parsed.date!;
      }
      if (parsed.totalSum != null) {
        _expectedQrTotal = parsed.totalSum;
      }
      if (parsed.items.isNotEmpty) {
        _items.addAll(parsed.items);
      }
    });

    if (parsed.items.isNotEmpty) {
      _showMessage('Распознано товаров: ${parsed.items.length}');
    } else if (parsed.totalSum != null) {
      _showMessage(
        'QR распознан! Сумма по чеку: ${parsed.totalSum!.toStringAsFixed(2)} ₽',
      );
    } else {
      _showMessage('Не удалось распознать товары — проверьте текст');
    }
  }

  void _onProductSelected(String productName) {
    final defaults = _catalog.productDefaults[normalizeProductName(productName)];
    if (defaults == null) return;

    if ((_brandController?.text ?? '').trim().isEmpty &&
        defaults.brand.isNotEmpty) {
      _brandController?.text = defaults.brand;
    }
    if (_selectedGroups.isEmpty && defaults.group.isNotEmpty) {
      setState(() {
        _selectedGroups = parseGroupList(defaults.group);
      });
    }
  }

  void _addItem() {
    final name = (_itemNameController?.text ?? '').trim();
    final brand = (_brandController?.text ?? '').trim();
    final draftGroup = _groupInputController.text.trim();
    var combinedGroups = draftGroup.isEmpty
        ? _selectedGroups
        : [..._selectedGroups, draftGroup];

    if (combinedGroups.isEmpty && name.isNotEmpty) {
      combinedGroups = suggestGroupsForProduct(name);
    }
    final groupStr = joinGroupList(combinedGroups);

    final priceText = _itemPriceController.text.trim().replaceAll(',', '.');
    final price = double.tryParse(priceText);
    final qty = int.tryParse(_itemQtyController.text.trim()) ?? 1;

    if (name.isEmpty) {
      _showMessage('Введите название товара');
      return;
    }
    if (price == null || price <= 0) {
      _showMessage('Введите корректную цену');
      return;
    }

    setState(() {
      _items.add(
        ReceiptItem(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: name,
          brand: brand,
          productGroup: groupStr,
          price: price,
          quantity: qty > 0 ? qty : 1,
        ),
      );
      _itemNameController?.clear();
      _brandController?.clear();
      _selectedGroups = [];
      _groupInputController.clear();
      _itemPriceController.clear();
      _itemQtyController.text = '1';
    });
  }

  Future<void> _saveReceipt() async {
    if (_isSaving) return;
    final store = (_storeController?.text ?? '').trim();
    if (store.isEmpty) {
      _showMessage('Введите название магазина');
      return;
    }
    if (_items.isEmpty) {
      _showMessage('Добавьте хотя бы один товар');
      return;
    }

    setState(() => _isSaving = true);

    final receiptId = DateTime.now().millisecondsSinceEpoch.toString();
    final permanentPhotos = await DatabaseService.instance.savePhotosPermanently(
      receiptId,
      _photoPaths,
    );

    if (!mounted) return;
    final receipt = Receipt(
      id: receiptId,
      storeName: store,
      date: _selectedDate,
      items: List.from(_items),
      photoPaths: permanentPhotos,
    );

    Navigator.pop(context, receipt);
  }

  @override
  Widget build(BuildContext context) {
    double currentTotal = 0;
    for (final item in _items) {
      currentTotal += item.total;
    }

    final qrTotal = _expectedQrTotal;
    final totalsMatch =
        qrTotal != null && (currentTotal - qrTotal).abs() < 0.01;

    return GlassBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('Новый чек'),
          actions: [
            if (_isMobilePlatform)
              IconButton(
                onPressed: _scanQrCode,
                icon: const Icon(Icons.qr_code_scanner),
                tooltip: 'Сканер QR (только дата и сумма)',
              ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    GlassCard(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_isMobilePlatform) ...[
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton.tonalIcon(
                                    onPressed: _isRecognizingOcr
                                        ? null
                                        : _takeCameraPhoto,
                                    icon: const Icon(Icons.camera_alt_outlined),
                                    label: Text(
                                      _photoPaths.isEmpty
                                          ? 'Фото чека'
                                          : '+ Ещё фото',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: FilledButton.tonalIcon(
                                    onPressed: _isRecognizingOcr
                                        ? null
                                        : _pickGalleryPhotos,
                                    icon: const Icon(
                                      Icons.photo_library_outlined,
                                    ),
                                    label: const Text('Из галереи'),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                          ] else if (_isDesktopPlatform &&
                              OcrService.isSupported) ...[
                            FilledButton.tonalIcon(
                              onPressed: _isRecognizingOcr
                                  ? null
                                  : _pickGalleryPhotos,
                              icon: const Icon(
                                Icons.add_photo_alternate_outlined,
                              ),
                              label: Text(
                                _photoPaths.isEmpty
                                    ? 'Загрузить фото / скрин чека (можно несколько)'
                                    : '+ Загрузить ещё фото чека',
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                          OutlinedButton.icon(
                            onPressed: _openPasteImportDialog,
                            icon: const Icon(Icons.text_snippet_outlined),
                            label: const Text('Вставить текст чека'),
                          ),
                          if (_isRecognizingOcr) ...[
                            const SizedBox(height: 12),
                            const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                  ),
                                ),
                                SizedBox(width: 10),
                                Text(
                                  'Распознаём чек оффлайн...',
                                  style: TextStyle(
                                    color: GlassColors.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (qrTotal != null) ...[
                      const SizedBox(height: 10),
                      GlassCard(
                        padding: const EdgeInsets.all(12),
                        borderRadius: 16,
                        tintColor: totalsMatch
                            ? GlassColors.successTint
                            : GlassColors.warningTint,
                        child: Row(
                          children: [
                            Icon(
                              totalsMatch ? Icons.check_circle : Icons.receipt,
                              color: totalsMatch
                                  ? GlassColors.positive
                                  : GlassColors.chartMedian,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                totalsMatch
                                    ? 'Сумма сходится с итогом чека (${qrTotal.toStringAsFixed(2)} ₽)'
                                    : 'Итог по чеку: ${qrTotal.toStringAsFixed(2)} ₽ (сейчас набрано: ${currentTotal.toStringAsFixed(2)} ₽)',
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: GlassColors.textPrimary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (_photoPaths.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      GlassCard(
                        padding: const EdgeInsets.all(10),
                        useBlur: false,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              height: 100,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: _photoPaths.length,
                                separatorBuilder: (context, index) =>
                                    const SizedBox(width: 8),
                                itemBuilder: (context, index) {
                                  return Stack(
                                    children: [
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(10),
                                        child: Image.file(
                                          File(_photoPaths[index]),
                                          height: 100,
                                          width: 80,
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                      Positioned(
                                        top: 3,
                                        right: 3,
                                        child: GestureDetector(
                                          onTap: () {
                                            setState(() {
                                              _photoPaths.removeAt(index);
                                            });
                                          },
                                          child: const CircleAvatar(
                                            radius: 11,
                                            backgroundColor: Colors.black54,
                                            child: Icon(
                                              Icons.close,
                                              size: 14,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Прикреплено фото: ${_photoPaths.length}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: GlassColors.textSecondary,
                                  ),
                                ),
                                if (_ocrTexts.isNotEmpty)
                                  TextButton.icon(
                                    onPressed: _showRawOcrDialog,
                                    icon: const Icon(
                                      Icons.article_outlined,
                                      size: 18,
                                    ),
                                    label: const Text('Текст OCR'),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    GlassCard(
                      padding: const EdgeInsets.all(14),
                      useBlur: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Autocomplete<String>(
                            optionsMaxHeight: 160,
                            optionsBuilder: (textEditingValue) {
                              final query = normalizeProductName(
                                textEditingValue.text,
                              );
                              if (query.isEmpty) return _catalog.stores;
                              return _catalog.stores.where(
                                (option) => normalizeProductName(option)
                                    .contains(query),
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
                                style: const TextStyle(
                                  color: GlassColors.textPrimary,
                                ),
                                decoration: const InputDecoration(
                                  labelText: 'Магазин (выберите или введите)',
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 10),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: GlassPillChip(
                              icon: Icons.calendar_today,
                              label: 'Дата чека: ${formatDate(_selectedDate)}',
                              selected: false,
                              onTap: _pickDate,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Autocomplete<String>(
                            optionsMaxHeight: 160,
                            onSelected: _onProductSelected,
                            optionsBuilder: (textEditingValue) {
                              final query = normalizeProductName(
                                textEditingValue.text,
                              );
                              if (query.isEmpty) {
                                return const Iterable<String>.empty();
                              }
                              return _catalog.products.where(
                                (option) => normalizeProductName(option)
                                    .contains(query),
                              );
                            },
                            fieldViewBuilder: (
                              context,
                              textEditingController,
                              focusNode,
                              onFieldSubmitted,
                            ) {
                              _itemNameController = textEditingController;
                              return TextField(
                                controller: textEditingController,
                                focusNode: focusNode,
                                style: const TextStyle(
                                  color: GlassColors.textPrimary,
                                ),
                                decoration: const InputDecoration(
                                  labelText: 'Товар (начните вводить)',
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 8),
                          Autocomplete<String>(
                            optionsMaxHeight: 140,
                            optionsBuilder: (textEditingValue) {
                              final query = normalizeProductName(
                                textEditingValue.text,
                              );
                              if (query.isEmpty) return _catalog.brands;
                              return _catalog.brands.where(
                                (o) => normalizeProductName(o).contains(query),
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
                                style: const TextStyle(
                                  color: GlassColors.textPrimary,
                                ),
                                decoration: const InputDecoration(
                                  labelText: 'Бренд / Производитель (необяз.)',
                                ),
                              );
                            },
                          ),
                          const SizedBox(height: 8),
                          MultiGroupInput(
                            selectedGroups: _selectedGroups,
                            availableGroups: _catalog.groups,
                            textController: _groupInputController,
                            onChanged: (groups) {
                              setState(() => _selectedGroups = groups);
                            },
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: TextField(
                                  controller: _itemPriceController,
                                  style: const TextStyle(
                                    color: GlassColors.textPrimary,
                                  ),
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                                  decoration: const InputDecoration(
                                    labelText: 'Цена ₽',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TextField(
                                  controller: _itemQtyController,
                                  style: const TextStyle(
                                    color: GlassColors.textPrimary,
                                  ),
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'Кол-во',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton.filled(
                                onPressed: _addItem,
                                icon: const Icon(Icons.add),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_items.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Center(
                          child: Text(
                            'Добавьте товары из чека выше',
                            style: TextStyle(color: GlassColors.textSecondary),
                          ),
                        ),
                      )
                    else
                      ...List.generate(_items.length, (index) {
                        final item = _items[index];
                        final tags = [
                          if (item.brand.isNotEmpty) item.brand,
                          ...item.groupList,
                        ].join(' • ');
                        final subtitle = tags.isEmpty
                            ? '${item.quantity} × ${item.price.toStringAsFixed(2)} ₽'
                            : '$tags • ${item.quantity} × ${item.price.toStringAsFixed(2)} ₽';

                        return GlassCard(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          borderRadius: 16,
                          useBlur: false,
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
                                        fontSize: 14,
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
                              Text(
                                '${item.total.toStringAsFixed(2)} ₽',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 14,
                                  color: GlassColors.textPrimary,
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  size: 20,
                                  color: GlassColors.textSecondary,
                                ),
                                onPressed: () {
                                  setState(() {
                                    _items.removeAt(index);
                                  });
                                },
                              ),
                            ],
                          ),
                        );
                      }),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 50,
                      child: FilledButton(
                        onPressed: _isSaving ? null : _saveReceipt,
                        child: Text(
                          'Сохранить чек (${currentTotal.toStringAsFixed(2)} ₽)',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PasteReceiptDialog extends StatefulWidget {
  const _PasteReceiptDialog();

  @override
  State<_PasteReceiptDialog> createState() => _PasteReceiptDialogState();
}

class _PasteReceiptDialogState extends State<_PasteReceiptDialog> {
  final _textController = TextEditingController();

  @override
  void dispose() {
    _textController.dispose();
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
        'Вставить текст чека',
        style: TextStyle(color: GlassColors.textPrimary),
      ),
      content: TextField(
        controller: _textController,
        style: const TextStyle(color: GlassColors.textPrimary),
        maxLines: 7,
        decoration: const InputDecoration(
          hintText: 'Вставьте текст чека (например, из письма)...',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _textController.text),
          child: const Text('Распознать'),
        ),
      ],
    );
  }
}