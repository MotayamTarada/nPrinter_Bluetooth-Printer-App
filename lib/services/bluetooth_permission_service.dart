import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

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
    if (currentStatus == PermissionStatus.granted) {
      return true;
    }

    final requestedStatus = await Permission.bluetooth.request();
    if (requestedStatus == PermissionStatus.granted) {
      return true;
    }

    // On iOS, permission_handler may report `denied` while status is still
    // not-determined until CoreBluetooth scanning/connection is attempted.
    // Trigger one scan attempt through the printer plugin, then re-check.
    if (requestedStatus == PermissionStatus.denied) {
      try {
        await PrintBluetoothThermal.pairedBluetooths;
      } catch (_) {}

      final refreshedStatus = await Permission.bluetooth.status;
      if (refreshedStatus == PermissionStatus.granted) {
        return true;
      }
      if (refreshedStatus == PermissionStatus.permanentlyDenied ||
          refreshedStatus == PermissionStatus.restricted) {
        await openAppSettings();
        return false;
      }
      return true;
    }

    if (requestedStatus == PermissionStatus.permanentlyDenied ||
        requestedStatus == PermissionStatus.restricted) {
      await openAppSettings();
    }

    return false;
  }

  static Future<bool> _ensureAndroidPermission() async {
    final sdkInt = await AndroidBluetoothDiscoveryService.androidSdkInt();

    if (sdkInt >= 31) {
      final statuses = await <Permission>[
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();

      final scanStatus = statuses[Permission.bluetoothScan] ?? PermissionStatus.denied;
      final connectStatus =
          statuses[Permission.bluetoothConnect] ?? PermissionStatus.denied;

      final granted =
          scanStatus == PermissionStatus.granted &&
          connectStatus == PermissionStatus.granted;

      if (!granted &&
          (scanStatus == PermissionStatus.permanentlyDenied ||
              connectStatus == PermissionStatus.permanentlyDenied)) {
        await openAppSettings();
      }

      return granted;
    }

    final locationStatus = await Permission.locationWhenInUse.request();
    if (locationStatus == PermissionStatus.granted) {
      return true;
    }

    if (locationStatus == PermissionStatus.permanentlyDenied) {
      await openAppSettings();
    }

    return false;
  }
}
