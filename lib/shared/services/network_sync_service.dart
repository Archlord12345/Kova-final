// shared/services/network_sync_service.dart — Central network coordinator
// Manages both LAN (direct TCP) and Internet (Railway relay) channels.
// Priority: LAN > Internet. Falls back automatically.

import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'package:kova/shared/models/network_alert.dart';
import 'package:kova/shared/models/web_history.dart';
import 'package:kova/shared/models/pending_sync.dart';
import 'package:kova/shared/services/lan_discovery_service.dart';
import 'package:kova/shared/services/lan_data_service.dart';
import 'package:kova/shared/services/local_storage.dart';
import 'package:kova/shared/services/crypto_service.dart';
import 'package:kova/local_backend/repositories/pending_sync_repository.dart';
import 'package:kova/local_backend/repositories/child_repository.dart';

class NetworkSyncService {
  static final NetworkSyncService _instance = NetworkSyncService._();
  static NetworkSyncService get instance => _instance;
  factory NetworkSyncService() => _instance;
  NetworkSyncService._();

  // ── Configurable relay URL ─────────────────────────────────────────────────
  // Default: Railway deployment. Can be overridden to local server for demo.
  // Set via: LocalStorage.setString('relay_url', 'http://192.168.x.x:3000')
  static const String _defaultRelayUrl =
      'https://kova-production-3f1f.up.railway.app';

  /// Get the current relay base URL (configurable via settings)
  String get _relayBaseUrl {
    final custom = LocalStorage.getString('relay_url');
    return custom.isNotEmpty ? custom : _defaultRelayUrl;
  }

  /// Set a custom relay URL (e.g., local server for demo)
  static Future<void> setRelayUrl(String url) async {
    await LocalStorage.setString('relay_url', url);
    debugPrint('🌐 Relay URL set to: $url');
  }

  /// Get the current relay URL
  static String getRelayUrl() {
    final custom = LocalStorage.getString('relay_url');
    return custom.isNotEmpty ? custom : _defaultRelayUrl;
  }

  /// Reset relay URL to default
  static Future<void> resetRelayUrl() async {
    await LocalStorage.remove('relay_url');
    debugPrint('🌐 Relay URL reset to default');
  }

  final _lanDiscovery = LanDiscoveryService();
  final _lanData = LanDataService();
  final _pendingSyncRepo = PendingSyncRepository();

  bool get isOfflineMode => LocalStorage.getBool('offline_mode', false);

  Timer? _pollTimer;
  Timer? _syncTimer;
  StreamSubscription? _connectivitySub;
  StreamSubscription? _deviceFoundSub;

  NetworkConnectionState _connectionState = NetworkConnectionState.none;
  String _role = 'child'; // 'parent' or 'child'
  String _pairToken = '';
  String _deviceId = '';
  CryptoService? _cryptoService;

  // ── Relay circuit breaker ─────────────────────────────────────────
  int _relayConsecutive404s = 0;
  DateTime? _relayCircuitOpenedAt;
  static const _relayCircuitThreshold = 3;
  static const _relayCircuitCooldown = Duration(seconds: 30);
  bool _isSyncing = false;

  // Reconnect cooldown: prevents stampede when multiple alerts fire while LAN is down
  DateTime? _lastReconnectAttempt;
  Completer<bool>? _activeReconnect;
  static const _reconnectCooldown = Duration(seconds: 15);

  // ── Bug Fix: Alert deduplication ───────────────────────────────────────────
  // Prevents the same (app+alertType) from being pushed multiple times within
  // a 10-second window. Key = "app:alertType", value = last push timestamp.
  final Map<String, DateTime> _alertDedupCache = {};
  static const _alertDedupWindow = Duration(seconds: 10);

  // Streams for UI
  final _connectionStateController =
      StreamController<NetworkConnectionState>.broadcast();
  final _alertReceivedController =
      StreamController<NetworkAlertSummary>.broadcast();
  final _historyReceivedController = StreamController<WebHistory>.broadcast();

  // ─── Pairing Complete Stream ──────────────────────────────────────────────
  // Fires immediately when pairing succeeds (LAN or Railway). Both parent and
  // child subscribe to this to navigate simultaneously instead of polling.
  final _pairingCompleteController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<NetworkConnectionState> get onConnectionStateChanged =>
      _connectionStateController.stream;
  Stream<NetworkAlertSummary> get onAlertReceived =>
      _alertReceivedController.stream;
  Stream<WebHistory> get onHistoryReceived => _historyReceivedController.stream;
  Stream<Map<String, dynamic>> get onPairingComplete =>
      _pairingCompleteController.stream;

  NetworkConnectionState get connectionState => _connectionState;
  bool get isConnected => _connectionState != NetworkConnectionState.none;
  bool get isLanConnected => _connectionState == NetworkConnectionState.lan;

  // ─────────────────────────────────────────────
  // Initialization
  // ─────────────────────────────────────────────

