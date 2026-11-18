import '../models/receipt.dart';

enum StatsPeriod {
  day('День'),
  week('Неделя'),
  month('Месяц'),
  quarter('Квартал'),
  year('Год'),
  all('Всё');

  final String label;
  const StatsPeriod(this.label);
}

List<Receipt> filterReceiptsByPeriod(
  List<Receipt> receipts,
  StatsPeriod period, {
  DateTime? referenceDate,
}) {
  if (period == StatsPeriod.all) return receipts;

  final now = referenceDate ?? DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  final DateTime startDate = switch (period) {
    StatsPeriod.day => today,
    StatsPeriod.week => today.subtract(const Duration(days: 6)),
    StatsPeriod.month => today.subtract(const Duration(days: 29)),
    StatsPeriod.quarter => today.subtract(const Duration(days: 89)),
    StatsPeriod.year => today.subtract(const Duration(days: 364)),
    StatsPeriod.all => today,
  };

  return receipts.where((r) => !r.date.isBefore(startDate)).toList();
}

List<String> parseGroupList(String rawGroups) {
  final seen = <String>{};
  final result = <String>[];
  for (final part in rawGroups.split(',')) {
    final clean = part.trim();
    final norm = normalizeProductName(clean);
    if (norm.isNotEmpty && seen.add(norm)) {
      result.add(clean);
    }
  }
  return result;
}

String joinGroupList(List<String> groups) {
  final seen = <String>{};
  final result = <String>[];
  for (final g in groups) {
    final clean = g.trim();
    final norm = normalizeProductName(clean);
    if (norm.isNotEmpty && seen.add(norm)) {
      result.add(clean);
    }
  }
  return result.join(', ');
}

bool itemMatchesFilters(
  ReceiptItem item, {
  Set<String> selectedGroupKeys = const {},
  Set<String> selectedBrandKeys = const {},
}) {
  if (selectedBrandKeys.isNotEmpty &&
      !selectedBrandKeys.contains(normalizeProductName(item.brand))) {
    return false;
  }

  if (selectedGroupKeys.isNotEmpty) {
    final itemGroupKeys =
        item.groupList.map(normalizeProductName).toSet();
    final hasAnyGroup =
        itemGroupKeys.any((key) => selectedGroupKeys.contains(key));
    if (!hasAnyGroup) return false;
  }

  return true;
}

double receiptFilteredTotal(
  Receipt receipt, {
  Set<String> selectedGroupKeys = const {},
  Set<String> selectedBrandKeys = const {},
}) {
  if (selectedGroupKeys.isEmpty && selectedBrandKeys.isEmpty) {
    return receipt.totalAmount;
  }
  double sum = 0;
  for (final item in receipt.items) {
    if (itemMatchesFilters(
      item,
      selectedGroupKeys: selectedGroupKeys,
      selectedBrandKeys: selectedBrandKeys,
    )) {
      sum += item.total;
    }
  }
  return sum;
}

class ProductTarget {
  final String name;
  final String brand;

  const ProductTarget({
    required this.name,
    this.brand = '',
  });

  String get key =>
      '${normalizeProductName(name)}||${normalizeProductName(brand)}';

  String get label => brand.trim().isEmpty ? name : '$name ($brand)';
}

class PricePoint {
  final String itemName;
  final String brand;
  final String storeName;
  final DateTime date;
  final double price;

  const PricePoint({
    required this.itemName,
    this.brand = '',
    required this.storeName,
    required this.date,
    required this.price,
  });
}

class ItemPriceStats {
  final List<PricePoint> history;
  final double median;
  final double minPrice;
  final double maxPrice;

  const ItemPriceStats({
    required this.history,
    required this.median,
    required this.minPrice,
    required this.maxPrice,
  });
}

class AutocompleteCatalog {
  final List<String> stores;
  final List<String> products;
  final List<String> brands;
  final List<String> groups;
  final Map<String, ({String brand, String group})> productDefaults;

  const AutocompleteCatalog({
    required this.stores,
    required this.products,
    required this.brands,
    required this.groups,
    required this.productDefaults,
  });
}

class ProductSummary {
  final ProductTarget target;
  final String displayName;
  final String brand;
  final List<String> groups;
  final String productGroup;
  final int purchaseCount;
  final double medianPrice;
  final double lastPrice;
  final double totalSpent;

  const ProductSummary({
    required this.target,
    required this.displayName,
    required this.brand,
    this.groups = const [],
    required this.productGroup,
    required this.purchaseCount,
    required this.medianPrice,
    required this.lastPrice,
    this.totalSpent = 0,
  });
}

String normalizeProductName(String name) {
  return name.trim().toLowerCase().replaceAll('ё', 'е');
}

String formatDate(DateTime date) {
  final day = date.day.toString().padLeft(2, '0');
  final month = date.month.toString().padLeft(2, '0');
  return '$day.$month.${date.year}';
}

