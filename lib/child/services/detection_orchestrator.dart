// child/services/detection_orchestrator.dart — Master coordinator for all detection services
// Real implementation using TextAnalyzer, ContextDetector, SeverityEngine

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:kova/core/app_mode.dart';
import 'package:kova/local_backend/repositories/child_repository.dart';
import 'package:kova/local_backend/repositories/alert_repository.dart';
import 'package:kova/local_backend/repositories/browser_history_repository.dart';
import 'package:kova/shared/models/network_alert.dart';
import 'package:kova/shared/models/web_history.dart';
import 'dart:convert';
import 'dart:async';
import 'package:kova/shared/services/notification_service.dart';
import 'package:kova/shared/services/local_storage.dart';
import 'package:kova/local_backend/repositories/pending_sync_repository.dart';
import 'package:kova/shared/models/pending_sync.dart';
import 'package:kova/shared/services/network_sync_service.dart';

import 'context_detector.dart';
import 'severity_engine.dart';
import 'monitoring_bridge.dart';
import 'tflite_analyzer_service.dart';
import 'text_analyzer.dart';

/// Master service that coordinates all detection and alerting
/// Only active when mode == AppMode.child
class DetectionOrchestrator {
  static final DetectionOrchestrator instance = DetectionOrchestrator._internal();
  DetectionOrchestrator._internal();

  final ChildRepository _childRepo = ChildRepository();
  final AlertRepository _alertRepo = AlertRepository();
  final BrowserHistoryRepository _browserRepo = BrowserHistoryRepository();
  final NetworkSyncService _networkSync = NetworkSyncService();
  final PendingSyncRepository _pendingSyncRepo = PendingSyncRepository();
  final ContextDetector _contextDetector = ContextDetector();
  final TfLiteAnalyzerService _tfLiteAnalyzer = TfLiteAnalyzerService();
  
  final _alertStreamController = StreamController<AlertModel>.broadcast();
  Stream<AlertModel> get onNewAlert => _alertStreamController.stream;
  
  StreamSubscription<NetworkAlertSummary>? _networkAlertSub;
  
  bool _active = false;
  String? _childId;
  String? _lastUrl;
  DateTime? _lastUrlTimestamp;

  /// In-memory cache of blocked app keys — avoids DB reads on every window_changed
  final Set<String> _blockedApps = {};

  /// Cached child model — avoids DB reads on every message (major latency fix)
  dynamic _cachedChild;
  DateTime? _childCacheTime;

