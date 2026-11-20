import '../models/receipt.dart';
import '../services/onnx_receipt_classifier.dart';
import 'auto_grouper.dart';
import 'price_analytics.dart';
import 'receipt_parser.dart';

class _ParsedMath {
  final int quantity;
  final double unitPrice;
  final double total;
  final bool isBareTotalOnly;
  final int matchStart;

  const _ParsedMath({
    required this.quantity,
    required this.unitPrice,
    required this.total,
    required this.isBareTotalOnly,
    required this.matchStart,
  });
}

class NeuralReceiptParser {
  /// Разбирает сырой текст чека через двухголовый ONNX-классификатор + строгий сборщик цифр.
  /// При отсутствии модели автоматически откатывается на базовый парсер.
  static Future<ParsedReceipt> parse(
    String rawText, {
    List<Receipt> existingReceipts = const [],
  }) async {
    final trimmed = rawText.trim();
    if (trimmed.isEmpty) return const ParsedReceipt(items: []);

    final qr = parseRussianFiscalQr(trimmed);
    if (qr != null) {
      return ParsedReceipt(
        date: qr.date,
        totalSum: qr.totalSum,
        items: const [],
      );
    }

    final lines = trimmed
        .split(RegExp(r'\r?\n'))
        .map((l) => l.replaceAll(RegExp(r'\s{2,}'), ' ').trim())
        .where((l) => l.isNotEmpty)
        .toList();

    final classified = await OnnxReceiptClassifier.instance.classifyLines(lines);
    if (classified == null || classified.isEmpty) {
      return parseReceiptText(rawText, existingReceipts: existingReceipts);
    }

    final neural = assembleFromClassified(
      classified,
      existingReceipts: existingReceipts,
    );

    final fallback = parseReceiptText(
      rawText,
      existingReceipts: existingReceipts,
    );

    if (neural.items.isEmpty) return fallback;

    return ParsedReceipt(
      storeName: neural.storeName ?? fallback.storeName,
      date: neural.date ?? fallback.date,
      totalSum: neural.totalSum ?? fallback.totalSum,
      items: neural.items,
    );
  }

