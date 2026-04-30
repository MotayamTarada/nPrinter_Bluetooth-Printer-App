import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

import '../services/android_bluetooth_discovery_service.dart';

class BluetoothDevicesScanPage extends StatefulWidget {
  const BluetoothDevicesScanPage({super.key});

  @override
  State<BluetoothDevicesScanPage> createState() =>
      _BluetoothDevicesScanPageState();
}

class _BluetoothDevicesScanPageState extends State<BluetoothDevicesScanPage> {
  static const Duration _nearbyScanTimeout = Duration(seconds: 16);
  static const String _defaultPairingPin = '0000';

  final TextEditingController _searchController = TextEditingController();
  final List<BluetoothInfo> _pairedDevices = <BluetoothInfo>[];
  final List<BluetoothInfo> _nearbyDevices = <BluetoothInfo>[];

  bool _isLoading = false;
  String _searchQuery = '';
  String? _pairingMac;

  bool get _isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_handleSearchChanged);
    _refreshDevices();
  }

  @override
  void dispose() {
    _searchController.removeListener(_handleSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _handleSearchChanged() {
    final value = _searchController.text;
    if (value == _searchQuery) {
      return;
    }
    setState(() => _searchQuery = value);
  }

  String _normalizeMac(String mac) {
    return mac.trim().replaceAll('-', ':').toUpperCase();
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

  bool _matchesSearch(BluetoothInfo device) {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return true;
    }
    final name = _deviceDisplayName(device).toLowerCase();
    final mac = _normalizeMac(device.macAdress).toLowerCase();
    return name.contains(query) || mac.contains(query);
  }

  List<BluetoothInfo> _filterBySearch(List<BluetoothInfo> devices) {
    return devices.where(_matchesSearch).toList();
  }

  Future<void> _refreshDevices() async {
    if (_isLoading || !_isSupported) {
      return;
    }

    setState(() {
      _isLoading = true;
      _pairedDevices.clear();
      _nearbyDevices.clear();
    });

    try {
      if (Platform.isIOS) {
        final iosAdapterState = await _primeIosBluetoothPrompt();
        if (iosAdapterState == BluetoothAdapterState.unauthorized) {
          if (mounted) {
            _showMessage(
              'تم رفض إذن البلوتوث لهذا التطبيق على iPhone. فعّله من الإعدادات مرة واحدة.',
            );
          }
          return;
        }
      }

      final hasPermissions = await _ensureBluetoothPermissions();
      if (!hasPermissions) {
        if (mounted) {
          _showMessage('لم يتم منح صلاحيات البلوتوث المطلوبة.');
        }
        return;
      }

      final isBluetoothOn = await PrintBluetoothThermal.bluetoothEnabled;
      if (!isBluetoothOn) {
        if (mounted) {
          _showMessage('يرجى تشغيل البلوتوث ثم إعادة المحاولة.');
        }
        return;
      }

      final pairedDevices = await PrintBluetoothThermal.pairedBluetooths;
      final normalizedPaired = _deduplicateDevices(pairedDevices);
      final pairedMacs = normalizedPaired
          .map((device) => _normalizeMac(device.macAdress))
          .toSet();

      List<BluetoothInfo> nearbyDevices = <BluetoothInfo>[];
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

  Future<BluetoothAdapterState?> _primeIosBluetoothPrompt() async {
    if (!Platform.isIOS) {
      return null;
    }

    try {
      final supported = await FlutterBluePlus.isSupported;
      if (!supported) {
        return BluetoothAdapterState.unavailable;
      }

      // On iOS, the first call to FlutterBluePlus initializes CoreBluetooth
      // and should trigger the Bluetooth permission prompt.
      var state = await FlutterBluePlus.adapterState.first.timeout(
        const Duration(seconds: 3),
        onTimeout: () => BluetoothAdapterState.unknown,
      );

      if (state == BluetoothAdapterState.unknown) {
        await Future<void>.delayed(const Duration(milliseconds: 700));
      }

      if (state == BluetoothAdapterState.unknown ||
          state == BluetoothAdapterState.turningOn) {
        try {
          await FlutterBluePlus.startScan(timeout: const Duration(seconds: 1));
        } catch (_) {
          // Ignore. We only need to touch CoreBluetooth to trigger iOS prompt.
        } finally {
          try {
            await FlutterBluePlus.stopScan();
          } catch (_) {}
        }
      }

      state = await FlutterBluePlus.adapterState.first.timeout(
        const Duration(seconds: 2),
        onTimeout: () => state,
      );
      return state;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _ensureBluetoothPermissions() async {
    if (Platform.isIOS) {
      // iOS Bluetooth access is handled by CoreBluetooth when the plugin is
      // used (e.g. bluetoothEnabled / pairedBluetooths). Avoid blocking the
      // flow here via permission_handler because it can report denied when the
      // iOS macro integration is not enabled, even though the runtime prompt
      // can still appear from the Bluetooth API call itself.
      return true;
    }

    if (!Platform.isAndroid) {
      return true;
    }

    final sdkInt = await AndroidBluetoothDiscoveryService.androidSdkInt();
    final isAndroid12OrHigher = sdkInt >= 31 || sdkInt == 0;

    final requiredPerms = isAndroid12OrHigher
        ? [Permission.bluetoothScan, Permission.bluetoothConnect]
        : [Permission.locationWhenInUse];
    final requestPerms = <Permission>[
      ...requiredPerms,
      if (isAndroid12OrHigher) Permission.locationWhenInUse,
    ];

    bool allGranted = true;
    for (final perm in requiredPerms) {
      if (!(await perm.status.isGranted)) {
        allGranted = false;
        break;
      }
    }

    if (allGranted) {
      return true;
    }

    if (mounted) {
      final continueRequest = await _showPermissionRationaleDialog(
        title: 'صلاحيات البلوتوث',
        message:
            'لإظهار الأجهزة القريبة وعمل الاقتران داخل التطبيق، يرجى منح صلاحيات البلوتوث (والموقع إذا لزم الأمر).',
      );
      if (!continueRequest) {
        return false;
      }
    }

    final requested = await requestPerms.request();

    bool grantedNow = true;
    bool permanentlyDenied = false;
    for (final perm in requiredPerms) {
      final status = requested[perm] ?? await perm.status;
      if (!status.isGranted) {
        grantedNow = false;
        if (status.isPermanentlyDenied) {
          permanentlyDenied = true;
        }
      }
    }

    if (grantedNow) {
      return true;
    }

    if (permanentlyDenied && mounted) {
      await _showOpenSettingsDialog(
        title: 'صلاحيات مرفوضة',
        message:
            'تم رفض بعض الصلاحيات نهائياً. يرجى تفعيلها من إعدادات الهاتف ثم العودة للتطبيق.',
      );
    }
    return false;
  }

  Future<bool> _showPermissionRationaleDialog({
    required String title,
    required String message,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('متابعة'),
            ),
          ],
        );
      },
    );

    return result ?? false;
  }

  Future<void> _showOpenSettingsDialog({
    required String title,
    required String message,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('لاحقاً'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(context);
                await openAppSettings();
              },
              child: const Text('فتح الإعدادات'),
            ),
          ],
        );
      },
    );
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

    final hasPermissions = await _ensureBluetoothPermissions();
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
        await _refreshDevices();
        if (mounted) {
          Navigator.pop(context, mac);
        }
      } else {
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
    final filteredPaired = _filterBySearch(_pairedDevices);
    final filteredNearby = _filterBySearch(_nearbyDevices);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('شاشة البلوتوث'),
          centerTitle: true,
          actions: [
            IconButton(
              tooltip: 'تحديث',
              onPressed: _isLoading ? null : _refreshDevices,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        body: _isSupported
            ? Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'ابحث باسم الجهاز أو MAC',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _searchQuery.trim().isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'مسح البحث',
                                icon: const Icon(Icons.close_rounded),
                                onPressed: _searchController.clear,
                              ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
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
                          title: 'الأجهزة المقترنة',
                          emptyText: 'لا توجد أجهزة مقترنة حالياً.',
                          devices: filteredPaired,
                          onTap: (device) async {
                            Navigator.pop(
                              context,
                              _normalizeMac(device.macAdress),
                            );
                          },
                          showPairingState: false,
                        ),
                        const SizedBox(height: 12),
                        _buildSection(
                          title: 'الأجهزة القريبة المتاحة الآن',
                          emptyText:
                              'لا توجد أجهزة قريبة حالياً. تأكد أن الطابعة في وضع الاقتران ثم اضغط تحديث.',
                          devices: filteredNearby,
                          onTap: _pairNearbyDevice,
                          showPairingState: true,
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'هذه الشاشة تعمل على Android و iOS فقط.',
                    textAlign: TextAlign.center,
                  ),
                ),
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
            child: Text(
              '$title (${devices.length})',
              style: const TextStyle(fontWeight: FontWeight.w700),
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
