import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../utils/auto_grouper.dart';

enum ReceiptLineRole {
  noise,
  store,
  date,
  total,
  discount,
  itemName,
  itemInline,
  itemMath,
}

class ClassifiedReceiptLine {
  final String text;
  final ReceiptLineRole role;
  final double roleConfidence;
  final String category;
  final double categoryConfidence;

  const ClassifiedReceiptLine({
    required this.text,
    required this.role,
    required this.roleConfidence,
    required this.category,
    required this.categoryConfidence,
  });
}

typedef _OrtAllocC = ffi.Pointer<ffi.Void> Function(ffi.Int64);
typedef _OrtAllocDart = ffi.Pointer<ffi.Void> Function(int);

typedef _OrtFreeC = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _OrtFreeDart = void Function(ffi.Pointer<ffi.Void>);

typedef _OrtLastErrC = ffi.Pointer<ffi.Uint8> Function();
typedef _OrtLastErrDart = ffi.Pointer<ffi.Uint8> Function();

typedef _OrtInitClfC = ffi.Int32 Function(
  ffi.Pointer<ffi.Uint8>,
  ffi.Int32,
);
typedef _OrtInitClfDart = int Function(
  ffi.Pointer<ffi.Uint8>,
  int,
);

typedef _OrtRunClfC = ffi.Int32 Function(
  ffi.Pointer<ffi.Int64>,
  ffi.Pointer<ffi.Int64>,
  ffi.Int32,
  ffi.Int32,
  ffi.Pointer<ffi.Pointer<ffi.Float>>,
  ffi.Pointer<ffi.Int64>,
  ffi.Pointer<ffi.Pointer<ffi.Float>>,
  ffi.Pointer<ffi.Int64>,
);
typedef _OrtRunClfDart = int Function(
  ffi.Pointer<ffi.Int64>,
  ffi.Pointer<ffi.Int64>,
  int,
  int,
  ffi.Pointer<ffi.Pointer<ffi.Float>>,
  ffi.Pointer<ffi.Int64>,
  ffi.Pointer<ffi.Pointer<ffi.Float>>,
  ffi.Pointer<ffi.Int64>,
);

class OnnxReceiptClassifier {
  OnnxReceiptClassifier._();
  static final OnnxReceiptClassifier instance = OnnxReceiptClassifier._();

  static const _channel = MethodChannel('pocket_receipt/ocr');
  static const _modelAsset = 'assets/ocr/receipt_clf.onnx';
  static const _vocabAsset = 'assets/ocr/receipt_clf_vocab.txt';

  static final _punctSymRe = RegExp(r'[\p{P}\p{S}]', unicode: true);

  bool _initialized = false;
  bool _available = false;
  String? _modelPath;
  Map<String, int>? _vocab;
  int _padId = 0;
  int _unkId = 1;
  int _clsId = 2;
  int _sepId = 3;

  Future<bool> _ensureLoaded() async {
    if (_initialized) return _available;
    _initialized = true;

    if (kIsWeb || (!Platform.isWindows && !Platform.isAndroid)) {
      _available = false;
      return false;
    }

    try {
      final vocabStr = await rootBundle.loadString(_vocabAsset);
      final map = <String, int>{};
      int idx = 0;
      for (final line in const LineSplitter().convert(vocabStr)) {
        map[line] = idx++;
      }
      _vocab = map;
      _padId = map['[PAD]'] ?? 0;
      _unkId = map['[UNK]'] ?? 1;
      _clsId = map['[CLS]'] ?? 2;
      _sepId = map['[SEP]'] ?? 3;

      if (Platform.isWindows) {
        final supportDir = await getApplicationSupportDirectory();
        final dir = Directory(p.join(supportDir.path, 'neural_ocr'));
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        final dest = File(p.join(dir.path, 'receipt_clf.onnx'));
        if (!await dest.exists() || await dest.length() == 0) {
          final data = await rootBundle.load(_modelAsset);
          final bytes = data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
          await dest.writeAsBytes(bytes, flush: true);
        }
        _modelPath = dest.path;
      }

      _available = true;
      return true;
    } catch (_) {
      _available = false;
      return false;
    }
  }

