import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_receipt/services/onnx_receipt_classifier.dart';
import 'package:pocket_receipt/utils/neural_receipt_parser.dart';

ClassifiedReceiptLine _l(
  String text,
  ReceiptLineRole role, {
  String cat = 'Другое',
  double conf = 0.95,
}) {
  return ClassifiedReceiptLine(
    text: text,
    role: role,
    roleConfidence: 0.95,
    category: cat,
    categoryConfidence: conf,
  );
}

void main() {
  test('Не принимает размер 24Х24 за 24*24=576 и читает 34.66 "1WT. =34.66', () {
    final parsed = NeuralReceiptParser.assembleFromClassified([
      _l('000 "AWAH"', ReceiptLineRole.noise),
      _l(
        'САЛО БЕЛ 24Х24 1С/КА 34.66 "1WT. =34.66',
        ReceiptLineRole.itemInline,
        cat: 'Хозтовары',
      ),
      _l('СУММА С УЧЕТОМ СКИДКИ =34.66', ReceiptLineRole.total),
    ]);

    expect(parsed.storeName, 'Ашан');
    expect(parsed.items.length, 1);
    expect(parsed.items.first.quantity, 1);
    expect(parsed.items.first.price, closeTo(34.66, 0.01));
    expect(parsed.items.first.total, closeTo(34.66, 0.01));
  });

  test('Сбрасывает рекламную шапку и отсекает СУММА НАС после ИТОГ', () {
    final parsed = NeuralReceiptParser.assembleFromClassified([
      _l('подарок', ReceiptLineRole.itemName),
      _l('срок прадтожения рани4ан', ReceiptLineRole.itemName),
      _l('g.atoi.ru', ReceiptLineRole.noise),
      _l('Кассовый чек', ReceiptLineRole.noise),
      _l('Фарш из свинины-говядины', ReceiptLineRole.itemName, cat: 'Мясо'),
      _l('НАС 10% 820.04*1.072 K =879.08', ReceiptLineRole.itemMath),
      _l('Свиной ГУлЯШ 525.02*1.036 КГ', ReceiptLineRole.itemInline, cat: 'Мясо'),
      _l('=543.92', ReceiptLineRole.itemMath),
      _l('Пакет "У мясника" большой', ReceiptLineRole.itemName, cat: 'Хозтовары'),
      _l('7.0*1 WT. =7.00', ReceiptLineRole.itemMath),
      _l('ИТОГ -1430.00', ReceiptLineRole.total),
      _l('СУММА НАС 10% =129.37', ReceiptLineRole.itemInline),
      _l('СУММА НАС 22% =1.26', ReceiptLineRole.itemInline, cat: 'Молочное'),
      _l('МЕСТО РАСЧЕТОВ МАГАЗИН МЯСНИКА', ReceiptLineRole.noise),
    ]);

    expect(parsed.storeName, 'МАГАЗИН МЯСНИКА');
    expect(parsed.totalSum, closeTo(1430.00, 0.01));
    expect(parsed.items.length, 3);
    expect(parsed.items[0].name, 'Фарш из свинины-говядины');
    expect(parsed.items[0].total, closeTo(879.08, 0.01));
    expect(parsed.items[1].total, closeTo(543.92, 0.01));
    expect(parsed.items[2].total, closeTo(7.00, 0.01));
  });
}