  /// Чистая сборка чека из уже размеченных строк (покрыта unit-тестами).
  static ParsedReceipt assembleFromClassified(
    List<ClassifiedReceiptLine> classified, {
    List<Receipt> existingReceipts = const [],
  }) {
    String? storeName;
    DateTime? date;
    double? totalSum;

    final catalog = existingReceipts.isEmpty
        ? null
        : buildAutocompleteCatalog(existingReceipts);

    final items = <ReceiptItem>[];
    final baseMicros = DateTime.now().microsecondsSinceEpoch;
    int idCounter = 0;

    String? pendingName;
    ClassifiedReceiptLine? pendingLine;
    _ParsedMath? pendingMath;
    bool seenFinalTotal = false;
    bool sawNoiseSincePending = false;
    int noiseStreak = 0;

    void clearPendingName() {
      pendingName = null;
      pendingLine = null;
      sawNoiseSincePending = false;
    }

    void pushItem({
      required String rawName,
      required _ParsedMath mathInfo,
      required ClassifiedReceiptLine? sourceLine,
    }) {
      final cleanName = _cleanItemName(rawName);
      if (cleanName.length < 2) return;
      if (_isNonProductLine(cleanName)) return;
      if (mathInfo.unitPrice <= 0 || mathInfo.total <= 0) return;

      final norm = normalizeProductName(cleanName);
      final history = catalog?.productDefaults[norm];

      final brand = history?.brand ?? '';
      String category = '';

      if (history != null && history.group.isNotEmpty) {
        category = history.group;
      } else {
        final det = suggestGroupsForProduct(cleanName);
        if (det.isNotEmpty) {
          category = joinGroupList(det);
        } else if (sourceLine != null &&
            sourceLine.category != 'Другое' &&
            sourceLine.categoryConfidence >= 0.45) {
          category = sourceLine.category;
        }
      }

      idCounter++;
      items.add(
        ReceiptItem(
          id: '${baseMicros}_nn_$idCounter',
          name: cleanName,
          brand: brand,
          productGroup: category,
          price: _round2(mathInfo.unitPrice),
          quantity: mathInfo.quantity,
        ),
      );
    }

    for (int i = 0; i < classified.length; i++) {
      final line = classified[i];
      final nextRole =
          i + 1 < classified.length ? classified[i + 1].role : null;

      switch (line.role) {
        case ReceiptLineRole.store:
          storeName ??= _cleanStoreName(line.text);
          if (pendingName != null) clearPendingName();
          break;

        case ReceiptLineRole.date:
          date ??= _extractDateFromLine(line.text);
          if (pendingName != null) clearPendingName();
          break;

        case ReceiptLineRole.total:
          final v = _extractLastAmount(line.text);
          if (v != null && v > 0) {
            totalSum = v;
            if (items.isNotEmpty) {
              seenFinalTotal = true;
            }
          }
          clearPendingName();
          pendingMath = null;
          break;

        case ReceiptLineRole.discount:
          if (pendingName != null) {
            sawNoiseSincePending = true;
          }
          break;

        case ReceiptLineRole.noise:
          if (seenFinalTotal) break;

          // Случай Ашана: "КОД ОПЕРАТОРА: 185 7.92 *1WT. =7.92"
          if (pendingName == null && pendingMath == null) {
            final embedded = _extractStrictMultiplyMath(line.text);
            if (embedded != null) {
              pendingMath = embedded;
              break;
            }
          }

          if (pendingName != null) {
            if (_isHeaderOrSeparatorNoise(line.text)) {
              clearPendingName();
              noiseStreak = 0;
            } else {
              sawNoiseSincePending = true;
              noiseStreak++;
              if (noiseStreak >= 3) {
                clearPendingName();
                noiseStreak = 0;
              }
            }
          }
          break;

        case ReceiptLineRole.itemName:
          if (seenFinalTotal) break;
          noiseStreak = 0;

          final stripped = _stripTrailingDiscount(line.text);
          if (_isNonProductLine(stripped)) break;

          if (pendingMath != null) {
            pushItem(
              rawName: stripped,
              mathInfo: pendingMath,
              sourceLine: line,
            );
            pendingMath = null;
            clearPendingName();
            break;
          }

          final inlineMath = nextRole != ReceiptLineRole.itemMath
              ? _extractItemMath(stripped, allowSimpleTrailingPrice: true)
              : null;
          if (inlineMath != null && inlineMath.matchStart >= 2) {
            final namePart = stripped.substring(0, inlineMath.matchStart);
            pushItem(
              rawName: namePart,
              mathInfo: inlineMath,
              sourceLine: line,
            );
            clearPendingName();
            break;
          }

          if (pendingName == null || sawNoiseSincePending) {
            pendingName = stripped;
            pendingLine = line;
            sawNoiseSincePending = false;
          } else {
            // Перенос длинного названия на соседнюю строку без шума между ними
            pendingName = '$pendingName $stripped';
            if (line.categoryConfidence >
                (pendingLine?.categoryConfidence ?? 0)) {
              pendingLine = line;
            }
          }
          break;

        case ReceiptLineRole.itemInline:
          if (seenFinalTotal) break;
          noiseStreak = 0;
          pendingMath = null;

          final stripped = _stripTrailingDiscount(line.text);
          if (_isNonProductLine(stripped)) {
            clearPendingName();
            break;
          }

          final mathInfo = _extractItemMath(
            stripped,
            allowSimpleTrailingPrice: true,
          );
          if (mathInfo != null && mathInfo.matchStart >= 2) {
            final namePart = stripped.substring(0, mathInfo.matchStart);
            final combinedName = (pendingName != null && !sawNoiseSincePending)
                ? '$pendingName $namePart'
                : namePart;
            pushItem(
              rawName: combinedName,
              mathInfo: mathInfo,
              sourceLine: line,
            );
            clearPendingName();
          } else {
            pendingName = (pendingName != null && !sawNoiseSincePending)
                ? '$pendingName $stripped'
                : stripped;
            pendingLine = line;
            sawNoiseSincePending = false;
          }
          break;

        case ReceiptLineRole.itemMath:
          if (seenFinalTotal) break;
          noiseStreak = 0;

          if (_isNonProductMathLine(line.text)) break;

          final mathInfo = _extractItemMath(
            line.text,
            allowSimpleTrailingPrice: true,
          );
          if (mathInfo == null) break;

          if (pendingName != null) {
            pushItem(
              rawName: pendingName!,
              mathInfo: mathInfo,
              sourceLine: pendingLine,
            );
            clearPendingName();
            pendingMath = null;
          } else if (mathInfo.isBareTotalOnly && items.isNotEmpty) {
            final prev = items.last;
            if ((prev.total - mathInfo.total).abs() <= 1.5 ||
                prev.quantity == 1) {
              items[items.length - 1] = ReceiptItem(
                id: prev.id,
                name: prev.name,
                brand: prev.brand,
                productGroup: prev.productGroup,
                price: _round2(mathInfo.total / prev.quantity),
                quantity: prev.quantity,
              );
            }
          } else {
            pendingMath = mathInfo;
          }
          break;
      }
    }

    // Если модель пропустила строку магазина (или дала тех. название) — проверяем известные сети и "МАГАЗИН ..."
    final knownChain = _scanKnownChain(classified);
    storeName = knownChain ?? storeName ?? _scanExplicitStoreLine(classified);

    return ParsedReceipt(
      storeName: storeName,
      date: date,
      totalSum: totalSum,
      items: items,
    );
  }