double calculateMedian(List<double> prices) {
  if (prices.isEmpty) return 0;
  final sorted = List<double>.from(prices)..sort();
  final middle = sorted.length ~/ 2;

  if (sorted.length.isOdd) {
    return sorted[middle];
  } else {
    return (sorted[middle - 1] + sorted[middle]) / 2;
  }
}

int levenshteinDistance(String a, String b) {
  final s1 = normalizeProductName(a).runes.toList();
  final s2 = normalizeProductName(b).runes.toList();

  if (s1.isEmpty) return s2.length;
  if (s2.isEmpty) return s1.length;

  var prev = List<int>.generate(s2.length + 1, (i) => i);
  var curr = List<int>.filled(s2.length + 1, 0);

  for (var i = 1; i <= s1.length; i++) {
    curr[0] = i;
    for (var j = 1; j <= s2.length; j++) {
      final cost = s1[i - 1] == s2[j - 1] ? 0 : 1;
      final del = prev[j] + 1;
      final ins = curr[j - 1] + 1;
      final sub = prev[j - 1] + cost;
      var minVal = del < ins ? del : ins;
      if (sub < minVal) minVal = sub;
      curr[j] = minVal;
    }
    final temp = prev;
    prev = curr;
    curr = temp;
  }

  return prev[s2.length];
}

double similarityRatio(String a, String b) {
  final s1 = normalizeProductName(a);
  final s2 = normalizeProductName(b);
  if (s1.isEmpty && s2.isEmpty) return 1.0;
  final maxLen = s1.length > s2.length ? s1.length : s2.length;
  if (maxLen == 0) return 1.0;
  return 1.0 - (levenshteinDistance(s1, s2) / maxLen);
}

bool _hasEnoughLetters(String word) {
  return RegExp(r'[а-яА-ЯёЁa-zA-Z]').allMatches(word).length >= 4;
}

bool isFuzzyProductMatch(String a, String b) {
  final na = normalizeProductName(a);
  final nb = normalizeProductName(b);
  if (na.isEmpty || nb.isEmpty) return false;
  if (na == nb) return true;

  if (similarityRatio(na, nb) >= 0.75) return true;

  final ca = na.replaceAll(RegExp(r'[\s.,/\\-]+'), '');
  final cb = nb.replaceAll(RegExp(r'[\s.,/\\-]+'), '');
  if (ca.isNotEmpty && cb.isNotEmpty && similarityRatio(ca, cb) >= 0.75) {
    return true;
  }

  final wordsA = na
      .split(RegExp(r'[\s.,/\\-]+'))
      .where(_hasEnoughLetters)
      .toList();
  final wordsB = nb
      .split(RegExp(r'[\s.,/\\-]+'))
      .where(_hasEnoughLetters)
      .toList();

  for (final wa in wordsA) {
    for (final wb in wordsB) {
      if (similarityRatio(wa, wb) >= 0.75) {
        return true;
      }
    }
  }
  return false;
}

List<ProductTarget> findSimilarProductTargets(
  ProductTarget target,
  List<Receipt> allReceipts,
) {
  final seenKeys = <String>{target.key};
  final similar = <ProductTarget>[];

  for (final receipt in allReceipts) {
    for (final item in receipt.items) {
      final candidate = ProductTarget(
        name: item.name.trim(),
        brand: item.brand.trim(),
      );
      if (seenKeys.contains(candidate.key)) continue;

      if (isFuzzyProductMatch(target.name, item.name)) {
        seenKeys.add(candidate.key);
        similar.add(candidate);
      }
    }
  }
  similar.sort((a, b) => a.label.compareTo(b.label));
  return similar;
}

ItemPriceStats buildMultiProductStats(
  List<ProductTarget> targets,
  List<Receipt> allReceipts,
) {
  final targetKeys = targets.map((t) => t.key).toSet();
  final history = <PricePoint>[];

  for (final receipt in allReceipts) {
    for (final item in receipt.items) {
      final itemKey =
          ProductTarget(name: item.name, brand: item.brand).key;
      if (targetKeys.contains(itemKey)) {
        history.add(
          PricePoint(
            itemName: item.name,
            brand: item.brand,
            storeName: receipt.storeName,
            date: receipt.date,
            price: item.price,
          ),
        );
      }
    }
  }

  history.sort((a, b) => b.date.compareTo(a.date));

  if (history.isEmpty) {
    return const ItemPriceStats(history: [], median: 0, minPrice: 0, maxPrice: 0);
  }

  final prices = history.map((e) => e.price).toList();
  final sortedPrices = List<double>.from(prices)..sort();

  return ItemPriceStats(
    history: history,
    median: calculateMedian(prices),
    minPrice: sortedPrices.first,
    maxPrice: sortedPrices.last,
  );
}

