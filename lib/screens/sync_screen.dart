import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/sync_service.dart';
import '../widgets/glass_ui.dart';
import 'qr_scanner_screen.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  final _server = WifiSyncServer();
  final _manualCodeController = TextEditingController();

  List<String> _ips = [];
  String? _selectedIp;
  bool _isServerRunning = false;
  bool _isConnecting = false;
  bool _didSync = false;
  String _statusText =
      'Убедитесь, что телефон и компьютер в одной домашней сети Wi-Fi.';

  bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void initState() {
    super.initState();
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      _startServer();
    }
  }

  @override
  void dispose() {
    _server.stop();
    _manualCodeController.dispose();
    super.dispose();
  }

  Future<void> _startServer() async {
    setState(() {
      _statusText = 'Запускаем локальный сервер Wi-Fi...';
    });

    try {
      final ips = await getLocalLanIps();
      await _server.start(
        onReceivedFromClient: (addedCount) {
          if (!mounted) return;
          setState(() {
            _didSync = true;
            _statusText =
                'Синхронизация завершена! Получено новых чеков: $addedCount';
          });
        },
      );

      if (!mounted) return;
      setState(() {
        _ips = ips;
        _selectedIp = ips.isNotEmpty ? ips.first : null;
        _isServerRunning = true;
        _statusText = ips.isEmpty
            ? 'Не найден локальный Wi-Fi IP-адрес'
            : 'Откройте это же окно на втором устройстве и отсканируйте QR';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = 'Ошибка запуска сервера: $e';
      });
    }
  }

  Future<void> _scanAndSync() async {
    final scanned = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (context) => const QrScannerScreen(
          title: 'QR синхронизации',
          hint: 'Наведите камеру на QR-код с экрана компьютера',
        ),
      ),
    );
    if (scanned == null || !mounted) return;
    await _connectWithCode(scanned);
  }

  Future<void> _connectWithCode(String rawCode) async {
    final info = SyncPayloadInfo.parse(rawCode);
    if (info == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Неверный формат QR-кода синхронизации')),
      );
      return;
    }

    setState(() {
      _isConnecting = true;
      _statusText = 'Подключаемся к ${info.host}:${info.port}...';
    });

    try {
      final summary = await WifiSyncClient.syncWithServer(info);
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _didSync = true;
        _statusText =
            'Готово! Получено чеков: ${summary.receivedCount}, отправлено с фото: ${summary.sentCount}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _statusText =
            'Не удалось подключиться ($e).\nПроверьте, что устройства в одном Wi-Fi и брандмауэр Windows не блокирует порт.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentPayload = (_isServerRunning && _selectedIp != null)
        ? SyncPayloadInfo(
            host: _selectedIp!,
            port: _server.port,
            token: _server.token,
          )
        : null;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          Navigator.pop(context, _didSync);
        }
      },
      child: GlassBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('Синхронизация по Wi-Fi'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.pop(context, _didSync),
            ),
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    GlassCard(
                      padding: const EdgeInsets.all(16),
                      tintColor: GlassColors.heroTint,
                      child: Row(
                        children: [
                          const Icon(
                            Icons.wifi,
                            color: GlassColors.accentLuminous,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _statusText,
                              style: const TextStyle(
                                fontSize: 13,
                                color: GlassColors.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_isMobile) ...[
                      SizedBox(
                        height: 52,
                        child: FilledButton.icon(
                          onPressed: _isConnecting ? null : _scanAndSync,
                          icon: const Icon(Icons.qr_code_scanner),
                          label: const Text('Сканировать QR с компьютера'),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (!_isServerRunning)
                      OutlinedButton.icon(
                        onPressed: _startServer,
                        icon: const Icon(Icons.qr_code_2),
                        label: const Text('Показать свой QR-код для приема'),
                      ),
                    if (currentPayload != null)
                      GlassCard(
                        padding: const EdgeInsets.all(22),
                        child: Column(
                          children: [
                            const Text(
                              'Наведите камеру второго устройства на этот QR:',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                                color: GlassColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: QrImageView(
                                data: currentPayload.toQrString(),
                                version: QrVersions.auto,
                                size: 210,
                                backgroundColor: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 14),
                            if (_ips.length > 1) ...[
                              const Text(
                                'Если не подключается — выберите другой сетевой IP:',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: GlassColors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                children: _ips.map((ip) {
                                  return GlassPillChip(
                                    label: ip,
                                    compact: true,
                                    selected: _selectedIp == ip,
                                    onTap: () {
                                      setState(() => _selectedIp = ip);
                                    },
                                  );
                                }).toList(),
                              ),
                              const SizedBox(height: 10),
                            ],
                            SelectableText(
                              currentPayload.toQrString(),
                              style: const TextStyle(
                                fontSize: 12,
                                color: GlassColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 20),
                    GlassCard(
                      padding: const EdgeInsets.all(16),
                      useBlur: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Или введите код подключения вручную:',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: GlassColors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _manualCodeController,
                                  style: const TextStyle(
                                    color: GlassColors.textPrimary,
                                  ),
                                  decoration: const InputDecoration(
                                    hintText: 'pocket_sync://192.168.x.x:...',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilledButton.tonal(
                                onPressed: _isConnecting
                                    ? null
                                    : () => _connectWithCode(
                                          _manualCodeController.text,
                                        ),
                                child: const Text('Синхр.'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (_isConnecting) ...[
                      const SizedBox(height: 16),
                      const Center(child: CircularProgressIndicator()),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}