  static const Map<String, String> _knownChains = {
    'ашан': 'Ашан',
    'awah': 'Ашан',
    'auchan': 'Ашан',
    'пятёрочка': 'Пятёрочка',
    'пятерочка': 'Пятёрочка',
    'агроторг': 'Пятёрочка',
    'магнит': 'Магнит',
    'тандер': 'Магнит',
    'вкусвилл': 'ВкусВилл',
    'перекресток': 'Перекрёсток',
    'перекрёсток': 'Перекрёсток',
    'лента': 'Лента',
    'дикси': 'Дикси',
    'окей': "О'КЕЙ",
    'красное': 'Красное&Белое',
    'fix price': 'Fix Price',
    'фикс прайс': 'Fix Price',
    'чижик': 'Чижик',
    'светофор': 'Светофор',
    'самокат': 'Самокат',
    'лавка': 'Яндекс Лавка',
  };

  static String? _scanKnownChain(List<ClassifiedReceiptLine> lines) {
    for (final l in lines) {
      final lower = normalizeProductName(l.text);
      for (final e in _knownChains.entries) {
        if (lower.contains(e.key)) return e.value;
      }
    }
    return null;
  }

  static String? _scanExplicitStoreLine(List<ClassifiedReceiptLine> lines) {
    final re = RegExp(
      r'((?:магазин|гипермаркет|супермаркет|универсам|минимаркет|пекарня|аптека|кофейня|кафе|столовая|ресторан)\s+[^\n]{2,})',
      caseSensitive: false,
      unicode: true,
    );
    for (final l in lines) {
      if (l.role == ReceiptLineRole.itemName ||
          l.role == ReceiptLineRole.itemInline ||
          l.role == ReceiptLineRole.itemMath) {
        continue;
      }
      final cleaned = l.text.replaceAll(RegExp(r'[«»"]'), '').trim();
      final m = re.firstMatch(cleaned);
      if (m != null) {
        return m.group(1)!.trim();
      }
    }
    return null;
  }

  static bool _isHeaderOrSeparatorNoise(String text) {
    final lower = normalizeProductName(text);
    const markers = [
      'кассовый чек',
      'продажа',
      'смена',
      'откр',
      'закр',
      'кассир',
      'оператор',
      'транзакц',
      'наименование',
      'atol',
      'atoi',
      'auchan',
      'nalog',
      'подарок',
      'отсканируйте',
    ];
    for (final m in markers) {
      if (lower.contains(m)) return true;
    }
    return false;
  }

  static bool _isNonProductLine(String name) {
    final lower = normalizeProductName(name);
    if (lower.isEmpty) return true;

    // Отдельное слово НДС / НАС (не задевает "ананас")
    if (RegExp(r'(?:^|[\s.,:;(\-])(?:ндс|нас|hдс)(?:$|[\s.,:;%)\d])')
        .hasMatch(lower)) {
      return true;
    }

    const forbidden = [
      'сумма ндс',
      'сумма нас',
      'ставка ндс',
      'без ндс',
      'наличными',
      'безналичными',
      'получено',
      'сдача',
      'саача',
      'электронными',
      'итог',
      'итого',
      'всего к оплате',
      'к оплате',
      'сумма с учетом',
      'ваша скидка',
      'ваа скидка',
      'ваша скика',
      'ваша скиака',
      'в том числе',
      'в томчисле',
      'кассир',
      'баланс',
      'начислено балл',
      'списано балл',
      'номер карты',
      'бонус',
    ];
    for (final phrase in forbidden) {
      if (lower == phrase ||
          lower.startsWith('$phrase ') ||
          lower.contains(' $phrase')) {
        return true;
      }
    }
    return false;
  }

