import 'price_analytics.dart';

String _toCyrillicHomoglyphs(String input) {
  const map = <String, String>{
    'a': 'а',
    'b': 'в',
    'c': 'с',
    'e': 'е',
    'h': 'н',
    'k': 'к',
    'm': 'м',
    'o': 'о',
    'p': 'р',
    't': 'т',
    'x': 'х',
    'y': 'у',
  };
  final lower = normalizeProductName(input);
  final sb = StringBuffer();
  for (final code in lower.runes) {
    final ch = String.fromCharCode(code);
    sb.write(map[ch] ?? ch);
  }
  return sb.toString();
}

const List<({String group, List<String> keywords})> _groupRules = [
  (
    group: 'Хозтовары',
    keywords: [
      'пакет',
      'мыло',
      'салф',
      'т/б',
      'туалет',
      'бумаг',
      'порош',
      'мощ',
      'шампун',
      'щетк',
      'губк',
      'фольг',
      'мешк',
      'зп укр',
      'зубн',
    ],
  ),
  (
    group: 'Снеки',
    keywords: [
      'чипс',
      'лейз',
      'lays',
      'сухар',
      'семен',
      'семеч',
      'орех',
      'снек',
      'попкорн',
    ],
  ),
  (
    group: 'Напитки',
    keywords: [
      'кофе',
      'чай',
      'сок',
      'вода',
      'минерал',
      'лимонад',
      'кола',
      'квас',
      'напит',
      'энерг',
    ],
  ),
  (
    group: 'Молочное',
    keywords: [
      'молок',
      'кефир',
      'сметан',
      'творог',
      'йогурт',
      'ряжен',
      'сливк',
      'сыр',
      'масло слив',
      'слив 82',
      'слив 72',
      'сгущ',
    ],
  ),
  (
    group: 'Мясо и рыба',
    keywords: [
      'колб',
      'сосис',
      'сардель',
      'ветчин',
      'мяс',
      'куриц',
      'филе',
      'грудк',
      'индейк',
      'свинин',
      'свиной',
      'говядин',
      'гуляш',
      'фарш',
      'сельдь',
      'рыб',
      'семг',
      'форел',
      'тунец',
      'шпрот',
    ],
  ),
  (
    group: 'Хлеб',
    keywords: [
      'хлеб',
      'батон',
      'булк',
      'лаваш',
      'лепеш',
      'бублик',
      'круассан',
    ],
  ),
  (
    group: 'Сладости',
    keywords: [
      'шокол',
      'милка',
      'milka',
      'зефир',
      'козинак',
      'прян',
      'печень',
      'конфет',
      'вафл',
      'торт',
      'пирожн',
      'мармелад',
      'халв',
      'mentos',
      'жвач',
    ],
  ),
  (
    group: 'Бакалея',
    keywords: [
      'спагет',
      'макарон',
      'круп',
      'рис ',
      'греч',
      'овсян',
      'мука',
      'сахар',
      'соль',
      'соус',
      'кетчуп',
      'майонез',
      'масло подс',
      'подсолн',
    ],
  ),
  (
    group: 'Овощи и фрукты',
    keywords: [
      'яблок',
      'банан',
      'апельсин',
      'мандарин',
      'огур',
      'помидор',
      'томат',
      'картоф',
      'морков',
      'лук ',
      'капуст',
      'виноград',
      'груш',
      'лимон',
      'ягод',
    ],
  ),
];

List<String> suggestGroupsForProduct(String productName) {
  final origNorm = normalizeProductName(productName);
  final homNorm = _toCyrillicHomoglyphs(productName);

  for (final rule in _groupRules) {
    for (final kw in rule.keywords) {
      if (origNorm.contains(kw) || homNorm.contains(kw)) {
        return [rule.group];
      }
    }
  }
  return const [];
}