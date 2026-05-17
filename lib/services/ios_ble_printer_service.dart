import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

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

class IosBlePrinterService {
  IosBlePrinterService._();

  static const String _targetAdvertisedServiceUuid =
      'E7810A71-73AE-499D-8C15-FAA9AEF0C3F2';
  static const String _primaryServiceUuid = 'FFF0';
  static const String _primaryCharacteristicUuid = 'FFF2';
  static const String _secondaryServiceUuid = '18F0';
  static const String _secondaryCharacteristicUuid = '2AF1';
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

  static Future<List<IosBleDiscoveredPrinter>> scanForPrinters({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!_isIos) {
      return const <IosBleDiscoveredPrinter>[];
    }

    final discoveredById = <String, IosBleDiscoveredPrinter>{};
    StreamSubscription<List<ScanResult>>? subscription;

    try {
      debugPrint('iOS BLE scan started timeout=${timeout.inSeconds}s');
      subscription = FlutterBluePlus.scanResults.listen(
        (results) {
          debugPrint('iOS BLE scanResults update count=${results.length}');
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
              'iOS BLE scan device name="$name" id="$id" '
              'services=$serviceUuids rssi=${result.rssi} isTarget=$isTarget',
            );

            _knownDevicesById[id] = result.device;
            if (!isTarget) {
              continue;
            }

            discoveredById[id] = IosBleDiscoveredPrinter(
              id: id,
              name: name,
              advertisedServiceUuids: serviceUuids,
            );
          }
        },
        onError: (Object e, StackTrace st) {
          debugPrint('iOS BLE scan error: $e');
          debugPrint(st.toString());
        },
      );

      await FlutterBluePlus.startScan(timeout: timeout);
      await Future<void>.delayed(timeout + const Duration(milliseconds: 200));
    } catch (e, stackTrace) {
      debugPrint('iOS BLE startScan exception: $e');
      debugPrint(stackTrace.toString());
    } finally {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      await subscription?.cancel();
      debugPrint(
        'iOS BLE scan ended matchedCount=${discoveredById.length}',
      );
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
      debugPrint('iOS BLE connect aborted: empty device id');
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
      debugPrint('iOS BLE connect failed: device not found id="$normalizedId"');
      return false;
    }

    await disconnect();

    try {
      await device.connect(timeout: const Duration(seconds: 10));
    } catch (e) {
      final text = e.toString().toLowerCase();
      if (!text.contains('already connected')) {
        debugPrint('iOS BLE connect exception id="$normalizedId": $e');
      }
    }

    List<BluetoothService> services = const <BluetoothService>[];
    try {
      services = await device.discoverServices();
    } catch (e, stackTrace) {
      debugPrint('iOS BLE discoverServices failed id="$normalizedId": $e');
      debugPrint(stackTrace.toString());
      return false;
    }

    for (final service in services) {
      final serviceUuid = _normalizeUuid(service.uuid.toString());
      debugPrint('iOS BLE service uuid=$serviceUuid');
      for (final characteristic in service.characteristics) {
        final uuid = _normalizeUuid(characteristic.uuid.toString());
        final p = characteristic.properties;
        debugPrint(
          'iOS BLE characteristic service=$serviceUuid uuid=$uuid '
          'write=${p.write} writeWithoutResponse=${p.writeWithoutResponse} '
          'notify=${p.notify}',
        );
      }
    }

    BluetoothCharacteristic? selected = _findPreferredCharacteristic(services);
    selected ??= _findFallbackWritableCharacteristic(services);

    if (selected == null) {
      debugPrint('iOS BLE connect failed: no writable characteristic found');
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
      'iOS BLE selected write characteristic service=$selectedServiceUuid '
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
      debugPrint('iOS BLE write skipped: empty payload');
      return true;
    }

    final resolvedId = (deviceId ?? _connectedDeviceId ?? '').trim().toUpperCase();
    if (resolvedId.isEmpty) {
      debugPrint('iOS BLE write failed: missing device id');
      return false;
    }

    final ready = await connectAndPrepareWriter(resolvedId);
    if (!ready) {
      debugPrint('iOS BLE write failed: connection not ready');
      return false;
    }

    final characteristic = _writeCharacteristic;
    if (characteristic == null) {
      debugPrint('iOS BLE write failed: missing write characteristic');
      return false;
    }

    final canWriteWithResponse = characteristic.properties.write;
    final canWriteWithoutResponse = characteristic.properties.writeWithoutResponse;
    if (!canWriteWithResponse && !canWriteWithoutResponse) {
      debugPrint(
        'iOS BLE write failed: selected characteristic is not writable',
      );
      return false;
    }

    final useWithoutResponse =
        canWriteWithoutResponse && !canWriteWithResponse ? true : canWriteWithoutResponse;
    final safeChunkSize = chunkSize <= 0 ? _defaultChunkSize : chunkSize;
    var chunkCount = 0;

    for (int i = 0; i < bytes.length; i += safeChunkSize) {
      final end = (i + safeChunkSize > bytes.length) ? bytes.length : i + safeChunkSize;
      final chunk = bytes.sublist(i, end);
      try {
        await characteristic.write(
          chunk,
          withoutResponse: useWithoutResponse,
        );
      } catch (e, stackTrace) {
        debugPrint(
          'iOS BLE write failed at chunk=$chunkCount length=${chunk.length}: $e',
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
      'iOS BLE write completed chunks=$chunkCount totalBytes=${bytes.length} '
      'withoutResponse=$useWithoutResponse',
    );
    return true;
  }
}