  static bool _isNonProductMathLine(String text) {
    final lower = normalizeProductName(text);
    const markers = [
      'сумма ндс',
      'сумма нас',
      'наличными',
      'безналичными',
      'получено',
      'сдача',
      'саача',
      'итого без скидки',
      'ваша скидка',
      'в том числе',
      'в томчисле',
    ];
    for (final m in markers) {
      if (lower.contains(m)) return true;
    }
    return false;
  }

  static String _stripTrailingDiscount(String input) {
    return input
        .replaceAll(
          RegExp(
            r'\s*(?:ндс|нас|hдс)\s*\d+\s*%?\s*(?:в\s*том\s*числе|в\s*томчисле|ваша\s*ски|ваа\s*ски|скидк).*$',
            caseSensitive: false,
            unicode: true,
          ),
          '',
        )
        .replaceAll(
          RegExp(
            r'\s*(?:в\s*том\s*числе|в\s*томчисле|в\s+числе|ваша\s*ски|ваа\s*ски).*$',
            caseSensitive: false,
            unicode: true,
          ),
          '',
        )
        .trim();
  }

  static String _cleanItemName(String raw) {
    var s = _stripTrailingDiscount(raw);
    s = s.replaceAll(RegExp(r'^\d{1,3}[.)]\s+'), '');
    s = s.replaceAll(
      RegExp(
        r'^(?:ндс|нас|hдс)\s*\d{1,2}\s*%?\s*',
        caseSensitive: false,
        unicode: true,
      ),
      '',
    );
    s = s.replaceAll(RegExp(r'\[[МM]\+\]\s*\d*'), '');
    s = s.replaceAll(RegExp(r'[\s=\-*×хx:;.,/]+$'), '');
    s = s.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    return s;
  }

  static String? _cleanStoreName(String raw) {
    final lower = normalizeProductName(raw);
    for (final e in _knownChains.entries) {
      if (lower.contains(e.key)) return e.value;
    }

    final cleaned = raw
        .replaceAll(
          RegExp(
            r'^(?:место\s+расчет(?:ов|а)?\s+|ооо\s+|000\s+|ао\s+|зао\s+|пао\s+)',
            caseSensitive: false,
            unicode: true,
          ),
          '',
        )
        .replaceAll(RegExp(r'[«»"]'), '')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
    return cleaned.length >= 2 ? cleaned : null;
  }

