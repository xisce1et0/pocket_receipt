import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'desktop_ocr_service.dart';

class OcrService {
  static const _channel = MethodChannel('pocket_receipt/ocr');

  static bool get isSupported =>
      !kIsWeb && (Platform.isAndroid || Platform.isWindows);

  static Future<String?> recognizeReceiptText(String imagePath) async {
    if (kIsWeb) return null;
    if (Platform.isAndroid) {
      return _channel.invokeMethod<String>(
        'recognizeText',
        {'imagePath': imagePath},
      );
    }
    if (Platform.isWindows) {
      return DesktopOcrService.recognizeText(imagePath);
    }
    return null;
  }
}