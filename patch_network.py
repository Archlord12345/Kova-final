import re

with open('lib/shared/services/network_sync_service.dart', 'r') as f:
    content = f.read()

# 1. Update _defaultRelayUrl
content = content.replace(
    "static const String _defaultRelayUrl = 'https://kova-production-3f1f.up.railway.app';",
    "static const String _defaultRelayUrl = 'https://kova-production-3f1f.up.railway.app';"
)

# 2. Add relay circuit breaker state
circuit_breaker = """
  // ── Relay circuit breaker ─────────────────────────────────────────
  int _relayConsecutive404s = 0;
  DateTime? _relayCircuitOpenedAt;
  static const _relayCircuitThreshold = 3;
  static const _relayCircuitCooldown = Duration(seconds: 30);
"""
content = re.sub(
    r"(bool _isSyncing = false;\s*// Reconnect cooldown)",
    circuit_breaker + r"\1",
    content,
    count=1
)

# 3. Restore _pushAlertToRelay inside pushAlert
push_alert_search = """    // Removed Railway relay fallback - pure local mode

    if (!delivered) {"""

push_alert_replace = """    // Fallback to Railway relay (summary only)
    if (!delivered) {
      await _pushAlertToRelay(alert);
      // We consider it 'delivered' to the relay queue, but we might still want to retry LAN later
      // The old behavior queued it anyway if LAN failed. Let's keep the queue logic below
      // but mark it delivered if relay success so it doesn't queue indefinitely.
    }

    if (!delivered) {"""

content = content.replace(push_alert_search, push_alert_replace)

# 4. Add _pushAlertToRelay method
push_alert_to_relay = """  /// Push alert summary to Railway relay
  Future<void> _pushAlertToRelay(NetworkAlertFull alert) async {
    if (_pairToken.isEmpty) return;
    _cryptoService ??= CryptoService(_pairToken);

    try {
      final summary = NetworkAlertSummary(
        severity: alert.severity,
        app: alert.app,
        alertType: alert.alertType,
        childName: alert.childName,
        timestamp: alert.timestamp,
      );
      
      final jsonStr = jsonEncode(summary.toJson());
      final encrypted = _cryptoService!.encryptPayload(jsonStr);

      final response = await http.post(
        Uri.parse('$_relayBaseUrl/api/alert/push'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_pairToken',
        },
        body: jsonEncode({
          'encryptedData': encrypted['data'],
          'iv': encrypted['iv']
        }),
      );

      if (response.statusCode == 201) {
        debugPrint('📤 Alert pushed to relay (summary)');
      } else {
        debugPrint('❌ Alert push failed: ${response.body}');
      }
    } catch (e) {
      debugPrint('❌ Alert push error: $e');
    }
  }

"""
content = content.replace(
  "  Future<void> pushHistory(WebHistory history, [String? itemId]) async {}",
  push_alert_to_relay + "  Future<void> pushHistory(WebHistory history, [String? itemId]) async {"
)

# 5. Fix pushHistory
push_history_full = """  Future<void> pushHistory(WebHistory history, [String? itemId]) async {
    if (_pairToken.isEmpty) return;
    _cryptoService ??= CryptoService(_pairToken);

    try {
      final jsonStr = jsonEncode(history.toJson());
      final encrypted = _cryptoService!.encryptPayload(jsonStr);

      final response = await http.post(
        Uri.parse('$_relayBaseUrl/api/history/push'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_pairToken',
        },
        body: jsonEncode({
          'encryptedData': encrypted['data'],
          'iv': encrypted['iv']
        }),
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
  }"""
content = content.replace("  Future<void> pushHistory(WebHistory history, [String? itemId]) async {}", push_history_full)

# 6. Fix polling
start_polling_search = """  void _startPolling() {
    _pollTimer?.cancel();
    // Pure local mode: no relay polling.
    // Instead, periodically ensure the parent stays connected to the child
    // via WebSocket over LAN (reconnect if connection dropped).
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _ensureParentConnected();
    });
    // Immediate first check
    _ensureParentConnected();
  }"""

start_polling_replace = """  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _ensureParentConnected();
      _pollAlerts();
      _pollHistory();
    });
    _ensureParentConnected();
    _pollAlerts();
    _pollHistory();
  }"""
content = content.replace(start_polling_search, start_polling_replace)

poll_alerts = """
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

          final decryptedStr = _cryptoService!.decryptPayload(encryptedData, iv);
          if (decryptedStr.isNotEmpty) {
            try {
              final summaryJson = jsonDecode(decryptedStr) as Map<String, dynamic>;
              final alert = NetworkAlertSummary.fromJson(summaryJson);
              _alertReceivedController.add(alert);
            } catch (e) {
              debugPrint('❌ Failed to parse decrypted alert: $e');
            }
          }
        }
      } else if (response.statusCode == 404 && response.body.contains('DEPLOYMENT_NOT_FOUND')) {
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

          final decryptedStr = _cryptoService!.decryptPayload(encryptedData, iv);
          if (decryptedStr.isNotEmpty) {
            try {
              final historyJson = jsonDecode(decryptedStr) as Map<String, dynamic>;
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
"""
content = content.replace(
    "  void _startSyncLoop() {",
    poll_alerts + "\n  void _startSyncLoop() {"
)

with open('lib/shared/services/network_sync_service.dart', 'w') as f:
    f.write(content)

