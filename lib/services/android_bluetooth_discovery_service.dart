import 'dart:io';

import 'package:flutter/services.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

class AndroidBluetoothDiscoveryService {
  AndroidBluetoothDiscoveryService._();

  static const MethodChannel _channel = MethodChannel(
    'com.example.nprinter_bluetooth_only/bluetooth_scan',
  );

  static Future<int> androidSdkInt() async {
    if (!Platform.isAndroid) {
      return 0;
    }

    try {
      return await _channel.invokeMethod<int>('androidSdkInt') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<List<BluetoothInfo>> discover({
    Duration timeout = const Duration(seconds: 10),
    bool includeBonded = true,
  }) async {
    if (!Platform.isAndroid) {
      return const <BluetoothInfo>[];
    }

    final rawResult = await _channel.invokeMethod<List<dynamic>>(
      'discover',
      <String, Object>{
        'timeoutMs': timeout.inMilliseconds,
        'includeBonded': includeBonded,
      },
    );

    if (rawResult == null || rawResult.isEmpty) {
      return const <BluetoothInfo>[];
    }

    final devices = <BluetoothInfo>[];
    for (final entry in rawResult) {
      if (entry is! Map) {
        continue;
      }

      final mac = (entry['macAdress'] ?? '').toString().trim();
      if (mac.isEmpty) {
        continue;
      }

      final name = (entry['name'] ?? '').toString();
      devices.add(BluetoothInfo(name: name, macAdress: mac));
    }

    return devices;
  }

  static Future<bool> pairDevice({
    required String macAddress,
    String pin = '',
  }) async {
    if (!Platform.isAndroid) {
      return false;
    }

    final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
      'pairDevice',
      <String, Object>{'mac': macAddress.trim(), 'pin': pin.trim()},
    );

    if (raw == null) {
      return false;
    }

    return raw['success'] == true;
  }
}
