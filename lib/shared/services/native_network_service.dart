import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';

class NativeNetworkService {
  static final NativeNetworkService _instance = NativeNetworkService._();
  factory NativeNetworkService() => _instance;

  static const MethodChannel _methodChannel = MethodChannel('com.kova.child/network_commands');
  static const EventChannel _eventChannel = EventChannel('com.kova.child/network_events');

  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  final _deviceFoundController = StreamController<Map<String, dynamic>>.broadcast();
  final _connectionStatusController = StreamController<bool>.broadcast();

  Stream<Map<String, dynamic>> get onMessageReceived => _messageController.stream;
  Stream<Map<String, dynamic>> get onDeviceFound => _deviceFoundController.stream;
  Stream<bool> get onConnectionStatusChanged => _connectionStatusController.stream;

  NativeNetworkService._() {
    _eventChannel.receiveBroadcastStream().listen((event) {
      if (event is Map) {
        final type = event['type'] as String;
        final payloadStr = event['payload'] as String;
        
        switch (type) {
          case 'device_found':
            final payload = jsonDecode(payloadStr);
            _deviceFoundController.add(payload);
            break;
          case 'message_received':
            try {
              final payload = jsonDecode(payloadStr);
              _messageController.add(payload);
            } catch (e) {
              print('NativeNetworkService JSON parse error: $e');
            }
            break;
          case 'client_connected':
            _connectionStatusController.add(true);
            break;
          case 'client_disconnected':
            _connectionStatusController.add(false);
            break;
        }
      }
    });
  }

  Future<void> startServer({required String name, int port = 18757, Map<String, String>? attributes}) async {
    await _methodChannel.invokeMethod('startServer', {
      'name': name, 
      'port': port,
      if (attributes != null) 'attributes': attributes,
    });
  }

  Future<void> stopServer() async {
    await _methodChannel.invokeMethod('stopServer');
  }

  Future<void> startDiscovery() async {
    await _methodChannel.invokeMethod('startDiscovery');
  }

  Future<void> stopDiscovery() async {
    await _methodChannel.invokeMethod('stopDiscovery');
  }

  Future<void> connectToParent(String host, int port) async {
    await _methodChannel.invokeMethod('connectToParent', {'host': host, 'port': port});
  }

  Future<void> disconnectClient() async {
    await _methodChannel.invokeMethod('disconnectClient');
  }

  Future<bool> sendMessage(Map<String, dynamic> data) async {
    try {
      final jsonStr = jsonEncode(data);
      final result = await _methodChannel.invokeMethod<bool>('sendMessage', {'message': jsonStr});
      return result ?? false;
    } catch (e) {
      print('NativeNetworkService send error: $e');
      return false;
    }
  }
}
