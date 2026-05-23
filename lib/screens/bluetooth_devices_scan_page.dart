import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import '../services/android_bluetooth_discovery_service.dart';
import '../services/ios_ble_printer_service.dart';
import '../services/bluetooth_permission_service.dart';

class BluetoothDevicesScanPage extends StatefulWidget {
  const BluetoothDevicesScanPage({super.key});

  @override
  State<BluetoothDevicesScanPage> createState() =>
      _BluetoothDevicesScanPageState();
}

class _BluetoothDevicesScanPageState extends State<BluetoothDevicesScanPage> {
  static const Duration _nearbyScanTimeout = Duration(seconds: 16);
  static const String _defaultPairingPin = '0000';

  final TextEditingController _pairedSearchController =
      TextEditingController();
  final TextEditingController _nearbySearchController =
      TextEditingController();
  final List<BluetoothInfo> _pairedDevices = <BluetoothInfo>[];
  final List<BluetoothInfo> _nearbyDevices = <BluetoothInfo>[];

  bool _isLoading = false;
  bool _isBluetoothOff = false;
  String _pairedSearchQuery = '';
  String _nearbySearchQuery = '';
  String? _pairingMac;
  bool _isReturningToHome = false;

  bool get _isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    _pairedSearchController.addListener(_handlePairedSearchChanged);
    _nearbySearchController.addListener(_handleNearbySearchChanged);
    _refreshDevices();
  }

  @override
  void dispose() {
    _pairedSearchController.removeListener(_handlePairedSearchChanged);
    _nearbySearchController.removeListener(_handleNearbySearchChanged);
    _pairedSearchController.dispose();
    _nearbySearchController.dispose();
    super.dispose();
  }

  Future<bool> _handlePairingCompletionFromSystem(
    String mac, {
    int maxAttempts = 8,
    Duration retryDelay = const Duration(milliseconds: 700),
  }) async {
    final normalizedMac = _normalizeMac(mac);
    if (normalizedMac.isEmpty || _isReturningToHome) {
      return false;
    }

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final isPaired = await _isDevicePairedNow(normalizedMac);
      if (isPaired) {
        _isReturningToHome = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          final navigator = Navigator.of(context);
          if (navigator.canPop()) {
            navigator.pop(normalizedMac);
          }
        });
        return true;
      }

      if (attempt < maxAttempts - 1) {
        await Future<void>.delayed(retryDelay);
      }
    }

    return false;
  }

  Future<bool> _isDevicePairedNow(String normalizedMac) async {
    try {
      final paired = await PrintBluetoothThermal.pairedBluetooths;
      return paired.any(
        (device) => _normalizeMac(device.macAdress) == normalizedMac,
      );
    } catch (_) {
      return false;
    }
  }

  void _handlePairedSearchChanged() {
    final value = _pairedSearchController.text;
    if (value == _pairedSearchQuery) {
      return;
    }
    setState(() => _pairedSearchQuery = value);
  }

  void _handleNearbySearchChanged() {
    final value = _nearbySearchController.text;
    if (value == _nearbySearchQuery) {
      return;
    }
    setState(() => _nearbySearchQuery = value);
  }

  String _normalizeMac(String mac) {
    final normalized = mac.trim().toUpperCase();
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return normalized;
    }
    return normalized.replaceAll('-', ':');
  }

  String _deviceDisplayName(BluetoothInfo device) {
    final name = device.name.trim();
    if (name.isEmpty) {
      return 'جهاز غير معروف';
    }
    return name;
  }

  bool _isNPrinterModelName(String name) {
    final normalized = name.trim().toUpperCase().replaceAll(
      RegExp(r'[\s_-]+'),
      '',
    );
    if (normalized.contains('FK99PLUS')) {
      return false;
    }
    return normalized.contains('NPRINTER') ||
        normalized.contains('FK99') ||
        normalized.contains('B300') ||
        normalized.contains('B380') ||
        normalized.contains('PRINTER001');
  }

  bool _isPrinterDeviceName(String name) {
    final normalized = name.trim().toLowerCase();
    if (normalized.contains('fk99plus')) {
      return false;
    }
    return normalized.contains('printer') ||
        normalized.contains('fk99') ||
        _isNPrinterModelName(name);
  }

  List<BluetoothInfo> _sortedByName(List<BluetoothInfo> devices) {
    final sorted = List<BluetoothInfo>.from(devices);
    sorted.sort((a, b) {
      final nameA = _deviceDisplayName(a).toLowerCase();
      final nameB = _deviceDisplayName(b).toLowerCase();
      final aIsPrinter = _isPrinterDeviceName(nameA);
      final bIsPrinter = _isPrinterDeviceName(nameB);

      if (aIsPrinter != bIsPrinter) {
        return aIsPrinter ? -1 : 1;
      }

      final compareName = nameA.compareTo(nameB);
      if (compareName != 0) {
        return compareName;
      }
      return _normalizeMac(a.macAdress).compareTo(_normalizeMac(b.macAdress));
    });
    return sorted;
  }

  bool _matchesSearch(BluetoothInfo device, String queryText) {
    final query = queryText.trim().toLowerCase();
    if (query.isEmpty) {
      return true;
    }
    final name = _deviceDisplayName(device).toLowerCase();
    final mac = _normalizeMac(device.macAdress).toLowerCase();
    return name.contains(query) || mac.contains(query);
  }

  List<BluetoothInfo> _filterBySearch(
    List<BluetoothInfo> devices,
    String queryText,
  ) {
    return devices.where((device) => _matchesSearch(device, queryText)).toList();
  }

  Future<void> _refreshDevices() async {
    if (_isLoading || !_isSupported) {
      return;
    }

    setState(() {
      _isLoading = true;
      _isBluetoothOff = false;
      _pairedDevices.clear();
      _nearbyDevices.clear();
    });

    try {
      List<BluetoothInfo> pairedDevices = <BluetoothInfo>[];
      List<BluetoothInfo> nearbyDevices = <BluetoothInfo>[];

      if (defaultTargetPlatform == TargetPlatform.iOS) {
        final scanOutcome =
            await IosBlePrinterService.startIosBleScanForPermissionAndPrinters();
        pairedDevices = scanOutcome.printers
            .map(
              (device) =>
                  BluetoothInfo(name: device.name, macAdress: device.id),
            )
            .toList(growable: false);

        if (pairedDevices.isEmpty &&
            !scanOutcome.permissionAfterScan.isGranted &&
            mounted) {
          _showMessage('Bluetooth permission is not granted on iOS.');
        }
      } else {
        final hasPermissions =
            await BluetoothPermissionService.ensureBluetoothPermission();
        if (!hasPermissions) {
          if (mounted) {
            _showMessage('Bluetooth permission is required.');
          }
          return;
        }

        final isBluetoothOn = await PrintBluetoothThermal.bluetoothEnabled;
        if (!isBluetoothOn) {
          if (mounted) {
            setState(() => _isBluetoothOff = true);
          }
          return;
        }

        pairedDevices = await PrintBluetoothThermal.pairedBluetooths;
      }

      final normalizedPaired = _deduplicateDevices(pairedDevices);
      final pairedMacs = normalizedPaired
          .map((device) => _normalizeMac(device.macAdress))
          .toSet();

      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          final discovered = await AndroidBluetoothDiscoveryService.discover(
            timeout: _nearbyScanTimeout,
            includeBonded: false,
          );
          nearbyDevices = _deduplicateDevices(discovered)
              .where(
                (device) =>
                    !pairedMacs.contains(_normalizeMac(device.macAdress)),
              )
              .toList();
        } catch (_) {
          nearbyDevices = <BluetoothInfo>[];
          if (mounted) {
            _showMessage(
              'تعذر قراءة الأجهزة القريبة حالياً. يمكنك اختيار جهاز مقترن أو إعادة التحديث.',
            );
          }
        }
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _pairedDevices
          ..clear()
          ..addAll(_sortedByName(normalizedPaired));
        _nearbyDevices
          ..clear()
          ..addAll(_sortedByName(nearbyDevices));
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  List<BluetoothInfo> _deduplicateDevices(List<BluetoothInfo> devices) {
    final byMac = <String, BluetoothInfo>{};

    for (final device in devices) {
      final mac = _normalizeMac(device.macAdress);
      if (mac.isEmpty) {
        continue;
      }

      final existing = byMac[mac];
      if (existing == null) {
        byMac[mac] = BluetoothInfo(name: device.name.trim(), macAdress: mac);
        continue;
      }

      if (existing.name.trim().isEmpty && device.name.trim().isNotEmpty) {
        byMac[mac] = BluetoothInfo(name: device.name.trim(), macAdress: mac);
      }
    }

    return byMac.values.toList();
  }

  Future<String?> _askPairPin(BluetoothInfo device) async {
    final controller = TextEditingController(text: '0000');
    final pin = await showDialog<String>(
      context: context,
      builder: (context) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: const Text('اقتران جهاز'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_deviceDisplayName(device)),
                const SizedBox(height: 4),
                Text(
                  _normalizeMac(device.macAdress),
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(color: Colors.black54),
                ),
                const SizedBox(height: 12),
                const Text(
                  'أدخل رمز الاقتران (مثال: 0000 أو 1234 حسب الطابعة).',
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'رمز الاقتران PIN',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, controller.text.trim()),
                child: const Text('اقتران'),
              ),
            ],
          ),
        );
      },
    );
    controller.dispose();
    return pin;
  }

  Future<void> _pairNearbyDevice(BluetoothInfo device) async {
    if (!Platform.isAndroid) {
      _showMessage('الاقتران من داخل التطبيق مدعوم حالياً على Android.');
      return;
    }

    final hasPermissions =
        await BluetoothPermissionService.ensureBluetoothPermission();
    if (!hasPermissions) {
      _showMessage('لم يتم منح الصلاحيات اللازمة للاقتران.');
      return;
    }

    final mac = _normalizeMac(device.macAdress);
    if (mac.isEmpty) {
      _showMessage('عنوان MAC غير صالح.');
      return;
    }

    if (!mounted) {
      return;
    }
    setState(() => _pairingMac = mac);

    try {
      _showMessage('جارٍ الاقتران داخل التطبيق باستخدام PIN: 0000');
      var paired = await AndroidBluetoothDiscoveryService.pairDevice(
        macAddress: mac,
        pin: _defaultPairingPin,
      );

      if (!mounted) {
        return;
      }

      if (!paired) {
        final pin = await _askPairPin(device);
        if (pin == null || pin.trim().isEmpty) {
          return;
        }
        paired = await AndroidBluetoothDiscoveryService.pairDevice(
          macAddress: mac,
          pin: pin,
        );
      }

      if (!mounted) {
        return;
      }
      if (paired) {
        _showMessage('تم الاقتران بنجاح. سيتم اختيار الجهاز.');
        await _handlePairingCompletionFromSystem(mac);
      } else {
        await _handlePairingCompletionFromSystem(mac);
        if (!mounted || _isReturningToHome) {
          return;
        }
        _showMessage(
          'تعذر الاقتران. تأكد أن الطابعة في وضع الاقتران والرمز صحيح.',
        );
      }
    } catch (_) {
      if (mounted) {
        _showMessage('حدث خطأ أثناء الاقتران.');
      }
    } finally {
      if (mounted) {
        setState(() => _pairingMac = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final filteredPaired = _filterBySearch(_pairedDevices, _pairedSearchQuery);
    final filteredNearby = _filterBySearch(_nearbyDevices, _nearbySearchQuery);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('البحث بواسطة بلوتوث'),
          centerTitle: true,
          actions: [
            IconButton(
              tooltip: 'تحديث',
              onPressed: _isLoading ? null : _refreshDevices,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: !_isSupported
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'هذه الشاشة تعمل على Android و iOS فقط.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : _isBluetoothOff
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'يرجى تشغيل البلوتوث ثم إعادة المحاولة.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                  ),
                ),
              )
            : Column(
                children: [
                  if (_isLoading) const LinearProgressIndicator(minHeight: 2),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
                    child: Row(
                      children: const [
                        Icon(Icons.info_outline_rounded, size: 18),
                        SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'اضغط على جهاز مقترن لاختياره مباشرة. واضغط على جهاز قريب للاقتران تلقائياً برمز PIN: 0000.',
                            style: TextStyle(fontSize: 12.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
                      children: [
                        _buildSection(
                          title: 'الأجهزة القريبة المتاحة الآن',
                          emptyText:
                              'لا توجد أجهزة قريبة حالياً. تأكد أن الطابعة في وضع الاقتران ثم اضغط تحديث.',
                          devices: filteredNearby,
                          onTap: _pairNearbyDevice,
                          showPairingState: true,
                          searchController: _nearbySearchController,
                          searchQuery: _nearbySearchQuery,
                          searchHintText: 'ابحث بالاسم أو MAC',
                        ),
                        const SizedBox(height: 12),
                        _buildSection(
                          title: 'الأجهزة المقترنة سابقا',
                          emptyText: 'لا توجد أجهزة مقترنة حالياً.',
                          devices: filteredPaired,
                          onTap: (device) async {
                            Navigator.pop(
                              context,
                              _normalizeMac(device.macAdress),
                            );
                          },
                          showPairingState: false,
                          searchController: _pairedSearchController,
                          searchQuery: _pairedSearchQuery,
                          searchHintText: 'ابحث بالاسم أو MAC',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required String emptyText,
    required List<BluetoothInfo> devices,
    required Future<void> Function(BluetoothInfo) onTap,
    required bool showPairingState,
    required TextEditingController searchController,
    required String searchQuery,
    required String searchHintText,
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black12),
        color: Colors.white.withValues(alpha: 0.68),
      ),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(12),
              ),
              color: const Color(0xffEAF5FF),
              border: const Border(bottom: BorderSide(color: Colors.black12)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '$title (${devices.length})',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 165,
                  height: 34,
                  child: TextField(
                    controller: searchController,
                    textAlignVertical: TextAlignVertical.center,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: searchHintText,
                      prefixIcon: const Icon(Icons.search_rounded, size: 18),
                      suffixIcon: searchQuery.trim().isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'مسح البحث',
                              icon: const Icon(Icons.close_rounded, size: 16),
                              onPressed: searchController.clear,
                            ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 7,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          if (devices.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                emptyText,
                style: const TextStyle(color: Colors.black54),
              ),
            )
          else
            ...List<Widget>.generate(devices.length, (index) {
              final device = devices[index];
              final deviceName = _deviceDisplayName(device);
              final mac = _normalizeMac(device.macAdress);
              final isPairing = showPairingState && _pairingMac == mac;
              final isPrinter = _isPrinterDeviceName(deviceName);
              final showNPrinterLogo =
                  isPrinter || _isNPrinterModelName(deviceName);
              return Column(
                children: [
                  ListTile(
                    leading: showNPrinterLogo
                        ? _buildNPrinterLogo()
                        : Icon(
                            showPairingState
                                ? Icons.bluetooth_searching_rounded
                                : Icons.bluetooth_connected_rounded,
                          ),
                    title: Text(deviceName),
                    subtitle: Text(mac, textDirection: TextDirection.ltr),
                    trailing: isPairing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : isPrinter
                        ? const Icon(
                            Icons.print_rounded,
                            color: Colors.blueGrey,
                          )
                        : Icon(
                            showPairingState
                                ? Icons.link_rounded
                                : Icons.check_circle_rounded,
                            color: showPairingState
                                ? const Color(0xff2D6EA8)
                                : Colors.green.shade700,
                          ),
                    onTap: isPairing ? null : () => onTap(device),
                  ),
                  if (index < devices.length - 1)
                    const Divider(height: 1, thickness: 0.8),
                ],
              );
            }),
        ],
      ),
    );
  }

  Widget _buildNPrinterLogo() {
    return SizedBox(
      width: 72,
      child: Image.asset(
        'assets/images/logo2.png',
        height: 20,
        fit: BoxFit.contain,
        alignment: Alignment.centerRight,
        errorBuilder: (_, _, _) => const Text(
          'nPrinter',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Colors.blueGrey,
          ),
        ),
      ),
    );
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}

