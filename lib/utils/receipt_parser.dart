import '../models/receipt.dart';
import 'auto_grouper.dart';
import 'price_analytics.dart';

class QrReceiptData {
  final DateTime? date;
  final double? totalSum;

  const QrReceiptData({this.date, this.totalSum});
}

class ParsedReceipt {
  final String? storeName;
  final DateTime? date;
  final double? totalSum;
  final List<ReceiptItem> items;

  const ParsedReceipt({
    this.storeName,
    this.date,
    this.totalSum,
    required this.items,
  });
}

QrReceiptData? parseRussianFiscalQr(String raw) {
  final trimmed = raw.trim();
  if (!trimmed.contains('t=') && !trimmed.contains('s=')) {
    return null;
  }

  final queryPart = trimmed.replaceFirst(RegExp(r'^.*\?'), '');
  final params = <String, String>{};

  for (final pair in queryPart.split('&')) {
    final idx = pair.indexOf('=');
    if (idx <= 0) continue;
    final key = pair.substring(0, idx).trim().toLowerCase();
    final value = pair.substring(idx + 1).trim();
    params[key] = value;
  }

  if (!params.containsKey('t') && !params.containsKey('s')) {
    return null;
  }

  DateTime? parsedDate;
  final tVal = params['t'];
  if (tVal != null) {
    final match =
        RegExp(r'^(\d{4})(\d{2})(\d{2})T?(\d{2})?(\d{2})?').firstMatch(tVal);
    if (match != null) {
      final year = int.parse(match.group(1)!);
      final month = int.parse(match.group(2)!);
      final day = int.parse(match.group(3)!);
      final hour = int.tryParse(match.group(4) ?? '0') ?? 0;
      final minute = int.tryParse(match.group(5) ?? '0') ?? 0;
      if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
        parsedDate = DateTime(year, month, day, hour, minute);
      }
    }
  }

  double? parsedSum;
  final sVal = params['s'];
  if (sVal != null) {
    parsedSum = _parseFormattedNumber(sVal);
  }

  if (parsedDate == null && parsedSum == null) return null;
  return QrReceiptData(date: parsedDate, totalSum: parsedSum);
}

bool _looksLikePureQrPayload(String rawText) {
  final lines = rawText
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  if (lines.isEmpty || lines.length > 2) return false;
  final joined = lines.join('&');
  return RegExp(
    r'(?:^|[?&])t=\d{8}T?\d{0,4}|(?:fn=\d+&i=\d+|fp=\d+)',
    caseSensitive: false,
  ).hasMatch(joined);
}

ParsedReceipt parseReceiptText(
  String rawText, {
  List<Receipt> existingReceipts = const [],
}) {
  if (_looksLikePureQrPayload(rawText)) {
    final qr = parseRussianFiscalQr(rawText);
    if (qr != null) {
      return ParsedReceipt(
        date: qr.date,
        totalSum: qr.totalSum,
        items: const [],
      );
    }
  }

  final rawLines = rawText
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();

  final preCleaned = _stripTaxAndDiscountNoise(rawLines);
  final lines = _mergeWrappedPriceLines(preCleaned);
  final storeName = _extractStoreName(rawLines);
  final date = _extractDateFromLines(rawLines);
  final extracted = _extractItems(lines);
  final enriched = enrichItemsFromCatalog(extracted.items, existingReceipts);

  return ParsedReceipt(
    storeName: storeName,
    date: date,
    totalSum: extracted.detectedTotal,
    items: enriched,
  );
}

/// Обогащает список товаров брендами и категориями из истории покупок и базовых правил.
List<ReceiptItem> enrichItemsFromCatalog(
  List<ReceiptItem> parsedItems,
  List<Receipt> existingReceipts,
) {
  final catalog = existingReceipts.isEmpty
      ? null
      : buildAutocompleteCatalog(existingReceipts);

  return parsedItems.map((item) {
    final norm = normalizeProductName(item.name);
    final exactDefaults = catalog?.productDefaults[norm];

    var brand = item.brand;
    var group = item.productGroup;

    if (exactDefaults != null) {
      if (brand.isEmpty) brand = exactDefaults.brand;
      if (group.isEmpty) group = exactDefaults.group;
    }

    if (group.isEmpty) {
      group = joinGroupList(suggestGroupsForProduct(item.name));
    }

    return item.copyWith(brand: brand, productGroup: group);
  }).toList();
}

