import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ShareService {
  static const _channel = MethodChannel('pocket_receipt/share');

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static Future<List<String>> getInitialSharedImages() async {
    if (!isSupported) return const [];
    final raw = await _channel.invokeMethod<List<dynamic>>(
      'getInitialSharedImages',
    );
    if (raw == null) return const [];
    return raw.whereType<String>().toList();
  }

  static void listenForSharedImages(
    void Function(List<String> paths) onImagesReceived,
  ) {
    if (!isSupported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSharedImages') {
        final raw = call.arguments as List<dynamic>?;
        if (raw != null) {
          final paths = raw.whereType<String>().toList();
          if (paths.isNotEmpty) {
            onImagesReceived(paths);
          }
        }
      }
    });
  }
}