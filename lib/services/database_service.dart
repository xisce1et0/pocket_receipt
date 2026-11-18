import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../models/receipt.dart';

class DatabaseService {
  DatabaseService._internal();
  static final DatabaseService instance = DatabaseService._internal();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final String dbPath;
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
      final docsDir = await getApplicationDocumentsDirectory();
      final appFolder = Directory(p.join(docsDir.path, 'PocketReceipt'));
      if (!await appFolder.exists()) {
        await appFolder.create(recursive: true);
      }
      dbPath = appFolder.path;
    } else {
      dbPath = await getDatabasesPath();
    }

    final fullPath = p.join(dbPath, 'pocket_receipt.db');

    return openDatabase(
      fullPath,
      version: 4,
      onConfigure: (db) async {
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE receipts (
            id TEXT PRIMARY KEY,
            store_name TEXT NOT NULL,
            date INTEGER NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE receipt_items (
            id TEXT PRIMARY KEY,
            receipt_id TEXT NOT NULL,
            name TEXT NOT NULL,
            brand TEXT NOT NULL DEFAULT '',
            product_group TEXT NOT NULL DEFAULT '',
            price REAL NOT NULL,
            quantity INTEGER NOT NULL,
            FOREIGN KEY (receipt_id) REFERENCES receipts (id) ON DELETE CASCADE
          )
        ''');

        await db.execute('''
          CREATE TABLE receipt_photos (
            id TEXT PRIMARY KEY,
            receipt_id TEXT NOT NULL,
            file_path TEXT NOT NULL,
            FOREIGN KEY (receipt_id) REFERENCES receipts (id) ON DELETE CASCADE
          )
        ''');

        await db.execute('''
          CREATE TABLE app_settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');

        await _seedInitialData(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            "ALTER TABLE receipt_items ADD COLUMN brand TEXT NOT NULL DEFAULT ''",
          );
          await db.execute(
            "ALTER TABLE receipt_items ADD COLUMN product_group TEXT NOT NULL DEFAULT ''",
          );
        }
        if (oldVersion < 3) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS receipt_photos (
              id TEXT PRIMARY KEY,
              receipt_id TEXT NOT NULL,
              file_path TEXT NOT NULL,
              FOREIGN KEY (receipt_id) REFERENCES receipts (id) ON DELETE CASCADE
            )
          ''');
        }
        if (oldVersion < 4) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS app_settings (
              key TEXT PRIMARY KEY,
              value TEXT NOT NULL
            )
          ''');
        }
      },
    );
  }

  Future<String?> getSetting(String key) async {
    final db = await database;
    final rows = await db.query(
      'app_settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String;
  }

  Future<void> setSetting(String key, String value) async {
    final db = await database;
    await db.insert(
      'app_settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Directory> _getPhotosDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final photosDir = Directory(p.join(appDir.path, 'receipt_photos'));
    if (!await photosDir.exists()) {
      await photosDir.create(recursive: true);
    }
    return photosDir;
  }

  Future<List<String>> savePhotosPermanently(
    String receiptId,
    List<String> sourcePaths,
  ) async {
    if (sourcePaths.isEmpty) return const [];
    final photosDir = await _getPhotosDirectory();

    final savedPaths = <String>[];
    for (int i = 0; i < sourcePaths.length; i++) {
      final srcPath = sourcePaths[i];
      if (srcPath.startsWith(photosDir.path)) {
        savedPaths.add(srcPath);
        continue;
      }
      final srcFile = File(srcPath);
      if (!await srcFile.exists()) continue;

      final ext = p.extension(srcPath).isEmpty ? '.jpg' : p.extension(srcPath);
      final destPath = p.join(
        photosDir.path,
        '${receiptId}_${DateTime.now().microsecondsSinceEpoch}_$i$ext',
      );
      await srcFile.copy(destPath);
      savedPaths.add(destPath);
    }
    return savedPaths;
  }

  Future<void> saveSyncedPhotoBytes(
    String receiptId,
    int index,
    String ext,
    Uint8List bytes,
  ) async {
    final photosDir = await _getPhotosDirectory();
    final cleanExt = ext.startsWith('.') ? ext : '.$ext';
    final destPath = p.join(
      photosDir.path,
      '${receiptId}_sync_${DateTime.now().microsecondsSinceEpoch}_$index$cleanExt',
    );
    await File(destPath).writeAsBytes(bytes, flush: true);

    final db = await database;
    await db.insert('receipt_photos', {
      'id': '${receiptId}_sync_${DateTime.now().microsecondsSinceEpoch}_$index',
      'receipt_id': receiptId,
      'file_path': destPath,
    });
  }

  Future<void> _seedInitialData(Database db) async {
    final now = DateTime.now();
    final samples = [
      Receipt(
        id: '1',
        storeName: 'Пятёрочка',
        date: now.subtract(const Duration(days: 2)),
        items: const [
          ReceiptItem(
            id: '1a',
            name: 'Молоко 2.5%',
            brand: 'Простоквашино',
            productGroup: 'Молочное',
            price: 89.00,
          ),
          ReceiptItem(
            id: '1b',
            name: 'Хлеб Бородинский',
            brand: 'Хлебный дом',
            productGroup: 'Хлеб',
            price: 55.00,
          ),
        ],
      ),
      Receipt(
        id: '2',
        storeName: 'Магнит',
        date: now.subtract(const Duration(days: 14)),
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
            name: 'Кофе в зернах 250г',
            brand: 'Lavazza',
            productGroup: 'Напитки',
            price: 540.00,
          ),
        ],
      ),
      Receipt(
        id: '3',
        storeName: 'ВкусВилл',
        date: now.subtract(const Duration(days: 29)),
        items: const [
          ReceiptItem(
            id: '3a',
            name: 'Молоко 2.5%',
            brand: 'ВкусВилл',
            productGroup: 'Молочное',
            price: 84.00,
          ),
          ReceiptItem(
            id: '3b',
            name: 'Хлеб Бородинский',
            brand: 'ВкусВилл',
            productGroup: 'Хлеб',
            price: 52.00,
          ),
        ],
      ),
      Receipt(
        id: '4',
        storeName: 'Пятёрочка',
        date: now.subtract(const Duration(days: 47)),
        items: const [
          ReceiptItem(
            id: '4a',
            name: 'Молоко 2.5%',
            brand: 'Простоквашино',
            productGroup: 'Молочное',
            price: 79.00,
          ),
          ReceiptItem(
            id: '4b',
            name: 'Кофе в зернах 250г',
            brand: 'Lavazza',
            productGroup: 'Напитки',
            price: 490.00,
          ),
        ],
      ),
    ];

    for (final receipt in samples) {
      await _insertReceiptWithDb(db, receipt);
    }
  }

  Future<void> _insertReceiptWithDb(DatabaseExecutor db, Receipt receipt) async {
    await db.insert('receipts', receipt.toMap());
    for (final item in receipt.items) {
      await db.insert('receipt_items', item.toMap(receipt.id));
    }
    for (int i = 0; i < receipt.photoPaths.length; i++) {
      await db.insert('receipt_photos', {
        'id': '${receipt.id}_photo_${DateTime.now().microsecondsSinceEpoch}_$i',
        'receipt_id': receipt.id,
        'file_path': receipt.photoPaths[i],
      });
    }
  }

  Future<void> insertReceipt(Receipt receipt) async {
    final db = await database;
    await db.transaction((txn) async {
      await _insertReceiptWithDb(txn, receipt);
    });
  }

  Future<bool> insertReceiptIfMissing(Receipt receipt) async {
    final db = await database;
    final existing = await db.query(
      'receipts',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [receipt.id],
    );
    if (existing.isNotEmpty) return false;
    await insertReceipt(receipt);
    return true;
  }

  Future<List<Receipt>> getAllReceipts() async {
    final db = await database;
    final receiptMaps = await db.query('receipts', orderBy: 'date DESC');
    final itemMaps = await db.query('receipt_items');
    final photoMaps = await db.query('receipt_photos');

    final itemsByReceipt = <String, List<ReceiptItem>>{};
    for (final map in itemMaps) {
      final receiptId = map['receipt_id'] as String;
      itemsByReceipt.putIfAbsent(receiptId, () => []);
      itemsByReceipt[receiptId]!.add(ReceiptItem.fromMap(map));
    }

    final photosByReceipt = <String, List<String>>{};
    for (final map in photoMaps) {
      final receiptId = map['receipt_id'] as String;
      photosByReceipt.putIfAbsent(receiptId, () => []);
      photosByReceipt[receiptId]!.add(map['file_path'] as String);
    }

    return receiptMaps.map((map) {
      final id = map['id'] as String;
      return Receipt.fromMap(
        map,
        itemsByReceipt[id] ?? [],
        photoPaths: photosByReceipt[id] ?? const [],
      );
    }).toList();
  }

  Future<Receipt?> getReceiptById(String id) async {
    final db = await database;
    final receiptMaps = await db.query(
      'receipts',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (receiptMaps.isEmpty) return null;

    final itemMaps = await db.query(
      'receipt_items',
      where: 'receipt_id = ?',
      whereArgs: [id],
    );
    final photoMaps = await db.query(
      'receipt_photos',
      where: 'receipt_id = ?',
      whereArgs: [id],
    );

    final items = itemMaps.map(ReceiptItem.fromMap).toList();
    final photos = photoMaps.map((m) => m['file_path'] as String).toList();
    return Receipt.fromMap(receiptMaps.first, items, photoPaths: photos);
  }

  Future<void> updateReceiptInfo(
    String receiptId,
    String storeName,
    DateTime date,
  ) async {
    final db = await database;
    await db.update(
      'receipts',
      {
        'store_name': storeName,
        'date': date.millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [receiptId],
    );
  }

  Future<void> updateReceiptItem(ReceiptItem item) async {
    final db = await database;
    await db.update(
      'receipt_items',
      {
        'name': item.name,
        'brand': item.brand,
        'product_group': item.productGroup,
        'price': item.price,
        'quantity': item.quantity,
      },
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  Future<void> deleteReceiptItem(String itemId) async {
    final db = await database;
    await db.delete(
      'receipt_items',
      where: 'id = ?',
      whereArgs: [itemId],
    );
  }

  Future<void> deleteReceipt(String id) async {
    final db = await database;
    final photoMaps = await db.query(
      'receipt_photos',
      where: 'receipt_id = ?',
      whereArgs: [id],
    );

    await db.delete(
      'receipts',
      where: 'id = ?',
      whereArgs: [id],
    );

    for (final map in photoMaps) {
      final file = File(map['file_path'] as String);
      if (await file.exists()) {
        await file.delete();
      }
    }
  }
}