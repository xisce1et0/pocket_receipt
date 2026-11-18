import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../models/receipt.dart';
import 'database_service.dart';

class SyncPayloadInfo {
  final String host;
  final int port;
  final String token;

  const SyncPayloadInfo({
    required this.host,
    required this.port,
    required this.token,
  });

  String toQrString() => 'pocket_sync://$host:$port|$token';

  static SyncPayloadInfo? parse(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.startsWith('pocket_sync://')) return null;
    final body = trimmed.substring('pocket_sync://'.length);
    final parts = body.split('|');
    if (parts.length != 2) return null;

    final addrParts = parts[0].split(':');
    if (addrParts.length != 2) return null;

    final host = addrParts[0].trim();
    final port = int.tryParse(addrParts[1].trim());
    final token = parts[1].trim();
    if (host.isEmpty || port == null || token.isEmpty) return null;

    return SyncPayloadInfo(host: host, port: port, token: token);
  }
}

class SyncResultSummary {
  final int receivedCount;
  final int sentCount;

  const SyncResultSummary({
    required this.receivedCount,
    required this.sentCount,
  });
}

Future<List<String>> getLocalLanIps() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLoopback: false,
  );

  final scored = <({String ip, int score})>[];
  for (final iface in interfaces) {
    final name = iface.name.toLowerCase();
    final isVirtualOrVpn = name.contains('vpn') ||
        name.contains('tun') ||
        name.contains('tap') ||
        name.contains('virtual') ||
        name.contains('vbox') ||
        name.contains('vmware') ||
        name.contains('wsl') ||
        name.contains('docker') ||
        name.contains('hyper-v');

    for (final addr in iface.addresses) {
      final ip = addr.address;
      if (ip.startsWith('127.') || ip.startsWith('169.254.')) continue;

      int score = 0;
      if (!isVirtualOrVpn) score += 100;
      if (ip.startsWith('192.168.') && !ip.startsWith('192.168.56.')) {
        score += 50;
      } else if (ip.startsWith('10.')) {
        score += 30;
      } else if (ip.startsWith('172.')) {
        score += 20;
      }
      if (name.contains('wi-fi') || name.contains('wlan')) score += 15;
      scored.add((ip: ip, score: score));
    }
  }

  scored.sort((a, b) => b.score.compareTo(a.score));
  final unique = <String>[];
  for (final item in scored) {
    if (!unique.contains(item.ip)) unique.add(item.ip);
  }
  return unique;
}

class WifiSyncServer {
  HttpServer? _server;
  late String token;
  int get port => _server?.port ?? 0;

  Future<void> start({
    required void Function(int addedCount) onReceivedFromClient,
  }) async {
    await stop();
    final rng = Random.secure();
    token = (100000 + rng.nextInt(900000)).toString();
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);

    _server!.listen((HttpRequest request) async {
      try {
        final reqToken = request.headers.value('x-sync-token');
        if (reqToken != token) {
          request.response.statusCode = HttpStatus.forbidden;
          await request.response.close();
          return;
        }

        final path = request.uri.path;
        if (request.method == 'POST' && path == '/sync') {
          await _handleSync(request, onReceivedFromClient);
        } else if (request.method == 'POST' && path == '/upload-photo') {
          await _handleUploadPhoto(request);
        } else if (request.method == 'GET' && path == '/download-photo') {
          await _handleDownloadPhoto(request);
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      } catch (_) {
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        } catch (_) {}
      }
    });
  }

  Future<void> _handleSync(
    HttpRequest request,
    void Function(int addedCount) onReceivedFromClient,
  ) async {
    final bodyStr = await utf8.decoder.bind(request).join();
    final bodyJson = jsonDecode(bodyStr) as Map<String, dynamic>;
    final clientReceiptsJson =
        (bodyJson['receipts'] as List<dynamic>? ?? const []);

    final existingServerReceipts = await DatabaseService.instance.getAllReceipts();
    final serverIds = existingServerReceipts.map((r) => r.id).toSet();
    final clientIds = <String>{};

    final needPhotosFor = <String>[];
    int addedOnServer = 0;

    for (final raw in clientReceiptsJson) {
      final map = raw as Map<String, dynamic>;
      final receipt = Receipt.fromJson(map);
      clientIds.add(receipt.id);

      if (!serverIds.contains(receipt.id)) {
        final inserted =
            await DatabaseService.instance.insertReceiptIfMissing(receipt);
        if (inserted) {
          addedOnServer++;
          final photoCount = (map['photoCount'] as int?) ?? 0;
          if (photoCount > 0) {
            needPhotosFor.add(receipt.id);
          }
        }
      }
    }

    final receiptsForClient = existingServerReceipts
        .where((r) => !clientIds.contains(r.id))
        .map((r) => r.toJson())
        .toList();

    final respPayload = {
      'needPhotosFor': needPhotosFor,
      'serverReceipts': receiptsForClient,
    };

    final respBytes = utf8.encode(jsonEncode(respPayload));
    request.response.headers.contentType = ContentType.json;
    request.response.contentLength = respBytes.length;
    request.response.add(respBytes);
    await request.response.close();

    if (addedOnServer > 0) {
      onReceivedFromClient(addedOnServer);
    }
  }

  Future<void> _handleUploadPhoto(HttpRequest request) async {
    final receiptId = request.uri.queryParameters['receiptId'];
    final indexStr = request.uri.queryParameters['index'];
    final ext = request.uri.queryParameters['ext'] ?? '.jpg';
    final index = int.tryParse(indexStr ?? '') ?? 0;

    if (receiptId == null || receiptId.isEmpty) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();

    await DatabaseService.instance.saveSyncedPhotoBytes(
      receiptId,
      index,
      ext,
      bytes,
    );

    request.response.statusCode = HttpStatus.ok;
    await request.response.close();
  }

  Future<void> _handleDownloadPhoto(HttpRequest request) async {
    final receiptId = request.uri.queryParameters['receiptId'];
    final index = int.tryParse(request.uri.queryParameters['index'] ?? '') ?? 0;
    if (receiptId == null) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    final receipt = await DatabaseService.instance.getReceiptById(receiptId);
    if (receipt == null || index < 0 || index >= receipt.photoPaths.length) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final file = File(receipt.photoPaths[index]);
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final bytes = await file.readAsBytes();
    final ext = p.extension(file.path).isEmpty ? '.jpg' : p.extension(file.path);
    request.response.headers.set('x-photo-ext', ext);
    request.response.headers.contentType = ContentType.binary;
    request.response.contentLength = bytes.length;
    request.response.add(bytes);
    await request.response.close();
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }
}

