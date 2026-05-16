// core/app_mode.dart — App mode management (parent vs child)
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

/// The two operating modes for KOVA
enum AppMode { parent, child, notConfigured }

/// Manages app mode selection and persistence
/// This is the heart of the dual-mode system
class AppModeManager {
  static const String _modeKey = 'app_mode';
  static const String _childIdKey = 'child_id';
  static const String _parentPinHashKey = 'parent_pin_hash';

  static AppMode _currentMode = AppMode.notConfigured;
  static AppMode get currentMode => _currentMode;

  static Future<AppMode> getMode() async {
    final prefs = await SharedPreferences.getInstance();
    final mode = prefs.getString(_modeKey);
    _currentMode = switch (mode) {
      'parent' => AppMode.parent,
      'child' => AppMode.child,
      _ => AppMode.notConfigured,
    };
    return _currentMode;
  }

  /// Initialize app as PARENT MODE with a PIN
  /// Called after user creates PIN on welcome screen
  static Future<void> setParentMode(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final hash = sha256.convert(utf8.encode(pin)).toString();
    await prefs.setString(_modeKey, 'parent');
    await prefs.setString(_parentPinHashKey, hash);
    _currentMode = AppMode.parent;
  }

  /// Initialize app as CHILD MODE with the resolved child UUID.
  /// Called from ParentConnectionScreen after the pair code is validated and
  /// the child record is found — passes the child's UUID (not the raw code).
  static Future<bool> setChildMode(String childId) async {
    if (childId.isEmpty) return false;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_modeKey, 'child');
    await prefs.setString(_childIdKey, childId);
    _currentMode = AppMode.child;

    return true;
  }

  /// Verify parent PIN for sensitive operations
  /// (e.g., viewing child alerts, changing settings)
  static Future<bool> verifyPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final storedHash = prefs.getString(_parentPinHashKey);
    if (storedHash == null) return false;
    final hash = sha256.convert(utf8.encode(pin)).toString();
    return hash == storedHash;
  }

  /// Get the linked child ID (child mode only)
  /// This is the pairing code that identifies which child record
  /// this device is monitoring for
  static Future<String?> getChildId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_childIdKey);
  }

  /// Reset app mode (requires PIN for security)
  /// Use this to switch between parent and child mode
  static Future<bool> resetMode(String pin) async {
    // Only parent can reset
    final isValid = await verifyPin(pin);
    if (!isValid) return false;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_modeKey);
    await prefs.remove(_childIdKey);
    _currentMode = AppMode.notConfigured;
    return true;
  }

  /// Get parent PIN hash (for storage/comparison only)
  /// Never expose the actual PIN
  static Future<String?> getPinHash() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_parentPinHashKey);
  }
}
