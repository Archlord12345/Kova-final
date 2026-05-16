// shared/services/lan_data_service.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:kova/shared/models/network_alert.dart';
import 'package:kova/shared/services/native_network_service.dart';

class LanChildProfile {
  final String childId;
  final String name;
  final int age;
  LanChildProfile({required this.childId, required this.name, required this.age});
  factory LanChildProfile.fromJson(Map<String, dynamic> j) => LanChildProfile(
    childId: j['childId'] as String? ?? '',
    name: j['name'] as String? ?? 'Child',
    age: j['age'] as int? ?? 10,
  );
}

class LanDataService {
  static final LanDataService _instance = LanDataService._();
  factory LanDataService() => _instance;

  String _pairToken = '';
  bool _isConnected = false;
  
  final _alertReceivedController = StreamController<NetworkAlertFull>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();
  final _childProfileReceivedController = StreamController<LanChildProfile>.broadcast();

  Stream<NetworkAlertFull> get onAlertReceived => _alertReceivedController.stream;
  Stream<bool> get onConnectionChanged => _connectionStateController.stream;
  Stream<LanChildProfile> get onChildProfileReceived => _childProfileReceivedController.stream;

  bool get isConnected => _isConnected;
  bool get isSocketHealthy => _isConnected; // Native WebSockets handle internal ping/pong health
  Future<bool> isServerHealthy() async => _isConnected;

  StreamSubscription? _messageSub;
  StreamSubscription? _connectionSub;

  LanDataService._() {
    _messageSub = NativeNetworkService().onMessageReceived.listen(_handleIncomingMessage);
    _connectionSub = NativeNetworkService().onConnectionStatusChanged.listen((status) {
      _isConnected = status;
      _connectionStateController.add(status);
    });
  }

  void setPairToken(String token) {
    _pairToken = token;
  }

  Future<bool> startServer([String pairToken = '']) async {
    if (pairToken.isNotEmpty) {
      _pairToken = pairToken;
    }
    // Note: startServer is already called by LanDiscoveryService with mDNS attributes.
    // So here we just return true. The NativeNetworkService manages the single WebSocket server instance.
    return true; 
  }

  Future<void> stopServer() async {
    await NativeNetworkService().stopServer();
    _isConnected = false;
    _connectionStateController.add(false);
  }

  Future<bool> connectToChild(String ip, int port, [String pairToken = '']) async {
    if (pairToken.isNotEmpty) {
      _pairToken = pairToken;
    }
    try {
      await NativeNetworkService().connectToParent(ip, port);
      // Send handshake
      final handshake = {
        'type': 'handshake',
        'role': 'parent',
        'pairToken': _pairToken,
      };
      await NativeNetworkService().sendMessage(handshake);
      return true;
    } catch (e) {
      print('❌ [LAN DATA] Connection failed: $e');
      return false;
    }
  }

  Future<bool> connectToParent(String ip, int port, [String pairToken = '']) async {
    if (pairToken.isNotEmpty) {
      _pairToken = pairToken;
    }
    try {
      await NativeNetworkService().connectToParent(ip, port);
      // Send handshake
      final handshake = {
        'type': 'handshake',
        'role': 'child',
        'pairToken': _pairToken,
      };
      await NativeNetworkService().sendMessage(handshake);
      return true;
    } catch (e) {
      print('❌ [LAN DATA] Connection failed: $e');
      return false;
    }
  }

  Future<void> disconnect() async {
    await NativeNetworkService().disconnectClient();
    _isConnected = false;
    _connectionStateController.add(false);
  }

  Future<void> disconnectClient() async {
    await disconnect();
  }

  Future<bool> sendAlert(Map<String, dynamic> alertJson) async {
    if (!_isConnected) return false;
    
    final payload = {
      'type': 'alert',
      'pairToken': _pairToken,
      'alert': alertJson,
    };
    return await NativeNetworkService().sendMessage(payload);
  }

  Future<bool> sendAlertSafe(NetworkAlertFull alert) async {
    if (!_isConnected) return false;
    final payload = {
      'type': 'alert',
      'pairToken': _pairToken,
      'alert': alert.toJson(),
    };
    try {
      final success = await NativeNetworkService().sendMessage(payload);
      if (!success) {
        // If native send failed, connection might be dead
        _isConnected = false;
        _connectionStateController.add(false);
      }
      return success;
    } catch (e) {
      print('❌ [LAN DATA] Send alert error: $e');
      return false;
    }
  }

  void sendChildProfile({
    required String childId,
    required String name,
    required int age,
  }) {
    if (!_isConnected) return;
    final payload = {
      'type': 'child_profile',
      'childId': childId,
      'name': name,
      'age': age,
    };
    try {
      NativeNetworkService().sendMessage(payload);
    } catch (e) {
      print('❌ [LAN DATA] Send child profile error: $e');
    }
  }
  
  void _handleIncomingMessage(Map<String, dynamic> json) {
    try {
      final type = json['type'] as String?;
      
      // Token validation
      if (type != 'child_profile') { // Profile might not have token
        final token = json['pairToken'] as String? ?? '';
        if (_pairToken.isNotEmpty && token != _pairToken) {
          debugPrint('⚠️ [LAN DATA] Ignoring packet with wrong token');
          return;
        }
      }

      if (type == 'alert') {
        final alertData = json['alert'] as Map<String, dynamic>?;
        if (alertData != null) {
          final alert = NetworkAlertFull.fromJson(alertData);
          _alertReceivedController.add(alert);
        }
      } else if (type == 'child_profile') {
        final profile = LanChildProfile.fromJson(json);
        _childProfileReceivedController.add(profile);
      }
    } catch (e) {
      print('⚠️ [LAN DATA] Message handle error: $e');
    }
  }

  void dispose() {
    _messageSub?.cancel();
    _connectionSub?.cancel();
    _alertReceivedController.close();
    _connectionStateController.close();
    _childProfileReceivedController.close();
  }
}