  /// Start the network sync service
  Future<void> start({required String role}) async {
    _role = role;
    _pairToken = LocalStorage.getString('pair_token');
    _deviceId = LocalStorage.getString('device_id');
    if (_pairToken.isNotEmpty) {
      _cryptoService = CryptoService(_pairToken);
    }

    // Always attach the LAN alert listener FIRST — before any early return —
    // so that after pairing completes and the pair token is written, alerts
    // flowing in via LAN are immediately bridged to onAlertReceived.
    _lanData.onAlertReceived.listen((alert) {
      _alertReceivedController.add(alert);
    });

    // ─── UDP Alert Listener (KDE Connect-style fallback) ──────────────────────
    // Listens for UDP alert packets when TCP connection fails
    _lanDiscovery.onUdpAlertReceived.listen((udpAlert) {
      try {
        final alertData = udpAlert['alert'] as Map<String, dynamic>?;
        if (alertData == null) return;

        debugPrint(
            '📨 [NETWORK SYNC] UDP alert received from ${udpAlert['deviceId']}');

        // Convert to NetworkAlertFull and broadcast to UI
        final alert = NetworkAlertFull.fromJson(alertData);
        _alertReceivedController.add(alert);
      } catch (e) {
        debugPrint('⚠️ [NETWORK SYNC] Failed to process UDP alert: $e');
      }
    });

    // Allow starting without a pair token during initial pairing.
    // LAN discovery will run in pairingMode, and relay calls are skipped.
    if (_pairToken.isEmpty) {
      print(
          '⚠️ No pair token — running in pairing-only mode (LAN discovery active)');
      // Start LAN discovery in pairing mode so devices can find each other
      await _lanDiscovery.start(role: role, pairingMode: true);
      return;
    }

    // Listen for connectivity changes
    _connectivitySub =
        Connectivity().onConnectivityChanged.listen(_handleConnectivityChange);

    // Start LAN discovery if not already running
    if (!_lanDiscovery.isRunning) {
      await _lanDiscovery.start(role: role);
    }

    // Listen for LAN device discovery
    _deviceFoundSub = _lanDiscovery.onDeviceFound.listen(_handleDeviceFound);

    // If child, start LAN server to accept parent connections
    if (role == 'child') {
      final serverStarted = await _lanData.startServer(_pairToken);
      if (serverStarted) {
        debugPrint(
            '✅ [NETWORK SYNC] Child LAN server started successfully on port 18757');
      } else {
        debugPrint(
            '❌ [NETWORK SYNC] Child LAN server failed to start - alerts will use Railway only');
      }
      _startSyncLoop();
    } else {
      // Parent: poll Railway relay and connect to child's TCP server when discovered
      _startPolling();
    }

    // NOTE: LAN alert listener is already attached above (before early-return block)

    // ── Parent: Receive child profile over LAN and persist it ─────────────────
    // When the child sends its name/age over LAN after pairing, the parent
    // saves it to SQLite so the dashboard shows the correct child name.
    if (role == 'parent') {
      _lanData.onChildProfileReceived.listen((profile) async {
        try {
          // Save/update the child record in the local database
          final childRepo = ChildRepository();
          final existing = await childRepo.getAll();
          if (existing.isEmpty) {
            // First time — create the child record
            await childRepo.create(profile.name, age: profile.age);
            print('👶 Child profile CREATED in DB: ${profile.name}');
          } else {
            // Already exists — update name/age
            await childRepo.updateName(existing.first.id, profile.name);
            await childRepo.updateAge(existing.first.id, profile.age);
            print('👶 Child profile UPDATED in DB: ${profile.name}');
          }
          // Also cache in LocalStorage for fast access
          await LocalStorage.setString('child_name', profile.name);
          if (profile.childId.isNotEmpty) {
            await LocalStorage.setChildId(profile.childId);
          }
          // Fire pairingCompleteController so the UI refreshes
          _pairingCompleteController.add({
            'method': 'lan_profile',
            'childName': profile.name,
            'childId': profile.childId,
          });
        } catch (e) {
          print('❌ Failed to persist child profile from LAN: $e');
        }
      });
    }

    // Check initial connectivity
    final result = await Connectivity().checkConnectivity();
    _handleConnectivityChange(result);

    print('🌐 Network sync started as $_role');
  }

  /// Stop the network sync service
  void stop() {
    _pollTimer?.cancel();
    _syncTimer?.cancel();
    _connectivitySub?.cancel();
    _deviceFoundSub?.cancel();
    _lanDiscovery.stop();
    _lanData.stopServer();
    _lanData.disconnectClient();
    _updateState(NetworkConnectionState.none);
    print('🌐 Network sync stopped');
  }

  // ─────────────────────────────────────────────
  // Pairing (Railway-based)
  // ─────────────────────────────────────────────

  Future<void> _ensureDeviceId() async {
    if (_deviceId.isEmpty) {
      _deviceId = LocalStorage.getString('device_id');
      if (_deviceId.isEmpty) {
        _deviceId = const Uuid().v4();
        await LocalStorage.setString('device_id', _deviceId);
      }
    }
  }

  /// Register a pairing code for LAN discovery and Internet relay fallback.
  Future<bool> registerPairingCode(String code) async {
    await _ensureDeviceId();
    _lanDiscovery.setActivePairCode(code); // For offline LAN discovery

    // Ensure LAN discovery is running in pairing mode.
    if (!_lanDiscovery.isRunning) {
      await _lanDiscovery.start(role: 'parent', pairingMode: true);
    }

    var relayRegistered = false;
    if (!isOfflineMode) {
      try {
        final response = await http
            .post(
              Uri.parse('$_relayBaseUrl/api/pair/register'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'code': code, 'parentDeviceId': _deviceId}),
            )
            .timeout(const Duration(seconds: 8));
        relayRegistered = response.statusCode == 200 || response.statusCode == 201;
        if (!relayRegistered) {
          debugPrint(
              '⚠️ Pair code relay register failed: ${response.statusCode} ${response.body}');
        }
      } catch (e) {
        debugPrint('⚠️ Pair code relay register error: $e');
      }
    }

