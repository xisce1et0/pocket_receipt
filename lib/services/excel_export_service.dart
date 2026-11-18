import 'dart:io';
import 'package:excel/excel.dart' as xls;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/receipt.dart';
import '../utils/price_analytics.dart';
import '../widgets/glass_ui.dart';

enum ExcelExportMode { compact, detailed }

class _ProductExcelRow {
  final String name;
  final String brand;
  final List<String> groups = [];
  final List<double> unitPrices = [];
  int totalQty = 0;
  double totalSpent = 0;

  _ProductExcelRow({required this.name, required this.brand});
}

class ExcelExportService {
  static const _xlsxMimeType =
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

  static const _monthNames = [
    'Январь',
    'Февраль',
    'Март',
    'Апрель',
    'Май',
    'Июнь',
    'Июль',
    'Август',
    'Сентябрь',
    'Октябрь',
    'Ноябрь',
    'Декабрь',
  ];

  static double _round2(double val) => double.parse(val.toStringAsFixed(2));

  static Uint8List buildExcelBytes(
    List<Receipt> receipts, {
    ExcelExportMode mode = ExcelExportMode.compact,
  }) {
    final workbook = xls.Excel.createExcel();
    final defaultSheet = workbook.getDefaultSheet();

    final sortedReceipts = List<Receipt>.from(receipts)
      ..sort((a, b) => b.date.compareTo(a.date));

    double grandTotal = 0;
    for (final r in sortedReceipts) {
      grandTotal += r.totalAmount;
    }

    final overviewSheet = workbook['Сводка'];
    overviewSheet.appendRow([xls.TextCellValue('Сводка по месяцам')]);
    overviewSheet.appendRow([
      xls.TextCellValue('Месяц'),
      xls.TextCellValue('Чеков'),
      xls.TextCellValue('Потрачено (₽)'),
    ]);

    final monthBuckets =
        <String, ({String label, int count, double spent})>{};
    for (final r in sortedReceipts) {
      final key = '${r.date.year}-${r.date.month.toString().padLeft(2, '0')}';
      final label = '${_monthNames[r.date.month - 1]} ${r.date.year}';
      final prev = monthBuckets[key];
      monthBuckets[key] = (
        label: label,
        count: (prev?.count ?? 0) + 1,
        spent: (prev?.spent ?? 0) + r.totalAmount,
      );
    }

    final monthKeys = monthBuckets.keys.toList()..sort((a, b) => b.compareTo(a));
    for (final key in monthKeys) {
      final b = monthBuckets[key]!;
      overviewSheet.appendRow([
        xls.TextCellValue(b.label),
        xls.IntCellValue(b.count),
        xls.DoubleCellValue(_round2(b.spent)),
      ]);
    }

    overviewSheet.appendRow([]);
    overviewSheet.appendRow([xls.TextCellValue('Расходы по группам')]);
    overviewSheet.appendRow([
      xls.TextCellValue('Группа'),
      xls.TextCellValue('Штук'),
      xls.TextCellValue('Потрачено (₽)'),
      xls.TextCellValue('Доля (%)'),
    ]);

    final groupBuckets = <String, ({String label, int qty, double spent})>{};
    int allItemsQty = 0;

    for (final r in sortedReceipts) {
      for (final item in r.items) {
        allItemsQty += item.quantity;
        final primaryGroup =
            item.groupList.isNotEmpty ? item.groupList.first : 'Без группы';
        final key = normalizeProductName(primaryGroup);
        final prev = groupBuckets[key];
        groupBuckets[key] = (
          label: prev?.label ?? primaryGroup,
          qty: (prev?.qty ?? 0) + item.quantity,
          spent: (prev?.spent ?? 0) + item.total,
        );
      }
    }

    final sortedGroups = groupBuckets.values.toList()
      ..sort((a, b) => b.spent.compareTo(a.spent));

    for (final g in sortedGroups) {
      final share = grandTotal > 0 ? (g.spent / grandTotal) * 100 : 0.0;
      overviewSheet.appendRow([
        xls.TextCellValue(g.label),
        xls.IntCellValue(g.qty),
        xls.DoubleCellValue(_round2(g.spent)),
        xls.DoubleCellValue(_round2(share)),
      ]);
    }

    overviewSheet.appendRow([
      xls.TextCellValue('ИТОГО'),
      xls.IntCellValue(allItemsQty),
      xls.DoubleCellValue(_round2(grandTotal)),
      xls.DoubleCellValue(grandTotal > 0 ? 100.0 : 0.0),
    ]);

    final productsSheet = workbook['Товары'];
    productsSheet.appendRow([
      xls.TextCellValue('Товар'),
      xls.TextCellValue('Бренд'),
      xls.TextCellValue('Группы'),
      xls.TextCellValue('Покупок'),
      xls.TextCellValue('Кол-во (шт)'),
      xls.TextCellValue('Мин (₽)'),
      xls.TextCellValue('Медиана (₽)'),
      xls.TextCellValue('Макс (₽)'),
      xls.TextCellValue('Потрачено (₽)'),
    ]);

    final productMap = <String, _ProductExcelRow>{};
    for (final r in sortedReceipts) {
      for (final item in r.items) {
        final target = ProductTarget(
          name: item.name.trim(),
          brand: item.brand.trim(),
        );
        final row = productMap.putIfAbsent(
          target.key,
          () => _ProductExcelRow(
            name: item.name.trim(),
            brand: item.brand.trim(),
          ),
        );
        row.groups.addAll(item.groupList);
        row.unitPrices.add(item.price);
        row.totalQty += item.quantity;
        row.totalSpent += item.total;
      }
    }

    final sortedProducts = productMap.values.toList()
      ..sort((a, b) => b.totalSpent.compareTo(a.totalSpent));

    int totalPurchases = 0;
    int totalProductQty = 0;
    double totalProductSpent = 0;

    for (final pRow in sortedProducts) {
      final sortedPrices = List<double>.from(pRow.unitPrices)..sort();
      final minPrice = sortedPrices.first;
      final maxPrice = sortedPrices.last;
      final median = calculateMedian(pRow.unitPrices);

      totalPurchases += pRow.unitPrices.length;
      totalProductQty += pRow.totalQty;
      totalProductSpent += pRow.totalSpent;

      productsSheet.appendRow([
        xls.TextCellValue(pRow.name),
        xls.TextCellValue(pRow.brand),
        xls.TextCellValue(joinGroupList(pRow.groups)),
        xls.IntCellValue(pRow.unitPrices.length),
        xls.IntCellValue(pRow.totalQty),
        xls.DoubleCellValue(_round2(minPrice)),
        xls.DoubleCellValue(_round2(median)),
        xls.DoubleCellValue(_round2(maxPrice)),
        xls.DoubleCellValue(_round2(pRow.totalSpent)),
      ]);
    }

    productsSheet.appendRow([
      xls.TextCellValue('ИТОГО (${sortedProducts.length} поз.)'),
      xls.TextCellValue(''),
      xls.TextCellValue(''),
      xls.IntCellValue(totalPurchases),
      xls.IntCellValue(totalProductQty),
      xls.TextCellValue(''),
      xls.TextCellValue(''),
      xls.TextCellValue(''),
      xls.DoubleCellValue(_round2(totalProductSpent)),
    ]);

    final summarySheet = workbook['Чеки'];
    summarySheet.appendRow([
      xls.TextCellValue('Дата'),
      xls.TextCellValue('Магазин'),
      xls.TextCellValue('Позиций'),
      xls.TextCellValue('Сумма (₽)'),
    ]);

    int totalPositions = 0;
    for (final receipt in sortedReceipts) {
      totalPositions += receipt.items.length;
      summarySheet.appendRow([
        xls.TextCellValue(formatDate(receipt.date)),
        xls.TextCellValue(receipt.storeName),
        xls.IntCellValue(receipt.items.length),
        xls.DoubleCellValue(_round2(receipt.totalAmount)),
      ]);
    }

    summarySheet.appendRow([
      xls.TextCellValue('ИТОГО'),
      xls.TextCellValue('Чеков: ${sortedReceipts.length}'),
      xls.IntCellValue(totalPositions),
      xls.DoubleCellValue(_round2(grandTotal)),
    ]);

    if (mode == ExcelExportMode.detailed) {
      final historySheet = workbook['История'];
      historySheet.appendRow([
        xls.TextCellValue('Дата'),
        xls.TextCellValue('Магазин'),
        xls.TextCellValue('Товар'),
        xls.TextCellValue('Бренд'),
        xls.TextCellValue('Группы'),
        xls.TextCellValue('Цена (₽)'),
        xls.TextCellValue('Кол-во'),
        xls.TextCellValue('Сумма (₽)'),
      ]);

      for (final receipt in sortedReceipts) {
        final dateStr = formatDate(receipt.date);
        for (final item in receipt.items) {
          historySheet.appendRow([
            xls.TextCellValue(dateStr),
            xls.TextCellValue(receipt.storeName),
            xls.TextCellValue(item.name),
            xls.TextCellValue(item.brand),
            xls.TextCellValue(item.productGroup),
            xls.DoubleCellValue(_round2(item.price)),
            xls.IntCellValue(item.quantity),
            xls.DoubleCellValue(_round2(item.total)),
          ]);
        }
      }

      historySheet.appendRow([
        xls.TextCellValue('ИТОГО'),
        xls.TextCellValue(''),
        xls.TextCellValue(''),
        xls.TextCellValue(''),
        xls.TextCellValue(''),
        xls.TextCellValue(''),
        xls.IntCellValue(allItemsQty),
        xls.DoubleCellValue(_round2(grandTotal)),
      ]);
    }

    const created = {'Сводка', 'Товары', 'Чеки', 'История'};
    if (defaultSheet != null && !created.contains(defaultSheet)) {
      workbook.delete(defaultSheet);
    }

    final encoded = workbook.encode();
    if (encoded == null) return Uint8List(0);
    return Uint8List.fromList(encoded);
  }

