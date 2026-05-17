import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class IosBleDiscoveredPrinter {
  const IosBleDiscoveredPrinter({
    required this.id,
    required this.name,
    required this.advertisedServiceUuids,
  });

  final String id;
  final String name;
  final List<String> advertisedServiceUuids;
}

class IosBleScanOutcome {
  const IosBleScanOutcome({
    required this.printers,
    required this.permissionBefore,
    required this.permissionAfterRequest,
    required this.permissionAfterScan,
  });

  final List<IosBleDiscoveredPrinter> printers;
  final PermissionStatus permissionBefore;
  final PermissionStatus permissionAfterRequest;
  final PermissionStatus permissionAfterScan;
}

class IosBlePrinterService {
  IosBlePrinterService._();

  static const String _targetAdvertisedServiceUuid =
      'E7810A71-73AE-499D-8C15-FAA9AEF0C3F2';
  static const String _primaryServiceUuid = 'FFF0';
  static const String _primaryCharacteristicUuid = 'FFF2';
  static const String _secondaryServiceUuid = '18F0';
  static const String _secondaryCharacteristicUuid = '2AF1';
  static const MethodChannel _iosBluetoothPermissionWarmupChannel =
      MethodChannel('ios_bluetooth_permission_warmup');
  static const int _defaultChunkSize = 180;
  static const Duration _defaultChunkDelay = Duration(milliseconds: 20);

  static final Map<String, BluetoothDevice> _knownDevicesById =
      <String, BluetoothDevice>{};

  static BluetoothDevice? _connectedDevice;
  static String? _connectedDeviceId;
  static BluetoothCharacteristic? _writeCharacteristic;

  static bool get _isIos => !kIsWeb && Platform.isIOS;

  static String _normalizeUuid(String value) {
    return value.trim().toUpperCase();
  }

  static bool _uuidMatches(String actual, String expected) {
    final normalizedActual = _normalizeUuid(actual);
    final normalizedExpected = _normalizeUuid(expected);
    if (normalizedActual == normalizedExpected) {
      return true;
    }
    if (normalizedExpected.length == 4 &&
        normalizedActual.startsWith('0000$normalizedExpected-')) {
      return true;
    }
    return false;
  }

  static String _deviceId(BluetoothDevice device) {
    return device.remoteId.toString().trim().toUpperCase();
  }

  static String _bestDeviceName(ScanResult result) {
    final platformName = result.device.platformName.trim();
    if (platformName.isNotEmpty) {
      return platformName;
    }

    final advName = result.advertisementData.advName.trim();
    if (advName.isNotEmpty) {
      return advName;
    }

    return 'Unknown BLE Device';
  }

  static bool _looksLikeTargetPrinter({
    required String name,
    required Iterable<String> advertisedServiceUuids,
  }) {
    final upperName = name.trim().toUpperCase();
    final byName = upperName.contains('B380');
    final byService = advertisedServiceUuids.any(
      (uuid) => _uuidMatches(uuid, _targetAdvertisedServiceUuid),
    );
    return byName || byService;
  }

  static Future<void> _warmUpNativeCoreBluetooth() async {
    try {
      await _iosBluetoothPermissionWarmupChannel.invokeMethod<void>(
        'warmUpBluetoothPermission',
      );
    } catch (_) {
      // Best effort warm-up.
    }
  }

  static Future<IosBleScanOutcome> startIosBleScanForPermissionAndPrinters() async {
    if (!_isIos) {
      return const IosBleScanOutcome(
        printers: <IosBleDiscoveredPrinter>[],
        permissionBefore: PermissionStatus.granted,
        permissionAfterRequest: PermissionStatus.granted,
        permissionAfterScan: PermissionStatus.granted,
      );
    }

    debugPrint('[iOS BLE] refresh pressed');
    final permissionBefore = await Permission.bluetooth.status;
    debugPrint('[iOS BLE] permission before = $permissionBefore');

    final permissionAfterRequest = await Permission.bluetooth.request();
    debugPrint('[iOS BLE] permission after request = $permissionAfterRequest');

    if (permissionAfterRequest.isPermanentlyDenied ||
        permissionAfterRequest.isRestricted) {
      await openAppSettings();
      return IosBleScanOutcome(
        printers: const <IosBleDiscoveredPrinter>[],
        permissionBefore: permissionBefore,
        permissionAfterRequest: permissionAfterRequest,
        permissionAfterScan: permissionAfterRequest,
      );
    }

    await _warmUpNativeCoreBluetooth();
    final printers = await scanForPrinters(timeout: const Duration(seconds: 8));
    final permissionAfterScan = await Permission.bluetooth.status;
    debugPrint('[iOS BLE] permission after scan = $permissionAfterScan');

    if (permissionAfterScan.isPermanentlyDenied ||
        permissionAfterScan.isRestricted) {
      await openAppSettings();
    }

    return IosBleScanOutcome(
      printers: printers,
      permissionBefore: permissionBefore,
      permissionAfterRequest: permissionAfterRequest,
      permissionAfterScan: permissionAfterScan,
    );
  }

