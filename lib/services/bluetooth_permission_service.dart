import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
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
    var status = await Permission.bluetooth.status;
    if (_isGranted(status)) {
      return true;
    }

    if (_isBlockedStatus(status)) {
      await openAppSettings();
      return false;
    }

    // On iOS, Bluetooth permission is ultimately driven by CoreBluetooth usage.
    // Touching FlutterBluePlus ensures iOS has a chance to present the system dialog.
    await _primeIosBluetoothAuthorization();

    status = await Permission.bluetooth.status;
    if (_isGranted(status)) {
      return true;
    }

    status = await Permission.bluetooth.request();
    if (_isGranted(status)) {
      return true;
    }

    if (_isBlockedStatus(status)) {
      await openAppSettings();
    }

    return false;
  }

  static Future<void> _primeIosBluetoothAuthorization() async {
    if (!Platform.isIOS) {
      return;
    }

    try {
      final supported = await FlutterBluePlus.isSupported;
      if (!supported) {
        return;
      }

      var state = await FlutterBluePlus.adapterState.first.timeout(
        const Duration(seconds: 2),
        onTimeout: () => BluetoothAdapterState.unknown,
      );

      if (state == BluetoothAdapterState.unknown ||
          state == BluetoothAdapterState.turningOn) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        state = await FlutterBluePlus.adapterState.first.timeout(
          const Duration(seconds: 2),
          onTimeout: () => state,
        );
      }

      if (state == BluetoothAdapterState.unknown ||
          state == BluetoothAdapterState.turningOn) {
        try {
          await FlutterBluePlus.startScan(timeout: const Duration(seconds: 1));
        } catch (_) {
          // No-op. We only need to initialize CoreBluetooth to trigger iOS prompt.
        } finally {
          try {
            await FlutterBluePlus.stopScan();
          } catch (_) {}
        }
      }
    } catch (_) {
      // Ignore transient iOS CoreBluetooth probing failures.
    }
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
