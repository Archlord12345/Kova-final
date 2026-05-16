// parent/services/app_control_service.dart — App control management
// Manages per-app monitoring settings

import 'package:flutter/foundation.dart';
import 'package:kova/local_backend/repositories/child_repository.dart';
import 'package:kova/local_backend/repositories/alert_repository.dart';
import 'package:kova/shared/services/local_storage.dart';
import 'package:kova/shared/services/network_sync_service.dart';
import 'package:kova/shared/models/network_alert.dart';

class AppControlService extends ChangeNotifier {
  final _childRepo = ChildRepository();
  final _alertRepo = AlertRepository();
  final _networkSync = NetworkSyncService();

  List<ChildModel> _children = [];
  final Map<String, AppControlData> _appData = {};
  bool _loading = false;
  String? _error;

  // Getters
  List<ChildModel> get children => _children;
  Map<String, AppControlData> get appData => _appData;
  bool get loading => _loading;
  String? get error => _error;

  // Load children and calculate app data
  Future<void> loadAppControls() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      _children = await _childRepo.getAll();
      await _calculateAppData();
      _error = null;
    } catch (e) {
      _error = 'Error loading app controls: $e';
      debugPrint(_error);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  // Calculate app statistics
  Future<void> _calculateAppData() async {
    final apps = ['whatsapp', 'tiktok', 'facebook', 'instagram', 'sms', 'x'];

    for (final app in apps) {
      // Get alerts for this app (across all children)
      final allAlerts = await _alertRepo.getAll();
      final appAlerts = allAlerts
          .where((a) => a.app.toLowerCase() == app)
          .toList();

      final alertCount = appAlerts.length;
      final blockCount = appAlerts.where((a) => a.resolved).length;

      // Check if app is enabled for any child
      final isEnabled = _children.any((c) => c.appControls[app] ?? true);

      // Load sensitivity and blocking from LocalStorage
      final sensitivity = LocalStorage.getInt('app_sensitivity_$app', 1);
      final blocking = LocalStorage.getInt('app_blocking_$app', 0);

      _appData[app] = AppControlData(
        name: _formatAppName(app),
        alerts: alertCount,
        blocks: blockCount,
        enabled: isEnabled,
        sensitivity: sensitivity,
        blocking: blocking,
      );
    }
  }

  String _formatAppName(String app) {
    switch (app) {
      case 'whatsapp':
        return 'WhatsApp';
      case 'tiktok':
        return 'TikTok';
      case 'facebook':
        return 'Facebook';
      case 'instagram':
        return 'Instagram';
      case 'sms':
        return 'SMS';
      case 'x':
        return 'X';
      default:
        return app;
    }
  }

  // Toggle app monitoring for a child
  Future<void> toggleAppControl(
    String childId,
    String app,
    bool enabled,
  ) async {
    try {
      await _childRepo.updateAppControl(childId, app, enabled);

      // Update local state and notify
      await loadAppControls();
    } catch (e) {
      debugPrint('Error toggling app control: $e');
    }
  }

  // Update sensitivity for an app
  Future<void> setSensitivity(String app, int value) async {
    await LocalStorage.setInt('app_sensitivity_$app', value);
    if (_appData.containsKey(app)) {
      _appData[app] = _appData[app]!.copyWith(sensitivity: value);
      notifyListeners();
    }
  }

  // Update blocking level for an app
  Future<void> setBlocking(String app, int value) async {
    await LocalStorage.setInt('app_blocking_$app', value);
    if (_appData.containsKey(app)) {
      _appData[app] = _appData[app]!.copyWith(blocking: value);
      notifyListeners();
    }
  }

  // Refresh data
  Future<void> refresh() => loadAppControls();

  /// Block an app on the child device
  Future<void> blockApp(String appKey) async {
    try {
      debugPrint('🚫 [APP_CONTROL] Sending block command for $appKey');
      
      // Create a special alert to trigger blocking on child device
      await _networkSync.pushAlert(NetworkAlertFull(
        childName: _children.isNotEmpty ? _children.first.name : 'unknown',
        app: appKey,
        alertType: 'parent_block',
        severity: 'critical',
        aiConfidence: 1.0,
        contentPreview: 'Parent blocked this app',
        scoreText: 1.0,
        scoreImage: 0.0,
        scoreGrooming: 0.0,
        scoreDelta: -10,
        timestamp: DateTime.now(),
      ));
      
      debugPrint('✅ [APP_CONTROL] Block command sent for $appKey');
    } catch (e) {
      debugPrint('❌ [APP_CONTROL] Failed to block app $appKey: $e');
      rethrow;
    }
  }

  /// Unblock an app on the child device
  Future<void> unblockApp(String appKey) async {
    try {
      debugPrint('🔓 [APP_CONTROL] Sending unblock command for $appKey');
      
      // Create a special alert to trigger unblocking on child device
      await _networkSync.pushAlert(NetworkAlertFull(
        childName: _children.isNotEmpty ? _children.first.name : 'unknown',
        app: appKey,
        alertType: 'parent_unblock',
        severity: 'safe',
        aiConfidence: 0.0,
        contentPreview: 'Parent unblocked this app',
        scoreText: 0.0,
        scoreImage: 0.0,
        scoreGrooming: 0.0,
        scoreDelta: 0,
        timestamp: DateTime.now(),
      ));
      
      debugPrint('✅ [APP_CONTROL] Unblock command sent for $appKey');
    } catch (e) {
      debugPrint('❌ [APP_CONTROL] Failed to unblock app $appKey: $e');
      rethrow;
    }
  }

  /// Ping the child device
  Future<void> pingChild() async {
    try {
      debugPrint('🔔 [APP_CONTROL] Sending ping command to child');
      
      final parentName = LocalStorage.getString('parent_name');
      final pName = parentName.isNotEmpty ? parentName : 'Parent';
      
      await _networkSync.pushAlert(NetworkAlertFull(
        childName: _children.isNotEmpty ? _children.first.name : 'unknown',
        app: 'system',
        alertType: 'parent_ping',
        severity: 'info',
        aiConfidence: 0.0,
        contentPreview: pName, // Send parent name in contentPreview
        scoreText: 0.0,
        scoreImage: 0.0,
        scoreGrooming: 0.0,
        scoreDelta: 0,
        timestamp: DateTime.now(),
      ));
      
      debugPrint('✅ [APP_CONTROL] Ping command sent');
    } catch (e) {
      debugPrint('❌ [APP_CONTROL] Failed to ping child: $e');
      rethrow;
    }
  }
}

// Data class for app control info
class AppControlData {
  final String name;
  final int alerts;
  final int blocks;
  final bool enabled;
  final int sensitivity;
  final int blocking;

  AppControlData({
    required this.name,
    required this.alerts,
    required this.blocks,
    required this.enabled,
    required this.sensitivity,
    required this.blocking,
  });

  AppControlData copyWith({
    String? name,
    int? alerts,
    int? blocks,
    bool? enabled,
    int? sensitivity,
    int? blocking,
  }) {
    return AppControlData(
      name: name ?? this.name,
      alerts: alerts ?? this.alerts,
      blocks: blocks ?? this.blocks,
      enabled: enabled ?? this.enabled,
      sensitivity: sensitivity ?? this.sensitivity,
      blocking: blocking ?? this.blocking,
    );
  }
}