  static Future<List<IosBleDiscoveredPrinter>> scanForPrinters({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!_isIos) {
      return const <IosBleDiscoveredPrinter>[];
    }

    final discoveredById = <String, IosBleDiscoveredPrinter>{};
    StreamSubscription<List<ScanResult>>? subscription;

    try {
      debugPrint('[iOS BLE] starting scan');
      subscription = FlutterBluePlus.scanResults.listen(
        (results) {
          for (final result in results) {
            final id = _deviceId(result.device);
            final name = _bestDeviceName(result);
            final serviceUuids = result.advertisementData.serviceUuids
                .map((uuid) => _normalizeUuid(uuid.toString()))
                .toList(growable: false);
            final isTarget = _looksLikeTargetPrinter(
              name: name,
              advertisedServiceUuids: serviceUuids,
            );

            debugPrint(
              '[iOS BLE] found device name=$name remoteId=$id '
              'serviceUuids=$serviceUuids rssi=${result.rssi} '
              'isTarget=$isTarget',
            );

            _knownDevicesById[id] = result.device;
            discoveredById[id] = IosBleDiscoveredPrinter(
              id: id,
              name: name,
              advertisedServiceUuids: serviceUuids,
            );
          }
        },
        onError: (Object e, StackTrace st) {
          debugPrint('[iOS BLE] scan error: $e');
          debugPrint(st.toString());
        },
      );

      await FlutterBluePlus.startScan(timeout: timeout);
      await Future<void>.delayed(timeout + const Duration(milliseconds: 200));
    } catch (e, stackTrace) {
      debugPrint('[iOS BLE] scan exception: $e');
      debugPrint(stackTrace.toString());
    } finally {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      await subscription?.cancel();
      debugPrint('[iOS BLE] scan finished');
      debugPrint('[iOS BLE] scan result count = ${discoveredById.length}');
    }

    final printers = discoveredById.values.toList(growable: false);
    printers.sort((a, b) {
      final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (byName != 0) {
        return byName;
      }
      return a.id.compareTo(b.id);
    });
    return printers;
  }

  static Future<void> disconnect() async {
    if (!_isIos) {
      return;
    }

    final device = _connectedDevice;
    _connectedDevice = null;
    _connectedDeviceId = null;
    _writeCharacteristic = null;

    if (device == null) {
      return;
    }

    try {
      await device.disconnect();
    } catch (_) {
      // Best effort disconnect.
    }
  }

  static Future<bool> connectAndPrepareWriter(String deviceId) async {
    if (!_isIos) {
      return false;
    }

    final normalizedId = deviceId.trim().toUpperCase();
    if (normalizedId.isEmpty) {
      debugPrint('[iOS BLE] connecting failed: empty remoteId');
      return false;
    }

    if (_connectedDeviceId == normalizedId && _writeCharacteristic != null) {
      return true;
    }

    BluetoothDevice? device = _knownDevicesById[normalizedId];
    if (device == null) {
      final discovered = await scanForPrinters(timeout: const Duration(seconds: 3));
      final matched = discovered.firstWhere(
        (printer) => printer.id == normalizedId,
        orElse: () => const IosBleDiscoveredPrinter(
          id: '',
          name: '',
          advertisedServiceUuids: <String>[],
        ),
      );
      if (matched.id.isNotEmpty) {
        device = _knownDevicesById[matched.id];
      }
    }

    if (device == null) {
      debugPrint('[iOS BLE] connecting failed: device not found remoteId=$normalizedId');
      return false;
    }

    await disconnect();

    try {
      debugPrint('[iOS BLE] connecting remoteId=$normalizedId');
      await device.connect(timeout: const Duration(seconds: 10));
    } catch (e) {
      final text = e.toString().toLowerCase();
      if (!text.contains('already connected')) {
        debugPrint('[iOS BLE] connecting exception remoteId=$normalizedId error=$e');
      }
    }

    List<BluetoothService> services = const <BluetoothService>[];
    try {
      services = await device.discoverServices();
    } catch (e, stackTrace) {
      debugPrint('[iOS BLE] discoverServices failed remoteId=$normalizedId error=$e');
      debugPrint(stackTrace.toString());
      return false;
    }

    for (final service in services) {
      final serviceUuid = _normalizeUuid(service.uuid.toString());
      debugPrint('[iOS BLE] service uuid=$serviceUuid');
      for (final characteristic in service.characteristics) {
        final uuid = _normalizeUuid(characteristic.uuid.toString());
        final p = characteristic.properties;
        debugPrint(
          '[iOS BLE] char service=$serviceUuid uuid=$uuid '
          'write=${p.write} writeWithoutResponse=${p.writeWithoutResponse} '
          'notify=${p.notify}',
        );
      }
    }

    BluetoothCharacteristic? selected = _findPreferredCharacteristic(services);
    selected ??= _findFallbackWritableCharacteristic(services);

    if (selected == null) {
      debugPrint('[iOS BLE] connecting failed: no writable characteristic');
      return false;
    }

    _connectedDevice = device;
    _connectedDeviceId = normalizedId;
    _writeCharacteristic = selected;

    final selectedServiceUuid = _selectedServiceUuid(
      selected: selected,
      services: services,
    );
    final selectedCharUuid = _normalizeUuid(selected.uuid.toString());
    final p = selected.properties;
    debugPrint(
      '[iOS BLE] selected write char service=$selectedServiceUuid '
      'characteristic=$selectedCharUuid write=${p.write} '
      'writeWithoutResponse=${p.writeWithoutResponse}',
    );
    return true;
  }

