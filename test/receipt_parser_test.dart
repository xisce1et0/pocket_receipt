import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_receipt/utils/receipt_parser.dart';

void main() {
  test('Парсинг чека АТОЛ (Магазин мясника) с реальными артефактами OCR', () {
    const ocrText = '''
ATO
Отсканируйте, чтобы получить
подарок
срок прадтожений страничон
V
g.atoi.ru
Кассовый чек
PM №91 000120 420153
ПРОДАЖА Ю00676621 Писаная
Тамара Алиевна
ОТКР. 18:15:41 Смена №2359
= ЗаКР. 18:16:04
Фарш из свинины-говядины
НАС 10% 820.04*1.072 K =879.08
Свиной ГУлЯШ 525.02*1.036 КГ
=543.92
НАС 10%
Пакет "у мясника" большой
7.0*1 WT. =7.00
НАС 22%
ИТОГ -1430.00
СУММА НАС 10% =129.37
СУММА НАС 22% =1.26
НАЛИЧНЫМИ =1430.00
ПОЛУЧЕНО НАЛИЧНЫМИ =1500.00
СДАЧА =70.00
Кассир Писаная Т. А. И ПОГОСЯН
АРМАН СУРЕНОВИЧ
МАГАЗИН МЯСНИКА
.11.26 18:12 3Н KKT 0106228992800
''';

    final parsed = parseReceiptText(ocrText);

    expect(parsed.storeName, 'МАГАЗИН МЯСНИКА');
    expect(parsed.totalSum, 1430.00);
    expect(parsed.items.length, 3);

    expect(parsed.items[0].name, 'Фарш из свинины-говядины');
    expect(parsed.items[0].total, closeTo(879.08, 0.01));
    expect(parsed.items[0].productGroup, 'Мясо');

    expect(parsed.items[1].name, 'Свиной ГУлЯШ');
    expect(parsed.items[1].total, closeTo(543.92, 0.01));
    expect(parsed.items[1].productGroup, 'Мясо');

    expect(parsed.items[2].name, 'Пакет "у мясника" большой');
    expect(parsed.items[2].total, closeTo(7.00, 0.01));
    expect(parsed.items[2].productGroup, 'Хозтовары');
  });

  test('Парсинг чека Ашан (регрессия)', () {
    const auchanText = '''
ООО "АШАН"
КАССОВЫЙ ЧЕК (ПРИХОД)
КОД ОПЕРАТОРА: 185
НОМЕР ТРАНЗАКЦИИ: 34/1195689
ПАКЕТ-МАЙКА БЕЛЫЙ 7.92 *1ШТ. =7.92
НДС 22% В ТОМ ЧИСЛЕ ВАША СКИДКА = 0.08
КД/КОЗИНАК ПОДСОЛН. 34.67 *4ШТ. =138.68
НДС 22% В ТОМ ЧИСЛЕ ВАША СКИДКА = 1.24
КП/МАСЛО СЛИВ 82,5 198.19 *1ШТ. =198.19
НДС 10% [М+] 7937
В ТОМ ЧИСЛЕ ВАША СКИДКА = 1.80
ЗП/КОЛБ С/К МИЛ САЛ 188.28 *1ШТ. =188.28
СЕЛЬДЬ Ф/К ЦАРСК УКР 287.38 *1ШТ. =287.38
ЧИПСЫ СЫР 140ГР ЛЕЙЗ 208.10 *1ШТ. =208.10
ИТОГО БЕЗ СКИДКИ =4013.63
ВАША СКИДКА =-50.63
СУММА С УЧЕТОМ СКИДКИ =3963.00
''';

    final parsed = parseReceiptText(auchanText);

    expect(parsed.storeName, 'Ашан');
    expect(parsed.totalSum, 3963.00);
    expect(parsed.items.length, 6);

    expect(parsed.items[1].quantity, 4);
    expect(parsed.items[1].price, closeTo(34.67, 0.01));
    expect(parsed.items[1].productGroup, 'Сладости');

    expect(parsed.items[2].productGroup, 'Молочное');
    expect(parsed.items[3].productGroup, 'Мясо');
    expect(parsed.items[4].productGroup, 'Рыба');
    expect(parsed.items[5].productGroup, 'Снеки');
  });
}