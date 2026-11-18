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

ParsedReceipt parseReceiptText(
  String rawText, {
  List<Receipt> existingReceipts = const [],
}) {
  final qr = parseRussianFiscalQr(rawText);
  if (qr != null) {
    return ParsedReceipt(
      date: qr.date,
      totalSum: qr.totalSum,
      items: const [],
    );
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
  final enriched = _enrichItemsFromCatalog(extracted.items, existingReceipts);

  return ParsedReceipt(
    storeName: storeName,
    date: date,
    totalSum: extracted.detectedTotal,
    items: enriched,
  );
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
    r'(?:^|[\s,.;:])(?:[нh][д][сc](?:\s*\d+%?)?|[нh][аa]?[сc](?:\s*\d+%?))(?=$|[\s,.;:])',
    caseSensitive: false,
  );
  final leadingTaxRegex = RegExp(r'^\d{1,2}%\s+');
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
    r'^[=\-~—]\s*(\d{1,3}(?:\s\d{3})*[.,]\d{2}|\d+[.,]\d{2})\s*[₽АБВГA-C]?$',
  );
  final orphanMultRegex = RegExp(
    r'^[*xх×]\s*\d+(?:[.,]\d+)?\s*(?:шт\.?|wt\.?|ut\.?|шt\.?|т\.?|кг|г|л|мл|уп)?(?:\s*=\s*\d+[.,]\d{2})?\s*$',
    caseSensitive: false,
  );

  for (final line in rawLines) {
    final orphanMatch = orphanResultRegex.firstMatch(line);
    if (orphanMatch != null && merged.isNotEmpty) {
      final prev = merged.last;
      // Не склеиваем верхнюю сумму списания из банка (вроде "- 1 729,80 ₽") с названием магазина!
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
  };

  for (final line in lines) {
    final norm = normalizeProductName(line);
    for (final entry in knownStores.entries) {
      if (norm.contains(entry.key)) {
        return entry.value;
      }
    }
  }

  final headerLimit = lines.length < 8 ? lines.length : 8;
  for (int i = 0; i < headerLimit; i++) {
    final line = lines[i];
    if (_isHeaderOrNoiseLine(line) || _containsDate(line)) continue;
    final hasRealWord = RegExp(r'[а-яА-ЯёЁa-zA-Z]{4,}').hasMatch(line);
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
    if (norm.contains('сегодня')) return DateTime(refNow.year, refNow.month, refNow.day);
    if (norm.contains('вчера')) {
      final y = refNow.subtract(const Duration(days: 1));
      return DateTime(y.year, y.month, y.day);
    }
  }

  return fallbackDate;
}