ItemPriceStats buildMultiItemPriceStats(
  List<String> targetNames,
  List<Receipt> allReceipts,
) {
  final targetSet = targetNames.map(normalizeProductName).toSet();
  final history = <PricePoint>[];

  for (final receipt in allReceipts) {
    for (final item in receipt.items) {
      if (targetSet.contains(normalizeProductName(item.name))) {
        history.add(
          PricePoint(
            itemName: item.name,
            brand: item.brand,
            storeName: receipt.storeName,
            date: receipt.date,
            price: item.price,
          ),
        );
      }
    }
  }

  history.sort((a, b) => b.date.compareTo(a.date));

  if (history.isEmpty) {
    return const ItemPriceStats(history: [], median: 0, minPrice: 0, maxPrice: 0);
  }

  final prices = history.map((e) => e.price).toList();
  final sortedPrices = List<double>.from(prices)..sort();

  return ItemPriceStats(
    history: history,
    median: calculateMedian(prices),
    minPrice: sortedPrices.first,
    maxPrice: sortedPrices.last,
  );
}

AutocompleteCatalog buildAutocompleteCatalog(List<Receipt> receipts) {
  final seenStores = <String>{};
  final seenProducts = <String>{};
  final seenBrands = <String>{};
  final seenGroups = <String>{};

  final stores = <String>[];
  final products = <String>[];
  final brands = <String>[];
  final groups = <String>[];
  final productDefaults = <String, ({String brand, String group})>{};

  for (final receipt in receipts) {
    final storeNorm = normalizeProductName(receipt.storeName);
    if (storeNorm.isNotEmpty && seenStores.add(storeNorm)) {
      stores.add(receipt.storeName.trim());
    }

    for (final item in receipt.items) {
      final prodNorm = normalizeProductName(item.name);
      if (prodNorm.isNotEmpty && seenProducts.add(prodNorm)) {
        products.add(item.name.trim());
      }

      final brandNorm = normalizeProductName(item.brand);
      if (brandNorm.isNotEmpty && seenBrands.add(brandNorm)) {
        brands.add(item.brand.trim());
      }

      for (final g in item.groupList) {
        final groupNorm = normalizeProductName(g);
        if (groupNorm.isNotEmpty && seenGroups.add(groupNorm)) {
          groups.add(g);
        }
      }

      if (prodNorm.isNotEmpty) {
        final existing = productDefaults[prodNorm];
        final nextBrand = (existing?.brand.isNotEmpty ?? false)
            ? existing!.brand
            : item.brand.trim();
        final nextGroup = (existing?.group.isNotEmpty ?? false)
            ? existing!.group
            : joinGroupList(item.groupList);
        productDefaults[prodNorm] = (brand: nextBrand, group: nextGroup);
      }
    }
  }

  stores.sort();
  products.sort();
  brands.sort();
  groups.sort();

  return AutocompleteCatalog(
    stores: stores,
    products: products,
    brands: brands,
    groups: groups,
    productDefaults: productDefaults,
  );
}

List<ProductSummary> buildProductSummaries(List<Receipt> receipts) {
  final sortedReceipts = List<Receipt>.from(receipts)
    ..sort((a, b) => b.date.compareTo(a.date));

  final grouped = <String, List<({ReceiptItem item, DateTime date})>>{};

  for (final receipt in sortedReceipts) {
    for (final item in receipt.items) {
      final target = ProductTarget(
        name: item.name.trim(),
        brand: item.brand.trim(),
      );
      if (normalizeProductName(item.name).isEmpty) continue;
      grouped.putIfAbsent(target.key, () => []);
      grouped[target.key]!.add((item: item, date: receipt.date));
    }
  }

  final summaries = <ProductSummary>[];

  grouped.forEach((key, entries) {
    final firstItem = entries.first.item;
    final prices = entries.map((e) => e.item.price).toList();

    double spent = 0;
    final allGroups = <String>[];
    for (final entry in entries) {
      spent += entry.item.total;
      allGroups.addAll(entry.item.groupList);
    }
    final mergedGroupStr = joinGroupList(allGroups);
    final mergedGroups = parseGroupList(mergedGroupStr);

    summaries.add(
      ProductSummary(
        target: ProductTarget(
          name: firstItem.name.trim(),
          brand: firstItem.brand.trim(),
        ),
        displayName: firstItem.name.trim(),
        brand: firstItem.brand.trim(),
        groups: mergedGroups,
        productGroup: mergedGroupStr,
        purchaseCount: entries.length,
        medianPrice: calculateMedian(prices),
        lastPrice: firstItem.price,
        totalSpent: spent,
      ),
    );
  });

  summaries.sort((a, b) {
    final nameCmp = a.displayName.compareTo(b.displayName);
    if (nameCmp != 0) return nameCmp;
    return a.brand.compareTo(b.brand);
  });
  return summaries;
}