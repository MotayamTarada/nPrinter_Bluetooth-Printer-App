import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

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
    final bluetoothPermission = Permission.bluetooth;
    var status = await bluetoothPermission.status;
    if (status == PermissionStatus.granted) {
      return true;
    }

    if (status == PermissionStatus.restricted ||
        status == PermissionStatus.permanentlyDenied) {
      return false;
    }

    status = await bluetoothPermission.request();
    if (status == PermissionStatus.granted) {
      return true;
    }

    // Fallback: بعض إصدارات iOS/SDK تُرجع الحالة عبر bluetoothConnect.
    final connectStatus = await Permission.bluetoothConnect.request();
    if (connectStatus == PermissionStatus.granted) {
      return true;
    }

    return false;
  }

  static Future<bool> _ensureAndroidPermission() async {
    final statuses = await [
      Permission.location,
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();

    if (statuses[Permission.location] != PermissionStatus.granted) {
      return false;
    }

    if (await Permission.location.serviceStatus.isDisabled) {
      return false;
    }

    return statuses[Permission.bluetoothScan] == PermissionStatus.granted &&
        statuses[Permission.bluetoothConnect] == PermissionStatus.granted;
  }
}
