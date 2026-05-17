// parent/services/dashboard_data_service.dart — Dashboard data provider
// Provides real data from repositories + remote alerts from network

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'dart:async' as async;
import 'package:kova/local_backend/repositories/child_repository.dart';
import 'package:kova/local_backend/repositories/alert_repository.dart';
import 'package:kova/shared/models/network_alert.dart';
import 'package:kova/shared/services/local_storage.dart';
import 'package:kova/shared/services/network_sync_service.dart';
import 'package:kova/shared/services/notification_service.dart';
import 'package:kova/parent/services/parent_permission_service.dart';

// Re-export ChildModel for consumers of this service
export 'package:kova/local_backend/repositories/child_repository.dart' show ChildModel;

class DashboardDataService extends ChangeNotifier {
  static final DashboardDataService instance = DashboardDataService._internal();
  factory DashboardDataService() => instance;
  DashboardDataService._internal();

  final _childRepo = ChildRepository();
  final _alertRepo = AlertRepository();
  final _networkSync = NetworkSyncService();

  StreamSubscription? _alertSub;
  StreamSubscription? _connectionSub;

  // ─── Child List Changed Stream (DIRECTIVE 3) ─────────────────────────────
  // Fires when a new child is added so dashboard refreshes immediately
  final _childListChangedController = async.StreamController<void>.broadcast();
  async.Stream<void> get onChildListChanged => _childListChangedController.stream;

  /// Notify listeners that child list has changed
  void notifyChildListChanged() {
    _childListChangedController.add(null);
    // Also reload data immediately
    loadDashboardData();
  }

  List<ChildModel>? _children;
  List<AlertModel>? _alerts;
  String? _parentName;
  String? _activeChildId;
  bool _loading = false;
  String? _error;
  NetworkConnectionState _connectionState = NetworkConnectionState.none;

  // Getters matching what DashboardScreen expects
  List<ChildModel>? get children => _children;
  List<AlertModel>? get alerts => _alerts;
  String? get parentName => _parentName ?? 'Parent';
  bool get loading => _loading;
  String? get error => _error;
  NetworkConnectionState get connectionState => _connectionState;
  bool get isLanConnected => _connectionState == NetworkConnectionState.lan;
  bool get isInternetConnected => _connectionState == NetworkConnectionState.internet;

  // Active child (use stored active child or first child)
  ChildModel? get activeChild {
    if (_children == null || _children!.isEmpty) return null;
    if (_activeChildId != null) {
      try {
        return _children!.firstWhere((c) => c.id == _activeChildId);
      } catch (_) {
        return _children!.first;
      }
    }
    return _children!.first;
  }

  // Dashboard metrics
  int get alertCount => _alerts?.where((a) => !a.read).length ?? 0;

  int get safetyScore {
    if (_children == null || _children!.isEmpty) return 100;
    final scores = _children!.map((c) => c.score).toList();
    final avgScore = scores.reduce((a, b) => a + b) / scores.length;
    return avgScore.toInt();
  }

  double get avgAiScore {
    if (_alerts == null || _alerts!.isEmpty) return 0.0;
    final totalScore = _alerts!.fold<double>(0.0, (sum, alert) => 
        sum + (alert.scoreText + alert.scoreImage + alert.scoreGrooming) / 3);
    return (totalScore / _alerts!.length * 100);
  }

  bool get hasAlerts => alertCount > 0;

  /// Initialize and start listening for remote alerts
  void startListening() {
    // Eagerly load data so alerts can be matched to children immediately
    loadDashboardData();
    
    // Start foreground service to keep parent app alive to receive alerts
    ParentPermissionService.startParentProtectionService();

    debugPrint('✅ [PARENT] onAlertReceived subscription active');

    // Listen for alerts from network (both LAN and Vercel relay)
    _alertSub = _networkSync.onAlertReceived.listen((alert) async {
      debugPrint('🔔 [PARENT] Alert received via LAN!');
      debugPrint('  severity = ${alert.severity}');
      debugPrint('  app      = ${alert.app}');

      await _handleRemoteAlert(alert);
    });

    debugPrint('✅ [PARENT] onAlertReceived listener active');

    // Listen for connection state changes
    _connectionSub = _networkSync.onConnectionStateChanged.listen((state) {
      _connectionState = state;
      notifyListeners();
      if (kDebugMode) debugPrint('🌐 Dashboard connection: ${state.name}');
    });
  }

