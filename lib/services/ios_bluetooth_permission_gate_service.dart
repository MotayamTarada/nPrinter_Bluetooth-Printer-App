import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ios_ble_printer_service.dart';

enum IosBluetoothGateState {
  loading,
  available,
  bluetoothOff,
  permissionDenied,
  unsupported,
  unknown,
}

class IosBluetoothGateSnapshot {
  const IosBluetoothGateSnapshot({
    required this.state,
    required this.permissionStatus,
    required this.adapterState,
  });

  final IosBluetoothGateState state;
  final PermissionStatus? permissionStatus;
  final BluetoothAdapterState? adapterState;
}

class IosBluetoothPermissionGateService {
  IosBluetoothPermissionGateService._();

  static bool get isIosGateRequired =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS && Platform.isIOS;

  static Future<IosBluetoothGateSnapshot> evaluate({
    bool requestIfNeeded = true,
  }) async {
    if (!isIosGateRequired) {
      return const IosBluetoothGateSnapshot(
        state: IosBluetoothGateState.unsupported,
        permissionStatus: null,
        adapterState: null,
      );
    }

    PermissionStatus status;
    if (requestIfNeeded) {
      // iOS may not expose the Bluetooth toggle in app settings until the app
      // touches CoreBluetooth APIs. Reuse the existing iOS BLE warm-up scan to
      // trigger the native permission flow without changing printer logic.
      final outcome =
          await IosBlePrinterService.startIosBleScanForPermissionAndPrinters();
      status = outcome.permissionAfterScan;
    } else {
      status = await Permission.bluetooth.status;
    }

    if (!status.isGranted) {
      return IosBluetoothGateSnapshot(
        state: IosBluetoothGateState.permissionDenied,
        permissionStatus: status,
        adapterState: null,
      );
    }

    final adapterState = await _readAdapterState();
    switch (adapterState) {
      case BluetoothAdapterState.on:
        return IosBluetoothGateSnapshot(
          state: IosBluetoothGateState.available,
          permissionStatus: status,
          adapterState: adapterState,
        );
      case BluetoothAdapterState.off:
      case BluetoothAdapterState.turningOff:
      case BluetoothAdapterState.turningOn:
        return IosBluetoothGateSnapshot(
          state: IosBluetoothGateState.bluetoothOff,
          permissionStatus: status,
          adapterState: adapterState,
        );
      case BluetoothAdapterState.unavailable:
        return IosBluetoothGateSnapshot(
          state: IosBluetoothGateState.unsupported,
          permissionStatus: status,
          adapterState: adapterState,
        );
      case BluetoothAdapterState.unauthorized:
        return IosBluetoothGateSnapshot(
          state: IosBluetoothGateState.permissionDenied,
          permissionStatus: status,
          adapterState: adapterState,
        );
      case BluetoothAdapterState.unknown:
        return IosBluetoothGateSnapshot(
          state: IosBluetoothGateState.unknown,
          permissionStatus: status,
          adapterState: adapterState,
        );
    }
  }

  static Future<void> openSystemSettings() async {
    await openAppSettings();
  }

  static Future<BluetoothAdapterState> _readAdapterState() async {
    try {
      return await FlutterBluePlus.adapterState.first.timeout(
        const Duration(seconds: 2),
      );
    } on TimeoutException {
      return BluetoothAdapterState.unknown;
    } catch (_) {
      return BluetoothAdapterState.unknown;
    }
  }
}
