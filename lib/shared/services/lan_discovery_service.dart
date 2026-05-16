// shared/services/lan_discovery_service.dart
import 'dart:async';
import 'package:kova/shared/models/network_alert.dart';
import 'package:kova/shared/services/local_storage.dart';
import 'package:kova/shared/services/crypto_service.dart';
import 'package:kova/shared/services/native_network_service.dart';
import 'package:flutter/foundation.dart';

class LanDiscoveryService {
  static final LanDiscoveryService _instance = LanDiscoveryService._();
  factory LanDiscoveryService() => _instance;

  final _deviceFoundController = StreamController<LanDeviceInfo>.broadcast();
  final _deviceLostController = StreamController<String>.broadcast();
  final _udpAlertReceivedController = StreamController<Map<String, dynamic>>.broadcast();

  final _discoveredDevices = <String, LanDeviceInfo>{};
  bool _isRunning = false;
  String _role = 'child';
  String _deviceId = '';
  String _pairToken = '';
  String? _activePairCode;
  bool _pairingMode = false;

  void Function(LanDeviceInfo)? _onPeerFoundCallback;
  StreamSubscription? _nativeDiscoverySub;
  StreamSubscription? _nativeMessageSub;

  Stream<LanDeviceInfo> get onDeviceFound => _deviceFoundController.stream;
  Stream<String> get onDeviceLost => _deviceLostController.stream;
  Stream<Map<String, dynamic>> get onUdpAlertReceived => _udpAlertReceivedController.stream;

  bool get isRunning => _isRunning;
  Map<String, LanDeviceInfo> get discoveredDevices => Map.unmodifiable(_discoveredDevices);

  LanDiscoveryService._() {
    _nativeDiscoverySub = NativeNetworkService().onDeviceFound.listen(_handleNativeDeviceFound);
    _nativeMessageSub = NativeNetworkService().onMessageReceived.listen((msg) {
      if (msg['type'] == 'kova_alert_udp') {
        _udpAlertReceivedController.add(msg);
      }
    });
  }

  LanDeviceInfo? get pairedPeer {
    final expectedRole = _role == 'parent' ? 'child' : 'parent';
    for (final device in _discoveredDevices.values) {
      if (device.role == expectedRole) return device;
    }
    return null;
  }

  LanDeviceInfo? findPeerByCode(String code) {
    for (final device in _discoveredDevices.values) {
      if (device.role == 'parent' && device.pairCode == code) return device;
    }
    return null;
  }

  LanDeviceInfo? findChildByCode(String code) {
    for (final device in _discoveredDevices.values) {
      if (device.role == 'child' && device.pairCode == code) return device;
    }
    return null;
  }

  void setOnPeerFoundCallback(void Function(LanDeviceInfo)? callback) {
    _onPeerFoundCallback = callback;
  }

  Future<LanDeviceInfo?> waitForPeerWithCode(String code, Duration timeout) async {
    final existing = findPeerByCode(code);
    if (existing != null) return existing;

    final completer = Completer<LanDeviceInfo?>();
    Timer? timeoutTimer;

    _onPeerFoundCallback = (device) {
      if (device.pairCode == code && !completer.isCompleted) {
        timeoutTimer?.cancel();
        completer.complete(device);
      }
    };

    timeoutTimer = Timer(timeout, () {
      if (!completer.isCompleted) {
        _onPeerFoundCallback = null;
        completer.complete(null);
      }
    });

    return completer.future;
  }

  void setActivePairCode(String code) {
    _activePairCode = code;
    // For Native Android NSD, we might need to restart the server to update the TXT records
    if (_isRunning && _role == 'child') {
      _startNativeChildServer();
    }
  }

  Future<void> start({required String role, bool pairingMode = false}) async {
    if (_isRunning) return;

    _role = role;
    _pairingMode = pairingMode;
    _deviceId = LocalStorage.getString('device_id');
    _pairToken = LocalStorage.getString('pair_token');

    if (_deviceId.isEmpty) return;
    if (!_pairingMode && _pairToken.isEmpty) return;

    _isRunning = true;
    _discoveredDevices.clear();

    if (_role == 'child') {
      // Child registers the mDNS service
      await _startNativeChildServer();
    } else {
      // Parent discovers the mDNS service
      await NativeNetworkService().startDiscovery();
    }
    print('📡 Native LAN Discovery started as $_role');
  }

  Future<void> _startNativeChildServer() async {
    final Map<String, String>? encryptedTokenMap = _activePairCode != null && _activePairCode!.isNotEmpty && _pairToken.isNotEmpty
        ? CryptoService(_activePairCode!).encryptPayload(_pairToken)
        : null;

    final attrs = <String, String>{
      'role': _role,
      'deviceId': _deviceId,
    };
    if (_activePairCode != null) attrs['pairCode'] = _activePairCode!;
    if (encryptedTokenMap != null) {
      attrs['encToken'] = encryptedTokenMap['data']!;
      attrs['encIv'] = encryptedTokenMap['iv']!;
    }

    final serviceName = 'KOVA_$_deviceId';
    await NativeNetworkService().startServer(name: serviceName, port: 18757, attributes: attrs);
  }

  void stop() {
    NativeNetworkService().stopDiscovery();
    NativeNetworkService().stopServer();
    _isRunning = false;
    _discoveredDevices.clear();
    print('📡 Native LAN Discovery stopped');
  }

  Future<bool> sendAlertViaUdp(LanDeviceInfo peer, Map<String, dynamic> alertData) async {
    // In the native implementation, sending an alert uses the active WebSocket connection
    final payload = {
      'type': 'kova_alert_udp',
      'role': _role,
      'pairToken': _pairToken,
      'deviceId': _deviceId,
      'alert': alertData,
    };
    return await NativeNetworkService().sendMessage(payload);
  }

  void _handleNativeDeviceFound(Map<String, dynamic> data) {
    try {
      final ip = data['ip'] as String;
      final port = data['port'] as int;
      final attrs = data['attributes'] as Map<dynamic, dynamic>? ?? {};

      final deviceId = attrs['deviceId'] as String?;
      final role = attrs['role'] as String?;
      if (deviceId == null || role == null) return;
      if (deviceId == _deviceId) return; // ignore self

      final expectedRole = _role == 'parent' ? 'child' : 'parent';
      if (role != expectedRole) return;

      final pairCode = attrs['pairCode'] as String?;
      final encToken = attrs['encToken'] as String?;
      final encIv = attrs['encIv'] as String?;

      final device = LanDeviceInfo(
        ipAddress: ip,
        port: port,
        deviceId: deviceId,
        role: role,
        pairCode: pairCode,
        encryptedPairToken: encToken,
        encryptedTokenIv: encIv,
        discoveredAt: DateTime.now(),
      );

      final isNew = !_discoveredDevices.containsKey(device.deviceId);
      _discoveredDevices[device.deviceId] = device;

      if (isNew) {
        print('🔍 Native Discovered ${device.role} device at ${device.ipAddress}');
        _deviceFoundController.add(device);

        if (_pairingMode && _onPeerFoundCallback != null) {
          if (device.pairCode != null) {
            _onPeerFoundCallback!(device);
            _onPeerFoundCallback = null;
          }
        }
      }
    } catch (e) {
      print('⚠️ Native Device Found error: $e');
    }
  }

  void dispose() {
    stop();
    _deviceFoundController.close();
    _deviceLostController.close();
    _udpAlertReceivedController.close();
    _nativeDiscoverySub?.cancel();
    _nativeMessageSub?.cancel();
  }
}
