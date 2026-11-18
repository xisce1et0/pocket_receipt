import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:image/image.dart' as img;

class _DetBox {
  final int x;
  final int y;
  final int w;
  final int h;

  const _DetBox(this.x, this.y, this.w, this.h);

  double get centerX => x + w / 2.0;
  double get centerY => y + h / 2.0;
}

class DesktopOcrService {
  static bool _initialized = false;
  static late final OrtSession _detSession;
  static late final OrtSession _recSession;
  static late final List<String> _dict;

  static Future<void> _ensureInitialized() async {
    if (_initialized) return;
    final ort = OnnxRuntime();
    _detSession = await ort.createSessionFromAsset('assets/ocr/det.onnx');
    _recSession = await ort.createSessionFromAsset('assets/ocr/rec.onnx');
    final ymlStr = await rootBundle.loadString('assets/ocr/rec_inference.yml');
    _dict = _parseDictFromYml(ymlStr);
    _initialized = true;
  }

  static Future<String> recognizeText(String imagePath) async {
    await _ensureInitialized();

    final fileBytes = await File(imagePath).readAsBytes();
    var decoded = img.decodeImage(fileBytes);
    if (decoded == null) {
      throw Exception('Не удалось прочитать изображение');
    }
    decoded = img.bakeOrientation(decoded);

    if (math.max(decoded.width, decoded.height) > 2048) {
      if (decoded.width >= decoded.height) {
        decoded = img.copyResize(decoded, width: 2048);
      } else {
        decoded = img.copyResize(decoded, height: 2048);
      }
    }

    final boxes = await _detectBoxes(decoded);
    if (boxes.isEmpty) return '';

    final rows = _groupIntoLines(boxes);
    final sb = StringBuffer();

    for (final row in rows) {
      final parts = <String>[];
      for (final box in row) {
        final crop = img.copyCrop(
          decoded,
          x: box.x,
          y: box.y,
          width: box.w,
          height: box.h,
        );
        final text = (await _recognizeLine(crop)).trim();
        if (text.isNotEmpty) {
          parts.add(text);
        }
      }
      if (parts.isNotEmpty) {
        if (sb.isNotEmpty) sb.write('\n');
        sb.write(parts.join(' '));
      }
    }
    return sb.toString();
  }

  static Future<List<_DetBox>> _detectBoxes(img.Image src) async {
    final srcW = src.width;
    final srcH = src.height;
    final maxSide = math.max(srcW, srcH);
    final scale = maxSide > 960 ? 960.0 / maxSide : 1.0;

    final resizeW = math.max(32, ((srcW * scale) / 32.0).round() * 32);
    final resizeH = math.max(32, ((srcH * scale) / 32.0).round() * 32);
    final ratioW = resizeW / srcW;
    final ratioH = resizeH / srcH;

    final resized = img.copyResize(src, width: resizeW, height: resizeH);
    final pixelCount = resizeW * resizeH;
    final input = Float32List(3 * pixelCount);

    for (int y = 0; y < resizeH; y++) {
      for (int x = 0; x < resizeW; x++) {
        final p = resized.getPixel(x, y);
        final idx = y * resizeW + x;
        input[idx] = (p.b.toDouble() / 255.0 - 0.485) / 0.229;
        input[pixelCount + idx] = (p.g.toDouble() / 255.0 - 0.456) / 0.224;
        input[2 * pixelCount + idx] = (p.r.toDouble() / 255.0 - 0.406) / 0.225;
      }
    }

    final inputName = _detSession.inputNames.first;
    final inTensor = await OrtValue.fromList(input, [1, 3, resizeH, resizeW]);
    Map<String, OrtValue> outputs = const {};

    final List<double> probMap;
    try {
      outputs = await _detSession.run({inputName: inTensor});
      final flat = await outputs.values.first.asFlattenedList();
      probMap = flat.map((e) => (e as num).toDouble()).toList();
    } finally {
      await inTensor.dispose();
      for (final out in outputs.values) {
        await out.dispose();
      }
    }

    // Поиск связных областей текста (BFS вместо OpenCV findContours)
    final visited = Uint8List(pixelCount);
    final queue = Queue<int>();
    final boxes = <_DetBox>[];

    for (int start = 0; start < pixelCount; start++) {
      if (visited[start] == 1 || probMap[start] <= 0.3) continue;

      visited[start] = 1;
      queue.add(start);

      int minX = start % resizeW;
      int maxX = minX;
      int minY = start ~/ resizeW;
      int maxY = minY;
      int count = 0;
      double sumProb = 0;

      while (queue.isNotEmpty) {
        final curr = queue.removeFirst();
        final cx = curr % resizeW;
        final cy = curr ~/ resizeW;
        count++;
        sumProb += probMap[curr];

        if (cx < minX) minX = cx;
        if (cx > maxX) maxX = cx;
        if (cy < minY) minY = cy;
        if (cy > maxY) maxY = cy;

        for (final dy in const [-1, 0, 1]) {
          final ny = cy + dy;
          if (ny < 0 || ny >= resizeH) continue;
          for (final dx in const [-1, 0, 1]) {
            if (dx == 0 && dy == 0) continue;
            final nx = cx + dx;
            if (nx < 0 || nx >= resizeW) continue;
            final nIdx = ny * resizeW + nx;
            if (visited[nIdx] == 0 && probMap[nIdx] > 0.3) {
              visited[nIdx] = 1;
              queue.add(nIdx);
            }
          }
        }
      }

      if (count < 10 || (sumProb / count) < 0.45) continue;

      final bw = (maxX - minX + 1).toDouble();
      final bh = (maxY - minY + 1).toDouble();
      final dist = (bw * bh * 1.5) / math.max(1.0, 2.0 * (bw + bh));

      final ux1 = math.max(0.0, minX - dist) / ratioW;
      final uy1 = math.max(0.0, minY - dist * 0.65) / ratioH;
      final ux2 = math.min(resizeW.toDouble(), maxX + 1 + dist) / ratioW;
      final uy2 = math.min(resizeH.toDouble(), maxY + 1 + dist * 0.65) / ratioH;

      final x = ux1.floor().clamp(0, srcW - 1);
      final y = uy1.floor().clamp(0, srcH - 1);
      final w = (ux2.ceil() - x).clamp(1, srcW - x);
      final h = (uy2.ceil() - y).clamp(1, srcH - y);

      if (w >= 8 && h >= 6) {
        boxes.add(_DetBox(x, y, w, h));
      }
    }

    return boxes;
  }