  /// Ищет явное выражение умножения ("7.92 *1WT. =7.92", `34.66 "1WT. =34.66`, "820.04*1.072 K =879.08").
  static _ParsedMath? _extractStrictMultiplyMath(String text) {
    final cleaned = _stripTaxPrefix(text);

    // 1. Приоритет: цена + кол-во + единица измерения + "= сумма" (терпит искажённый знак '*' вроде '"')
    final unitTotalRe = RegExp(
      r'(\d+(?:[.,]\d{1,2})?)(?:\s*[мm]\.?)?\s*[*×xх"•·~]?\s*(\d+(?:[.,]\d{1,3})?)\s*(шт\.?|wt\.?|ut\.?|кг|к|k|уп\.?|л)\s*[=\-]\s*(\d+[.,]\d{2})',
      caseSensitive: false,
      unicode: true,
    );
    final unitMatches = unitTotalRe.allMatches(cleaned).toList();
    if (unitMatches.isNotEmpty) {
      final m = unitMatches.last;
      final priceVal = _parseNum(m.group(1));
      final qtyVal = _parseNum(m.group(2));
      final unit = (m.group(3) ?? '').toLowerCase();
      final totalVal = _parseNum(m.group(4));
      if (priceVal != null &&
          qtyVal != null &&
          totalVal != null &&
          priceVal > 0 &&
          qtyVal > 0 &&
          totalVal > 0) {
        final isWholeQty =
            (qtyVal - qtyVal.roundToDouble()).abs() < 0.001 &&
            qtyVal >= 1 &&
            qtyVal <= 100 &&
            !unit.startsWith('к') &&
            !unit.startsWith('k');
        if (isWholeQty) {
          final qty = qtyVal.round();
          final unitPrice = (priceVal * qty - totalVal).abs() <= 0.15
              ? priceVal
              : _round2(totalVal / qty);
          return _ParsedMath(
            quantity: qty,
            unitPrice: unitPrice,
            total: totalVal,
            isBareTotalOnly: false,
            matchStart: _originalIndex(text, cleaned, m.start),
          );
        }
        return _ParsedMath(
          quantity: 1,
          unitPrice: totalVal,
          total: totalVal,
          isBareTotalOnly: false,
          matchStart: _originalIndex(text, cleaned, m.start),
        );
      }
    }

    // 2. Общий формат умножения ("525.02*1.036 КГ", "2 x 49.90 = 99.80")
    // Пропускаем габариты в названиях товаров без копеек и без "= сумма" (например "24Х24")
    final multRe = RegExp(
      r'(\d+(?:[.,]\d{1,3})?)\s*(шт\.?|wt\.?|ut\.?|кг|к|k|уп\.?|л)?\s*[*×xх]\s*(\d+(?:[.,]\d{1,3})?)\s*(шт\.?|wt\.?|ut\.?|кг|к|k|уп\.?|л)?(?:\s*[=\-]\s*(\d+(?:[.,]\d{1,2})?))?',
      caseSensitive: false,
      unicode: true,
    );

    final matches = multRe.allMatches(cleaned).toList();
    for (final m in matches.reversed) {
      final aStr = m.group(1)!;
      final unitA = (m.group(2) ?? '').toLowerCase();
      final bStr = m.group(3)!;
      final unitB = (m.group(4) ?? '').toLowerCase();
      final explicitTotal = _parseNum(m.group(5));

      // Игнорируем размеры вроде "24Х24", "30x40", "10х15"
      if (explicitTotal == null &&
          unitA.isEmpty &&
          unitB.isEmpty &&
          !_hasDecimals(aStr) &&
          !_hasDecimals(bStr)) {
        continue;
      }

      final a = _parseNum(aStr);
      final b = _parseNum(bStr);
      if (a == null || b == null || a <= 0 || b <= 0) continue;

      double qtyVal;
      double priceVal;

      if (unitA.isNotEmpty && unitB.isEmpty) {
        qtyVal = a;
        priceVal = b;
      } else if (unitB.isNotEmpty && unitA.isEmpty) {
        priceVal = a;
        qtyVal = b;
      } else {
        final aHas2Dec = _hasTwoDecimals(aStr);
        final bHas2Dec = _hasTwoDecimals(bStr);
        if (!aHas2Dec && bHas2Dec && a <= 30) {
          qtyVal = a;
          priceVal = b;
        } else {
          priceVal = a;
          qtyVal = b;
        }
      }

      final computedTotal = explicitTotal ?? _round2(priceVal * qtyVal);
      final isWholeQty =
          (qtyVal - qtyVal.roundToDouble()).abs() < 0.001 &&
          qtyVal >= 1 &&
          qtyVal <= 100 &&
          !unitA.startsWith('к') &&
          !unitA.startsWith('k') &&
          !unitB.startsWith('к') &&
          !unitB.startsWith('k');

      if (isWholeQty) {
        final qty = qtyVal.round();
        final unitPrice = (priceVal * qty - computedTotal).abs() <= 0.15
            ? priceVal
            : _round2(computedTotal / qty);
        return _ParsedMath(
          quantity: qty,
          unitPrice: unitPrice,
          total: computedTotal,
          isBareTotalOnly: false,
          matchStart: _originalIndex(text, cleaned, m.start),
        );
      }

      return _ParsedMath(
        quantity: 1,
        unitPrice: computedTotal,
        total: computedTotal,
        isBareTotalOnly: false,
        matchStart: _originalIndex(text, cleaned, m.start),
      );
    }

    return null;
  }