({List<ReceiptItem> newItems, int skippedDuplicates}) deduplicateOverlapItems({
  required List<ReceiptItem> existingItems,
  required List<ReceiptItem> incomingItems,
  int overlapWindow = 32,
}) {
  if (existingItems.isEmpty || incomingItems.isEmpty) {
    return (newItems: incomingItems, skippedDuplicates: 0);
  }

  final startIdx = existingItems.length > overlapWindow
      ? existingItems.length - overlapWindow
      : 0;
  final tailPool = List<ReceiptItem>.from(existingItems.sublist(startIdx));

  int cleanMatches = 0;
  final tempPool = List<ReceiptItem>.from(tailPool);
  for (int i = 0; i < incomingItems.length && i < overlapWindow; i++) {
    final inc = incomingItems[i];
    for (int j = 0; j < tempPool.length; j++) {
      final cand = tempPool[j];
      final sameAmt = (inc.total - cand.total).abs() <= 0.15 ||
          (inc.price - cand.price).abs() <= 0.05;
      if (sameAmt && isFuzzyProductMatch(inc.name, cand.name)) {
        tempPool.removeAt(j);
        cleanMatches++;
        break;
      }
    }
  }

  final isOverlapPhoto = cleanMatches >= 2;
  final uniqueNew = <ReceiptItem>[];
  int skipped = 0;

  for (int i = 0; i < incomingItems.length; i++) {
    final incoming = incomingItems[i];
    int matchIndex = -1;

    if (i < overlapWindow) {
      for (int j = 0; j < tailPool.length; j++) {
        final candidate = tailPool[j];
        final sameAmount =
            (incoming.total - candidate.total).abs() <= 0.15 ||
                (incoming.price - candidate.price).abs() <= 0.05;
        final edgeNameMatch = isOverlapPhoto && i < 2;
        if ((sameAmount || edgeNameMatch) &&
            isFuzzyProductMatch(incoming.name, candidate.name)) {
          matchIndex = j;
          break;
        }
      }
    }

    if (matchIndex >= 0) {
      tailPool.removeAt(matchIndex);
      skipped++;
    } else {
      uniqueNew.add(incoming);
    }
  }

  return (newItems: uniqueNew, skippedDuplicates: skipped);
}

double? _parseFormattedNumber(String raw) {
  final compact = raw.replaceAll(RegExp(r'\s+'), '').replaceAll(',', '.');
  return double.tryParse(compact);
}

