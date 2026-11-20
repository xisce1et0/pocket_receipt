import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'desktop_paddle_ocr.dart';

class OcrService {
  static const _channel = MethodChannel('pocket_receipt/ocr');

  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isWindows);

  static Future<String?> recognizeReceiptText(String imagePath) async {
    if (!isSupported) return null;
    if (Platform.isAndroid) {
      return _channel.invokeMethod<String>(
        'recognizeText',
        {'imagePath': imagePath},
      );
    }
    if (Platform.isWindows) {
      return DesktopPaddleOcr.instance.recognizeReceiptText(imagePath);
    }
    return null;
  }
}