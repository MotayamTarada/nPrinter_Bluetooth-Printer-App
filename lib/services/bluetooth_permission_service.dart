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
    var bluetoothStatus = await Permission.bluetooth.status;
    if (bluetoothStatus == PermissionStatus.granted) {
      return true;
    }

    if (bluetoothStatus == PermissionStatus.restricted ||
        bluetoothStatus == PermissionStatus.permanentlyDenied) {
      await openAppSettings();
      return false;
    }

    bluetoothStatus = await Permission.bluetooth.request();
    if (bluetoothStatus == PermissionStatus.granted) {
      return true;
    }

    final connectStatus = await Permission.bluetoothConnect.request();
    if (connectStatus == PermissionStatus.granted) {
      return true;
    }

    if (bluetoothStatus == PermissionStatus.permanentlyDenied ||
        connectStatus == PermissionStatus.permanentlyDenied) {
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