    print(relayRegistered
        ? '📱 Code $code registered for LAN + relay pairing by parent'
        : '📱 Code $code registered for local LAN pairing only');
    // LAN registration is enough to let same-network devices pair.
    return true;
  }

  /// Claim a pairing code and get pair token (child side)
  Future<String?> claimPairingCode(String code) async {
    // 1. Ensure we have a device ID
    await _ensureDeviceId();

    // 2. Try local LAN discovery first (with retry for timing issues)
    if (!_lanDiscovery.isRunning) {
      // Start in pairing mode — no pair token required
      await _lanDiscovery.start(role: 'child', pairingMode: true);
    }

    // ─── Reactive LAN Discovery with Retry ───────────────────────────────────
    // Child waits 1.5s before first attempt so the parent's UDP socket is
    // fully bound and ready to receive broadcasts. Then retries up to 3x.
    // This eliminates the "needs 2 attempts" bug.
    LanDeviceInfo? localPeer;
    const maxAttempts = 10;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        // Wait before each attempt: 500ms first try, 800ms subsequent
        final delayMs = attempt == 1 ? 500 : 800;
        print(
            '📡 LAN discovery attempt $attempt/$maxAttempts (delay: ${delayMs}ms)...');
        await Future.delayed(Duration(milliseconds: delayMs));

        // Broadcast our presence immediately before listening
        if (_lanDiscovery.isRunning) {
          _lanDiscovery.setActivePairCode(code);
        }

        localPeer = await _lanDiscovery.waitForPeerWithCode(
          code,
          const Duration(seconds: 3),
        );
        if (localPeer != null) {
          print('📡 LAN peer found on attempt $attempt');
          break;
        }
        print('⚠️ LAN attempt $attempt: no peer found, retrying...');
      } catch (e) {
        print('⚠️ LAN discovery attempt $attempt error: $e');
      }
    }

    if (localPeer != null) {
      // Offline fallback: Generate our own pair token
      _pairToken = const Uuid().v4();
      await LocalStorage.setPairToken(_pairToken);
      _cryptoService = CryptoService(_pairToken);

      // Save parent peer info so we can reconnect on restart!
      await LocalStorage.setLastChildPeer(localPeer.toJson());

      // After pairing via UDP discovery, establish TCP data channel IMMEDIATELY
      final connected = await _lanData.connectToParent(
          localPeer.ipAddress, 18757, _pairToken);
      if (connected) {
        debugPrint('✅ [LAN] TCP data channel established');
        _updateState(NetworkConnectionState.lan);
      } else {
        debugPrint('❌ [LAN] TCP connect failed — alerts will use Railway');
        _updateState(NetworkConnectionState.internet);
      }

      // Re-init discovery with the new pairToken (no longer in pairing mode)
      _lanDiscovery.stop();
      _lanData.stopServer();

      _lanDiscovery.setActivePairCode(code);
      _lanDiscovery.start(role: 'child'); // run without await

      _startSyncLoop();

      // ─── Send child profile over LAN so parent gets the name immediately ─
      // This fixes the "parent doesn't see child name after pairing" bug.
      final childName = LocalStorage.getString('child_name', 'Child');
      final childId = LocalStorage.getString('child_id', _deviceId);
      final childAge = LocalStorage.getInt('child_age', 10);
      _lanData.sendChildProfile(
        childId: childId,
        name: childName,
        age: childAge,
      );
      print('📤 Child profile sent to parent via LAN: $childName');

      // ─── Notify both screens simultaneously ───────────────────────────────
      _pairingCompleteController.add({
        'method': 'lan',
        'pairToken': _pairToken,
        'peerIp': localPeer.ipAddress,
        'role': 'child',
      });

      print('🔗 Pairing claimed via LAN!');
      return _pairToken;
    }

    // 3. Internet relay fallback for different networks / mobile data
    if (!isOfflineMode) {
      try {
        final response = await http
            .post(
              Uri.parse('$_relayBaseUrl/api/pair/claim'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'code': code, 'childDeviceId': _deviceId}),
            )
            .timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final token = data['pairToken'] as String? ?? '';
          if (token.isNotEmpty) {
            _pairToken = token;
            await LocalStorage.setPairToken(_pairToken);
            await LocalStorage.setChildDeviceId(_deviceId);
            final parentDeviceId = data['parentDeviceId'] as String? ?? '';
            if (parentDeviceId.isNotEmpty) {
              await LocalStorage.setParentDeviceId(parentDeviceId);
            }
            _cryptoService = CryptoService(_pairToken);
            _updateState(NetworkConnectionState.internet);
            _startSyncLoop();
            _pairingCompleteController.add({
              'method': 'relay',
              'pairToken': _pairToken,
              'role': 'child',
            });
            print('🔗 Pairing claimed via relay!');
            return _pairToken;
          }
        } else {
          debugPrint(
              '⚠️ Relay claim failed: ${response.statusCode} ${response.body}');
        }
      } catch (e) {
        debugPrint('⚠️ Relay claim error: $e');
      }
    }

    print('❌ Claim failed: parent not found on LAN or relay');
    return null;
  }

  /// Check pairing status manually (parent side polling)
  Future<String?> checkPairingStatus(String code) async {
    // Check if child has claimed the code via LAN!
    if (_connectionState == NetworkConnectionState.lan ||
        _lanDiscovery.pairedPeer != null) {
      return _pairToken;
    }

    final childPeer = _lanDiscovery.findChildByCode(code);
    if (childPeer != null && childPeer.encryptedPairToken.isNotEmpty) {
      // The child generated a pairToken for us!
      _pairToken = CryptoService(code).decryptPayload(
          childPeer.encryptedPairToken, childPeer.encryptedTokenIv);
      await LocalStorage.setPairToken(_pairToken);
      _cryptoService = CryptoService(_pairToken);

      await LocalStorage.setLastChildPeer(childPeer.toJson());

      // Parent is already running the TCP server, child will connect to us
      _lanData.setPairToken(_pairToken);
      _updateState(NetworkConnectionState.lan);
      if (_role == 'parent') {
        _startPolling();
      } else {
        _startSyncLoop();
      }

      // ─── Notify both screens immediately ─────────────────────────────────
      _pairingCompleteController.add({
        'method': 'lan',
        'pairToken': _pairToken,
        'peerIp': childPeer.ipAddress,
        'role': 'parent',
      });

      print('🔗 Child connected via LAN, pairing complete');
      return _pairToken;
    }

    if (!isOfflineMode) {
      try {
        final response = await http
            .get(Uri.parse('$_relayBaseUrl/api/pair/status?code=$code'))
            .timeout(const Duration(seconds: 8));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final token = data['pairToken'] as String? ?? '';
          final paired = data['paired'] == true || data['claimed'] == true;
          if (paired && token.isNotEmpty) {
            _pairToken = token;
            await LocalStorage.setPairToken(_pairToken);
            _cryptoService = CryptoService(_pairToken);
            _updateState(NetworkConnectionState.internet);
            _startPolling();
            _pairingCompleteController.add({
              'method': 'relay',
              'pairToken': _pairToken,
              'role': 'parent',
            });
            print('🔗 Child connected via relay, pairing complete');
            return _pairToken;
          }
        }
      } catch (e) {
        debugPrint('⚠️ Relay status check error: $e');
      }
    }

    return null;
  }

  // ─────────────────────────────────────────────
  // Alert Pushing (child side)
  // ─────────────────────────────────────────────

  Future<void> pushAlert(NetworkAlertFull alert, [String? itemId]) async {
    // ── Bug Fix #4: Alert deduplication ──────────────────────────────────────
    // Skip if the same (app+alertType) was already pushed within 10 seconds.
    // This prevents the 4x-in-1-second flood seen in MIUI logs.
    if (itemId == null) {
      final dedupKey = '${alert.app}:${alert.alertType}';
      final now = DateTime.now();
      final lastPush = _alertDedupCache[dedupKey];
      if (lastPush != null && now.difference(lastPush) < _alertDedupWindow) {
        debugPrint(
            '🔇 [PUSH ALERT] Dedup: skipping duplicate $dedupKey (${now.difference(lastPush).inMilliseconds}ms ago)');
        return;
      }
      _alertDedupCache[dedupKey] = now;
      // Prune old entries to prevent memory leak
      _alertDedupCache.removeWhere(
          (_, ts) => now.difference(ts) > const Duration(minutes: 2));
    }

    debugPrint('📤 [PUSH ALERT] severity=${alert.severity}');

    bool delivered = false;

    // ── Child: ensure server is running, wait for parent to connect ──
    if (_role == 'child' &&
        (!_lanData.isConnected || !_lanData.isSocketHealthy)) {
      // Child runs server - ensure it's running and wait for parent connection
      await _ensureChildServerRunning();
      if (!_lanData.isConnected) {
        debugPrint(
            '⏳ [PUSH ALERT] Child server running, waiting for parent to connect...');
      }
    }

    // ── Parent: debounced reconnect to child's server ──
    if (_role == 'parent' &&
        (!_lanData.isConnected || !_lanData.isSocketHealthy)) {
      final now = DateTime.now();
      final cooldownExpired = _lastReconnectAttempt == null ||
          now.difference(_lastReconnectAttempt!) > _reconnectCooldown;

      if (cooldownExpired) {
        if (_activeReconnect == null || _activeReconnect!.isCompleted) {
          _activeReconnect = Completer<bool>();
          _lastReconnectAttempt = now;
          debugPrint('🔁 [PUSH ALERT] Parent reconnecting to child server...');
          try {
            // Parent: connect to discovered child
            final discoveredChild = _lanDiscovery.pairedPeer;
            if (discoveredChild != null) {
              debugPrint(
                  '🔍 [PUSH ALERT] Found child via discovery: ${discoveredChild.ipAddress}:${discoveredChild.port}');
              final connected = await _lanData.connectToParent(
                  discoveredChild.ipAddress, discoveredChild.port, _pairToken);
              if (connected) {
                debugPrint('✅ [PUSH ALERT] Connected to child server');
                _activeReconnect!.complete(true);
              } else {
                _activeReconnect!.complete(false);
              }
            } else {
              debugPrint('⚠️ [PUSH ALERT] Child not found via discovery');
              _activeReconnect!.complete(false);
            }
          } catch (e) {
            debugPrint('⚠️ [PUSH ALERT] Reconnect failed: $e');
            _activeReconnect!.complete(false);
          }
        } else {
          debugPrint('🔁 [PUSH ALERT] Waiting on existing reconnect...');
          await _activeReconnect!.future;
        }
      } else {
        debugPrint('⏳ [PUSH ALERT] Reconnect cooldown active, skipping...');
      }
    }

    // Relay is primary unless in offline mode
    if (!isOfflineMode) {
      debugPrint('📡 [PUSH ALERT] Attempting Relay server first...');
      try {
        final success = await _pushAlertToRelay(alert);
        if (success) delivered = true;
      } catch (e) {
        debugPrint('❌ [PUSH ALERT] Relay failed: $e');
      }
    } else {
      debugPrint('📴 [PUSH ALERT] Offline mode enabled, skipping Relay.');
    }

    // Try LAN if Relay failed or Offline mode enabled
    if (!delivered) {
      if (_lanData.isConnected && _lanData.isSocketHealthy) {
        debugPrint('📡 [PUSH ALERT] Sending via LAN...');
        try {
          final success = await _lanData.sendAlertSafe(alert);
          debugPrint(success
              ? '✅ [PUSH ALERT] LAN SUCCESS'
              : '❌ [PUSH ALERT] LAN returned false');
          delivered = success;
        } catch (e) {
          debugPrint('❌ [PUSH ALERT] LAN exception: $e');
        }
      } else {
        debugPrint('❌ [PUSH ALERT] LAN unavailable');
      }
    }

    if (delivered && itemId != null) {
      await _pendingSyncRepo.deleteList([itemId]);
      return;
    }

    // ── UDP fallback (KDE Connect-style) ──────────────────────────────
    // When TCP fails but we can see the peer via discovery, try UDP
    if (!delivered) {
      final peer = _lanDiscovery.pairedPeer;
      if (peer != null) {
        debugPrint('📡 [PUSH ALERT] TCP LAN failed, trying UDP fallback...');
        try {
          final udpSuccess =
              await _lanDiscovery.sendAlertViaUdp(peer, alert.toJson());
          if (udpSuccess) {
            // UDP is best-effort, consider it "delivered" for queuing purposes
            // but we won't delete from queue since UDP has no ACK
            debugPrint('📤 [PUSH ALERT] UDP sent (best-effort, no guarantee)');
            // Don't mark as fully delivered - let it queue for TCP/Railway retry
          }
        } catch (e) {
          debugPrint('⚠️ [PUSH ALERT] UDP fallback failed: $e');
        }
      }
    }

    if (!delivered) {
      debugPrint('💾 [PUSH ALERT] Saving to local queue for retry...');
      try {
        await _pendingSyncRepo.insert(
          PendingSync(
            id: const Uuid().v4(),
            type: 'alert',
            payload: jsonEncode(alert.toJson()),
          ),
        );
        debugPrint('✅ [PUSH ALERT] Queued for retry');
      } catch (e) {
        debugPrint('❌ [PUSH ALERT] Queue failed: $e');
      }
    }

    if (delivered && itemId != null) {
      await _pendingSyncRepo.deleteList([itemId]);
      debugPrint('🗑️ [PUSH ALERT] Pending sync item removed');
    }
  }

  // ─────────────────────────────────────────────
  // Web History Pushing (child side)
  // ─────────────────────────────────────────────

  /// Push alert summary to Railway relay
  Future<bool> _pushAlertToRelay(NetworkAlertFull alert) async {
    if (_pairToken.isEmpty) return false;
    _cryptoService ??= CryptoService(_pairToken);

    try {
      final summary = NetworkAlertSummary(
        severity: alert.severity,
        app: alert.app,
        alertType: alert.alertType,
        childName: alert.childName,
        timestamp: alert.timestamp,
        contentPreview: alert.contentPreview, // Include preview for ping text
      );

      final jsonStr = jsonEncode(summary.toJson());
      final encrypted = _cryptoService!.encryptPayload(jsonStr);

      final response = await http.post(
        Uri.parse('$_relayBaseUrl/api/alert/push'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_pairToken',
        },
        body: jsonEncode(
            {'encryptedData': encrypted['data'], 'iv': encrypted['iv']}),
      );

      if (response.statusCode == 201) {
        debugPrint('📤 Alert pushed to relay (summary)');
        return true;
      } else {
        debugPrint('❌ Alert push failed: ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('❌ Alert push error: $e');
      return false;
    }
  }

  Future<void> pushHistory(WebHistory history, [String? itemId]) async {
    if (_pairToken.isEmpty) return;
    _cryptoService ??= CryptoService(_pairToken);

    // Try Relay first unless offline mode
    if (!isOfflineMode) {
      try {
        final jsonStr = jsonEncode(history.toJson());
        final encrypted = _cryptoService!.encryptPayload(jsonStr);

        final response = await http.post(
          Uri.parse('$_relayBaseUrl/api/history/push'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $_pairToken',
          },
          body: jsonEncode(
              {'encryptedData': encrypted['data'], 'iv': encrypted['iv']}),
        );

        if (response.statusCode == 201) {
          debugPrint('📤 History pushed to relay');
          if (itemId != null) {
            await _pendingSyncRepo.deleteList([itemId]);
          }
        } else {
          debugPrint('❌ History push failed: ${response.body}');
        }
      } catch (e) {
        debugPrint('❌ History push error: $e');
      }
    }
    
    // Optional: LAN fallback for history could be implemented here
  }

  // ─────────────────────────────────────────────
  // Alert Polling (parent side)
  // ─────────────────────────────────────────────

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _ensureParentConnected();
      if (!isOfflineMode) {
        _pollAlerts();
        _pollHistory();
      }
    });
    _ensureParentConnected();
    if (!isOfflineMode) {
      _pollAlerts();
      _pollHistory();
    }
  }

  /// Parent-side: ensure WebSocket connection to child's server is alive.
  /// If not connected, re-discover via mDNS and reconnect.
  Future<void> _ensureParentConnected() async {
    if (_role != 'parent' || _pairToken.isEmpty) return;

    if (_lanData.isConnected && _lanData.isSocketHealthy) {
      // Connection is healthy — nothing to do
      return;
    }

    debugPrint(
        '🔁 [PARENT POLL] Not connected to child — attempting reconnect...');

    // Try to find child via discovery
    final peer = _lanDiscovery.pairedPeer;
    if (peer != null) {
      debugPrint(
          '🔍 [PARENT POLL] Found child at ${peer.ipAddress}:${peer.port}');
      try {
        final connected = await _lanData.connectToParent(
          peer.ipAddress,
          peer.port,
          _pairToken,
        );
        if (connected) {
          debugPrint('✅ [PARENT POLL] Reconnected to child server');
          _updateState(NetworkConnectionState.lan);
        } else {
          debugPrint('❌ [PARENT POLL] Connection failed');
        }
      } catch (e) {
        debugPrint('❌ [PARENT POLL] Reconnect error: $e');
      }
    } else {
      debugPrint('⏳ [PARENT POLL] No child peer found via discovery yet');
      // Re-trigger mDNS discovery if not running
      if (!_lanDiscovery.isRunning) {
        await _lanDiscovery.start(role: 'parent');
        debugPrint('📡 [PARENT POLL] Restarted mDNS discovery');
      }
    }
  }

  Future<void> _pollAlerts() async {
    if (_pairToken.isEmpty) return;

    if (_relayCircuitOpenedAt != null) {
      final elapsed = DateTime.now().difference(_relayCircuitOpenedAt!);
      if (elapsed < _relayCircuitCooldown) return;
      _relayCircuitOpenedAt = null;
      _relayConsecutive404s = 0;
    }

    try {
      final response = await http.get(
        Uri.parse('$_relayBaseUrl/api/alert/poll'),
        headers: {
          'Authorization': 'Bearer $_pairToken',
        },
      );

      if (response.statusCode == 200) {
        _relayConsecutive404s = 0;
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final alerts = data['alerts'] as List<dynamic>? ?? [];

        _cryptoService ??= CryptoService(_pairToken);

        for (final alertJson in alerts) {
          final map = alertJson as Map<String, dynamic>;
          final encryptedData = map['encryptedData'] as String? ?? '';
          final iv = map['iv'] as String? ?? '';

          final decryptedStr =
              _cryptoService!.decryptPayload(encryptedData, iv);
          if (decryptedStr.isNotEmpty) {
            try {
              final summaryJson =
                  jsonDecode(decryptedStr) as Map<String, dynamic>;
              final alert = NetworkAlertSummary.fromJson(summaryJson);
              _alertReceivedController.add(alert);
            } catch (e) {
              debugPrint('❌ Failed to parse decrypted alert: $e');
            }
          }
        }
      } else if (response.statusCode == 404 &&
          response.body.contains('DEPLOYMENT_NOT_FOUND')) {
        _relayConsecutive404s++;
        if (_relayConsecutive404s >= _relayCircuitThreshold) {
          _relayCircuitOpenedAt = DateTime.now();
        }
      }
    } catch (e) {
      // ignore
    }
  }

  Future<void> _pollHistory() async {
    if (_pairToken.isEmpty) return;
    try {
      final response = await http.get(
        Uri.parse('$_relayBaseUrl/api/history/poll'),
        headers: {
          'Authorization': 'Bearer $_pairToken',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final historyList = data['history'] as List<dynamic>? ?? [];

        _cryptoService ??= CryptoService(_pairToken);

        for (final item in historyList) {
          final map = item as Map<String, dynamic>;
          final encryptedData = map['encryptedData'] as String? ?? '';
          final iv = map['iv'] as String? ?? '';

          final decryptedStr =
              _cryptoService!.decryptPayload(encryptedData, iv);
          if (decryptedStr.isNotEmpty) {
            try {
              final historyJson =
                  jsonDecode(decryptedStr) as Map<String, dynamic>;
              final webHistory = WebHistory.fromJson(historyJson);
              _historyReceivedController.add(webHistory);
            } catch (e) {
              debugPrint('❌ Failed to parse decrypted history: $e');
            }
          }
        }
      }
    } catch (e) {
      // ignore
    }
  }

  void _startSyncLoop() {
    _syncTimer?.cancel();
    // Sync every 8 seconds for faster alert delivery
    _syncTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      _syncLoop();
      _pollAcks();
      _syncChildProfileIfNeeded(); // Retry profile sync periodically (DIRECTIVE 5)
    });
    _syncLoop();
    _pollAcks();
  }

  /// Periodic check to sync child profile if not yet available (DIRECTIVE 5)
  Future<void> _syncChildProfileIfNeeded() async {
    if (_role != 'child' || _pairToken.isEmpty) return;

    final currentName = LocalStorage.getString('child_name');
    final childId = LocalStorage.getChildId();
    if (childId == null && currentName.isEmpty) return;

    // Retry while the child still has the temporary local placeholder.
    if (currentName.isNotEmpty && currentName != 'Connected Device') return;

    print('🔄 Periodic child profile sync attempt...');
    await syncChildProfile();
  }

  void triggerSyncLoop() {
    if (_role == 'child') {
      _syncLoop();
    }
  }

  DateTime? _syncStartedAt;

  Future<void> _syncLoop() async {
    if (_role != 'child' || _pairToken.isEmpty) return;

    // Safety: if _isSyncing has been stuck for more than 30 seconds, force-reset it
    if (_isSyncing && _syncStartedAt != null) {
      final elapsed = DateTime.now().difference(_syncStartedAt!).inSeconds;
      if (elapsed > 30) {
        print('⚠️ [SYNC] _isSyncing stuck for ${elapsed}s — force-resetting');
        _isSyncing = false;
      } else {
        return;
      }
    }
    if (_isSyncing) return;
    _isSyncing = true;
    _syncStartedAt = DateTime.now();

    try {
      final items = await _pendingSyncRepo.getAll();
      if (items.isEmpty) {
        _isSyncing = false;
        _syncStartedAt = null;
        return;
      }

      // Process at most 10 items per cycle to avoid blocking the pipeline
      final batch = items.take(10).toList();

      for (var item in batch) {
        try {
          if (item.type == 'alert') {
            final alert = NetworkAlertFull.fromJson(jsonDecode(item.payload));
            await pushAlert(alert, item.id);
          } else if (item.type == 'history') {
            final history = WebHistory.fromJson(jsonDecode(item.payload));
            await pushHistory(history, item.id);
          } else if (item.type == 'child_profile') {
            // Retry pushing child profile
            final data = jsonDecode(item.payload);
            await pushChildProfile(
              childId: data['childId'],
              name: data['name'],
              age: data['age'] ?? 10,
              avatarPath: data['avatarPath'],
              settings: data['settings'],
            );
          }
        } catch (e) {
          print('❌ Sync item ${item.id} error: $e');
          // Continue processing other items — don't let one failure block all
        }
      }
    } catch (e) {
      print('❌ Sync loop error: $e');
    } finally {
      _isSyncing = false;
      _syncStartedAt = null;
    }
  }

  Future<void> _pollAcks() async {}

  // ─────────────────────────────────────────────
  // Connection Management
  // ─────────────────────────────────────────────

  void _handleConnectivityChange(List<ConnectivityResult> results) {
    if (results.isEmpty) {
      _updateState(NetworkConnectionState.none);
      return;
    }
    final hasWifi = results.contains(ConnectivityResult.wifi);
    final hasMobile = results.contains(ConnectivityResult.mobile);
    final hasEthernet = results.contains(ConnectivityResult.ethernet);
    final hasInternet = hasWifi || hasMobile || hasEthernet;

    if (hasWifi && _lanDiscovery.pairedPeer != null) {
      _updateState(NetworkConnectionState.lan);
    } else if (hasInternet) {
      _updateState(NetworkConnectionState.internet);
    } else {
      _updateState(NetworkConnectionState.none);
    }

    // ── Bug Fix: Child server lifecycle ───────────────────────────────────────
    // If we're child and WiFi just came back, ensure server is running
    if (_role == 'child' && hasWifi) {
      // Fire-and-forget is intentional here — don't block connectivity updates
      _ensureChildServerRunning().catchError((e) {
        debugPrint('⚠️ [CHILD] Server health check error: $e');
      });
    }
  }

  /// Ensure child LAN server is running (restarts if needed)
  Future<void> _ensureChildServerRunning() async {
    if (_role != 'child') return;

    try {
      // Check if server is actually accepting connections
      final isHealthy = await _lanData.isServerHealthy();
      if (!isHealthy) {
        debugPrint('🔌 [CHILD] Server unhealthy, restarting...');
        await _lanData.stopServer();
        await Future.delayed(const Duration(milliseconds: 500));
        await _lanData.startServer(_pairToken);
        debugPrint('✅ [CHILD] Server restarted successfully');
      }
    } catch (e) {
      debugPrint('⚠️ [CHILD] Server health check failed: $e');
      // Force restart
      try {
        await _lanData.stopServer();
        await Future.delayed(const Duration(milliseconds: 500));
        await _lanData.startServer(_pairToken);
      } catch (e2) {
        debugPrint('❌ [CHILD] Server restart failed: $e2');
      }
    }
  }

  void _handleDeviceFound(LanDeviceInfo device) {
    print('🔍 Paired device found on LAN: ${device.ipAddress}');

    // If parent, connect to child's TCP server — only set state AFTER TCP connects
    if (_role == 'parent') {
      _lanData
          .connectToParent(device.ipAddress, device.port, _pairToken)
          .then((connected) {
        if (connected) {
          _updateState(NetworkConnectionState.lan);
        } else {
          debugPrint(
              '⚠️ [DEVICE FOUND] TCP handshake failed to ${device.ipAddress} — staying on current state');
        }
      });
      // DON'T set state to LAN here — wait for TCP to actually connect
    } else {
      // Child side: we're running the TCP server, so discovery = ready
      _updateState(NetworkConnectionState.lan);
    }
  }

  void _updateState(NetworkConnectionState newState) {
    if (_connectionState != newState) {
      _connectionState = newState;
      _connectionStateController.add(newState);
      print('🌐 Connection state: ${newState.name}');
    }
  }

  // ─────────────────────────────────────────────
  // Child Profile Sync (DIRECTIVE 1 & 2)
  // ─────────────────────────────────────────────

  /// Push child profile to relay immediately after creation (parent side)
  /// Called by ChildProfileService after saving to local SQLite
  Future<bool> pushChildProfile({
    required String childId,
    required String name,
    int age = 10,
    String? avatarPath,
    Map<String, dynamic>? settings,
  }) async {
    if (_pairToken.isEmpty) {
      print('❌ Cannot push child profile: no pair token');
      return false;
    }

    _cryptoService ??= CryptoService(_pairToken);

    // Encrypt profile data
    final profileData = jsonEncode({
      'childId': childId,
      'name': name,
      'age': age,
      'avatarPath': avatarPath,
      'settings': settings ?? {},
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    final encrypted = _cryptoService!.encryptPayload(profileData);

    try {
      final response = await http
          .post(
            Uri.parse('$_relayBaseUrl/api/child/register'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $_pairToken',
              'Connection': 'keep-alive',
            },
            body: jsonEncode({
              'childId': childId,
              'name': name,
              'age': age,
              'avatarUrl': avatarPath,
              'settings': settings ?? {},
              'encryptedData': encrypted['data'],
              'iv': encrypted['iv'],
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode == 200) {
        print('👤 Child profile pushed to relay: $name ($childId)');
        return true;
      } else {
        print(
            '❌ Child profile push failed: ${response.statusCode} ${response.body}');
        // Add to pending sync for retry
        await _pendingSyncRepo.insert(
          PendingSync(
            id: const Uuid().v4(),
            type: 'child_profile',
            payload: profileData,
          ),
        );
        return false;
      }
    } catch (e) {
      print('❌ Child profile push error: $e');
      // Add to pending sync for retry
      await _pendingSyncRepo.insert(
        PendingSync(
          id: const Uuid().v4(),
          type: 'child_profile',
          payload: jsonEncode(profileData),
        ),
      );
      return false;
    }
  }

  /// Sync child profile from relay to local SQLite (child side).
  /// Called on boot and periodically until profile is received.
  Future<bool> syncChildProfile() async {
    if (_pairToken.isEmpty) return false;
    _cryptoService ??= CryptoService(_pairToken);

    try {
      final response = await http.get(
        Uri.parse('$_relayBaseUrl/api/child/profile'),
        headers: {'Authorization': 'Bearer $_pairToken'},
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) return false;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final profile = data['profile'] as Map<String, dynamic>? ?? data;
      final encryptedData = profile['encryptedData'] as String? ?? '';
      final iv = profile['iv'] as String? ?? '';

      Map<String, dynamic> decodedProfile = profile;
      if (encryptedData.isNotEmpty && iv.isNotEmpty) {
        final decrypted = _cryptoService!.decryptPayload(encryptedData, iv);
        if (decrypted.isNotEmpty) {
          decodedProfile = jsonDecode(decrypted) as Map<String, dynamic>;
        }
      }

      final childId = decodedProfile['childId'] as String? ?? '';
      final name = decodedProfile['name'] as String? ?? 'Connected Device';
      final ageValue = decodedProfile['age'];
      final age = ageValue is int
          ? ageValue
          : int.tryParse(ageValue?.toString() ?? '') ?? 10;
      if (childId.isEmpty) return false;

      final childRepo = ChildRepository();
      final existing = await childRepo.getById(childId);
      if (existing == null) {
        final localId = await childRepo.create(name, age: age);
        if (localId != childId) {
          await LocalStorage.setChildId(localId);
        }
      } else {
        await childRepo.updateName(childId, name);
        await childRepo.updateAge(childId, age);
        await LocalStorage.setChildId(childId);
      }
      await LocalStorage.setString('child_name', name);
      await LocalStorage.setInt('child_age', age);
      print('👤 Child profile synced from relay: $name');
      return true;
    } catch (e) {
      debugPrint('⚠️ Child profile sync error: $e');
      return false;
    }
  }

  // ─────────────────────────────────────────────
  // Test Alert (for presentation / demo)
  // ─────────────────────────────────────────────

  /// Send a test alert via the relay server (no encryption needed).
  /// Works from BOTH child and parent side — useful for demo videos.
  Future<bool> sendTestAlert({
    String app = 'WhatsApp',
    String severity = 'high',
    String alertType = 'suspicious_content',
    String? childName,
  }) async {
    if (_pairToken.isEmpty) {
      debugPrint('❌ [TEST ALERT] No pair token — cannot send test alert');
      return false;
    }

    final name = childName ?? LocalStorage.getString('child_name', 'Child');

    try {
      final response = await http
          .post(
            Uri.parse('$_relayBaseUrl/api/alert/test'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $_pairToken',
            },
            body: jsonEncode({
              'app': app,
              'severity': severity,
              'alertType': alertType,
              'childName': name,
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 201) {
        debugPrint('🧪 [TEST ALERT] Sent: $app - $severity via relay');
        return true;
      } else {
        debugPrint(
            '❌ [TEST ALERT] Server returned: ${response.statusCode} ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('❌ [TEST ALERT] Error: $e');
      return false;
    }
  }

  /// Check server health (useful for settings screen)
  Future<Map<String, dynamic>?> checkServerHealth() async {
    try {
      final response = await http
          .get(
            Uri.parse('$_relayBaseUrl/api/health'),
          )
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('❌ Server health check failed: $e');
    }
    return null;
  }

  void dispose() {
    stop();
    _connectionStateController.close();
    _alertReceivedController.close();
    _historyReceivedController.close();
  }
}