class WifiSyncClient {
  static Future<SyncResultSummary> syncWithServer(SyncPayloadInfo info) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6);

    try {
      final localReceipts = await DatabaseService.instance.getAllReceipts();
      final localById = {for (final r in localReceipts) r.id: r};

      final syncReq = await client.post(info.host, info.port, '/sync');
      syncReq.headers.set('x-sync-token', info.token);
      syncReq.headers.contentType = ContentType.json;

      final reqBytes = utf8.encode(
        jsonEncode({
          'receipts': localReceipts.map((r) => r.toJson()).toList(),
        }),
      );
      syncReq.contentLength = reqBytes.length;
      syncReq.add(reqBytes);

      final syncResp = await syncReq.close();
      if (syncResp.statusCode != HttpStatus.ok) {
        throw Exception('Сервер отклонил подключение (${syncResp.statusCode})');
      }

      final respStr = await utf8.decoder.bind(syncResp).join();
      final respJson = jsonDecode(respStr) as Map<String, dynamic>;

      final needPhotosFor =
          (respJson['needPhotosFor'] as List<dynamic>? ?? const [])
              .whereType<String>()
              .toList();

      int sentCount = needPhotosFor.length;
      for (final rId in needPhotosFor) {
        final local = localById[rId];
        if (local == null) continue;
        for (int i = 0; i < local.photoPaths.length; i++) {
          final file = File(local.photoPaths[i]);
          if (!await file.exists()) continue;
          final ext =
              p.extension(file.path).isEmpty ? '.jpg' : p.extension(file.path);
          final photoBytes = await file.readAsBytes();

          final upReq = await client.post(
            info.host,
            info.port,
            '/upload-photo?receiptId=${Uri.encodeQueryComponent(rId)}&index=$i&ext=${Uri.encodeQueryComponent(ext)}',
          );
          upReq.headers.set('x-sync-token', info.token);
          upReq.headers.contentType = ContentType.binary;
          upReq.contentLength = photoBytes.length;
          upReq.add(photoBytes);
          final upResp = await upReq.close();
          await upResp.drain<void>();
        }
      }

      final serverReceiptsRaw =
          (respJson['serverReceipts'] as List<dynamic>? ?? const []);
      int receivedCount = 0;

      for (final raw in serverReceiptsRaw) {
        final map = raw as Map<String, dynamic>;
        final receipt = Receipt.fromJson(map);
        final inserted =
            await DatabaseService.instance.insertReceiptIfMissing(receipt);
        if (inserted) {
          receivedCount++;
          final photoCount = (map['photoCount'] as int?) ?? 0;
          for (int i = 0; i < photoCount; i++) {
            final dlReq = await client.get(
              info.host,
              info.port,
              '/download-photo?receiptId=${Uri.encodeQueryComponent(receipt.id)}&index=$i',
            );
            dlReq.headers.set('x-sync-token', info.token);
            final dlResp = await dlReq.close();
            if (dlResp.statusCode == HttpStatus.ok) {
              final ext = dlResp.headers.value('x-photo-ext') ?? '.jpg';
              final builder = BytesBuilder(copy: false);
              await for (final chunk in dlResp) {
                builder.add(chunk);
              }
              await DatabaseService.instance.saveSyncedPhotoBytes(
                receipt.id,
                i,
                ext,
                builder.takeBytes(),
              );
            } else {
              await dlResp.drain<void>();
            }
          }
        }
      }

      return SyncResultSummary(
        receivedCount: receivedCount,
        sentCount: sentCount,
      );
    } finally {
      client.close();
    }
  }
}