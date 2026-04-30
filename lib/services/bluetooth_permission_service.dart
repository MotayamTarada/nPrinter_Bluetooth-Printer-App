import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import 'android_bluetooth_discovery_service.dart';

class BluetoothPermissionService {
  BluetoothPermissionService._();

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
    final currentStatus = await Permission.bluetooth.status;
    if (_isGranted(currentStatus)) {
      return true;
    }

    if (_isBlockedStatus(currentStatus)) {
      await openAppSettings();
      return false;
    }

    final requestedStatus = await Permission.bluetooth.request();
    if (_isGranted(requestedStatus)) {
      return true;
    }

    if (_isBlockedStatus(requestedStatus)) {
      await openAppSettings();
    }
    return false;
  }

  static Future<bool> _ensureAndroidPermission() async {
    final sdkInt = await AndroidBluetoothDiscoveryService.androidSdkInt();
    final isAndroid12OrHigher = sdkInt == 0 || sdkInt >= 31;

    final requiredPermissions = <Permission>[
      if (isAndroid12OrHigher) Permission.bluetoothScan,
      if (isAndroid12OrHigher) Permission.bluetoothConnect,
      // Keep location for compatibility with older and some vendor stacks.
      Permission.locationWhenInUse,
    ];

    final missingPermissions = <Permission>[];
    for (final permission in requiredPermissions) {
      final status = await permission.status;
      if (_isGranted(status)) {
        continue;
      }

      if (_isBlockedStatus(status)) {
        await openAppSettings();
        return false;
      }

      missingPermissions.add(permission);
    }

    if (missingPermissions.isEmpty) {
      return true;
    }

    final requested = await missingPermissions.request();
    for (final permission in requiredPermissions) {
      final status = requested[permission] ?? await permission.status;
      if (_isGranted(status)) {
        continue;
      }
      if (_isBlockedStatus(status)) {
        await openAppSettings();
      }
      return false;
    }

    return true;
  }

  static bool _isGranted(PermissionStatus status) {
    return status.isGranted || status.isLimited;
  }

  static bool _isBlockedStatus(PermissionStatus status) {
    return status.isPermanentlyDenied || status.isRestricted;
  }
}