  /// Классифицирует все непустые строки чека батчем.
  /// Возвращает null, если модель недоступна на текущей платформе.
  Future<List<ClassifiedReceiptLine>?> classifyLines(List<String> lines) async {
    if (lines.isEmpty) return const [];
    if (!await _ensureLoaded()) return null;

    final vocab = _vocab!;
    final encoded = <List<int>>[];
    int maxLen = 0;

    for (int i = 0; i < lines.length; i++) {
      final prev = i > 0 ? lines[i - 1] : '';
      final next = i + 1 < lines.length ? lines[i + 1] : '';
      final seq = _encodeWindow(prev, lines[i], next, vocab);
      encoded.add(seq);
      if (seq.length > maxLen) maxLen = seq.length;
    }

    final batchSize = lines.length;
    final flatIds = Int64List(batchSize * maxLen);
    final flatMask = Int64List(batchSize * maxLen);

    for (int i = 0; i < batchSize; i++) {
      final seq = encoded[i];
      final rowOff = i * maxLen;
      for (int j = 0; j < maxLen; j++) {
        if (j < seq.length) {
          flatIds[rowOff + j] = seq[j];
          flatMask[rowOff + j] = 1;
        } else {
          flatIds[rowOff + j] = _padId;
          flatMask[rowOff + j] = 0;
        }
      }
    }

    Float32List roleLogits;
    Float32List catLogits;

    try {
      if (Platform.isWindows) {
        final modelPath = _modelPath!;
        final out = await Isolate.run(
          () => _runWindowsClfInIsolate(
            modelPath: modelPath,
            inputIds: flatIds,
            attentionMask: flatMask,
            batchSize: batchSize,
            seqLen: maxLen,
          ),
        );
        roleLogits = out.roleLogits;
        catLogits = out.catLogits;
      } else if (Platform.isAndroid) {
        final raw = await _channel.invokeMapMethod<String, dynamic>(
          'classifyReceiptLines',
          {
            'inputIds': flatIds,
            'attentionMask': flatMask,
            'batchSize': batchSize,
            'seqLen': maxLen,
          },
        );
        if (raw == null) return null;
        final rList = raw['roleLogits'];
        final cList = raw['catLogits'];
        roleLogits = rList is Float32List
            ? rList
            : Float32List.fromList(
                (rList as List).map((e) => (e as num).toDouble()).toList(),
              );
        catLogits = cList is Float32List
            ? cList
            : Float32List.fromList(
                (cList as List).map((e) => (e as num).toDouble()).toList(),
              );
      } else {
        return null;
      }
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }

    final numRoles = ReceiptLineRole.values.length;
    final numCats = defaultProductGroups.length;
    if (roleLogits.length < batchSize * numRoles ||
        catLogits.length < batchSize * numCats) {
      return null;
    }

    final results = <ClassifiedReceiptLine>[];
    for (int i = 0; i < batchSize; i++) {
      final rRes = _softmaxArgmax(roleLogits, i * numRoles, numRoles);
      final cRes = _softmaxArgmax(catLogits, i * numCats, numCats);

      results.add(
        ClassifiedReceiptLine(
          text: lines[i],
          role: ReceiptLineRole.values[rRes.index],
          roleConfidence: rRes.prob,
          category: defaultProductGroups[cRes.index],
          categoryConfidence: cRes.prob,
        ),
      );
    }
    return results;
  }

  List<int> _encodeWindow(
    String prevLine,
    String currLine,
    String nextLine,
    Map<String, int> vocab,
  ) {
    final pIds = _encodeText(prevLine, 22, vocab);
    final cIds = _encodeText(currLine, 48, vocab);
    final nIds = _encodeText(nextLine, 22, vocab);
    return <int>[
      _clsId,
      ...pIds,
      _sepId,
      ...cIds,
      _sepId,
      ...nIds,
      _sepId,
    ];
  }

  List<int> _encodeText(String text, int maxTokens, Map<String, int> vocab) {
    final ids = <int>[];
    for (final w in _basicTokenize(text)) {
      final sub = _wordpieceTokenizeWord(w, vocab);
      for (final id in sub) {
        ids.add(id);
        if (ids.length >= maxTokens) return ids;
      }
    }
    return ids;
  }

  List<String> _basicTokenize(String text) {
    final tokens = <String>[];
    final buf = StringBuffer();

    for (final cp in text.runes) {
      if (_isWhitespace(cp)) {
        if (buf.isNotEmpty) {
          tokens.add(buf.toString());
          buf.clear();
        }
      } else {
        final ch = String.fromCharCode(cp);
        if (_isPunctOrSymbol(cp, ch)) {
          if (buf.isNotEmpty) {
            tokens.add(buf.toString());
            buf.clear();
          }
          tokens.add(ch);
        } else {
          buf.write(ch);
        }
      }
    }
    if (buf.isNotEmpty) {
      tokens.add(buf.toString());
    }
    return tokens;
  }

  bool _isWhitespace(int cp) {
    return cp == 0 ||
        cp == 0xFFFD ||
        cp == 0x20 ||
        cp == 0x09 ||
        cp == 0x0A ||
        cp == 0x0D ||
        cp == 0x0B ||
        cp == 0x0C ||
        cp == 0xA0;
  }

  bool _isPunctOrSymbol(int cp, String ch) {
    if ((cp >= 33 && cp <= 47) ||
        (cp >= 58 && cp <= 64) ||
        (cp >= 91 && cp <= 96) ||
        (cp >= 123 && cp <= 126)) {
      return true;
    }
    return _punctSymRe.hasMatch(ch);
  }