  /// Start detection services
  Future<void> start() async {
    if (_active) return;
    
    // Get child ID
    _childId = await AppModeManager.getChildId();
    if (_childId == null) {
      if (kDebugMode) debugPrint('❌ DetectionOrchestrator: No child ID found');
      return;
    }

    _active = true;

    // Initialize ML model
    await _tfLiteAnalyzer.init();

    // Populate the blocked-app cache from the database
    try {
      final persisted = await _childRepo.getBlockedApps(_childId!);
      _blockedApps.addAll(persisted);
      if (kDebugMode && persisted.isNotEmpty) {
        debugPrint('🔒 Loaded ${persisted.length} blocked apps from DB: $persisted');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Failed to load blocked apps cache: $e');
    }

    // Set up bridge callbacks for all 3 channels + tamper
    MonitoringBridge.onContent = _processContent;
    MonitoringBridge.onConversation = _processConversation;
    MonitoringBridge.onMetadata = _processMetadata;
    MonitoringBridge.onTamper = _processTamper;
    MonitoringBridge.onBrowserContent = _processBrowserContent;
    
    // Pre-cache child model so first detection is instant
    _cachedChild = await _childRepo.getById(_childId!);
    _childCacheTime = DateTime.now();

    // Listen for parent-initiated block/unblock commands
    _networkAlertSub?.cancel();
    _networkAlertSub = _networkSync.onAlertReceived.listen((alert) {
      if (!_active) return;
      if (alert.alertType == 'parent_block' && alert.app != null) {
        debugPrint('🚫 [CHILD/BG] Received parent block command for ${alert.app}');
        safeBlockApp(alert.app!);
      } else if (alert.alertType == 'parent_unblock' && alert.app != null) {
        debugPrint('🔓 [CHILD/BG] Received parent unblock command for ${alert.app}');
        unblockApp(alert.app!);
      }
    });

    // Initialize bridge (registers handlers on 3 channels)
    MonitoringBridge.init();

    if (kDebugMode) debugPrint('🛡️ KOVA Detection Orchestrator: ACTIVE (${_blockedApps.length} apps blocked)');
  }

  /// Stop detection services
  void stop() {
    _active = false;
    _blockedApps.clear();
    _cachedChild = null;
    _childCacheTime = null;
    _networkAlertSub?.cancel();
    _tfLiteAnalyzer.close();
    MonitoringBridge.reset();
    
    // Don't close the stream controller if already closed
    if (!_alertStreamController.isClosed) {
      _alertStreamController.close();
    }
    
    if (kDebugMode) debugPrint('🛑 KOVA Detection Orchestrator: STOPPED');
  }

  /// Dispose resources - call when app is shutting down
  void dispose() {
    stop();
    if (kDebugMode) debugPrint('🗑️ KOVA Detection Orchestrator: DISPOSED');
  }

  /// Get child model from cache (refreshes every 60 seconds)
  Future<dynamic> _getChild() async {
    // CRITICAL FIX: Check _childId is not null
    if (_childId == null) {
      debugPrint('❌ Cannot get child: _childId is null');
      return null;
    }

    final now = DateTime.now();
    if (_cachedChild != null && _childCacheTime != null &&
        now.difference(_childCacheTime!).inSeconds < 60) {
      return _cachedChild;
    }
    _cachedChild = await _childRepo.getById(_childId!);
    _childCacheTime = now;
    return _cachedChild;
  }

  /// Merge TFLite and keyword scores by taking the max of each field.
  /// This ensures detection works even when TFLite fails to initialize.
  Map<String, dynamic> _mergeScores(
    Map<String, dynamic> tfliteScores,
    Map<String, double> keywordScores,
  ) {
    double max(String key) {
      final a = (tfliteScores[key] as num?)?.toDouble() ?? 0.0;
      final b = keywordScores[key] ?? 0.0;
      return a > b ? a : b;
    }

    final unsafe   = max('unsafe');
    final sexual   = max('sexual');
    final grooming = max('grooming');
    final violence = max('violence');
    final unsafeSubstances = max('unsafe_substances');
    final personalInfo     = max('personal_info');

    return {
      'unsafe':            unsafe,
      'safe':              (1.0 - unsafe).clamp(0.0, 1.0),
      'sexual':            sexual,
      'grooming':          grooming,
      'violence':          violence,
      'unsafe_substances': unsafeSubstances,
      'personal_info':     personalInfo,
      'detected_keywords': keywordScores['detected_keywords'] ?? 0.0,
    };
  }

  /// Process single content from monitoring services
  /// direction = 'incoming' (notification) or 'outgoing' (keyboard)
  Future<void> _processContent(
    String app,
    String text,
    String source,
    String direction,
    String conversationId,
    String? senderName,
  ) async {
    if (!_active || _childId == null) return;

    // Use cached child model — avoids blocking DB read on every message
    final child = await _getChild();
    if (child == null) return;

    final appKey = _normalizeAppName(app);
    final isEnabled = child.appControls[appKey] ?? true;
    if (!isEnabled) {
      if (kDebugMode) debugPrint('⏸️ Monitoring disabled for $appKey');
      return;
    }

    // Add to conversation context with direction info
    _contextDetector.addMessage(
      conversationId,
      text,
      sender: direction == 'outgoing' ? 'child' : senderName,
    );

    // Analyze with both engines and merge (max-wins strategy)
    // TextAnalyzer runs first — it's synchronous and always works offline.
    // TFLite runs second — improves confidence when model is loaded.
    final keywordScores = TextAnalyzer.analyze(text);
    final tfliteScores  = await _tfLiteAnalyzer.analyzeText(text);
    final textScores    = _mergeScores(tfliteScores, keywordScores);

    if (kDebugMode) {
      debugPrint('🔍 [$app] keyword_unsafe=${keywordScores["unsafe"]?.toStringAsFixed(2)} '
          'tflite_unsafe=${(tfliteScores["unsafe"] as num?)?.toStringAsFixed(2)} '
          'merged_unsafe=${(textScores["unsafe"] as num?)?.toStringAsFixed(2)}');
    }

    final contextResult = _contextDetector.analyze(conversationId);

    // Calculate severity
    final severity = SeverityEngine.calculate(
      textScores: textScores,
      contextScores: contextResult,
    );

    // Always log detection details (not just in debug mode)
    debugPrint('🔍 [$app] dir=$direction severity=$severity text=${textScores['unsafe']?.toStringAsFixed(2)} ctx=${contextResult['grooming_risk']?.toStringAsFixed(2)}');
    debugPrint('   └─ sexual=${textScores['sexual']?.toStringAsFixed(2)} grooming=${textScores['grooming']?.toStringAsFixed(2)} violence=${textScores['violence']?.toStringAsFixed(2)}');
    debugPrint('   └─ ctxPattern=${contextResult['pattern']} indicators=${contextResult['indicators']}');
    debugPrint('   └─ contentPreview: "${text.length > 50 ? '${text.substring(0, 50)}...' : text}"');

    // Skip safe content
    if (severity == 'safe') return;

    // Update child score
    final delta = SeverityEngine.scoreDelta(severity);
    await _childRepo.updateScore(_childId!, delta);

    // Create alert
    final alertType = SeverityEngine.getType(
      textScores: textScores,
      contextScores: contextResult,
    );

    // Create alert with retry logic to prevent SQLite database_is_locked concurrency crashes
    String alertId = '';
    for (int retry = 0; retry < 3; retry++) {
      try {
        alertId = await _alertRepo.create(
          childId: _childId!,
          app: appKey,
          type: alertType,
          severity: severity,
          scoreText: textScores['unsafe'] ?? 0.0,
          scoreImage: 0.0,
          scoreGrooming: (contextResult['grooming_risk'] as num?)?.toDouble() ?? 0.0,
          contentPreview: text.length > 200 ? '${text.substring(0, 200)}...' : text,
        );
        break; // Success
      } catch (e) {
        if (retry == 2) {
          debugPrint('❌ Failed to create alert after 3 retries: $e');
          return; // Give up
        }
        await Future.delayed(Duration(milliseconds: 100 * (retry + 1))); // Backoff
      }
    }

    // CRITICAL FIX: Check _childId is not null before using
    if (_childId == null) {
      debugPrint('❌ Cannot create alert: _childId is null');
      return;
    }

    _alertStreamController.add(AlertModel(
      id: alertId,
      childId: _childId!,
      app: appKey,
      type: alertType,
      severity: severity,
      scoreText: textScores['unsafe'] ?? 0.0,
      scoreImage: 0.0,
      scoreGrooming: (contextResult['grooming_risk'] as num?)?.toDouble() ?? 0.0,
      contentPreview: text.length > 200 ? '${text.substring(0, 200)}...' : text,
      read: false,
      resolved: false,
      createdAt: DateTime.now(),
    ));

    // Show notification only for medium+ severity (not low)
    if (severity != 'low' && severity != 'safe') {
      await _showAlertNotification(appKey, severity, alertId, text);
    }

    // For critical only: await delivery BEFORE blocking so crash can't kill the alert
    // HIGH severity also gets immediate sync but no blocking overlay
    if (severity == 'critical' || severity == 'high') {
      await _pushAlertToNetwork(
        severity: severity,
        app: appKey,
        alertType: alertType,
        aiConfidence: textScores['unsafe'] ?? 0.0,
        contentPreview: text.length > 200 ? '${text.substring(0, 200)}...' : text,
        scoreText: textScores['unsafe'] ?? 0.0,
        scoreGrooming: (contextResult['grooming_risk'] as num?)?.toDouble() ?? 0.0,
        scoreDelta: delta,
        immediateSync: true,
      );
      debugPrint('✅ [ALERT PIPELINE] Alert delivered to parent before blocking action');
    } else {
      _pushAlertToNetwork(
        severity: severity,
        app: appKey,
        alertType: alertType,
        aiConfidence: textScores['unsafe'] ?? 0.0,
        contentPreview: text.length > 200 ? '${text.substring(0, 200)}...' : text,
        scoreText: textScores['unsafe'] ?? 0.0,
        scoreGrooming: (contextResult['grooming_risk'] as num?)?.toDouble() ?? 0.0,
        scoreDelta: delta,
        immediateSync: false,
      );
    }

    // Handle CRITICAL severity only - block AFTER alert is delivered
    // User wants overlay ONLY for optimum danger (critical), not high/medium/low
    if (severity == 'critical') {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (!_active) return; // Check if still active
        try {
          safeBlockApp(appKey);
        } catch (e) {
          debugPrint('⚠️ [BLOCK] Failed to block app $appKey: $e');
        }
      });
    }