bool _isHeaderOrNoiseLine(String line) {
  final norm = _normalizeHomoglyphs(line);
  if (norm.contains('онлайн') && norm.contains('касса')) return true;
  if (norm == 'ваша' || norm == 'чек' || norm == 'назад') return true;
  // Строка состояния телефона (например "19:34 4G 95%")
  if (RegExp(r'^\d{1,2}:\d{2}\b').hasMatch(norm)) return true;

  const noiseWords = [
    '000 ',
    '000"',
    'ооо',
    'оао',
    'пао',
    'зао',
    'ао ',
    'ип ',
    'инн',
    'кпп',
    'огрн',
    'кассовый чек',
    'товарный чек',
    'код оператора',
    'транзакц',
    'атол',
    'эвотор',
    'штрих',
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
    'офд',
    'ккт',
    'ндс',
    'предоплата',
    'полный расчет',
    'полный расчёт',
    'скидка',
    'бонус',
    'баланс',
    'акцион',
    'купон',
    'действует',
    'потратить',
    'потратьте',
    'спасибо за покупку',
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
  fixed = fixed.replaceAllMapped(
    RegExp(r'([xх*×]\s*\d+)\s+(\d{3})\b', caseSensitive: false),
    (m) => '${m.group(1)}.${m.group(2)}',
  );
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
  String? pendingName;
  double? detectedTotal;
  double? topBankTotal;
  int idCounter = 0;

  // Поддерживает пробелы в тысячах ("1 250,00"), символ ₽ и "р." / "руб."
  final pureMathRegex = RegExp(
    r'^(?:(\d{1,3}(?:\s\d{3})*[.,]\d{2}|\d+[.,]\d+|\d{1,3}(?:\s\d{3})*|\d+)\s*(?:шт\.?|wt\.?|ut\.?|шt\.?|т\.?|кг|г|л|мл|уп)?\s*[xх*×]\s*(\d{1,3}(?:\s\d{3})*[.,]\d{2}|\d+[.,]\d+|\d{1,3}(?:\s\d{3})*|\d+)(?:\s*₽|\s+(?:руб\.?|р\.?|p\.?))?\s*(?:шт\.?|wt\.?|ut\.?|шt\.?|т\.?|кг|г|л|мл|уп)?(?:\s*(?:=|\s)\s*(\d{1,3}(?:\s\d{3})*[.,]\d{2}|\d+[.,]\d{2}|\d{1,3}(?:\s\d{3})*|\d+)(?:\s*₽|\s+(?:руб\.?|р\.?|p\.?))?)?|[=−-]?\s*(?:(\d{1,3}(?:\s\d{3})*[.,]\d{2}|\d+[.,]\d{2})(?:\s*₽|\s+(?:руб\.?|р\.?|p\.?))?|(\d{1,3}(?:\s\d{3})*|\d+)(?:\s*₽|\s+(?:руб\.?|р\.?|p\.?))))\s*[=*АБВГA-C]?\s*$',
    caseSensitive: false,
  );

  final inlineMathRegex = RegExp(
    r'^(.+?)\s+(\d{1,3}(?:\s\d{3})*[.,]\d{2}|\d+[.,]\d+|\d{1,3}(?:\s\d{3})*|\d+)\s*(?:шт\.?|wt\.?|ut\.?|шt\.?|т\.?|кг|г|л|мл|уп)?\s*[xх*×]\s*(\d{1,3}(?:\s\d{3})*[.,]\d{2}|\d+[.,]\d+|\d{1,3}(?:\s\d{3})*|\d+)(?:\s*₽|\s+(?:руб\.?|р\.?|p\.?))?\s*(?:шт\.?|wt\.?|ut\.?|шt\.?|т\.?|кг|г|л|мл|уп)?(?:\s*(?:=|\s)\s*(\d{1,3}(?:\s\d{3})*[.,]\d{2}|\d+[.,]\d{2}|\d{1,3}(?:\s\d{3})*|\d+)(?:\s*₽|\s+(?:руб\.?|р\.?|p\.?))?)?\s*[=*АБВГA-C]?\s*$',
    caseSensitive: false,
  );

  final inlinePriceRegex = RegExp(
    r'^(.+?)\s+(?:(\d{1,3}(?:\s\d{3})*[.,]\d{2}|\d+[.,]\d{2})(?:\s*₽|\s+(?:руб\.?|р\.?|p\.?))?|(\d{1,3}(?:\s\d{3})*|\d+)(?:\s*₽|\s+(?:руб\.?|р\.?|p\.?)))\s*[=*АБВГA-C]?\s*$',
    caseSensitive: false,
  );

  for (int idx = 0; idx < lines.length; idx++) {
    final line = _healOcrMathGlitches(lines[idx].trim());

    if (_isSummaryStopLine(line)) {
      detectedTotal = _findBestReceiptTotal(lines, idx) ?? topBankTotal;
      break;
    }

    if (_isHeaderOrNoiseLine(line) || _containsDate(line)) {
      pendingName = null;
      continue;
    }

    final mathMatch = pureMathRegex.firstMatch(line);
    if (mathMatch != null) {
      final firstNum = mathMatch.group(1);
      final secondNum = mathMatch.group(2);
      final thirdNum = mathMatch.group(3);
      final singleNum = mathMatch.group(4) ?? mathMatch.group(5);

      if (pendingName != null) {
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
              name: _cleanItemName(pendingName),
              price: parsed.price,
              quantity: parsed.qty,
            ),
          );
        }
      } else if (firstNum != null &&
          secondNum != null &&
          items.isNotEmpty &&
          items.last.quantity == 1) {
        // Банковский формат: сначала "Товар  179,80 ₽", а на следующей строке "2 шт × 89,90 ₽"
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
        // Запоминаем верхнюю сумму списания из банковской шапки (например "- 1 729,80 ₽")
        if (line.contains('₽') ||
            line.startsWith('-') ||
            line.startsWith('−')) {
          topBankTotal ??= _parseFormattedNumber(singleNum);
        }
      }

      pendingName = null;
      continue;
    }

    final inlineMathMatch = inlineMathRegex.firstMatch(line);
    if (inlineMathMatch != null) {
      final nameCandidate = inlineMathMatch.group(1)!;
      if (RegExp(r'[а-яА-ЯёЁa-zA-Z]{2,}').hasMatch(nameCandidate)) {
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
              name: _cleanItemName(nameCandidate),
              price: parsed.price,
              quantity: parsed.qty,
            ),
          );
          pendingName = null;
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
          RegExp(r'[а-яА-ЯёЁa-zA-Z]{2,}').hasMatch(nameCandidate)) {
        idCounter++;
        items.add(
          ReceiptItem(
            id: '${DateTime.now().microsecondsSinceEpoch}_$idCounter',
            name: _cleanItemName(nameCandidate),
            price: price,
          ),
        );
        pendingName = null;
        continue;
      }
    }

    if (RegExp(r'[а-яА-ЯёЁa-zA-Z]{3,}').hasMatch(line) &&
        !_looksLikeStoreLine(line)) {
      pendingName = line;
    } else {
      pendingName = null;
    }
  }

  return (items: items, detectedTotal: detectedTotal ?? topBankTotal);
}

double? _findBestReceiptTotal(List<String> lines, int startIndex) {
  double? fallbackTotal;
  final priceRegex = RegExp(r'(\d{1,3}(?:\s\d{3})*[.,]\d{2}|\d+[.,]\d{2})');

  for (int i = startIndex; i < lines.length; i++) {
    final norm = _normalizeHomoglyphs(lines[i]);
    final m = priceRegex.firstMatch(lines[i]);
    if (m == null) continue;
    final val = _parseFormattedNumber(m.group(1)!);
    if (val == null || val <= 0) continue;

    if (norm.contains('к оплате') || norm.contains('с учетом скидки')) {
      return val;
    }
    if (fallbackTotal == null &&
        (norm.contains('итог') || norm.contains('всего'))) {
      fallbackTotal = val;
    }
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

  int? qty;
  double? unitPrice;

  if (aIsWhole && a <= 50 && (!bIsWhole || b > a)) {
    qty = a.round();
    unitPrice = b;
  } else if (bIsWhole && b <= 50 && !aIsWhole) {
    qty = b.round();
    unitPrice = a;
  }

  if (qty != null && unitPrice != null) {
    if (total != null &&
        total > 0 &&
        (unitPrice * qty - total).abs() > 0.02) {
      final derived = total / qty;
      if ((derived - unitPrice).abs() / derived < 0.15) {
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

List<ReceiptItem> _enrichItemsFromCatalog(
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