  static _ParsedMath? _extractItemMath(
    String text, {
    required bool allowSimpleTrailingPrice,
  }) {
    final mult = _extractStrictMultiplyMath(text);
    if (mult != null) return mult;

    final cleaned = _stripTaxPrefix(text);

    // Табличный формат: "<qty> <price> <total>"
    final tabRe = RegExp(
      r'(\d+(?:[.,]\d{1,3})?)\s+(\d+[.,]\d{2})\s+(\d+[.,]\d{2})\s*₽?$',
    );
    final tabM = tabRe.firstMatch(cleaned);
    if (tabM != null) {
      final q = _parseNum(tabM.group(1));
      final p = _parseNum(tabM.group(2));
      final t = _parseNum(tabM.group(3));
      if (q != null && p != null && t != null && (q * p - t).abs() <= 0.15) {
        final isWhole =
            (q - q.roundToDouble()).abs() < 0.001 && q >= 1 && q <= 100;
        return _ParsedMath(
          quantity: isWhole ? q.round() : 1,
          unitPrice: isWhole ? p : t,
          total: t,
          isBareTotalOnly: false,
          matchStart: _originalIndex(text, cleaned, tabM.start),
        );
      }
    }

    // Одиночная сумма со знаком "=" (например "=543.92")
    final eqRe = RegExp(r'^\s*[=\-]\s*(\d+[.,]\d{2})\s*₽?\s*$');
    final eqM = eqRe.firstMatch(cleaned);
    if (eqM != null) {
      final t = _parseNum(eqM.group(1));
      if (t != null && t > 0) {
        return _ParsedMath(
          quantity: 1,
          unitPrice: t,
          total: t,
          isBareTotalOnly: true,
          matchStart: 0,
        );
      }
    }

    // Простая цена в конце строки ("Багет чесночный 69.00" или "Кофе 250 ₽")
    if (allowSimpleTrailingPrice) {
      final trailRe = RegExp(
        r'(?:^|\s)[=\-]?\s*(\d+[.,]\d{2}|\d+\s*₽)\s*(?:₽|руб\.?)?$',
        caseSensitive: false,
        unicode: true,
      );
      final trailM = trailRe.firstMatch(cleaned);
      if (trailM != null) {
        final numStr = trailM.group(1)!.replaceAll(RegExp(r'[^\d.,]'), '');
        final t = _parseNum(numStr);
        if (t != null && t > 0 && t < 500000) {
          return _ParsedMath(
            quantity: 1,
            unitPrice: t,
            total: t,
            isBareTotalOnly: trailM.start == 0,
            matchStart: _originalIndex(text, cleaned, trailM.start),
          );
        }
      }
    }

    return null;
  }

  static String _stripTaxPrefix(String text) {
    return text.replaceAll(
      RegExp(
        r'^(?:(?:ндс|нас|hдс)\s*\d{1,2}\s*%?|без\s+ндс)\s*',
        caseSensitive: false,
        unicode: true,
      ),
      '',
    );
  }

  static int _originalIndex(String orig, String stripped, int strippedIdx) {
    final shift = orig.length - stripped.length;
    return (strippedIdx + shift).clamp(0, orig.length);
  }

  static double? _extractLastAmount(String text) {
    final matches = RegExp(r'\d+[.,]\d{2}').allMatches(text).toList();
    if (matches.isEmpty) return null;
    return _parseNum(matches.last.group(0));
  }

  static DateTime? _extractDateFromLine(String text) {
    final ru = RegExp(r'(\d{2})[./-](\d{2})[./-](\d{2,4})').firstMatch(text);
    if (ru != null) {
      final d = int.parse(ru.group(1)!);
      final m = int.parse(ru.group(2)!);
      var y = int.parse(ru.group(3)!);
      if (y < 100) y += 2000;
      if (y >= 2020 && y <= 2100 && m >= 1 && m <= 12 && d >= 1 && d <= 31) {
        return DateTime(y, m, d);
      }
    }
    return null;
  }

  static bool _hasDecimals(String s) => s.contains('.') || s.contains(',');

  static bool _hasTwoDecimals(String s) {
    final idx = s.indexOf(RegExp(r'[.,]'));
    return idx >= 0 && (s.length - idx - 1) == 2;
  }

  static double? _parseNum(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return double.tryParse(raw.replaceAll(',', '.'));
  }

  static double _round2(double v) => double.parse(v.toStringAsFixed(2));
}