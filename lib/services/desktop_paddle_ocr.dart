import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

typedef _OrtAllocC = ffi.Pointer<ffi.Void> Function(ffi.Int64);
typedef _OrtAllocDart = ffi.Pointer<ffi.Void> Function(int);

typedef _OrtFreeC = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _OrtFreeDart = void Function(ffi.Pointer<ffi.Void>);

typedef _OrtLastErrC = ffi.Pointer<ffi.Uint8> Function();
typedef _OrtLastErrDart = ffi.Pointer<ffi.Uint8> Function();

typedef _OrtInitC = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
  ffi.Int32,
);
typedef _OrtInitDart = int Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Pointer<ffi.Uint8>,
  int,
);

typedef _OrtRunC = ffi.Int32 Function(
  ffi.Int32,
  ffi.Pointer<ffi.Float>,
  ffi.Int64,
  ffi.Pointer<ffi.Int64>,
  ffi.Int32,
  ffi.Pointer<ffi.Pointer<ffi.Float>>,
  ffi.Pointer<ffi.Int64>,
  ffi.Pointer<ffi.Int64>,
  ffi.Pointer<ffi.Int32>,
);
typedef _OrtRunDart = int Function(
  int,
  ffi.Pointer<ffi.Float>,
  int,
  ffi.Pointer<ffi.Int64>,
  int,
  ffi.Pointer<ffi.Pointer<ffi.Float>>,
  ffi.Pointer<ffi.Int64>,
  ffi.Pointer<ffi.Int64>,
  ffi.Pointer<ffi.Int32>,
);

class DesktopPaddleOcr {
  DesktopPaddleOcr._();
  static final DesktopPaddleOcr instance = DesktopPaddleOcr._();

  bool _assetsReady = false;
  late String _detPath;
  late String _recPath;
  late List<String> _dict;

  Future<void> _ensureAssets() async {
    if (_assetsReady) return;
    final supportDir = await getApplicationSupportDirectory();
    final ocrDir = Directory(p.join(supportDir.path, 'neural_ocr'));
    if (!await ocrDir.exists()) {
      await ocrDir.create(recursive: true);
    }

    _detPath = await _copyAssetIfNeeded(
      'assets/ocr/det.onnx',
      File(p.join(ocrDir.path, 'det.onnx')),
    );
    _recPath = await _copyAssetIfNeeded(
      'assets/ocr/rec.onnx',
      File(p.join(ocrDir.path, 'rec.onnx')),
    );
    final ymlPath = await _copyAssetIfNeeded(
      'assets/ocr/rec_inference.yml',
      File(p.join(ocrDir.path, 'rec_inference.yml')),
    );

    _dict = _parseDictionaryFromYml(await File(ymlPath).readAsString());
    _assetsReady = true;
  }

  Future<String> _copyAssetIfNeeded(String assetKey, File dest) async {
    if (!await dest.exists() || await dest.length() == 0) {
      final data = await rootBundle.load(assetKey);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      await dest.writeAsBytes(bytes, flush: true);
    }
    return dest.path;
  }

  Future<String> recognizeReceiptText(String imagePath) async {
    await _ensureAssets();

    final file = File(imagePath);
    if (!await file.exists()) {
      throw Exception('Файл изображения не найден');
    }

    final fileBytes = await file.readAsBytes();
    final decoded = await _decodeRgba(fileBytes);
    final detPath = _detPath;
    final recPath = _recPath;
    final dict = _dict;

    return Isolate.run(
      () => _runPaddleOcrInIsolate(
        rgba: decoded.rgba,
        width: decoded.width,
        height: decoded.height,
        detPath: detPath,
        recPath: recPath,
        dict: dict,
      ),
    );
  }

  Future<({Uint8List rgba, int width, int height})> _decodeRgba(
    Uint8List bytes,
  ) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final origW = descriptor.width;
    final origH = descriptor.height;