  List<int> _wordpieceTokenizeWord(String word, Map<String, int> vocab) {
    if (word.length > 64) return [_unkId];
    final subIds = <int>[];
    int start = 0;

    while (start < word.length) {
      int end = word.length;
      int? found;
      while (start < end) {
        var substr = word.substring(start, end);
        if (start > 0) substr = '##$substr';
        final id = vocab[substr];
        if (id != null) {
          found = id;
          break;
        }
        end--;
      }
      if (found == null) return [_unkId];
      subIds.add(found);
      start = end;
    }
    return subIds;
  }

  ({int index, double prob}) _softmaxArgmax(
    Float32List logits,
    int offset,
    int count,
  ) {
    int bestIdx = 0;
    double maxVal = logits[offset];
    for (int i = 1; i < count; i++) {
      final v = logits[offset + i];
      if (v > maxVal) {
        maxVal = v;
        bestIdx = i;
      }
    }
    double sumExp = 0.0;
    for (int i = 0; i < count; i++) {
      sumExp += math.exp(logits[offset + i] - maxVal);
    }
    final bestProb = sumExp > 0 ? (1.0 / sumExp) : 1.0;
    return (index: bestIdx, prob: bestProb);
  }
}

({Float32List roleLogits, Float32List catLogits}) _runWindowsClfInIsolate({
  required String modelPath,
  required Int64List inputIds,
  required Int64List attentionMask,
  required int batchSize,
  required int seqLen,
}) {
  final lib = ffi.DynamicLibrary.executable();
  final alloc = lib.lookupFunction<_OrtAllocC, _OrtAllocDart>('ort_alloc');
  final free = lib.lookupFunction<_OrtFreeC, _OrtFreeDart>('ort_free');
  final lastErr = lib.lookupFunction<_OrtLastErrC, _OrtLastErrDart>(
    'ort_get_last_error',
  );
  final initClf = lib.lookupFunction<_OrtInitClfC, _OrtInitClfDart>(
    'ort_init_clf',
  );
  final runClf = lib.lookupFunction<_OrtRunClfC, _OrtRunClfDart>('ort_run_clf');

  String readErr() {
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

  final encodedPath = utf8.encode(modelPath);
  final pPath = alloc(encodedPath.length + 1).cast<ffi.Uint8>();
  try {
    final pathView = pPath.asTypedList(encodedPath.length + 1);
    pathView.setAll(0, encodedPath);
    pathView[encodedPath.length] = 0;

    final initRc = initClf(pPath, 4);
    if (initRc != 0) {
      throw Exception('ONNX clf init error ($initRc): ${readErr()}');
    }
  } finally {
    free(pPath.cast());
  }

  final idsBuf = alloc(inputIds.length * 8).cast<ffi.Int64>();
  final maskBuf = alloc(attentionMask.length * 8).cast<ffi.Int64>();
  final outRolePtr =
      alloc(ffi.sizeOf<ffi.Pointer<ffi.Float>>()).cast<ffi.Pointer<ffi.Float>>();
  final outRoleLenPtr = alloc(8).cast<ffi.Int64>();
  final outCatPtr =
      alloc(ffi.sizeOf<ffi.Pointer<ffi.Float>>()).cast<ffi.Pointer<ffi.Float>>();
  final outCatLenPtr = alloc(8).cast<ffi.Int64>();

  ffi.Pointer<ffi.Float> nativeRole = ffi.nullptr;
  ffi.Pointer<ffi.Float> nativeCat = ffi.nullptr;

  try {
    idsBuf.asTypedList(inputIds.length).setAll(0, inputIds);
    maskBuf.asTypedList(attentionMask.length).setAll(0, attentionMask);
    outRolePtr.value = ffi.nullptr;
    outRoleLenPtr.value = 0;
    outCatPtr.value = ffi.nullptr;
    outCatLenPtr.value = 0;

    final rc = runClf(
      idsBuf,
      maskBuf,
      batchSize,
      seqLen,
      outRolePtr,
      outRoleLenPtr,
      outCatPtr,
      outCatLenPtr,
    );
    if (rc != 0) {
      throw Exception('ONNX clf run error ($rc): ${readErr()}');
    }

    nativeRole = outRolePtr.value;
    nativeCat = outCatPtr.value;
    final roleLen = outRoleLenPtr.value;
    final catLen = outCatLenPtr.value;

    final roleData = roleLen > 0 && nativeRole != ffi.nullptr
        ? Float32List.fromList(nativeRole.asTypedList(roleLen))
        : Float32List(0);
    final catData = catLen > 0 && nativeCat != ffi.nullptr
        ? Float32List.fromList(nativeCat.asTypedList(catLen))
        : Float32List(0);

    return (roleLogits: roleData, catLogits: catData);
  } finally {
    if (nativeRole != ffi.nullptr) free(nativeRole.cast());
    if (nativeCat != ffi.nullptr) free(nativeCat.cast());
    free(idsBuf.cast());
    free(maskBuf.cast());
    free(outRolePtr.cast());
    free(outRoleLenPtr.cast());
    free(outCatPtr.cast());
    free(outCatLenPtr.cast());
  }
}