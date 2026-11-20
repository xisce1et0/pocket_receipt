import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pocket_receipt/models/receipt.dart';
import 'package:pocket_receipt/screens/home_screen.dart';
import 'package:pocket_receipt/services/excel_export_service.dart';
import 'package:pocket_receipt/utils/auto_grouper.dart';
import 'package:pocket_receipt/utils/price_analytics.dart';
import 'package:pocket_receipt/utils/receipt_parser.dart';

void main() {
  testWidgets('Главный экран открывается с заголовком', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: HomeScreen(initialReceipts: [])),
    );
    expect(find.text('Карманный чек'), findsOneWidget);
  });

  test('Расчет медианы работает корректно', () {
    expect(calculateMedian([10, 50, 20]), 20);
    expect(calculateMedian([79, 84, 92, 89]), 86.5);
    expect(calculateMedian([]), 0);
  });

  test('Фильтр по периодам корректно отбирает чеки', () {
    final ref = DateTime(2026, 11, 15, 12, 0);
    final receipts = [
      Receipt(id: '1', storeName: 'A', date: DateTime(2026, 11, 15, 9, 0), items: const []),
      Receipt(id: '2', storeName: 'B', date: DateTime(2026, 11, 10, 10, 0), items: const []),
      Receipt(id: '3', storeName: 'C', date: DateTime(2026, 10, 25, 10, 0), items: const []),
      Receipt(id: '4', storeName: 'D', date: DateTime(2026, 9, 1, 10, 0), items: const []),
      Receipt(id: '5', storeName: 'E', date: DateTime(2025, 1, 1, 10, 0), items: const []),
    ];

    expect(filterReceiptsByPeriod(receipts, StatsPeriod.day, referenceDate: ref).length, 1);
    expect(filterReceiptsByPeriod(receipts, StatsPeriod.week, referenceDate: ref).length, 2);
    expect(filterReceiptsByPeriod(receipts, StatsPeriod.month, referenceDate: ref).length, 3);
    expect(filterReceiptsByPeriod(receipts, StatsPeriod.quarter, referenceDate: ref).length, 4);
    expect(filterReceiptsByPeriod(receipts, StatsPeriod.all, referenceDate: ref).length, 5);
  });

  test('Левенштейн находит опечатки и не путает 450г с 250г', () {
    expect(levenshteinDistance('молоео', 'молоко'), 1);
    expect(isFuzzyProductMatch('молоео', 'Молоко 2.5%'), true);
    expect(isFuzzyProductMatch('СЫР РОСС.НАР.350Г', 'СЫР РОСС. НАР.350Г'), true);
    expect(isFuzzyProductMatch('СПАГЕТТТИНИ 450Г', 'Кофе в зернах 250г'), false);
  });

  test('Авто-группы правильно определяют категории без ложных брендов', () {
    expect(suggestGroupsForProduct('ЧИПСЫ СЫР 14ОГР ЛЕЙЗ'), ['Снеки']);
    expect(suggestGroupsForProduct('КП/МАСЛО СЛИВ 82,5'), ['Молочное']);
    expect(suggestGroupsForProduct('КП/ Т/Б РОМ 2СЛ 4Р'), ['Хозтовары']);
    expect(suggestGroupsForProduct('ЗП/КОЛБ С/К МИЛ САЛ'), ['Мясо']);
    expect(suggestGroupsForProduct('MILKA BUBBLES MOJ.ПО'), ['Сладости']);
    expect(suggestGroupsForProduct('СПАГЕТТТИНИ 450Г'), ['Бакалея']);
  });

  test('Парсер не крадет чужой бренд и ставит авто-группы', () {
    final existing = [
      Receipt(
        id: 'old',
        storeName: 'Магнит',
        date: DateTime(2026, 11, 1),
        items: const [
          ReceiptItem(
            id: 'c1',
            name: 'Кофе в зернах 250г',
            brand: 'Эрра',
            productGroup: 'Кофе',
            price: 500,
          ),
        ],
      ),
    ];

    const auchanText = '''
000 "AWAH"
СПАГЕТТТИНИ 450Г 109.00 *1WT.
=109.00
КП/МАСЛО СЛИВ 82,5 198.19 *1WT.
=198.19
ИТОГО К ОПЛАТЕ =307.19
''';

    final parsed = parseReceiptText(auchanText, existingReceipts: existing);
    expect(parsed.items.length, 2);
    expect(parsed.items[0].brand, '');
    expect(parsed.items[0].productGroup, 'Бакалея');
    expect(parsed.items[1].brand, '');
    expect(parsed.items[1].productGroup, 'Молочное');
  });

  test('Дедупликация убирает сдвинутое масло на краю 3-го фото и Милку', () {
    const existing = [
      ReceiptItem(id: '1', name: 'КП/МАСЛО СЛИВ 82,5', price: 198.19),
      ReceiptItem(id: '2', name: 'ЗП/КОЛБ С/К МИЛ САЛ', price: 188.28),
      ReceiptItem(id: '3', name: 'СЫР РОСС. НАР.350Г', price: 317.11),
      ReceiptItem(id: '4', name: 'MILKA BUBBLES MOJ.ПО', price: 133.78),
    ];
    const photo3 = [
      ReceiptItem(id: '5', name: 'МАСЛО СЛИВ 82,5', price: 188.28),
      ReceiptItem(id: '6', name: 'СЫР РОСС. НАР.350Г', price: 317.11),
      ReceiptItem(id: '7', name: 'MILKA BUBBLES MOL.NO', price: 133.78),
    ];

    final dedup = deduplicateOverlapItems(
      existingItems: existing,
      incomingItems: photo3,
    );
    expect(dedup.skippedDuplicates, 3);
    expect(dedup.newItems.length, 0);
  });

  test('Парсер разбирает скриншот Т-Банка (₽, пробелы в тысячах, текстовая дата)', () {
    const tbankScreen = '''
19:34   4G 95%
Операция
ВкусВилл
Супермаркеты
- 1 729,80 ₽
17 ноября 2026, 18:15
Кэшбэк +52 ₽
Чек
Молоко ВкусВилл 3.2%   179,80 ₽
2 шт × 89,90 ₽
Сыр Гауда 250г   1 250,00 Р
Кофе Латте   300 ₽
Итого   1 729,80 ₽
''';

    final parsed = parseReceiptText(tbankScreen);
    expect(parsed.storeName, 'ВкусВилл');
    expect(parsed.date, DateTime(2026, 11, 17));
    expect(parsed.totalSum, 1729.80);
    expect(parsed.items.length, 3);
    expect(parsed.items[0].quantity, 2);
    expect(parsed.items[0].price, 89.90);
    expect(parsed.items[1].price, 1250.00);
    expect(parsed.items[2].price, 300.00);
  });

  test('Парсер разбирает скриншот Сбера (двухстрочные товары и без Итого внизу)', () {
    const sberScreen = '''
14:20   LTE 80
Пятёрочка
Покупка
545,50 ₽
15 ноября, 12:40
Детали чека
Хлеб Бородинский
1 × 55,50 ₽   55,50 ₽
Колбаса Докторская   490 Р
Оплата картой 1234
''';

    final parsed = parseReceiptText(sberScreen);
    expect(parsed.storeName, 'Пятёрочка');
    expect(parsed.totalSum, 545.50);
    expect(parsed.items.length, 2);
    expect(parsed.items[0].price, 55.50);
    expect(parsed.items[1].price, 490.00);
  });

  test('Генерация Excel (.xlsx) работает в компактном и подробном режимах', () {
    final receipts = [
      Receipt(
        id: '1',
        storeName: 'Пятёрочка',
        date: DateTime(2026, 11, 15),
        items: const [
          ReceiptItem(
            id: '1a',
            name: 'Молоко 2.5%',
            brand: 'Простоквашино',
            productGroup: 'Молочное',
            price: 89.50,
            quantity: 2,
          ),
        ],
      ),
      Receipt(
        id: '2',
        storeName: 'Ашан',
        date: DateTime(2026, 11, 16),
        items: const [
          ReceiptItem(
            id: '2a',
            name: 'Молоко 2.5%',
            brand: 'Простоквашино',
            productGroup: 'Молочное',
            price: 92.00,
          ),
          ReceiptItem(
            id: '2b',
            name: 'Хлеб',
            price: 55.00,
          ),
        ],
      ),
    ];

    final compactBytes = ExcelExportService.buildExcelBytes(
      receipts,
      mode: ExcelExportMode.compact,
    );
    final detailedBytes = ExcelExportService.buildExcelBytes(
      receipts,
      mode: ExcelExportMode.detailed,
    );

    expect(compactBytes.length, greaterThan(100));
    expect(detailedBytes.length, greaterThan(compactBytes.length));
    expect(compactBytes[0], 0x50);
    expect(compactBytes[1], 0x4B);
    expect(detailedBytes[0], 0x50);
    expect(detailedBytes[1], 0x4B);
  });
}