    int? targetW;
    int? targetH;
    const maxDim = 2048;
    if (origW > maxDim || origH > maxDim) {
      if (origW >= origH) {
        targetW = maxDim;
      } else {
        targetH = maxDim;
      }
    }

    final codec = await descriptor.instantiateCodec(
      targetWidth: targetW,
      targetHeight: targetH,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final w = image.width;
    final h = image.height;
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);

    image.dispose();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();

    if (byteData == null) {
      throw Exception('Не удалось декодировать изображение');
    }

    return (
      rgba: Uint8List.fromList(byteData.buffer.asUint8List()),
      width: w,
      height: h,
    );
  }
}

List<String> _parseDictionaryFromYml(String content) {
  final result = <String>[];
  bool inDict = false;

  for (final rawLine in const LineSplitter().convert(content)) {
    if (!inDict) {
      if (rawLine.trimLeft().startsWith('character_dict:')) {
        inDict = true;
      }
      continue;
    }

    final trimmed = rawLine.trim();
    if (trimmed.isEmpty) continue;
    if (!trimmed.startsWith('- ')) {
      inDict = false;
      continue;
    }

    var token = trimmed.substring(2).trim();
    if (token.length >= 2 && token.startsWith("'") && token.endsWith("'")) {
      token = token.substring(1, token.length - 1).replaceAll("''", "'");
    } else if (token.length >= 2 &&
        token.startsWith('"') &&
        token.endsWith('"')) {
      token = token
          .substring(1, token.length - 1)
          .replaceAll('\\"', '"')
          .replaceAll('\\\\', '\\');
    }
    result.add(token);
  }
  return result;
}

class _OrtNative {
  final _OrtAllocDart alloc;
  final _OrtFreeDart free;
  final _OrtLastErrDart lastErr;
  final _OrtInitDart initOcr;
  final _OrtRunDart runOcr;

  _OrtNative._({
    required this.alloc,
    required this.free,
    required this.lastErr,
    required this.initOcr,
    required this.runOcr,
  });

  factory _OrtNative.open() {
    final lib = ffi.DynamicLibrary.executable();
    return _OrtNative._(
      alloc: lib.lookupFunction<_OrtAllocC, _OrtAllocDart>('ort_alloc'),
      free: lib.lookupFunction<_OrtFreeC, _OrtFreeDart>('ort_free'),
      lastErr: lib.lookupFunction<_OrtLastErrC, _OrtLastErrDart>(
        'ort_get_last_error',
      ),
      initOcr: lib.lookupFunction<_OrtInitC, _OrtInitDart>('ort_init_ocr'),
      runOcr: lib.lookupFunction<_OrtRunC, _OrtRunDart>('ort_run_ocr'),
    );
  }

