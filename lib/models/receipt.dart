class ReceiptItem {
  final String id;
  final String name;
  final String brand;
  final String productGroup;
  final double price;
  final int quantity;

  const ReceiptItem({
    required this.id,
    required this.name,
    this.brand = '',
    this.productGroup = '',
    required this.price,
    this.quantity = 1,
  });

  double get total => price * quantity;

  List<String> get groupList {
    return productGroup
        .split(',')
        .map((g) => g.trim())
        .where((g) => g.isNotEmpty)
        .toList();
  }

  ReceiptItem copyWith({
    String? id,
    String? name,
    String? brand,
    String? productGroup,
    double? price,
    int? quantity,
  }) {
    return ReceiptItem(
      id: id ?? this.id,
      name: name ?? this.name,
      brand: brand ?? this.brand,
      productGroup: productGroup ?? this.productGroup,
      price: price ?? this.price,
      quantity: quantity ?? this.quantity,
    );
  }

  Map<String, dynamic> toMap(String receiptId) {
    return {
      'id': id,
      'receipt_id': receiptId,
      'name': name,
      'brand': brand,
      'product_group': productGroup,
      'price': price,
      'quantity': quantity,
    };
  }

  factory ReceiptItem.fromMap(Map<String, dynamic> map) {
    return ReceiptItem(
      id: map['id'] as String,
      name: map['name'] as String,
      brand: (map['brand'] as String?) ?? '',
      productGroup: (map['product_group'] as String?) ?? '',
      price: (map['price'] as num).toDouble(),
      quantity: map['quantity'] as int,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'brand': brand,
      'productGroup': productGroup,
      'price': price,
      'quantity': quantity,
    };
  }

  factory ReceiptItem.fromJson(Map<String, dynamic> json) {
    return ReceiptItem(
      id: json['id'] as String,
      name: json['name'] as String,
      brand: (json['brand'] as String?) ?? '',
      productGroup: (json['productGroup'] as String?) ?? '',
      price: (json['price'] as num).toDouble(),
      quantity: json['quantity'] as int,
    );
  }
}

class Receipt {
  final String id;
  final String storeName;
  final DateTime date;
  final List<ReceiptItem> items;
  final List<String> photoPaths;

  const Receipt({
    required this.id,
    required this.storeName,
    required this.date,
    required this.items,
    this.photoPaths = const [],
  });

  double get totalAmount {
    double sum = 0;
    for (final item in items) {
      sum += item.total;
    }
    return sum;
  }

  Receipt copyWith({
    String? id,
    String? storeName,
    DateTime? date,
    List<ReceiptItem>? items,
    List<String>? photoPaths,
  }) {
    return Receipt(
      id: id ?? this.id,
      storeName: storeName ?? this.storeName,
      date: date ?? this.date,
      items: items ?? this.items,
      photoPaths: photoPaths ?? this.photoPaths,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'store_name': storeName,
      'date': date.millisecondsSinceEpoch,
    };
  }

  factory Receipt.fromMap(
    Map<String, dynamic> map,
    List<ReceiptItem> items, {
    List<String> photoPaths = const [],
  }) {
    return Receipt(
      id: map['id'] as String,
      storeName: map['store_name'] as String,
      date: DateTime.fromMillisecondsSinceEpoch(map['date'] as int),
      items: items,
      photoPaths: photoPaths,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'storeName': storeName,
      'dateMs': date.millisecondsSinceEpoch,
      'items': items.map((e) => e.toJson()).toList(),
      'photoCount': photoPaths.length,
    };
  }

  factory Receipt.fromJson(Map<String, dynamic> json) {
    final rawItems = (json['items'] as List<dynamic>? ?? const []);
    return Receipt(
      id: json['id'] as String,
      storeName: json['storeName'] as String,
      date: DateTime.fromMillisecondsSinceEpoch(json['dateMs'] as int),
      items: rawItems
          .map((e) => ReceiptItem.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}