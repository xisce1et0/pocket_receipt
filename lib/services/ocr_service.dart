import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class OcrService {
  static const _channel = MethodChannel('pocket_receipt/ocr');

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static Future<String?> recognizeReceiptText(String imagePath) async {
    if (!isSupported) return null;
    return _channel.invokeMethod<String>(
      'recognizeText',
      {'imagePath': imagePath},
    );
  }
}