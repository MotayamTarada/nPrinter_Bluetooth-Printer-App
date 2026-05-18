import 'package:flutter/material.dart';

import '../services/ios_bluetooth_permission_gate_service.dart';

class IosBluetoothPermissionPage extends StatefulWidget {
  const IosBluetoothPermissionPage({required this.onContinue, super.key});

  final VoidCallback onContinue;

  @override
  State<IosBluetoothPermissionPage> createState() =>
      _IosBluetoothPermissionPageState();
}

class _IosBluetoothPermissionPageState
    extends State<IosBluetoothPermissionPage> {
  IosBluetoothGateSnapshot _snapshot = const IosBluetoothGateSnapshot(
    state: IosBluetoothGateState.loading,
    permissionStatus: null,
    adapterState: null,
  );
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh(requestIfNeeded: true);
  }

  Future<void> _refresh({required bool requestIfNeeded}) async {
    if (_busy) return;
    setState(() => _busy = true);
    final next = await IosBluetoothPermissionGateService.evaluate(
      requestIfNeeded: requestIfNeeded,
    );
    if (!mounted) return;
    setState(() {
      _snapshot = next;
      _busy = false;
    });
    if (next.state == IosBluetoothGateState.available) {
      widget.onContinue();
    }
  }

  Future<void> _openSettings() async {
    await IosBluetoothPermissionGateService.openSystemSettings();
  }

  @override
  Widget build(BuildContext context) {
    final state = _snapshot.state;
    final title = _titleForState(state);
    final message = _messageForState(state);

    return Scaffold(
      appBar: AppBar(title: const Text('Bluetooth Permission')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Icon(
                Icons.bluetooth_searching_rounded,
                size: 56,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Colors.black54),
              ),
              const SizedBox(height: 28),
              if (state == IosBluetoothGateState.loading || _busy)
                const Center(child: CircularProgressIndicator()),
              if (state == IosBluetoothGateState.permissionDenied) ...[
                FilledButton(
                  onPressed: _openSettings,
                  child: const Text('Open iPhone Settings'),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: () => _refresh(requestIfNeeded: true),
                  child: const Text('Try Again'),
                ),
              ],
              if (state == IosBluetoothGateState.bluetoothOff) ...[
                OutlinedButton(
                  onPressed: () => _refresh(requestIfNeeded: false),
                  child: const Text('Refresh Status'),
                ),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: _openSettings,
                  child: const Text('Open iPhone Settings'),
                ),
              ],
              if (state == IosBluetoothGateState.unsupported ||
                  state == IosBluetoothGateState.unknown) ...[
                OutlinedButton(
                  onPressed: () => _refresh(requestIfNeeded: true),
                  child: const Text('Retry'),
                ),
              ],
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }

  String _titleForState(IosBluetoothGateState state) {
    switch (state) {
      case IosBluetoothGateState.available:
        return 'Bluetooth Available';
      case IosBluetoothGateState.bluetoothOff:
        return 'Bluetooth is Off';
      case IosBluetoothGateState.permissionDenied:
        return 'Bluetooth Permission Denied';
      case IosBluetoothGateState.unsupported:
        return 'Bluetooth Unsupported';
      case IosBluetoothGateState.unknown:
        return 'Bluetooth Status Unknown';
      case IosBluetoothGateState.loading:
        return 'Checking Bluetooth';
    }
  }

  String _messageForState(IosBluetoothGateState state) {
    switch (state) {
      case IosBluetoothGateState.available:
        return 'Bluetooth access is granted. Continuing to the app.';
      case IosBluetoothGateState.bluetoothOff:
        return 'Turn on Bluetooth from iPhone settings, then refresh.';
      case IosBluetoothGateState.permissionDenied:
        return 'Please allow Bluetooth permission in Settings to continue.';
      case IosBluetoothGateState.unsupported:
        return 'This iPhone does not support required Bluetooth features.';
      case IosBluetoothGateState.unknown:
        return 'Could not determine Bluetooth status. Please retry.';
      case IosBluetoothGateState.loading:
        return 'Checking Bluetooth authorization and adapter status...';
    }
  }
}