  /// Handle an alert received from a remote child device
  Future<void> _handleRemoteAlert(NetworkAlertSummary alert) async {
    try {
      // Ensure children are loaded before processing alerts
      if (_children == null || _children!.isEmpty) {
        await loadDashboardData();
      }

      // Find the child this alert belongs to
      var child = activeChild;
      if (child == null) {
        // Last resort: read directly from DB
        final freshChildren = await _childRepo.getAll();
        if (freshChildren.isEmpty) {
          if (kDebugMode) debugPrint('⚠️ Alert received but no children registered — dropping');
          return;
        }
        _children = freshChildren;
        child = freshChildren.first;
      }

      // Save alert to local database
      final alertId = await _alertRepo.create(
        childId: child.id,
        app: alert.app,
        type: alert.alertType,
        severity: alert.severity,
        scoreText: alert is NetworkAlertFull ? alert.scoreText : 0.0,
        scoreImage: alert is NetworkAlertFull ? alert.scoreImage : 0.0,
        scoreGrooming: alert is NetworkAlertFull ? alert.scoreGrooming : 0.0,
      );

      // 3. Show system notification — CRITICAL for parent awareness
      try {
        final severity = alert.severity;
        final app = alert.app;
        final childName = child.name;

        final title = switch (severity) {
          'critical' => '🚨 ALERTE CRITIQUE — $childName',
          'high'     => '⚠️ Contenu dangereux — $childName',
          'medium'   => '⚡ Contenu suspect — $childName',
          _          => 'KOVA — Alerte pour $childName',
        };

        final String body;
        if (alert is NetworkAlertFull && alert.contentPreview.isNotEmpty) {
          body = 'Activité suspecte sur $app: "${alert.contentPreview}"';
        } else {
          body = 'Activité suspecte détectée sur $app. Vérifiez maintenant.';
        }

        await NotificationService.showAlert(title, body, alertId: alertId);
        debugPrint('🔔 [PARENT] Notification shown: $title');
      } catch (e) {
        debugPrint('❌ [PARENT] Failed to show notification: $e');
      }

      // Refresh dashboard data
      await loadDashboardData();

      if (kDebugMode) {
        final via = _connectionState == NetworkConnectionState.lan ? "LAN" : "internet";
        debugPrint('📥 Remote alert saved: $alertId (via $via)');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Failed to process remote alert: $e');
    }
  }

  // Load all dashboard data
  Future<void> loadDashboardData() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      // Load children from repository
      _children = await _childRepo.getAll();

      // Load alerts from repository
      _alerts = await _alertRepo.getAll();

      // Load parent name from local storage
      _parentName = LocalStorage.getString('parent_name');

      _error = null;
    } catch (e) {
      _error = 'Error loading dashboard: $e';
      debugPrint(_error);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  // Refresh dashboard data
  Future<void> refresh() => loadDashboardData();

  // Update parent name
  Future<void> updateParentName(String name) async {
    await LocalStorage.setString('parent_name', name);
    _parentName = name;
    notifyListeners();
  }

  // Update child profile (name and age)
  Future<void> updateChildProfile(String childId, String name, int age) async {
    await _childRepo.updateName(childId, name);
    await _childRepo.updateAge(childId, age);
    // Reload to reflect changes
    await loadDashboardData();
  }

  // Delete a child and all associated data
  Future<void> deleteChild(String childId) async {
    await _childRepo.delete(childId);
    // If deleted child was active, clear the active child
    if (_activeChildId == childId) {
      _activeChildId = null;
      await LocalStorage.remove('child_id');
    }
    // Reload to reflect changes
    await loadDashboardData();
  }

  // Update active child
  Future<void> setActiveChild(String childId) async {
    _activeChildId = childId;
    await LocalStorage.setChildId(childId);
    notifyListeners();
  }

  // Get child by ID
  ChildModel? getChildById(String id) {
    if (_children == null) return null;
    try {
      return _children!.firstWhere((c) => c.id == id);
    } catch (e) {
      return null;
    }
  }

  @override
  void dispose() {
    _alertSub?.cancel();
    _connectionSub?.cancel();
    _childListChangedController.close();
    super.dispose();
  }
}
