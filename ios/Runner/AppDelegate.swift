import Flutter
import CoreBluetooth
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, CBCentralManagerDelegate {
  private var bluetoothCentralManager: CBCentralManager?
  private var didWarmUpBluetoothPermission = false

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

    // Ensure iOS Bluetooth privacy prompt can appear even when scene-based
    // window initialization is delayed. This makes the app show up under
    // Settings > Privacy & Security > Bluetooth after first request.
    warmUpBluetoothPermissionIfNeeded()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  private func warmUpBluetoothPermission() {
    guard !didWarmUpBluetoothPermission else {
      return
    }
    didWarmUpBluetoothPermission = true
    bluetoothCentralManager = CBCentralManager(
      delegate: self,
      queue: nil,
      options: [
        CBCentralManagerOptionShowPowerAlertKey: true
      ]
    )
  }

  private func warmUpBluetoothPermissionIfNeeded() {
    if #available(iOS 13.0, *) {
      guard CBCentralManager.authorization == .notDetermined else {
        return
      }
    }
    warmUpBluetoothPermission()
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    // لا نحتاج منطق إضافي. إنشاء CBCentralManager يكفي لتحريك صلاحية Bluetooth على iOS.
  }
}