  static List<List<_DetBox>> _groupIntoLines(List<_DetBox> boxes) {
    final sorted = List<_DetBox>.from(boxes)
      ..sort((a, b) => a.centerY.compareTo(b.centerY));

    final rows = <List<_DetBox>>[];
    for (final box in sorted) {
      if (rows.isEmpty) {
        rows.add([box]);
        continue;
      }
      final current = rows.last;
      final avgY =
          current.fold<double>(0, (s, b) => s + b.centerY) / current.length;
      final avgH =
          current.fold<double>(0, (s, b) => s + b.h) / current.length;
      final threshold = math.max(avgH, box.h.toDouble()) * 0.55;

      if ((box.centerY - avgY).abs() <= threshold) {
        current.add(box);
      } else {
        rows.add([box]);
      }
    }

    for (final row in rows) {
      row.sort((a, b) => a.centerX.compareTo(b.centerX));
    }
    return rows;
  }

  static Future<String> _recognizeLine(img.Image crop) async {
    const imgH = 48;
    final ratio = crop.width / crop.height;
    final resizedW = math.max(8, math.min(1280, (imgH * ratio).ceil()));
    final targetW = math.max(320, ((resizedW + 31) ~/ 32) * 32);

    final resized = img.copyResize(crop, width: resizedW, height: imgH);
    final planeSize = imgH * targetW;
    final input = Float32List(3 * planeSize);

    for (int y = 0; y < imgH; y++) {
      final rowOff = y * targetW;
      for (int x = 0; x < resizedW; x++) {
        final p = resized.getPixel(x, y);
        final idx = rowOff + x;
        input[idx] = ((p.b.toDouble() / 255.0) - 0.5) / 0.5;
        input[planeSize + idx] = ((p.g.toDouble() / 255.0) - 0.5) / 0.5;
        input[2 * planeSize + idx] = ((p.r.toDouble() / 255.0) - 0.5) / 0.5;
      }
    }

    final inputName = _recSession.inputNames.first;
    final inTensor = await OrtValue.fromList(input, [1, 3, imgH, targetW]);
    Map<String, OrtValue> outputs = const {};

    final List<double> logits;
    final int timeSteps;
    final int numClasses;

    try {
      outputs = await _recSession.run({inputName: inTensor});
      final outTensor = outputs.values.first;
      timeSteps = outTensor.shape[1];
      numClasses = outTensor.shape[2];
      final flat = await outTensor.asFlattenedList();
      logits = flat.map((e) => (e as num).toDouble()).toList();
    } finally {
      await inTensor.dispose();
      for (final out in outputs.values) {
        await out.dispose();
      }
    }

    final sb = StringBuffer();
    int prevIdx = -1;
    for (int t = 0; t < timeSteps; t++) {
      final rowOff = t * numClasses;
      int bestIdx = 0;
      double bestVal = logits[rowOff];
      for (int c = 1; c < numClasses; c++) {
        final v = logits[rowOff + c];
        if (v > bestVal) {
          bestVal = v;
          bestIdx = c;
        }
      }

      if (bestIdx != 0 && bestIdx != prevIdx) {
        final dictIdx = bestIdx - 1;
        if (dictIdx >= 0 && dictIdx < _dict.length) {
          sb.write(_dict[dictIdx]);
        } else if (numClasses == _dict.length + 2 &&
            bestIdx == _dict.length + 1) {
          sb.write(' ');
        }
      }
      prevIdx = bestIdx;
    }

    return sb.toString();
  }

  static List<String> _parseDictFromYml(String ymlContent) {
    final result = <String>[];
    bool inDict = false;

    for (final rawLine in ymlContent.split(RegExp(r'\r?\n'))) {
      if (!inDict) {
        if (rawLine.trimLeft().startsWith('character_dict:')) {
          inDict = true;
        }
        continue;
      }

      final trimmed = rawLine.trim();
      if (trimmed.isEmpty) continue;
      if (!trimmed.startsWith('- ')) break;

      var token = trimmed.substring(2).trim();
      if (token.length >= 2 && token.startsWith("'") && token.endsWith("'")) {
        token = token.substring(1, token.length - 1).replaceAll("''", "'");
      } else if (token.length >= 2 &&
          token.startsWith('"') &&
          token.endsWith('"')) {
        token = token
            .substring(1, token.length - 1)
            .replaceAll(r'\"', '"')
            .replaceAll(r'\\', r'\');
      }
      result.add(token);
    }

    return result;
  }
}