String _normalizeHomoglyphs(String input) {
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

List<String> _stripTaxAndDiscountNoise(List<String> rawLines) {
  final result = <String>[];
  bool skipNextOrphanEq = false;

  final discountSplitRegex = RegExp(
    r'(?:^|\s)(?:[вb]\s+(?:[тt][оo][мm]\s+числе|числе)|[тt][оo][мm]\s+числе|числе\s+[вb]аша|(?:[вb]аша\s+)?(?:скидк[а-я]*|скиа\d*)\d*)',
    caseSensitive: false,
  );
  final taxRegex = RegExp(
    r'(?:^|[\s,.;:])(?:без\s+[нh][дaа][сc]|ставка\s+[нh][дaа][сc](?:\s*\d+(?:/\d+)?%?)?|сумма\s+[нh][дaа][сc](?:\s*\d+(?:/\d+)?%?)?|[нh][д][сc](?:\s*\d+(?:/\d+)?%?)?|[нh][аa][сc]\s*\d+(?:/\d+)?%?)(?=$|[\s,.;:])',
    caseSensitive: false,
  );
  final leadingTaxRegex = RegExp(r'^\d{1,2}(?:/\d{2,3})?%\s+');
  final badgeRegex = RegExp(r'\[?[мm]\+\]?\s*\d*', caseSensitive: false);

  for (final raw in rawLines) {
    if (skipNextOrphanEq) {
      skipNextOrphanEq = false;
      if (RegExp(r'^[=\-~—]\s*\d+[.,]\d{2}\s*$').hasMatch(raw)) {
        continue;
      }
    }

    final norm = _normalizeHomoglyphs(raw);

    final isSummaryLine = norm.contains('итог') ||
        norm.contains('всего') ||
        norm.contains('к оплате') ||
        norm.contains('с учетом скидки');

    if (!isSummaryLine && discountSplitRegex.hasMatch(raw)) {
      final match = discountSplitRegex.firstMatch(raw)!;
      var before = raw.substring(0, match.start).trim();
      before = before
          .replaceAll(badgeRegex, '')
          .replaceAll(taxRegex, ' ')
          .replaceFirst(leadingTaxRegex, '')
          .replaceFirst(
            RegExp(r'\s+[вb](?:\s+[тt][оo][мm])?$', caseSensitive: false),
            '',
          )
          .replaceAll(RegExp(r'\s{2,}'), ' ')
          .trim();

      if (before.isNotEmpty) {
        result.add(before);
      } else {
        skipNextOrphanEq = true;
      }
      continue;
    }

    if (isSummaryLine) {
      result.add(raw);
      continue;
    }

    var cleaned = raw
        .replaceAll(badgeRegex, '')
        .replaceAll(taxRegex, ' ')
        .replaceFirst(leadingTaxRegex, '')
        .replaceFirst(
          RegExp(r'\s+[вb](?:\s+[тt][оo][мm])?$', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();

    if (cleaned.isNotEmpty) {
      result.add(cleaned);
    }
  }

  return result;
}

List<String> _mergeWrappedPriceLines(List<String> rawLines) {
  final merged = <String>[];
  final orphanResultRegex = RegExp(
    r'^[=\-~—:]\s*(\d{1,3}(?:\s\d{3})*[.,]\d{2}|\d+[.,]\d{2})\s*[₽АБВГA-C]?$',
  );
  final orphanMultRegex = RegExp(
    r'^[*xх×]\s*\d+(?:[.,]\d+)?\s*(?:\p{L}{1,5}\.?)?(?:\s*[=—-]\s*\d+[.,]\d{2})?\s*$',
    caseSensitive: false,
    unicode: true,
  );

  for (final line in rawLines) {
    final orphanMatch = orphanResultRegex.firstMatch(line);
    if (orphanMatch != null && merged.isNotEmpty) {
      final prev = merged.last;
      final isBankMinusHeader =
          line.startsWith('-') && line.contains('₽') && !prev.contains('*');
      if (!isBankMinusHeader &&
          !_isHeaderOrNoiseLine(prev) &&
          !_isSummaryStopLine(prev) &&
          !RegExp(r'=\s*\d+[.,]\d{2}\s*$').hasMatch(prev)) {
        merged[merged.length - 1] = '$prev =${orphanMatch.group(1)}';
        continue;
      }
    }

    final multMatch = orphanMultRegex.firstMatch(line);
    if (multMatch != null && merged.isNotEmpty) {
      final prev = merged.last;
      if (!_isHeaderOrNoiseLine(prev) &&
          !_isSummaryStopLine(prev) &&
          !RegExp(r'[*xх×]').hasMatch(prev)) {
        merged[merged.length - 1] = '$prev $line';
        continue;
      }
    }

    merged.add(line);
  }
  return merged;
}

String? _extractStoreName(List<String> lines) {
  const knownStores = <String, String>{
    'пятёрочка': 'Пятёрочка',
    'пятерочка': 'Пятёрочка',
    'магнит': 'Магнит',
    'вкусвилл': 'ВкусВилл',
    'перекрёсток': 'Перекрёсток',
    'перекресток': 'Перекрёсток',
    'лента': 'Лента',
    'ашан': 'Ашан',
    'awah': 'Ашан',
    'auchan': 'Ашан',
    'мошан': 'Ашан',
    'дикси': 'Дикси',
    'окей': 'О\'КЕЙ',
    'красное&белое': 'Красное&Белое',
    'красное и белое': 'Красное&Белое',
    'фикс прайс': 'Fix Price',
    'fix price': 'Fix Price',
    'самокат': 'Самокат',
    'яндекс лавка': 'Яндекс Лавка',
    'ozon': 'Ozon',
    'озон': 'Ozon',
    'wildberries': 'Wildberries',
    'азбука вкуса': 'Азбука Вкуса',
    'метро': 'METRO',
    'светофор': 'Светофор',
    'чижик': 'Чижик',
    'верный': 'Верный',
    'бристоль': 'Бристоль',
    'spar': 'SPAR',
    'спар': 'SPAR',
    'магнолия': 'Магнолия',
  };

  for (final line in lines) {
    final norm = normalizeProductName(line);
    for (final entry in knownStores.entries) {
      if (norm.contains(entry.key)) {
        return entry.value;
      }
    }
  }

  // 1. Строка "Место расчетов   МАГАЗИН ..."
  for (final line in lines) {
    final norm = _normalizeHomoglyphs(line);
    if (norm.contains('место расчет')) {
      final after = line
          .replaceFirst(
            RegExp(r'^.*место\s+расчет[а-я]*[:\s]*', caseSensitive: false),
            '',
          )
          .trim();
      final afterNorm = _normalizeHomoglyphs(after);
      if (after.length >= 4 &&
          RegExp(r'\p{L}{4,}', unicode: true).hasMatch(after) &&
          !afterNorm.startsWith('г.') &&
          !afterNorm.startsWith('ул.') &&
          !afterNorm.startsWith('респ')) {
        return after.replaceAll(RegExp(r'[«»"]'), '').trim();
      }
    }
  }

// 2. Явное название магазина в любом месте чека (например, "МАГАЗИН МЯСНИКА" внизу)
  final explicitStoreRegex = RegExp(
    r'((?:магазин|гипермаркет|супермаркет|универсам|минимаркет|пекарня|аптека|кофейня|кафе|столовая|ресторан)\s+[^\n]{2,})',
    caseSensitive: false,
    unicode: true,
  );
  for (final line in lines) {
    final cleaned = line.replaceAll(RegExp(r'[«»"]'), '').trim();
    if (_looksLikePriceLine(cleaned) || _containsDate(cleaned)) continue;
    final m = explicitStoreRegex.firstMatch(cleaned);
    if (m != null) {
      return m.group(1)!.trim();
    }
  }

  // 3. Fallback: первая осмысленная строка в шапке
  final headerLimit = lines.length < 8 ? lines.length : 8;
  for (int i = 0; i < headerLimit; i++) {
    final line = lines[i];
    if (_isHeaderOrNoiseLine(line) ||
        _isInlineItemMetaLine(line) ||
        _containsDate(line)) {
      continue;
    }
    final hasRealWord = RegExp(r'\p{L}{4,}', unicode: true).hasMatch(line);
    if (hasRealWord && !_looksLikePriceLine(line)) {
      return line.replaceAll(RegExp(r'[«»"]'), '').trim();
    }
  }
  return null;
}

bool _containsDate(String line) {
  if (RegExp(r'\b\d{2}[./-]\d{2}[./-]\d{2,4}\b').hasMatch(line)) {
    return true;
  }
  return RegExp(
    r'(?:^|\s)\d{1,2}\s+(?:янв|фев|мар|апр|ма[йя]|июн|июл|авг|сен|окт|ноя|дек)',
    caseSensitive: false,
  ).hasMatch(normalizeProductName(line));
}

DateTime? _extractDateFromLines(List<String> lines, {DateTime? nowOverride}) {
  final numericRegex = RegExp(r'\b(\d{2})[./-](\d{2})[./-](\d{2,4})\b');
  final textMonthRegex = RegExp(
    r'(?:^|\s)(\d{1,2})\s+(янв[а-я]*|фев[а-я]*|мар[а-я]*|апр[а-я]*|ма[йя]|июн[а-я]*|июл[а-я]*|авг[а-я]*|сен[а-я]*|окт[а-я]*|ноя[а-я]*|дек[а-я]*)(?:\s+(\d{4}))?(?=$|[\s,.])',
    caseSensitive: false,
  );
  const months = <String, int>{
    'янв': 1,
    'фев': 2,
    'мар': 3,
    'апр': 4,
    'май': 5,
    'мая': 5,
    'июн': 6,
    'июл': 7,
    'авг': 8,
    'сен': 9,
    'окт': 10,
    'ноя': 11,
    'дек': 12,
  };

  final refNow = nowOverride ?? DateTime.now();
  DateTime? fallbackDate;

  for (int i = 0; i < lines.length; i++) {
    final line = lines[i];
    final norm = _normalizeHomoglyphs(line);
    final prevNorm = i > 0 ? _normalizeHomoglyphs(lines[i - 1]) : '';

    final isCouponDate = norm.contains('00:00') ||
        norm.contains('23:59') ||
        norm.contains('действует') ||
        norm.contains('потратить') ||
        norm.contains('потратьте') ||
        prevNorm.contains('действует') ||
        prevNorm.contains('потратить') ||
        prevNorm.contains('потратьте');

    final numMatch = numericRegex.firstMatch(line);
    if (numMatch != null) {
      final day = int.parse(numMatch.group(1)!);
      final month = int.parse(numMatch.group(2)!);
      var year = int.parse(numMatch.group(3)!);
      if (year < 100) year += 2000;

      if (day >= 1 && day <= 31 && month >= 1 && month <= 12 && year >= 2020) {
        final candidate = DateTime(year, month, day);
        if (!isCouponDate) return candidate;
        fallbackDate ??= candidate;
      }
    }

    final textMatch = textMonthRegex.firstMatch(normalizeProductName(line));
    if (textMatch != null) {
      final day = int.parse(textMatch.group(1)!);
      final monthPrefix = textMatch.group(2)!.substring(0, 3);
      final month = months[monthPrefix];
      final year = int.tryParse(textMatch.group(3) ?? '') ?? refNow.year;
      if (month != null && day >= 1 && day <= 31 && year >= 2020) {
        final candidate = DateTime(year, month, day);
        if (!isCouponDate) return candidate;
        fallbackDate ??= candidate;
      }
    }
  }

  for (final line in lines) {
    final norm = normalizeProductName(line);
    if (norm.contains('сегодня')) {
      return DateTime(refNow.year, refNow.month, refNow.day);
    }
    if (norm.contains('вчера')) {
      final y = refNow.subtract(const Duration(days: 1));
      return DateTime(y.year, y.month, y.day);
    }
  }

  return fallbackDate;
}

/// Служебные строки между названием товара и его ценой — пропускаем, не сбрасывая название.
bool _isInlineItemMetaLine(String line) {
  final norm = _normalizeHomoglyphs(line);
  if (norm.isEmpty) return true;

  if (RegExp(r'^[\d\s\-_/:.#№]+$').hasMatch(norm) &&
      !RegExp(r'\d+[.,]\d{2}').hasMatch(norm)) {
    return true;
  }
  if (RegExp(r'^(?:арт|код|штрих|gtin|ean|plu|sku)\.?[\s:№-]*\d+',
          caseSensitive: false)
      .hasMatch(norm)) {
    return true;
  }
  if (RegExp(r'^\[?[мmтt][+\-]?\]?$').hasMatch(norm)) return true;

  const inlineMeta = [
    'полный расчет',
    'полный расчёт',
    'предоплата',
    'признак способа расчета',
    'признак предмета расчета',
    'способ расчета',
    'предмет расчета',
    'без ндс',
    'ставка ндс',
    'сумма ндс',
    'скидка',
    'ваша скидка',
    'бонус',
    'начислено бонус',
    'списано бонус',
    'маркированный товар',
  ];
  for (final phrase in inlineMeta) {
    if (norm.contains(phrase)) return true;
  }
  if (norm == 'товар' || norm == 'услуга' || norm == 'подакцизный товар') {
    return true;
  }
  if (RegExp(r'(?:^|\s)(?:ндс|нас)(?:\s|$|\d)').hasMatch(norm)) return true;
  return false;
}

bool _isHeaderOrNoiseLine(String line) {
  final norm = _normalizeHomoglyphs(line);
  if (norm.contains('онлайн') && norm.contains('касса')) return true;
  if (norm == 'ваша' ||
      norm == 'чек' ||
      norm == 'назад' ||
      norm == 'подарок' ||
      norm == 'ато' ||
      norm == 'наименование' ||
      norm == 'цена' ||
      norm == 'сумма' ||
      norm == 'кол-во') {
    return true;
  }
  if (RegExp(r'^\d{1,2}:\d{2}\b').hasMatch(norm)) return true;

  // Короткие аббревиатуры проверяем по границам слов, чтобы не цеплять "какао"
  if (RegExp(
    r'(?:^|[\s"«(])(?:000|ооо|оао|пао|зао|ао|ип|инн|кпп|огрн|ккт|офд|рнм|фн|фд|фп|зн|рм)(?:$|[\s"».,:№])',
  ).hasMatch(norm)) {
    return true;
  }

  const noiseWords = [
    'кассовый чек',
    'товарный чек',
    'отсканируйте',
    'предложения ограничен',
    'срок прадтож',
    'срок предлож',
    'g.atol',
    'g.atoi',
    'продажа №',
    'продажа ю',
    'откр.',
    'закр.',
    'код оператора',
    'транзакц',
    'атол',
    'эвотор',
    'штрих-м',
    'приход',
    'добро пожаловать',
    'смена',
    'чек №',
    'чек n',
    'чек от',
    'детали чека',
    'детали операции',
    'детали платежа',
    'скачать чек',
    'сохранить чек',
    'поделиться',
    'операция',
    'покупка',
    'списание',
    'успешно',
    'оплачено',
    'оплата картой',
    'оплата товаров',
    'кэшбэк',
    'кешбэк',
    'супермаркеты',
    'т-банк',
    'тинькофф',
    'сбербанк',
    'альфа-банк',
    'кассир',
    'место расчетов',
    'место расчет',
    'сайт фнс',
    'сайт нс',
    'nalog',
    'баланс',
    'акцион',
    'купон',
    'действует',
    'потратить',
    'потратьте',
    'спасибо за покупку',
    'наименование цена',
    'наименование кол',
  ];
  for (final word in noiseWords) {
    if (norm.contains(word)) return true;
  }
  return false;
}

bool _isSummaryStopLine(String line) {
  final norm = _normalizeHomoglyphs(line);
  const stopWords = [
    'итог',
    'всего',
    'к оплате',
    'сумма с учетом',
    'безналичными',
    'наличными',
    'электронными',
    'банковской картой',
    'оплата картой',
    'сдача',
  ];
  for (final word in stopWords) {
    if (norm.startsWith(word) || norm.contains(' $word')) {
      return true;
    }
  }
  return false;
}

bool _looksLikePriceLine(String line) {
  return RegExp(
    r'(?:\d+[.,]\d{2}\s*[₽=*АБВГ]?|\d+\s*₽)\s*$',
  ).hasMatch(line.trim());
}

String _healOcrMathGlitches(String line) {
  var fixed = line;
  // O/О вместо нуля в числах ("1O9.90", "49.9O")
  fixed = fixed.replaceAllMapped(
    RegExp(r'(\d)[oOоО](\d|[.,])'),
    (m) => '${m.group(1)}0${m.group(2)}',
  );
  fixed = fixed.replaceAllMapped(
    RegExp(r'(\d[.,]\d?)[oOоО](?=$|\s|₽)'),
    (m) => '${m.group(1)}0',
  );
  // Пробелы вокруг разделителя в цене ("89, 99" -> "89.99")
  fixed = fixed.replaceAllMapped(
    RegExp(r'(\d)\s*([.,])\s*(\d{2})(?=$|\s|[₽=*АБВГA-C])'),
    (m) => '${m.group(1)}.${m.group(3)}',
  );
  // "x 1 000" -> "x 1.000"
  fixed = fixed.replaceAllMapped(
    RegExp(r'([xх*×]\s*\d+)\s+(\d{3})\b', caseSensitive: false),
    (m) => '${m.group(1)}.${m.group(2)}',
  );
  // "89.90 % 2" -> "89.90 * 2"
  fixed = fixed.replaceAllMapped(
    RegExp(r'(\d+[.,]\d{2})\s*%\s*(\d+(?:[.,]\d+)?)'),
    (m) => '${m.group(1)} * ${m.group(2)}',
  );
  return fixed;
}

({List<ReceiptItem> items, double? detectedTotal}) _extractItems(
  List<String> lines,
) {
  final items = <ReceiptItem>[];
  final pendingNameParts = <String>[];
  double? detectedTotal;
  double? topBankTotal;
  int idCounter = 0;

  String consumePendingName() {
    final joined = pendingNameParts.join(' ');
    pendingNameParts.clear();
    return _cleanItemName(joined);
  }

  String mergeWithPendingIfContinuation(String inlineCandidate) {
    if (pendingNameParts.isEmpty) return _cleanItemName(inlineCandidate);
    final trimmed = inlineCandidate.trim();
    final startsLowerOrDigit = RegExp(r'^[a-zа-яё\d(%"]').hasMatch(trimmed);
    final prevStartsNumbered =
        RegExp(r'^\d{1,2}[.)]\s+').hasMatch(pendingNameParts.first);
    final curStartsNumbered = RegExp(r'^\d{1,2}[.)]\s+').hasMatch(trimmed);

    final looksLikeTail = trimmed.length <= 14 ||
        startsLowerOrDigit ||
        (prevStartsNumbered && !curStartsNumbered);

    if (looksLikeTail) {
      final full = '${pendingNameParts.join(' ')} $trimmed';
      pendingNameParts.clear();
      return _cleanItemName(full);
    }
    pendingNameParts.clear();
    return _cleanItemName(trimmed);
  }

  const numPattern =
      r'\d{1,3}(?:\s\d{3})*[.,]\d+|\d+[.,]\d+|\d{1,3}(?:\s\d{3})*|\d+';
  const moneyPattern =
      r'\d{1,3}(?:\s\d{3})*[.,]\d{2}|\d+[.,]\d{2}|\d{1,3}(?:\s\d{3})*|\d+';

  final pureMathRegex = RegExp(
    '^'
    '(?:($numPattern)\\s*(?:\\p{L}{1,5}\\.?)?\\s*[xх*×]\\s*($numPattern)'
    '(?:\\s*₽|\\s+(?:руб\\.?|р\\.?|p\\.?))?\\s*(?:\\p{L}{1,5}\\.?)?'
    '(?:\\s*(?:=|[—~-]|\\s)\\s*($moneyPattern)(?:\\s*₽|\\s+(?:руб\\.?|р\\.?|p\\.?))?)?'
    '|[=−-]?\\s*(?:(\\d{1,3}(?:\\s\\d{3})*[.,]\\d{2}|\\d+[.,]\\d{2})(?:\\s*₽|\\s+(?:руб\\.?|р\\.?|p\\.?))?'
    '|(\\d{1,3}(?:\\s\\d{3})*|\\d+)(?:\\s*₽|\\s+(?:руб\\.?|р\\.?|p\\.?))))'
    '\\s*[=*АБВГA-C]?\\s*\$',
    caseSensitive: false,
    unicode: true,
  );

  final inlineMathRegex = RegExp(
    '^(.+?)\\s+($numPattern)\\s*(?:\\p{L}{1,5}\\.?)?\\s*[xх*×]\\s*($numPattern)'
    '(?:\\s*₽|\\s+(?:руб\\.?|р\\.?|p\\.?))?\\s*(?:\\p{L}{1,5}\\.?)?'
    '(?:\\s*(?:=|[—~-]|\\s)\\s*($moneyPattern)(?:\\s*₽|\\s+(?:руб\\.?|р\\.?|p\\.?))?)?'
    '\\s*[=*АБВГA-C]?\\s*\$',
    caseSensitive: false,
    unicode: true,
  );

  // Табличная строка без знака умножения: "Молоко 3.2% 1.000 89.99 89.99"
  final tabularLineRegex = RegExp(
    '^(.+?)\\s+(\\d+(?:[.,]\\d{1,3})?)\\s*(?:\\p{L}{1,4}\\.?)?\\s+'
    '(\\d{1,3}(?:\\s\\d{3})*[.,]\\d{2}|\\d+(?:[.,]\\d{1,3})?)\\s*(?:\\p{L}{1,4}\\.?)?\\s+'
    '(\\d{1,3}(?:\\s\\d{3})*[.,]\\d{2}|\\d+[.,]\\d{2})\\s*[₽=*АБВГA-C]?\\s*\$',
    caseSensitive: false,
    unicode: true,
  );

  final inlinePriceRegex = RegExp(
    '^(.+?)\\s+[=]?\\s*(?:(\\d{1,3}(?:\\s\\d{3})*[.,]\\d{2}|\\d+[.,]\\d{2})(?:\\s*₽|\\s+(?:руб\\.?|р\\.?|p\\.?))?'
    '|(\\d{1,3}(?:\\s\\d{3})*|\\d+)(?:\\s*₽|\\s+(?:руб\\.?|р\\.?|p\\.?)))'
    '\\s*[=*АБВГA-C]?\\s*\$',
    caseSensitive: false,
    unicode: true,
  );

  for (int idx = 0; idx < lines.length; idx++) {
    final line = _healOcrMathGlitches(lines[idx].trim());

    if (_isSummaryStopLine(line)) {
      if (items.isNotEmpty) {
        detectedTotal = _findBestReceiptTotal(lines, idx) ?? topBankTotal;
        break;
      } else {
        topBankTotal ??= _findBestReceiptTotal(lines, idx, maxLookahead: 1);
        pendingNameParts.clear();
        continue;
      }
    }

    if (_isInlineItemMetaLine(line)) {
      continue;
    }

    if (_isHeaderOrNoiseLine(line) || _containsDate(line)) {
      pendingNameParts.clear();
      continue;
    }

    final mathMatch = pureMathRegex.firstMatch(line);
    if (mathMatch != null) {
      final firstNum = mathMatch.group(1);
      final secondNum = mathMatch.group(2);
      final thirdNum = mathMatch.group(3);
      final singleNum = mathMatch.group(4) ?? mathMatch.group(5);

      if (pendingNameParts.isNotEmpty) {
        final parsed = _resolveQtyAndPrice(
          firstNumStr: firstNum,
          secondNumStr: secondNum,
          totalNumStr: thirdNum ?? singleNum,
        );
        if (parsed != null) {
          idCounter++;
          items.add(
            ReceiptItem(
              id: '${DateTime.now().microsecondsSinceEpoch}_$idCounter',
              name: consumePendingName(),
              price: parsed.price,
              quantity: parsed.qty,
            ),
          );
        } else {
          pendingNameParts.clear();
        }
      } else if (firstNum != null &&
          secondNum != null &&
          items.isNotEmpty &&
          items.last.quantity == 1) {
        final parsed = _resolveQtyAndPrice(
          firstNumStr: firstNum,
          secondNumStr: secondNum,
          totalNumStr: thirdNum,
        );
        if (parsed != null &&
            parsed.qty > 1 &&
            (parsed.qty * parsed.price - items.last.total).abs() <= 0.15) {
          items[items.length - 1] = items.last.copyWith(
            price: parsed.price,
            quantity: parsed.qty,
          );
        }
      } else if (items.isEmpty && singleNum != null) {
        if (line.contains('₽') ||
            line.startsWith('-') ||
            line.startsWith('−')) {
          topBankTotal ??= _parseFormattedNumber(singleNum);
        }
      }

      continue;
    }

    final inlineMathMatch = inlineMathRegex.firstMatch(line);
    if (inlineMathMatch != null) {
      final nameCandidate = inlineMathMatch.group(1)!;
      if (RegExp(r'\p{L}{2,}', unicode: true).hasMatch(nameCandidate)) {
        final parsed = _resolveQtyAndPrice(
          firstNumStr: inlineMathMatch.group(2),
          secondNumStr: inlineMathMatch.group(3),
          totalNumStr: inlineMathMatch.group(4),
        );
        if (parsed != null) {
          idCounter++;
          items.add(
            ReceiptItem(
              id: '${DateTime.now().microsecondsSinceEpoch}_$idCounter',
              name: mergeWithPendingIfContinuation(nameCandidate),
              price: parsed.price,
              quantity: parsed.qty,
            ),
          );
          continue;
        }
      }
    }

    final tabularMatch = tabularLineRegex.firstMatch(line);
    if (tabularMatch != null) {
      final nameCandidate = tabularMatch.group(1)!;
      final n1 = _parseFormattedNumber(tabularMatch.group(2)!);
      final n2 = _parseFormattedNumber(tabularMatch.group(3)!);
      final n3 = _parseFormattedNumber(tabularMatch.group(4)!);
      if (n1 != null &&
          n2 != null &&
          n3 != null &&
          n3 > 0 &&
          RegExp(r'\p{L}{2,}', unicode: true).hasMatch(nameCandidate) &&
          (n1 * n2 - n3).abs() <= (n3 * 0.02 > 0.2 ? n3 * 0.02 : 0.2)) {
        final parsed = _resolveQtyAndPrice(
          firstNumStr: tabularMatch.group(2),
          secondNumStr: tabularMatch.group(3),
          totalNumStr: tabularMatch.group(4),
        );
        if (parsed != null) {
          idCounter++;
          items.add(
            ReceiptItem(
              id: '${DateTime.now().microsecondsSinceEpoch}_$idCounter',
              name: mergeWithPendingIfContinuation(nameCandidate),
              price: parsed.price,
              quantity: parsed.qty,
            ),
          );
          continue;
        }
      }
    }

    final inlinePriceMatch = inlinePriceRegex.firstMatch(line);
    if (inlinePriceMatch != null) {
      final nameCandidate = inlinePriceMatch.group(1)!;
      final priceRaw = inlinePriceMatch.group(2) ?? inlinePriceMatch.group(3);
      final price =
          priceRaw != null ? _parseFormattedNumber(priceRaw) : null;
      if (price != null &&
          price > 0 &&
          !RegExp(r'^\d+[.,]\d+\s*[*xх×]').hasMatch(nameCandidate) &&
          RegExp(r'\p{L}{2,}', unicode: true).hasMatch(nameCandidate)) {
        idCounter++;
        items.add(
          ReceiptItem(
            id: '${DateTime.now().microsecondsSinceEpoch}_$idCounter',
            name: mergeWithPendingIfContinuation(nameCandidate),
            price: price,
          ),
        );
        continue;
      }
    }

    if (RegExp(r'\p{L}{2,}', unicode: true).hasMatch(line) &&
        !_looksLikeStoreLine(line)) {
      if (RegExp(r'^\d{1,2}[.)]\s+').hasMatch(line)) {
        pendingNameParts.clear();
      }
      pendingNameParts.add(line);
      if (pendingNameParts.length > 3) {
        pendingNameParts.removeAt(0);
      }
    }
  }

  return (items: items, detectedTotal: detectedTotal ?? topBankTotal);
}

double? _findBestReceiptTotal(
  List<String> lines,
  int startIndex, {
  int? maxLookahead,
}) {
  double? fallbackTotal;
  final priceRegex = RegExp(r'(\d{1,3}(?:\s\d{3})*[.,]\d{2}|\d+[.,]\d{2})');
  final pureNumberRegex = RegExp(
    r'^[=−~—-]?\s*(\d{1,3}(?:\s\d{3})*[.,]\d{2}|\d+[.,]\d{2})\s*₽?$',
  );
  final endIndex = maxLookahead == null
      ? lines.length
      : (startIndex + maxLookahead < lines.length
          ? startIndex + maxLookahead
          : lines.length);

  for (int i = startIndex; i < endIndex; i++) {
    final healed = _healOcrMathGlitches(lines[i]);
    final norm = _normalizeHomoglyphs(healed);

    final isPriority =
        norm.contains('к оплате') || norm.contains('с учетом скидки');
    final isTotalWord =
        isPriority || norm.contains('итог') || norm.contains('всего');
    if (!isTotalWord) continue;

    double? val;
    final m = priceRegex.firstMatch(healed);
    if (m != null) {
      val = _parseFormattedNumber(m.group(1)!);
    } else if (i + 1 < lines.length) {
      final nextHealed = _healOcrMathGlitches(lines[i + 1]);
      final nextMatch = pureNumberRegex.firstMatch(nextHealed);
      if (nextMatch != null) {
        val = _parseFormattedNumber(nextMatch.group(1)!);
      }
    }

    if (val == null || val <= 0) continue;
    if (isPriority) return val;
    fallbackTotal ??= val;
  }
  return fallbackTotal;
}

bool _looksLikeStoreLine(String line) {
  final norm = _normalizeHomoglyphs(line);
  const storeKeywords = [
    'пятёрочка',
    'пятерочка',
    'магнит',
    'вкусвилл',
    'перекрёсток',
    'перекресток',
    'лента',
    'ашан',
    'дикси',
  ];
  return storeKeywords.any((k) => norm == k);
}

int _decimalDigitsCount(String raw) {
  final m = RegExp(r'[.,](\d+)\s*$').firstMatch(raw.trim());
  return m == null ? 0 : m.group(1)!.length;
}

({int qty, double price})? _resolveQtyAndPrice({
  String? firstNumStr,
  String? secondNumStr,
  String? totalNumStr,
}) {
  if (firstNumStr == null && secondNumStr == null && totalNumStr != null) {
    final total = _parseFormattedNumber(totalNumStr);
    if (total != null && total > 0) return (qty: 1, price: total);
    return null;
  }

  final a = firstNumStr != null ? _parseFormattedNumber(firstNumStr) : null;
  final b = secondNumStr != null ? _parseFormattedNumber(secondNumStr) : null;
  final total =
      totalNumStr != null ? _parseFormattedNumber(totalNumStr) : null;

  if (a == null || b == null) return null;

  final aIsWhole = (a - a.roundToDouble()).abs() < 0.0001 && a >= 1;
  final bIsWhole = (b - b.roundToDouble()).abs() < 0.0001 && b >= 1;
  final aDec = firstNumStr != null ? _decimalDigitsCount(firstNumStr) : 0;
  final bDec = secondNumStr != null ? _decimalDigitsCount(secondNumStr) : 0;

  int? qty;
  double? unitPrice;

  if (aIsWhole && a <= 50 && bIsWhole && b <= 50) {
    if ((aDec == 3 || aDec == 0) && bDec == 2) {
      qty = a.round();
      unitPrice = b;
    } else if ((bDec == 3 || bDec == 0) && aDec == 2) {
      qty = b.round();
      unitPrice = a;
    } else if (b > a) {
      qty = a.round();
      unitPrice = b;
    } else {
      qty = b.round();
      unitPrice = a;
    }
  } else if (aIsWhole && a <= 50 && (!bIsWhole || b > a)) {
    qty = a.round();
    unitPrice = b;
  } else if (bIsWhole && b <= 50 && (!aIsWhole || a > b)) {
    qty = b.round();
    unitPrice = a;
  }

  if (qty != null && unitPrice != null) {
    if (total != null &&
        total > 0 &&
        (unitPrice * qty - total).abs() > 0.02) {
      final derived = total / qty;
      if (derived >= 0.5 && total <= unitPrice * qty * 1.05) {
        unitPrice = double.parse(derived.toStringAsFixed(2));
      }
    }
    return (qty: qty, price: unitPrice);
  }

  final fallbackTotal = total ?? (a * b);
  if (fallbackTotal > 0) {
    return (qty: 1, price: double.parse(fallbackTotal.toStringAsFixed(2)));
  }
  return null;
}

String _cleanItemName(String raw) {
  return raw
      .replaceFirst(RegExp(r'^[\d]+[.)]\s*'), '')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();
}