  String readLastError() {
    final ptr = lastErr();
    if (ptr == ffi.nullptr) return 'Unknown ONNX error';
    final bytes = <int>[];
    for (int i = 0; i < 4096; i++) {
      final b = ptr[i];
      if (b == 0) break;
      bytes.add(b);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  ffi.Pointer<ffi.Uint8> allocUtf8(String value) {
    final encoded = utf8.encode(value);
    final ptr = alloc(encoded.length + 1).cast<ffi.Uint8>();
    final view = ptr.asTypedList(encoded.length + 1);
    view.setAll(0, encoded);
    view[encoded.length] = 0;
    return ptr;
  }

  void ensureInitialized(String detPath, String recPath) {
    final pDet = allocUtf8(detPath);
    final pRec = allocUtf8(recPath);
    try {
      final rc = initOcr(pDet, pRec, 4);
      if (rc != 0) {
        throw Exception('ONNX init error ($rc): ${readLastError()}');
      }
    } finally {
      free(pDet.cast());
      free(pRec.cast());
    }
  }

  ({Float32List data, List<int> shape}) run({
    required bool isRec,
    required Float32List input,
    required List<int> shape,
  }) {
    final inBuf = alloc(input.length * 4).cast<ffi.Float>();
    final shapeBuf = alloc(shape.length * 8).cast<ffi.Int64>();
    final outDataPtr =
        alloc(ffi.sizeOf<ffi.Pointer<ffi.Float>>()).cast<ffi.Pointer<ffi.Float>>();
    final outLenPtr = alloc(8).cast<ffi.Int64>();
    final outShapeBuf = alloc(4 * 8).cast<ffi.Int64>();
    final outShapeLenPtr = alloc(4).cast<ffi.Int32>();

    ffi.Pointer<ffi.Float> nativeOut = ffi.nullptr;

    try {
      inBuf.asTypedList(input.length).setAll(0, input);
      shapeBuf.asTypedList(shape.length).setAll(0, shape);
      outDataPtr.value = ffi.nullptr;
      outLenPtr.value = 0;
      outShapeLenPtr.value = 0;

      final rc = runOcr(
        isRec ? 1 : 0,
        inBuf,
        input.length,
        shapeBuf,
        shape.length,
        outDataPtr,
        outLenPtr,
        outShapeBuf,
        outShapeLenPtr,
      );
      if (rc != 0) {
        throw Exception('ONNX run error ($rc): ${readLastError()}');
      }

      nativeOut = outDataPtr.value;
      final outLen = outLenPtr.value;
      final outShapeLen = outShapeLenPtr.value;

      final copiedData = outLen > 0 && nativeOut != ffi.nullptr
          ? Float32List.fromList(nativeOut.asTypedList(outLen))
          : Float32List(0);
      final copiedShape = outShapeLen > 0
          ? List<int>.from(outShapeBuf.asTypedList(outShapeLen))
          : <int>[];

      return (data: copiedData, shape: copiedShape);
    } finally {
      if (nativeOut != ffi.nullptr) free(nativeOut.cast());
      free(inBuf.cast());
      free(shapeBuf.cast());
      free(outDataPtr.cast());
      free(outLenPtr.cast());
      free(outShapeBuf.cast());
      free(outShapeLenPtr.cast());
    }
  }
}

class _Pt {
  final double x;
  final double y;
  const _Pt(this.x, this.y);
}

class _TextBox {
  final _Pt tl;
  final _Pt tr;
  final _Pt br;
  final _Pt bl;
  final double centerX;
  final double centerY;
  final int cropW;
  final int cropH;

  const _TextBox({
    required this.tl,
    required this.tr,
    required this.br,
    required this.bl,
    required this.centerX,
    required this.centerY,
    required this.cropW,
    required this.cropH,
  });
}

class _RawComponent {
  final List<int> pixels;
  final int minX;
  final int minY;
  final int maxX;
  final int maxY;
  final double pcaAngle;

  const _RawComponent({
    required this.pixels,
    required this.minX,
    required this.minY,
    required this.maxX,
    required this.maxY,
    required this.pcaAngle,
  });
}

String _runPaddleOcrInIsolate({
  required Uint8List rgba,
  required int width,
  required int height,
  required String detPath,
  required String recPath,
  required List<String> dict,
}) {
  final ort = _OrtNative.open();
  ort.ensureInitialized(detPath, recPath);

  final detected = _detectTextBoxes(
    ort: ort,
    rgba: rgba,
    srcW: width,
    srcH: height,
  );
  if (detected.boxes.isEmpty) return '';

  final lines = _groupBoxesIntoLines(detected.boxes, detected.medianAngle);
  final sb = StringBuffer();

  for (final lineBoxes in lines) {
    final parts = <String>[];
    for (final box in lineBoxes) {
      final text = _recognizeBox(
        ort: ort,
        rgba: rgba,
        srcW: width,
        srcH: height,
        box: box,
        dict: dict,
      ).trim();
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

({List<_TextBox> boxes, double medianAngle}) _detectTextBoxes({
  required _OrtNative ort,
  required Uint8List rgba,
  required int srcW,
  required int srcH,
}) {
  final maxSide = math.max(srcW, srcH);
  const limitSide = 1024;
  final scale = maxSide > limitSide ? limitSide / maxSide : 1.0;

  final resizeW = math.max(32, ((srcW * scale) / 32.0).round() * 32);
  final resizeH = math.max(32, ((srcH * scale) / 32.0).round() * 32);
  final ratioW = resizeW / srcW;
  final ratioH = resizeH / srcH;

  final pixelCount = resizeW * resizeH;
  final inputFloats = Float32List(3 * pixelCount);
  const mean0 = 0.485;
  const mean1 = 0.456;
  const mean2 = 0.406;
  const invStd0 = 1.0 / 0.229;
  const invStd1 = 1.0 / 0.224;
  const invStd2 = 1.0 / 0.225;

  for (int y = 0; y < resizeH; y++) {
    final sy = ((y + 0.5) / ratioH - 0.5).clamp(0.0, (srcH - 1).toDouble());
    final y0 = sy.floor();
    final y1 = math.min(y0 + 1, srcH - 1);
    final fy = sy - y0;
    final row0 = y0 * srcW;
    final row1 = y1 * srcW;
    final dstRow = y * resizeW;

    for (int x = 0; x < resizeW; x++) {
      final sx = ((x + 0.5) / ratioW - 0.5).clamp(0.0, (srcW - 1).toDouble());
      final x0 = sx.floor();
      final x1 = math.min(x0 + 1, srcW - 1);
      final fx = sx - x0;

      final i00 = (row0 + x0) * 4;
      final i10 = (row0 + x1) * 4;
      final i01 = (row1 + x0) * 4;
      final i11 = (row1 + x1) * 4;

      final w00 = (1.0 - fx) * (1.0 - fy);
      final w10 = fx * (1.0 - fy);
      final w01 = (1.0 - fx) * fy;
      final w11 = fx * fy;

      final r = (rgba[i00] * w00 +
              rgba[i10] * w10 +
              rgba[i01] * w01 +
              rgba[i11] * w11) /
          255.0;
      final g = (rgba[i00 + 1] * w00 +
              rgba[i10 + 1] * w10 +
              rgba[i01 + 1] * w01 +
              rgba[i11 + 1] * w11) /
          255.0;
      final b = (rgba[i00 + 2] * w00 +
              rgba[i10 + 2] * w10 +
              rgba[i01 + 2] * w01 +
              rgba[i11 + 2] * w11) /
          255.0;

      // Канал BGR как в NeuralOcrEngine.kt
      final dstIdx = dstRow + x;
      inputFloats[dstIdx] = (b - mean0) * invStd0;
      inputFloats[pixelCount + dstIdx] = (g - mean1) * invStd1;
      inputFloats[2 * pixelCount + dstIdx] = (r - mean2) * invStd2;
    }
  }

  final detOut = ort.run(
    isRec: false,
    input: inputFloats,
    shape: [1, 3, resizeH, resizeW],
  );
  final probMap = detOut.data;
  if (probMap.length < pixelCount) {
    return (boxes: const <_TextBox>[], medianAngle: 0.0);
  }

  // Поиск связных компонент на бинарной карте вероятностей (prob > 0.30)
  final visited = Uint8List(pixelCount);
  final queue = Int32List(pixelCount);
  final components = <_RawComponent>[];
  final wideAngles = <double>[];

  for (int idx = 0; idx < pixelCount; idx++) {
    if (visited[idx] != 0 || probMap[idx] <= 0.30) continue;

    int qHead = 0;
    int qTail = 0;
    queue[qTail++] = idx;
    visited[idx] = 1;

    final pixels = <int>[];
    int minX = resizeW;
    int maxX = 0;
    int minY = resizeH;
    int maxY = 0;

    while (qHead < qTail) {
      final cur = queue[qHead++];
      pixels.add(cur);
      final cx = cur % resizeW;
      final cy = cur ~/ resizeW;
      if (cx < minX) minX = cx;
      if (cx > maxX) maxX = cx;
      if (cy < minY) minY = cy;
      if (cy > maxY) maxY = cy;

      if (cx > 0) {
        final n = cur - 1;
        if (visited[n] == 0 && probMap[n] > 0.30) {
          visited[n] = 1;
          queue[qTail++] = n;
        }
      }
      if (cx + 1 < resizeW) {
        final n = cur + 1;
        if (visited[n] == 0 && probMap[n] > 0.30) {
          visited[n] = 1;
          queue[qTail++] = n;
        }
      }
      if (cy > 0) {
        final n = cur - resizeW;
        if (visited[n] == 0 && probMap[n] > 0.30) {
          visited[n] = 1;
          queue[qTail++] = n;
        }
      }
      if (cy + 1 < resizeH) {
        final n = cur + resizeW;
        if (visited[n] == 0 && probMap[n] > 0.30) {
          visited[n] = 1;
          queue[qTail++] = n;
        }
      }
    }

    final bw = maxX - minX + 1;
    final bh = maxY - minY + 1;
    if (math.min(bw, bh) < 3 || pixels.length < 6) continue;

    // Средняя вероятность в bounding box
    double sumScore = 0.0;
    int countScore = 0;
    for (int py = minY; py <= maxY; py++) {
      final rowOff = py * resizeW;
      for (int px = minX; px <= maxX; px++) {
        sumScore += probMap[rowOff + px];
        countScore++;
      }
    }
    if (countScore == 0 || (sumScore / countScore) < 0.45) continue;

    // Оцениваем угол наклона по PCA для широких текстовых строк
    double pcaAngle = 0.0;
    if (bw > bh * 2.2) {
      double mx = 0;
      double my = 0;
      for (final pIdx in pixels) {
        mx += (pIdx % resizeW);
        my += (pIdx ~/ resizeW);
      }
      mx /= pixels.length;
      my /= pixels.length;

      double cxx = 0;
      double cyy = 0;
      double cxy = 0;
      for (final pIdx in pixels) {
        final dx = (pIdx % resizeW) - mx;
        final dy = (pIdx ~/ resizeW) - my;
        cxx += dx * dx;
        cyy += dy * dy;
        cxy += dx * dy;
      }
      final theta = 0.5 * math.atan2(2.0 * cxy, cxx - cyy);
      if (theta.abs() < math.pi / 5) {
        pcaAngle = theta;
        wideAngles.add(theta);
      }
    }

    components.add(
      _RawComponent(
        pixels: pixels,
        minX: minX,
        minY: minY,
        maxX: maxX,
        maxY: maxY,
        pcaAngle: pcaAngle,
      ),
    );
  }

  wideAngles.sort();
  final medianAngle =
      wideAngles.isNotEmpty ? wideAngles[wideAngles.length ~/ 2] : 0.0;

  final boxes = <_TextBox>[];
  for (final comp in components) {
    final bw = comp.maxX - comp.minX + 1;
    final bh = comp.maxY - comp.minY + 1;
    final useOwnAngle = bw > bh * 3.0 &&
        (comp.pcaAngle - medianAngle).abs() < (math.pi / 18);
    final angle = useOwnAngle ? comp.pcaAngle : medianAngle;
    final cosA = math.cos(angle);
    final sinA = math.sin(angle);

    double minU = double.infinity;
    double maxU = -double.infinity;
    double minV = double.infinity;
    double maxV = -double.infinity;

    for (final pIdx in comp.pixels) {
      final px = (pIdx % resizeW).toDouble();
      final py = (pIdx ~/ resizeW).toDouble();
      final u = px * cosA + py * sinA;
      final v = -px * sinA + py * cosA;
      if (u < minU) minU = u;
      if (u > maxU) maxU = u;
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }

    final rw = maxU - minU + 1.0;
    final rh = maxV - minV + 1.0;
    if (math.min(rw, rh) < 2.5) continue;

    // DBNet unclip expansion (ratio = 1.55)
    final area = rw * rh;
    final perimeter = 2.0 * (rw + rh);
    final dist = (area * 1.55) / math.max(1.0, perimeter);

    final u0 = minU - dist;
    final u1 = maxU + dist;
    final v0 = minV - dist;
    final v1 = maxV + dist;

    _Pt toSrc(double u, double v) {
      final rx = u * cosA - v * sinA;
      final ry = u * sinA + v * cosA;
      return _Pt(
        (rx / ratioW).clamp(0.0, srcW.toDouble()),
        (ry / ratioH).clamp(0.0, srcH.toDouble()),
      );
    }

    final tl = toSrc(u0, v0);
    final tr = toSrc(u1, v0);
    final br = toSrc(u1, v1);
    final bl = toSrc(u0, v1);

    final cropW = _hypot(tr.x - tl.x, tr.y - tl.y).round();
    final cropH = _hypot(bl.x - tl.x, bl.y - tl.y).round();
    if (cropW < 6 || cropH < 6) continue;

    boxes.add(
      _TextBox(
        tl: tl,
        tr: tr,
        br: br,
        bl: bl,
        centerX: (tl.x + tr.x + br.x + bl.x) / 4.0,
        centerY: (tl.y + tr.y + br.y + bl.y) / 4.0,
        cropW: cropW,
        cropH: cropH,
      ),
    );
  }

  return (boxes: boxes, medianAngle: medianAngle);
}

List<List<_TextBox>> _groupBoxesIntoLines(
  List<_TextBox> boxes,
  double medianAngle,
) {
  final cosA = math.cos(medianAngle);
  final sinA = math.sin(medianAngle);

  final rotated = boxes.map((box) {
    final pts = [box.tl, box.tr, box.br, box.bl];
    double minRx = double.infinity;
    double maxRx = -double.infinity;
    for (final pt in pts) {
      final rx = pt.x * cosA + pt.y * sinA;
      if (rx < minRx) minRx = rx;
      if (rx > maxRx) maxRx = rx;
    }
    return (
      box: box,
      rotX: box.centerX * cosA + box.centerY * sinA,
      rotY: -box.centerX * sinA + box.centerY * cosA,
      minRotX: minRx,
      maxRotX: maxRx,
    );
  }).toList()
    ..sort((a, b) => a.rotY.compareTo(b.rotY));

  final rows =
      <List<({_TextBox box, double rotX, double rotY, double minRotX, double maxRotX})>>[];

  for (final item in rotated) {
    List<({_TextBox box, double rotX, double rotY, double minRotX, double maxRotX})>?
        bestRow;
    double bestDiffY = double.infinity;

    final startRow = math.max(0, rows.length - 3);
    for (int rIdx = rows.length - 1; rIdx >= startRow; rIdx--) {
      final row = rows[rIdx];

      bool horizConflict = false;
      for (final ex in row) {
        final overlap =
            math.min(item.maxRotX, ex.maxRotX) - math.max(item.minRotX, ex.minRotX);
        final minW =
            math.min(item.maxRotX - item.minRotX, ex.maxRotX - ex.minRotX);
        if (minW > 0 && overlap > minW * 0.35) {
          horizConflict = true;
          break;
        }
      }
      if (horizConflict) continue;

      var nearest = row.first;
      double bestDx = (nearest.rotX - item.rotX).abs();
      double sumH = 0;
      for (final ex in row) {
        sumH += ex.box.cropH;
        final dx = (ex.rotX - item.rotX).abs();
        if (dx < bestDx) {
          bestDx = dx;
          nearest = ex;
        }
      }

      final avgH = sumH / row.length;
      final threshold = math.max(avgH, item.box.cropH.toDouble()) * 0.60;
      final diffY = (item.rotY - nearest.rotY).abs();

      if (diffY <= threshold && diffY < bestDiffY) {
        bestDiffY = diffY;
        bestRow = row;
      }
    }

    if (bestRow != null) {
      bestRow.add(item);
    } else {
      rows.add([item]);
    }
  }

  rows.sort((a, b) {
    final ay = a.fold<double>(0, (s, e) => s + e.rotY) / a.length;
    final by = b.fold<double>(0, (s, e) => s + e.rotY) / b.length;
    return ay.compareTo(by);
  });

  return rows.map((row) {
    row.sort((a, b) => a.rotX.compareTo(b.rotX));
    return row.map((e) => e.box).toList();
  }).toList();
}

String _recognizeBox({
  required _OrtNative ort,
  required Uint8List rgba,
  required int srcW,
  required int srcH,
  required _TextBox box,
  required List<String> dict,
}) {
  const imgH = 48;
  final ratio = box.cropW / box.cropH;
  final resizedW = math.max(8, math.min(1280, (imgH * ratio).ceil()));
  final targetW = math.max(320, ((resizedW + 31) ~/ 32) * 32);

  final planeSize = imgH * targetW;
  final inputFloats = Float32List(3 * planeSize);

  final ux = box.tr.x - box.tl.x;
  final uy = box.tr.y - box.tl.y;
  final vx = box.bl.x - box.tl.x;
  final vy = box.bl.y - box.tl.y;
  final maxX = (srcW - 1).toDouble();
  final maxY = (srcH - 1).toDouble();

  for (int y = 0; y < imgH; y++) {
    final ty = (y + 0.5) / imgH;
    final baseX = box.tl.x + ty * vx;
    final baseY = box.tl.y + ty * vy;
    final dstRow = y * targetW;

    for (int x = 0; x < resizedW; x++) {
      final tx = (x + 0.5) / resizedW;
      final sx = (baseX + tx * ux).clamp(0.0, maxX);
      final sy = (baseY + tx * uy).clamp(0.0, maxY);

      final x0 = sx.floor();
      final y0 = sy.floor();
      final x1 = math.min(x0 + 1, srcW - 1);
      final y1 = math.min(y0 + 1, srcH - 1);
      final fx = sx - x0;
      final fy = sy - y0;

      final i00 = (y0 * srcW + x0) * 4;
      final i10 = (y0 * srcW + x1) * 4;
      final i01 = (y1 * srcW + x0) * 4;
      final i11 = (y1 * srcW + x1) * 4;

      final w00 = (1.0 - fx) * (1.0 - fy);
      final w10 = fx * (1.0 - fy);
      final w01 = (1.0 - fx) * fy;
      final w11 = fx * fy;

      final r = rgba[i00] * w00 +
          rgba[i10] * w10 +
          rgba[i01] * w01 +
          rgba[i11] * w11;
      final g = rgba[i00 + 1] * w00 +
          rgba[i10 + 1] * w10 +
          rgba[i01 + 1] * w01 +
          rgba[i11 + 1] * w11;
      final b = rgba[i00 + 2] * w00 +
          rgba[i10 + 2] * w10 +
          rgba[i01 + 2] * w01 +
          rgba[i11 + 2] * w11;

      final dstIdx = dstRow + x;
      inputFloats[dstIdx] = (b / 255.0 - 0.5) / 0.5;
      inputFloats[planeSize + dstIdx] = (g / 255.0 - 0.5) / 0.5;
      inputFloats[2 * planeSize + dstIdx] = (r / 255.0 - 0.5) / 0.5;
    }
  }

  final recOut = ort.run(
    isRec: true,
    input: inputFloats,
    shape: [1, 3, imgH, targetW],
  );
  if (recOut.shape.length < 3) return '';

  final timeSteps = recOut.shape[1];
  final numClasses = recOut.shape[2];
  final logits = recOut.data;
  if (logits.length < timeSteps * numClasses) return '';

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
      if (dictIdx >= 0 && dictIdx < dict.length) {
        sb.write(dict[dictIdx]);
      } else if (numClasses == dict.length + 2 && bestIdx == dict.length + 1) {
        sb.write(' ');
      }
    }
    prevIdx = bestIdx;
  }
  return sb.toString();
}

double _hypot(double dx, double dy) => math.sqrt(dx * dx + dy * dy);