  static String _buildFileName(List<Receipt> receipts, ExcelExportMode mode) {
    final now = DateTime.now();
    final dateTag =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final suffix = mode == ExcelExportMode.detailed ? '_full' : '';
    if (receipts.length == 1) {
      return 'chek_$dateTag$suffix.xlsx';
    }
    return 'cheki_${receipts.length}_$dateTag$suffix.xlsx';
  }

  static Future<void> exportReceipts(
    BuildContext context,
    List<Receipt> receipts,
  ) async {
    if (receipts.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет чеков для экспорта')),
      );
      return;
    }

    final isDesktop =
        !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

    if (isDesktop) {
      final mode = await _pickDesktopMode(context, receipts.length);
      if (mode == null || !context.mounted) return;
      final bytes = buildExcelBytes(receipts, mode: mode);
      await _saveViaPicker(context, _buildFileName(receipts, mode), bytes);
      return;
    }

    var selectedMode = ExcelExportMode.compact;
    final result =
        await showModalBottomSheet<({String action, ExcelExportMode mode})>(
      context: context,
      isScrollControlled: true,
      backgroundColor: GlassColors.sheetBg,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
                      child: Text(
                        'Экспорт в Excel (${receipts.length} чек.)',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: GlassColors.textPrimary,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          GlassPillChip(
                            label: 'Компактный (Сводка + Товары)',
                            compact: true,
                            selected: selectedMode == ExcelExportMode.compact,
                            onTap: () {
                              setModalState(() {
                                selectedMode = ExcelExportMode.compact;
                              });
                            },
                          ),
                          GlassPillChip(
                            label: 'Подробный (+ История по дням)',
                            compact: true,
                            selected: selectedMode == ExcelExportMode.detailed,
                            onTap: () {
                              setModalState(() {
                                selectedMode = ExcelExportMode.detailed;
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Divider(height: 1, color: GlassColors.divider),
                    ListTile(
                      leading: const Icon(
                        Icons.save_alt,
                        color: GlassColors.accentLuminous,
                      ),
                      title: const Text(
                        'Сохранить на телефон (в Загрузки)',
                        style: TextStyle(color: GlassColors.textPrimary),
                      ),
                      onTap: () => Navigator.pop(
                        sheetContext,
                        (action: 'save', mode: selectedMode),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(
                        Icons.share,
                        color: GlassColors.accentLuminous,
                      ),
                      title: const Text(
                        'Отправить / Открыть в Excel',
                        style: TextStyle(color: GlassColors.textPrimary),
                      ),
                      onTap: () => Navigator.pop(
                        sheetContext,
                        (action: 'share', mode: selectedMode),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );

    if (!context.mounted || result == null) return;

    final bytes = buildExcelBytes(receipts, mode: result.mode);
    final fileName = _buildFileName(receipts, result.mode);

    if (result.action == 'save') {
      await _saveViaPicker(context, fileName, bytes);
    } else if (result.action == 'share') {
      final tempDir = await getTemporaryDirectory();
      final tempFile = File(p.join(tempDir.path, fileName));
      await tempFile.writeAsBytes(bytes, flush: true);

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(tempFile.path, mimeType: _xlsxMimeType)],
          subject: 'Экспорт чеков в Excel',
        ),
      );
    }
  }

  static Future<ExcelExportMode?> _pickDesktopMode(
    BuildContext context,
    int count,
  ) {
    return showDialog<ExcelExportMode>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: GlassColors.sheetBg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: const BorderSide(color: GlassColors.cardBorder),
        ),
        title: Text(
          'Экспорт в Excel ($count чек.)',
          style: const TextStyle(color: GlassColors.textPrimary),
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '• Компактный: 3 листа (Сводка по месяцам и группам, Товары с медианой без повторов, Чеки).',
              style: TextStyle(color: GlassColors.textSecondary),
            ),
            SizedBox(height: 8),
            Text(
              '• Подробный: добавляет 4-й лист «История» со всеми позициями по дням.',
              style: TextStyle(color: GlassColors.textSecondary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Отмена'),
          ),
          OutlinedButton(
            onPressed: () =>
                Navigator.pop(dialogContext, ExcelExportMode.detailed),
            child: const Text('Подробный'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, ExcelExportMode.compact),
            child: const Text('Компактный'),
          ),
        ],
      ),
    );
  }

  static Future<void> _saveViaPicker(
    BuildContext context,
    String fileName,
    Uint8List bytes,
  ) async {
    final savedUri = await FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      mimeType: _xlsxMimeType,
    );

    if (savedUri == null || !context.mounted) return;

    if (savedUri.scheme == 'file') {
      final outFile = File(savedUri.toFilePath());
      if (await outFile.exists() && await outFile.length() == 0) {
        await outFile.writeAsBytes(bytes, flush: true);
      }
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Сохранено: ${outFile.path}')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Файл $fileName сохранен!')),
      );
    }
  }
}