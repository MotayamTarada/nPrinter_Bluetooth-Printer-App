import Flutter
import CoreBluetooth
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, CBCentralManagerDelegate {
  private var bluetoothCentralManager: CBCentralManager?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if let controller = window?.rootViewController as? FlutterViewController {
      let warmUpChannel = FlutterMethodChannel(
        name: "ios_bluetooth_permission_warmup",
        binaryMessenger: controller.binaryMessenger
      )

      warmUpChannel.setMethodCallHandler { [weak self] call, result in
        guard call.method == "warmUpBluetoothPermission" else {
          result(FlutterMethodNotImplemented)
          return
        }

        self?.warmUpBluetoothPermission()
        result(nil)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  private func warmUpBluetoothPermission() {
    bluetoothCentralManager = CBCentralManager(
      delegate: self,
      queue: nil,
      options: [
        CBCentralManagerOptionShowPowerAlertKey: true
      ]
    )
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    // لا نحتاج منطق إضافي. إنشاء CBCentralManager يكفي لتحريك صلاحية Bluetooth على iOS.
  }
}