  static String _selectedServiceUuid({
    required BluetoothCharacteristic selected,
    required List<BluetoothService> services,
  }) {
    for (final service in services) {
      final serviceUuid = _normalizeUuid(service.uuid.toString());
      for (final characteristic in service.characteristics) {
        final sameUuid =
            _normalizeUuid(characteristic.uuid.toString()) ==
            _normalizeUuid(selected.uuid.toString());
        if (sameUuid) {
          return serviceUuid;
        }
      }
    }
    return 'UNKNOWN';
  }

  static BluetoothCharacteristic? _findPreferredCharacteristic(
    List<BluetoothService> services,
  ) {
    for (final service in services) {
      final serviceUuid = _normalizeUuid(service.uuid.toString());
      for (final characteristic in service.characteristics) {
        final charUuid = _normalizeUuid(characteristic.uuid.toString());
        if (_uuidMatches(serviceUuid, _primaryServiceUuid) &&
            _uuidMatches(charUuid, _primaryCharacteristicUuid) &&
            _isWritable(characteristic)) {
          return characteristic;
        }
      }
    }

    for (final service in services) {
      final serviceUuid = _normalizeUuid(service.uuid.toString());
      for (final characteristic in service.characteristics) {
        final charUuid = _normalizeUuid(characteristic.uuid.toString());
        if (_uuidMatches(serviceUuid, _secondaryServiceUuid) &&
            _uuidMatches(charUuid, _secondaryCharacteristicUuid) &&
            _isWritable(characteristic)) {
          return characteristic;
        }
      }
    }
    return null;
  }

  static BluetoothCharacteristic? _findFallbackWritableCharacteristic(
    List<BluetoothService> services,
  ) {
    for (final service in services) {
      for (final characteristic in service.characteristics) {
        if (_isWritable(characteristic)) {
          return characteristic;
        }
      }
    }
    return null;
  }

  static bool _isWritable(BluetoothCharacteristic characteristic) {
    final p = characteristic.properties;
    return p.write || p.writeWithoutResponse;
  }

  static Future<bool> writeEscPosBytes(
    List<int> bytes, {
    String? deviceId,
    int chunkSize = _defaultChunkSize,
    Duration interChunkDelay = _defaultChunkDelay,
  }) async {
    if (!_isIos) {
      return false;
    }

    if (bytes.isEmpty) {
      debugPrint('[iOS BLE] print complete chunks=0 totalBytes=0');
      return true;
    }

    final resolvedId = (deviceId ?? _connectedDeviceId ?? '').trim().toUpperCase();
    if (resolvedId.isEmpty) {
      debugPrint('[iOS BLE] writing failed: missing remoteId');
      return false;
    }

    final ready = await connectAndPrepareWriter(resolvedId);
    if (!ready) {
      debugPrint('[iOS BLE] writing failed: connection not ready');
      return false;
    }

    final characteristic = _writeCharacteristic;
    if (characteristic == null) {
      debugPrint('[iOS BLE] writing failed: write characteristic missing');
      return false;
    }

    final canWriteWithResponse = characteristic.properties.write;
    final canWriteWithoutResponse = characteristic.properties.writeWithoutResponse;
    if (!canWriteWithResponse && !canWriteWithoutResponse) {
      debugPrint('[iOS BLE] writing failed: selected characteristic not writable');
      return false;
    }

    final useWithoutResponse =
        canWriteWithoutResponse && !canWriteWithResponse ? true : canWriteWithoutResponse;
    final safeChunkSize = chunkSize <= 0 ? _defaultChunkSize : chunkSize;
    var chunkCount = 0;

    for (int i = 0; i < bytes.length; i += safeChunkSize) {
      final end = (i + safeChunkSize > bytes.length) ? bytes.length : i + safeChunkSize;
      final chunk = bytes.sublist(i, end);
      debugPrint(
        '[iOS BLE] writing chunk index=$chunkCount '
        'size=${chunk.length} withoutResponse=$useWithoutResponse',
      );
      try {
        await characteristic.write(
          chunk,
          withoutResponse: useWithoutResponse,
        );
      } catch (e, stackTrace) {
        debugPrint(
          '[iOS BLE] writing failed at chunk=$chunkCount length=${chunk.length} error=$e',
        );
        debugPrint(stackTrace.toString());
        return false;
      }
      chunkCount++;
      if (end < bytes.length) {
        await Future<void>.delayed(interChunkDelay);
      }
    }

    debugPrint(
      '[iOS BLE] print complete chunks=$chunkCount totalBytes=${bytes.length} '
      'withoutResponse=$useWithoutResponse',
    );
    return true;
  }
}
