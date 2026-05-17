import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'android_bluetooth_discovery_service.dart';

class BluetoothPermissionService {
  BluetoothPermissionService._();
  static const MethodChannel _iosBluetoothPermissionWarmupChannel =
      MethodChannel('ios_bluetooth_permission_warmup');

  static Future<bool> ensureBluetoothPermission() async {
    if (kIsWeb) {
      return true;
    }

    if (Platform.isIOS) {
      return _ensureIosPermission();
    }

    if (Platform.isAndroid) {
      return _ensureAndroidPermission();
    }

    return true;
  }

  static Future<bool> _ensureIosPermission() async {
    var status = await Permission.bluetooth.status;

    if (status.isGranted) {
      return true;
    }

    if (status.isRestricted || status.isPermanentlyDenied) {
      return false;
    }

    status = await Permission.bluetooth.request();
    if (status.isGranted) {
      return true;
    }
    if (status.isRestricted || status.isPermanentlyDenied) {
      return false;
    }

    await _warmUpIosBluetoothNative();
    status = await Permission.bluetooth.status;

    if (status.isGranted) {
      return true;
    }

    if (status.isRestricted || status.isPermanentlyDenied) {
      return false;
    }

    return false;
  }

  static Future<void> _warmUpIosBluetoothNative() async {
    try {
      await _iosBluetoothPermissionWarmupChannel.invokeMethod<void>(
        'warmUpBluetoothPermission',
      );
    } catch (_) {
      // Best effort warm-up only.
    }
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }

  static Future<bool> _ensureAndroidPermission() async {
    final sdkInt = await AndroidBluetoothDiscoveryService.androidSdkInt();

    if (sdkInt >= 31) {
      final statuses = await <Permission>[
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();

      final scanStatus =
          statuses[Permission.bluetoothScan] ?? PermissionStatus.denied;

      final connectStatus =
          statuses[Permission.bluetoothConnect] ?? PermissionStatus.denied;

      final granted = scanStatus.isGranted && connectStatus.isGranted;

      if (!granted &&
          (scanStatus.isPermanentlyDenied ||
              connectStatus.isPermanentlyDenied)) {
        await openAppSettings();
      }

      return granted;
    }

    final locationStatus = await Permission.locationWhenInUse.request();

    if (locationStatus.isGranted) {
      return true;
    }

    if (locationStatus.isPermanentlyDenied) {
      await openAppSettings();
    }

    return false;
  }
}
