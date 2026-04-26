import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
  static const Duration _quickScanTimeout = Duration(seconds: 6);
  static const List<Duration> _forceScanTimeouts = <Duration>[
    Duration(seconds: 6),
    Duration(seconds: 8),
  ];

  final List<BluetoothInfo> _devices = <BluetoothInfo>[];
  final TextEditingController _searchController = TextEditingController();
  bool _isLoading = false;
  String _searchQuery = '';

  bool get _isSupported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  String _deviceDisplayName(BluetoothInfo device) {
    final trimmedName = device.name.trim();
    return trimmedName.isEmpty ? 'Unknown' : trimmedName;
  }

  bool _isPrinterDeviceName(String name) {
    final normalized = name.trim().toLowerCase();
    return normalized.contains('printer') || _isNPrinterModelName(name);
  }

  bool _isNPrinterModelName(String name) {
    final normalized = name.trim().toUpperCase().replaceAll(
      RegExp(r'[\s_-]+'),
      '',
    );
    return normalized.contains('B300') ||
        normalized.contains('B380') ||
        normalized.contains('PRINTER001');
  }

  String _normalizeMac(String mac) {
    return mac.trim().replaceAll('-', ':').toUpperCase();
  }

  bool _matchesSearch(BluetoothInfo device) {
    if (_searchQuery.trim().isEmpty) {
      return true;
    }
    final query = _searchQuery.trim().toLowerCase();
    final name = _deviceDisplayName(device).toLowerCase();
    final mac = _normalizeMac(device.macAdress).toLowerCase();
    return name.contains(query) || mac.contains(query);
  }

  List<BluetoothInfo> get _filteredDevices {
    return _devices.where(_matchesSearch).toList();
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      final value = _searchController.text;
      if (_searchQuery == value) {
        return;
      }
      setState(() => _searchQuery = value);
    });
    _loadDevices();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<bool> _ensurePermissions() async {
    if (Platform.isAndroid) {
      final btConnect = await Permission.bluetoothConnect.request();
      final btScan = await Permission.bluetoothScan.request();
      await Permission.locationWhenInUse.request();
      return btConnect.isGranted && btScan.isGranted;
    }

    if (Platform.isIOS) {
      final bluetooth = await Permission.bluetooth.request();
      return bluetooth.isGranted || bluetooth.isLimited;
    }

    return true;
  }

  List<BluetoothInfo> _mergeDevices(
    List<BluetoothInfo> first,
    List<BluetoothInfo> second,
  ) {
    final byMac = <String, BluetoothInfo>{};

    void addAll(List<BluetoothInfo> source) {
      for (final device in source) {
        final mac = device.macAdress.trim();
        if (mac.isEmpty) {
          continue;
        }
        final normalizedMac = _normalizeMac(mac);

        final existing = byMac[normalizedMac];
        if (existing == null) {
          byMac[normalizedMac] = BluetoothInfo(
            name: device.name,
            macAdress: normalizedMac,
          );
          continue;
        }

        if (existing.name.trim().isEmpty && device.name.trim().isNotEmpty) {
          byMac[normalizedMac] = BluetoothInfo(
            name: device.name,
            macAdress: normalizedMac,
          );
        }
      }
    }

    addAll(first);
    addAll(second);

    final merged = byMac.values.toList();
    merged.sort((a, b) {
      final aName = _deviceDisplayName(a);
      final bName = _deviceDisplayName(b);
      final aIsPrinter = _isPrinterDeviceName(aName);
      final bIsPrinter = _isPrinterDeviceName(bName);

      if (aIsPrinter != bIsPrinter) {
        return aIsPrinter ? -1 : 1;
      }

      final nameCompare = aName.toLowerCase().compareTo(bName.toLowerCase());
      if (nameCompare != 0) {
        return nameCompare;
      }

      return a.macAdress.compareTo(b.macAdress);
    });
    return merged;
  }

  Future<List<BluetoothInfo>> _discoverNearbyWithRetry() async {
    return AndroidBluetoothDiscoveryService.discover(
      timeout: _quickScanTimeout,
    );
  }

  Future<List<BluetoothInfo>> _discoverNearbyForced() async {
    final byMac = <String, BluetoothInfo>{};
    for (var i = 0; i < _forceScanTimeouts.length; i++) {
      final timeout = _forceScanTimeouts[i];
      final discovered = await AndroidBluetoothDiscoveryService.discover(
        timeout: timeout,
      );
      for (final device in discovered) {
        final mac = _normalizeMac(device.macAdress);
        if (mac.isEmpty) {
          continue;
        }
        final existing = byMac[mac];
        if (existing == null || existing.name.trim().isEmpty) {
          byMac[mac] = BluetoothInfo(name: device.name, macAdress: mac);
        }
      }
      if (byMac.isNotEmpty) {
        break;
      }

      if (i < _forceScanTimeouts.length - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }

    return byMac.values.toList();
  }

  Future<void> _loadDevices({bool forceSearch = false}) async {
    if (_isLoading) {
      return;
    }
    if (!_isSupported) {
      if (mounted) {
        _showMessage('هذه الصفحة تعمل على Android و iOS فقط');
      }
      return;
    }

    setState(() {
      _devices.clear();
      _isLoading = true;
    });

    try {
      final hasPermission = await _ensurePermissions();
      if (!hasPermission) {
        _showMessage('يرجى منح صلاحيات البلوتوث والموقع للبحث');
        setState(() => _isLoading = false);
        return;
      }

      final isBluetoothOn = await PrintBluetoothThermal.bluetoothEnabled;
      if (!isBluetoothOn) {
        _showMessage('يرجى تشغيل البلوتوث');
        setState(() => _isLoading = false);
        return;
      }

      final pairedDevices = await PrintBluetoothThermal.pairedBluetooths;
      var finalDevices = pairedDevices;

      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          final nearbyDevices = forceSearch
              ? await _discoverNearbyForced()
              : await _discoverNearbyWithRetry();
          finalDevices = _mergeDevices(pairedDevices, nearbyDevices);
        } catch (_) {
          finalDevices = _mergeDevices(pairedDevices, const <BluetoothInfo>[]);
          _showMessage(
            'تم عرض الأجهزة المحفوظة فقط. فعّل وضع الاقتران في الطابعة ثم حدّث.',
          );
        }
      } else {
        finalDevices = _mergeDevices(pairedDevices, const <BluetoothInfo>[]);
      }

      if (!mounted) return;
      setState(() {
        _devices
          ..clear()
          ..addAll(finalDevices);
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showMessage('تعذر جلب أجهزة البلوتوث');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('اختيار جهاز البلوتوث'),
        centerTitle: true,
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _loadDevices(forceSearch: true),
        child: const Icon(Icons.refresh),
      ),
    );
  }

  Widget _buildBody() {
    if (!_isSupported) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'البحث عن الأجهزة متاح على Android و iOS فقط.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('جارٍ تحميل الأجهزة وحصر الأجهزة القريبة...'),
          ],
        ),
      );
    }

    if (_devices.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'لا توجد أجهزة.\nضع الطابعة على وضع الاقتران ثم اضغط تحديث.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final visibleDevices = _filteredDevices;

    return Column(
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
                      onPressed: () {
                        _searchController.clear();
                      },
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        if (visibleDevices.isEmpty)
          const Expanded(
            child: Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  'لا توجد نتيجة مطابقة للبحث.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              itemCount: visibleDevices.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, index) {
                final device = visibleDevices[index];
                final deviceName = _deviceDisplayName(device);
                final isPrinter = _isPrinterDeviceName(deviceName);
                final isNPrinterModel = _isNPrinterModelName(deviceName);

                return ListTile(
                  leading: Icon(
                    isPrinter ? Icons.print_rounded : Icons.bluetooth_rounded,
                    color: isPrinter ? Colors.blueGrey : null,
                  ),
                  title: Row(
                    children: [
                      Expanded(child: Text(deviceName)),
                      if (isNPrinterModel) ...[
                        const SizedBox(width: 8),
                        Image.asset(
                          'assets/images/logo2.png',
                          height: 16,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const Text(
                            'nPrinter',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.blueGrey,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    _normalizeMac(device.macAdress),
                    textDirection: TextDirection.ltr,
                  ),
                  onTap: () =>
                      Navigator.pop(context, _normalizeMac(device.macAdress)),
                );
              },
            ),
          ),
      ],
    );
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}
