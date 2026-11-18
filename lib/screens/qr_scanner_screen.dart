import 'dart:math' as math;
import 'dart:ui';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class QrScannerScreen extends StatefulWidget {
  final String title;
  final String hint;

  const QrScannerScreen({
    super.key,
    this.title = 'Сканер QR-кода',
    this.hint = 'Поместите QR-код внутрь рамки',
  });

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  bool _isDetected = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: const Color.fromRGBO(18, 22, 26, 0.9),
        foregroundColor: Colors.white,
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: MobileScanner(
              onDetect: (capture) {
                if (_isDetected) return;
                for (final barcode in capture.barcodes) {
                  final raw = barcode.rawValue;
                  if (raw != null && raw.trim().isNotEmpty) {
                    _isDetected = true;
                    Navigator.pop(context, raw.trim());
                    return;
                  }
                }
              },
            ),
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final minSide =
                    math.min(constraints.maxWidth, constraints.maxHeight);
                final boxSize = math.min(240.0, math.max(130.0, minSide * 0.54));

                return Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: Container(
                          width: boxSize,
                          height: boxSize,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: const Color(0xFF2DD4BF),
                              width: 3,
                            ),
                            borderRadius: BorderRadius.circular(22),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            decoration: BoxDecoration(
                              color: const Color.fromRGBO(255, 255, 255, 0.84),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: Colors.white,
                                width: 1,
                              ),
                            ),
                            child: Text(
                              widget.hint,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF1A2530),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}