    if (kDebugMode) debugPrint('🚨 Alert created: $alertId');
  }

  /// Process conversation batch
  Future<void> _processConversation(
    String app,
    List<Map<String, dynamic>> messages,
    String? senderName,
  ) async {
    if (!_active || _childId == null || messages.isEmpty) return;

    // Use cached child model — avoids blocking DB read
    final child = await _getChild();
    if (child == null) return;

    final appKey = _normalizeAppName(app);
    final isEnabled = child.appControls[appKey] ?? true;
    if (!isEnabled) return;

    // Extract texts for analysis
    final texts = messages
        .map((m) => m['text']?.toString() ?? '')
        .where((t) => t.isNotEmpty)
        .toList();

    if (texts.isEmpty) return;

    // Batch analyze with both engines and merge
    final tfliteBatch  = await _tfLiteAnalyzer.analyzeBatch(texts);
    final keywordBatch = TextAnalyzer.analyzeBatch(texts);
    final batchResult  = _mergeScores(
      tfliteBatch,
      Map<String, double>.fromEntries(
        keywordBatch.entries
            .where((e) => e.value is num)
            .map((e) => MapEntry(e.key, (e.value as num).toDouble())),
      ),
    );
    final conversationId = '${appKey}_$_childId';
    
    // Add all messages to context
    for (final msg in messages) {
      _contextDetector.addMessage(
        conversationId,
        msg['text']?.toString() ?? '',
        sender: msg['sender']?.toString(),
      );
    }
    
    final contextResult = _contextDetector.analyze(conversationId);

    // Calculate severity
    final severity = SeverityEngine.calculate(
      textScores: batchResult,
      contextScores: contextResult,
    );

    if (severity == 'safe') return;

    // Update score
    final delta = SeverityEngine.scoreDelta(severity);
    await _childRepo.updateScore(_childId!, delta);

    // Create alert
    final alertType = SeverityEngine.getType(
      textScores: batchResult,
      contextScores: contextResult,
    );

    final alertId = await _alertRepo.create(
      childId: _childId!,
      app: appKey,
      type: alertType,
      severity: severity,
      scoreText: batchResult['unsafe'] ?? 0.0,
      scoreImage: 0.0,
      scoreGrooming: (contextResult['grooming_risk'] as num?)?.toDouble() ?? 0.0,
      contentPreview: texts.take(3).join(' | ').length > 200
          ? '${texts.take(3).join(' | ').substring(0, 200)}...'
          : texts.take(3).join(' | '),
    );

    // CRITICAL FIX: Check _childId is not null before using
    if (_childId == null) {
      debugPrint('❌ Cannot create conversation alert: _childId is null');
      return;
    }

    _alertStreamController.add(AlertModel(
      id: alertId,
      childId: _childId!,
      app: appKey,
      type: alertType,
      severity: severity,
      scoreText: batchResult['unsafe'] ?? 0.0,
      scoreImage: 0.0,
      scoreGrooming: (contextResult['grooming_risk'] as num?)?.toDouble() ?? 0.0,
      contentPreview: texts.take(3).join(' | ').length > 200
          ? '${texts.take(3).join(' | ').substring(0, 200)}...'
          : texts.take(3).join(' | '),
      read: false,
      resolved: false,
      createdAt: DateTime.now(),
    ));

    // Show notification only for medium+ severity (not low)
    if (severity != 'low' && severity != 'safe') {
      await _showAlertNotification(appKey, severity, alertId, 'Conversation batch');
    }

    // For critical/high: await delivery BEFORE blocking so crash can't kill the alert
    if (severity == 'critical' || severity == 'high') {
      await _pushAlertToNetwork(
        severity: severity,
        app: appKey,
        alertType: alertType,
        aiConfidence: batchResult['unsafe'] ?? 0.0,
        contentPreview: texts.take(3).join(' | '),
        scoreText: batchResult['unsafe'] ?? 0.0,
        scoreGrooming: (contextResult['grooming_risk'] as num?)?.toDouble() ?? 0.0,
        scoreDelta: delta,
        immediateSync: true,
      );
      debugPrint('✅ [ALERT PIPELINE] Alert delivered to parent before blocking action');
    } else {
      _pushAlertToNetwork(
        severity: severity,
        app: appKey,
        alertType: alertType,
        aiConfidence: batchResult['unsafe'] ?? 0.0,
        contentPreview: texts.take(3).join(' | '),
        scoreText: batchResult['unsafe'] ?? 0.0,
        scoreGrooming: (contextResult['grooming_risk'] as num?)?.toDouble() ?? 0.0,
        scoreDelta: delta,
        immediateSync: false,
      );
    }

    // Handle CRITICAL severity only - block AFTER alert is delivered
    // User wants overlay ONLY for optimum danger (critical), not high/medium/low
    if (severity == 'critical') {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (!_active) return; // Check if still active
        safeBlockApp(appKey).catchError((e) {
          debugPrint('⚠️ [CONVERSATION BLOCK] Failed: $e');
        });
      });
    }

    if (kDebugMode) debugPrint('🚨 Conversation alert created: $alertId');
  }

  /// Process metadata from accessibility service
  /// Tracks which apps the child navigates to AND enforces active blocks
  void _processMetadata(
    String event,
    String app,
    Map<String, dynamic> data,
  ) {
    if (!_active) return;

    if (event == 'window_changed') {
      final appKey = _normalizeAppName(app);
      final windowType = data['windowType'] as String? ?? 'other';

      if (kDebugMode) {
        debugPrint('🪟 Child navigated to $appKey ($windowType)');
      }

      // ── LOCKING LOOP: If this app is in the blocked cache, re-block immediately ──
      if (_blockedApps.contains(appKey)) {
        if (kDebugMode) {
          debugPrint('🔒 BLOCKED APP DETECTED: $appKey — re-triggering block overlay');
        }
        // Fire-and-forget with safety wrapper
        safeBlockApp(appKey).catchError((e) {
          debugPrint('⚠️ [METADATA] Non-fatal block error: $e');
        });
        return;
      }

      // Also check against the raw package name for apps not yet normalized
      final rawPkg = app.toLowerCase();
      for (final blocked in _blockedApps) {
        final pkg = _appKeyToPackage(blocked);
        if (pkg != null && rawPkg == pkg) {
          if (kDebugMode) {
            debugPrint('🔒 BLOCKED PKG DETECTED: $rawPkg — re-triggering block overlay');
          }
          // Fire-and-forget with safety wrapper
          safeBlockApp(blocked).catchError((e) {
            debugPrint('⚠️ [METADATA] Non-fatal block error: $e');
          });
          return;
        }
      }
    }
  }

  // ─────────────────────────────────────────────
  // Web History Logging
  // ─────────────────────────────────────────────

  Future<void> _processBrowserContent(String app, String url, String title) async {
    if (!_active || _childId == null) return;
    
    // Debounce: don't log the exact same URL within 10 seconds
    final now = DateTime.now();
    if (_lastUrl == url && _lastUrlTimestamp != null) {
      if (now.difference(_lastUrlTimestamp!).inSeconds < 10) {
        return;
      }
    }
    
    _lastUrl = url;
    _lastUrlTimestamp = now;

    if (kDebugMode) {
      debugPrint('📚 Saving to Web History: $url ($title)');
    }

    final history = WebHistory(url: url, title: title, createdAt: now);

    // Save locally
    await _browserRepo.insert(history);

    // Queue for sync instead of pushing directly
    final pendingItem = PendingSync(
      id: 'hist_${now.millisecondsSinceEpoch}',
      type: 'history',
      payload: jsonEncode(history.toJson()),
    );
    await _pendingSyncRepo.insert(pendingItem);
  }

  // ─────────────────────────────────────────────
  // Tamper detection — self-defense alerts
  // ─────────────────────────────────────────────

  /// Handle tamper events from the native watchdog / accessibility service.
  /// These are ALWAYS critical severity — immediately alert the parent.
  Future<void> _processTamper(
    String type,
    String message,
    Map<String, dynamic> data,
  ) async {
    if (!_active || _childId == null) return;

    if (kDebugMode) {
      debugPrint('🛡️ TAMPER DETECTED: $type → $message');
    }

    // Map tamper type to human-readable description
    final descriptions = {
      'uninstall_attempt': 'Attempted to uninstall KOVA',
      'service_disable_attempt': 'Attempted to disable KOVA services',
      'accessibility_disabled': 'Accessibility service was disabled',
      'notification_listener_disabled': 'Notification listener was disabled',
      'keyboard_disabled': 'KOVA keyboard was disabled or switched',
      'device_admin_disabled': 'Device admin was deactivated',
    };

    final description = descriptions[type] ?? message;

    // 1. Store critical alert locally
    final alertId = await _alertRepo.create(
      childId: _childId!,
      app: 'kova_self_defense',
      type: 'tamper_$type',
      severity: 'critical',
      scoreText: 1.0,
      scoreImage: 0.0,
      scoreGrooming: 0.0,
    );

    // CRITICAL FIX: Check _childId is not null before using
    if (_childId == null) {
      debugPrint('❌ Cannot create tamper alert: _childId is null');
      return;
    }

    _alertStreamController.add(AlertModel(
      id: alertId,
      childId: _childId!,
      app: 'kova_self_defense',
      type: 'tamper_$type',
      severity: 'critical',
      scoreText: 1.0,
      scoreImage: 0.0,
      scoreGrooming: 0.0,
      read: false,
      resolved: false,
      createdAt: DateTime.now(),
    ));

    // 2. Push to parent immediately
    await _pushAlertToNetwork(
      severity: 'critical',
      app: 'kova_self_defense',
      alertType: 'tamper_$type',
      aiConfidence: 1.0,
      contentPreview: description,
    );

    // 3. Send local notification
    await NotificationService.showCriticalAlert(
      '🛡️ Tamper Alert',
      description,
    );
  }

  /// Push alert to parent device via network (LAN or Internet)
  /// If [immediateSync] is true, calls pushAlert directly instead of just queuing.
  Future<void> _pushAlertToNetwork({
    required String severity,
    required String app,
    required String alertType,
    required double aiConfidence,
    String? contentPreview,
    double scoreText = 0.0,
    double scoreGrooming = 0.0,
    int scoreDelta = 0,
    bool immediateSync = false,
  }) async {
    print('📤 [ALERT PIPELINE] Step 2: _pushAlertToNetwork started - app=$app, severity=$severity');
    try {
      final childName = LocalStorage.getString('child_name', 'Child');

      final alert = NetworkAlertFull(
        severity: severity,
        app: app,
        alertType: alertType,
        childName: childName,
        timestamp: DateTime.now(),
        aiConfidence: aiConfidence,
        contentPreview: contentPreview,
        scoreText: scoreText,
        scoreGrooming: scoreGrooming,
        scoreDelta: scoreDelta,
      );

      // We explicitly construct Summary here just in case, but really
      // NetworkSyncService used to do this. We'll just serialize it as NetworkAlertSummary
      // to the queue so it takes less space and is ready for Vercel.
      // Wait, LAN might want full data. 
      // If we put full data in the queue, NetworkSyncService can downcast it when sending to Vercel.
      final pendingItem = PendingSync(
        id: 'alert_${DateTime.now().millisecondsSinceEpoch}',
        type: 'alert',
        payload: jsonEncode(alert.toJson()),
      );
      await _pendingSyncRepo.insert(pendingItem);

      // For critical/high severity, push immediately instead of waiting for sync loop
      if (immediateSync) {
        print('📤 [ALERT PIPELINE] Step 3: IMMEDIATE sync for $severity alert...');
        try {
          await _networkSync.pushAlert(alert, pendingItem.id);
        } catch (e) {
          print('⚠️ [ALERT PIPELINE] Immediate push failed, sync loop will retry: $e');
        }
      } else {
        // Trigger sync manually (periodic loop will also handle it)
        print('📤 [ALERT PIPELINE] Step 3: Triggering network sync loop...');
        _networkSync.triggerSyncLoop();
      }

      print('✅ [ALERT PIPELINE] Step 4: Alert queued and sync triggered');
      if (kDebugMode) debugPrint('📤 Alert queued for network push');
    } catch (e) {
      print('❌ [ALERT PIPELINE] ERROR in _pushAlertToNetwork: $e');
      if (kDebugMode) debugPrint('⚠️ Network push failed (local alert saved): $e');
    }
  }

  // ─────────────────────────────────────────────
  // Package name mapping (shared by _blockApp & _appKeyToPackage)
  // ─────────────────────────────────────────────
  static const Map<String, String> _pkgMap = {
    // Messaging
    'whatsapp': 'com.whatsapp',
    'whatsapp_business': 'com.whatsapp.w4b',
    'facebook': 'com.facebook.katana',
    'messenger': 'com.facebook.orca',
    'messenger_lite': 'com.facebook.mlite',
    'tiktok': 'com.zhiliaoapp.musically',
    'instagram': 'com.instagram.android',
    'telegram': 'org.telegram.messenger',
    'signal': 'org.thoughtcrime.securesms',
    'twitter': 'com.twitter.android',
    'discord': 'com.discord',
    'snapchat': 'com.snapchat.android',
    'skype': 'com.skype.raider',
    'viber': 'com.viber.voip',
    'sms': 'com.google.android.apps.messaging',
    'samsung_messages': 'com.samsung.android.messaging',
    // Browsers
    'chrome': 'com.android.chrome',
    'firefox': 'org.mozilla.firefox',
    'brave': 'com.brave.browser',
    'opera': 'com.opera.browser',
    'edge': 'com.microsoft.emmx',
    'duckduckgo': 'com.duckduckgo.mobile.android',
    'samsung_browser': 'com.sec.android.app.sbrowser',
    'kiwi': 'com.kiwibrowser.browser',
    // Search & Video
    'youtube': 'com.google.android.youtube',
    'google': 'com.google.android.googlequicksearchbox',
  };

  /// Resolve an app key to its Android package name
  String? _appKeyToPackage(String appKey) => _pkgMap[appKey];

  /// Block an app using native blocker, persist to DB + in-memory cache
  Future<void> _blockApp(String app) async {
    final pkg = _pkgMap[app];
    if (pkg == null) return;

    // ── 1. Add to in-memory cache immediately (instant enforcement) ──
    _blockedApps.add(app);

    // ── 2. Persist to database (survives restart) ──
    if (_childId != null) {
      try {
        await _childRepo.setAppBlocked(_childId!, app, true);
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ Failed to persist block for $app: $e');
      }
    }

    // ── 3. Trigger native overlay via ForegroundService FIRST ──
    // The service is always running and can launch activities even when
    // the Flutter engine / MainActivity is backgrounded or dead.
    // This fixes the "black flash then disappear" bug caused by MethodChannel
    // silently failing when the engine isn't in foreground.
    bool launched = false;
    try {
      const platform = MethodChannel('com.kova.child/setup');
      await platform.invokeMethod('blockAppViaService', {'pkg': pkg});
      launched = true;
      if (kDebugMode) debugPrint('🚫 App blocked via ForegroundService: $app ($pkg)');
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ ForegroundService block failed: $e');
    }

    // Fallback: MethodChannel direct (only if service path failed)
    if (!launched) {
      try {
        const channel = MethodChannel('com.kova.child/blocker');
        await channel.invokeMethod('blockApp', {'pkg': pkg});
        if (kDebugMode) debugPrint('🚫 App blocked via MethodChannel fallback: $app ($pkg)');
      } catch (e) {
        if (kDebugMode) debugPrint('❌ Both block paths failed for $app: $e');
      }
    }
  }

  /// SAFER version of _blockApp with proper error handling and retry logic
  /// This prevents crashes on MIUI and other OEM skins
  /// PUBLIC: Can be called from accessibility bridge
  Future<void> safeBlockApp(String app) async {
    final pkg = _pkgMap[app];
    if (pkg == null) {
      debugPrint('⚠️ [BLOCK] No package mapping for app: $app');
      return;
    }

    // Add to in-memory cache immediately
    _blockedApps.add(app);

    // Persist to database
    if (_childId != null) {
      try {
        await _childRepo.setAppBlocked(_childId!, app, true);
        debugPrint('✅ [BLOCK] App $app blocked in database');
      } catch (e) {
        debugPrint('⚠️ [BLOCK] Failed to persist block for $app: $e');
        // Continue even if DB fails - in-memory cache is still active
      }
    }

    // Try to show overlay with retry logic
    int attempts = 0;
    const maxAttempts = 3;

    while (attempts < maxAttempts) {
      try {
        const platform = MethodChannel('com.kova.child/setup');
        await platform.invokeMethod('blockAppViaService', {'pkg': pkg});
        debugPrint('🚫 [BLOCK] Successfully blocked app via ForegroundService: $app');
        return; // Success - exit
      } catch (e) {
        attempts++;
        debugPrint('⚠️ [BLOCK] Attempt $attempts/$maxAttempts failed: $e');
        if (attempts < maxAttempts) {
          await Future.delayed(Duration(milliseconds: 300 * attempts));
        }
      }
    }

    // Final fallback: try direct MethodChannel
    try {
      const channel = MethodChannel('com.kova.child/blocker');
      await channel.invokeMethod('blockApp', {'pkg': pkg});
      debugPrint('🚫 [BLOCK] Successfully blocked app via fallback: $app');
    } catch (e) {
      debugPrint('❌ [BLOCK] All blocking methods failed for $app: $e');
      // App is still in _blockedApps cache, so it will be blocked on next window change
    }
  }

  /// Unblock an app (called from parent dashboard via network sync)
  Future<void> unblockApp(String app) async {
    _blockedApps.remove(app);

    // Notify native Android layer to dismiss the overlay
    try {
      final pkg = _pkgMap[app] ?? app;
      const channel = MethodChannel('com.kova.child/blocker');
      await channel.invokeMethod('unblockApp', {'pkg': pkg});
      if (kDebugMode) debugPrint('🔓 [UNBLOCK] Instructed native service to dismiss overlay for $app');
    } catch (e) {
      debugPrint('⚠️ [UNBLOCK] Failed to call native unblock for $app: $e');
    }

    if (_childId != null) {
      try {
        await _childRepo.setAppBlocked(_childId!, app, false);
        if (kDebugMode) debugPrint('✅ App unblocked: $app');
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ Failed to persist unblock for $app: $e');
      }
    }
  }

  /// Check if an app is currently blocked
  bool isAppBlocked(String app) => _blockedApps.contains(_normalizeAppName(app));

  /// Show alert notification to parent
  Future<void> _showAlertNotification(
    String app,
    String severity,
    String alertId,
    String content,
  ) async {
    final title = _getAlertTitle(app, severity);
    final body = _getAlertBody(app, severity, content);

    if (severity == 'critical') {
      await NotificationService.showCriticalAlert(title, body);
    } else {
      await NotificationService.showAlert(title, body, alertId: alertId);
    }
  }

  String _getAlertTitle(String app, String severity) {
    final appName = app.substring(0, 1).toUpperCase() + app.substring(1);
    return switch (severity) {
      'critical' => '🚨 CRITICAL: $appName Alert',
      'high' => '⚠️ High Risk: $appName',
      'medium' => '⚡ Medium Risk: $appName',
      _ => 'KOVA Alert: $appName',
    };
  }

  String _getAlertBody(String app, String severity, String content) {
    final preview = content.length > 50 ? '${content.substring(0, 50)}...' : content;
    return 'Potentially harmful content detected. Preview: "$preview"';
  }

  /// Normalize app name / package to internal key
  String _normalizeAppName(String app) {
    final lower = app.toLowerCase();
    // Messaging
    if (lower.contains('whatsapp') || lower == 'com.whatsapp.w4b') return 'whatsapp';
    if (lower.contains('com.facebook.orca') || lower.contains('com.facebook.mlite')) return 'messenger';
    if (lower.contains('com.facebook.katana') || lower == 'facebook') return 'facebook';
    if (lower.contains('instagram')) return 'instagram';
    if (lower.contains('tiktok') || lower.contains('musically') || lower.contains('ugc.trill')) return 'tiktok';
    if (lower.contains('telegram')) return 'telegram';
    if (lower.contains('snapchat')) return 'snapchat';
    if (lower.contains('signal') || lower.contains('securesms')) return 'signal';
    if (lower.contains('twitter')) return 'twitter';
    if (lower.contains('discord')) return 'discord';
    if (lower.contains('skype')) return 'skype';
    if (lower.contains('viber')) return 'viber';
    // Browsers
    if (lower.contains('chrome') || lower == 'com.android.chrome') return 'chrome';
    if (lower.contains('firefox') || lower.contains('mozilla') || lower.contains('fenix')) return 'firefox';
    if (lower.contains('brave')) return 'brave';
    if (lower.contains('opera')) return 'opera';
    if (lower.contains('edge') || lower.contains('emmx')) return 'edge';
    if (lower.contains('duckduckgo')) return 'duckduckgo';
    if (lower.contains('sbrowser') || lower.contains('samsung') && lower.contains('browser')) return 'samsung_browser';
    if (lower.contains('kiwi')) return 'kiwi';
    if (lower.contains('ucmobile') || lower.contains('ucbrowser')) return 'ucbrowser';
    // Search & Video
    if (lower.contains('youtube')) return 'youtube';
    if (lower.contains('googlequicksearchbox') || lower.contains('searchlite')) return 'google';
    // SMS
    if (lower.contains('sms') || lower.contains('messaging') || lower.contains('com.android.mms')) return 'sms';
    return lower;
  }

  // Legacy compatibility methods
  static Future<Map<String, dynamic>?> analyzeMessage({
    required String childId,
    required String app,
    required String messageText,
    required String? senderName,
    required List<String> attachedImagePaths,
  }) async {
    final tfLite = TfLiteAnalyzerService();
    if (!tfLite.isInitialized) await tfLite.init();
    final textScores = await tfLite.analyzeText(messageText);
    
    final detector = ContextDetector();
    detector.addMessage('${app}_$childId', messageText, sender: senderName);
    final contextResult = detector.analyze('${app}_$childId');
    
    final severity = SeverityEngine.calculate(
      textScores: textScores,
      contextScores: contextResult,
    );

    if (severity == 'safe') return null;

    return _buildAlertData(
      childId: childId,
      app: app,
      textScores: textScores,
      contextScores: contextResult,
      userReported: false,
    );
  }

  static Future<Map<String, dynamic>?> analyzeConversation({
    required String childId,
    required String app,
    required String senderName,
    required List<Map<String, dynamic>> messages,
    required String? metadata,
  }) async {
    final texts = messages.map((m) => m['text']?.toString() ?? '').where((t) => t.isNotEmpty).toList();
    if (texts.isEmpty) return null;
    
    final tfLite = TfLiteAnalyzerService();
    if (!tfLite.isInitialized) await tfLite.init();
    final batchResult = await tfLite.analyzeBatch(texts);
    
    final detector = ContextDetector();
    
    for (final msg in messages) {
      detector.addMessage('${app}_$childId', msg['text']?.toString() ?? '');
    }
    
    final contextResult = detector.analyze('${app}_$childId');
    final severity = SeverityEngine.calculate(
      textScores: batchResult,
      contextScores: contextResult,
    );

    if (severity == 'safe') return null;

    return _buildAlertData(
      childId: childId,
      app: app,
      textScores: batchResult,
      contextScores: contextResult,
      userReported: false,
    );
  }

  static Map<String, dynamic> _buildAlertData({
    required String childId,
    required String app,
    required Map<String, dynamic> textScores,
    required Map<String, dynamic> contextScores,
    required bool userReported,
  }) {
    final severity = SeverityEngine.calculate(
      textScores: {
        'unsafe': (textScores['unsafe'] as num?)?.toDouble() ?? 0.0,
        'sexual': (textScores['sexual'] as num?)?.toDouble() ?? 0.0,
        'grooming': (textScores['grooming'] as num?)?.toDouble() ?? 0.0,
        'violence': (textScores['violence'] as num?)?.toDouble() ?? 0.0,
      },
      contextScores: contextScores,
    );

    final safetyScore = SeverityEngine.calculateSafetyScore(
      textConfidence: (textScores['unsafe'] as num?)?.toDouble() ?? 0.0,
      groomingConfidence: (contextScores['grooming_risk'] as num?)?.toDouble() ?? 0.0,
      imageConfidence: 0.0,
    );

    return {
      'childId': childId,
      'app': app,
      'severity': severity,
      'safetyScore': safetyScore,
      'scores': {
        'text': textScores['unsafe'] ?? 0.0,
        'grooming': contextScores['grooming_risk'] ?? 0.0,
        'image': 0.0,
      },
      'userReported': userReported,
      'requiresImmediateAction': severity == 'critical' || severity == 'high',
    };
  }

  /// User manually reports a conversation as harmful
  static Future<Map<String, dynamic>> analyzeUserReport({
    required String childId,
    required String app,
    required String senderName,
    required List<Map<String, dynamic>> messages,
    required String? userReportText,
  }) async {
    var alert = await analyzeConversation(
      childId: childId,
      app: app,
      senderName: senderName,
      messages: messages,
      metadata: userReportText,
    );

    alert ??= {
      'childId': childId,
      'app': app,
      'severity': 'high',
      'safetyScore': 30,
      'message': userReportText ?? 'User reported this conversation as harmful',
      'scores': {'text': 0.5, 'grooming': 0.5, 'image': 0.0},
      'userReported': true,
      'requiresImmediateAction': true,
    };

    alert['userReported'] = true;
    alert['requiresImmediateAction'] = true;
    if (alert['severity'] == 'low' || alert['severity'] == 'safe') {
      alert['severity'] = 'medium';
    }

    return alert;
  }

  /// Generate realistic test alert for demo purposes
  static Future<Map<String, dynamic>> generateTestAlert({
    required String childId,
    required String severity,
  }) async {
    final testMessages = [
      {'text': 'hey you look special today'},
      {'text': 'but dont tell your parents about our chats ok'},
      {'text': 'you seem so mature for your age'},
    ];

    final alert = await analyzeConversation(
      childId: childId,
      app: 'WhatsApp',
      senderName: 'TestSender',
      messages: testMessages,
      metadata: 'test_alert',
    );

    if (alert != null) {
      alert['severity'] = severity;
      alert['isTestAlert'] = true;
    }

    return alert ?? {
      'childId': childId,
      'app': 'WhatsApp',
      'severity': severity,
      'safetyScore': severity == 'high' ? 30 : 50,
      'message': 'Test alert for demo',
      'isTestAlert': true,
    };
  }
}
