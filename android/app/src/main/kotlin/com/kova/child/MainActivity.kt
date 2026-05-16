package com.kova.child

import android.content.Intent
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Context
import android.view.accessibility.AccessibilityManager
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.kova.child.network.KovaNetworkModule

class MainActivity : FlutterActivity() {
  private val SETUP_CHANNEL = "com.kova.child/setup"
  private val BLOCKER_CHANNEL = "com.kova.child/blocker"
  private var networkModule: KovaNetworkModule? = null

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    networkModule = KovaNetworkModule(context, flutterEngine)

    // ── Register the 3 monitoring channels ──
    // KovaChannelManager is used by all native services
    // to send data to Flutter across the 3 channels:
    //   com.kova.child/notifications
    //   com.kova.child/keyboard
    //   com.kova.child/accessibility
    KovaChannelManager.register(flutterEngine)

    // ── Setup Channel ──
    // Handles child device setup and service status checks
    MethodChannel(
      flutterEngine.dartExecutor.binaryMessenger,
      SETUP_CHANNEL
    ).setMethodCallHandler { call, result ->
      when (call.method) {
        "hideIcon" -> {
          hideAppIcon()
          result.success(true)
        }
        "activateDeviceAdmin" -> {
          activateDeviceAdmin()
          result.success(true)
        }
        "startProtection" -> {
          startForegroundService()
          result.success(true)
        }
        "startParentProtection" -> {
          startParentForegroundService()
          result.success(true)
        }
        "syncDynamicRules" -> {
          val rulesJson = call.argument<String>("rulesJson")
          if (rulesJson != null) {
            KovaAccessibilityService.updateRules(rulesJson)
            result.success(true)
          } else {
            result.error("INVALID_ARGS", "rulesJson is null", null)
          }
        }
        // ── Status checks ──
        "isAccessibilityEnabled" -> {
          result.success(isAccessibilityServiceEnabled())
        }
        "isNotificationListenerEnabled" -> {
          result.success(isNotificationListenerEnabled())
        }
        "isKeyboardEnabled" -> {
          result.success(isKovaKeyboardEnabled())
        }
        "isKeyboardEnabledInSettings" -> {
          result.success(isKeyboardEnabledInSettings())
        }
        // ── Settings launchers ──
        "openAccessibilitySettings" -> {
          openAccessibilitySettings()
          result.success(true)
        }
        "openNotificationListenerSettings" -> {
          openNotificationListenerSettings()
          result.success(true)
        }
        "openInputMethodSettings" -> {
          openInputMethodSettings()
          result.success(true)
        }
        "openInputMethodPicker" -> {
          openInputMethodPicker()
          result.success(true)
        }
        "isBatteryOptimizationIgnored" -> {
          val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
          result.success(pm.isIgnoringBatteryOptimizations(packageName))
        }
        "requestIgnoreBatteryOptimizations" -> {
          if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val intent = Intent(
              Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
              android.net.Uri.parse("package:$packageName")
            )
            startActivity(intent)
          }
          result.success(true)
        }
        "openAutoStartSettings" -> {
          val success = openAutoStartSettings()
          result.success(success)
        }
        "openHuaweiProtectedApps" -> {
          // EMUI-specific: Direct link to protected apps settings
          val success = openHuaweiProtectedApps()
          result.success(success)
        }
        "getDeviceManufacturer" -> {
          result.success(Build.MANUFACTURER ?: "unknown")
        }
        "getSdkVersion" -> {
          result.success(Build.VERSION.SDK_INT)
        }
        "acquireMulticastLock" -> {
          acquireMulticastLock()
          result.success(true)
        }
        "releaseMulticastLock" -> {
          releaseMulticastLock()
          result.success(true)
        }
        "acquireWifiLock" -> {
          acquireWifiLock()
          result.success(true)
        }
        "releaseWifiLock" -> {
          releaseWifiLock()
          result.success(true)
        }
        "blockAppViaService" -> {
          // Reliable block via ForegroundService — works even when Flutter is backgrounded
          val pkg = call.argument<String>("pkg")
          val reason = call.argument<String>("reason") ?: "App is blocked for your safety"
          if (pkg != null) {
            val serviceIntent = Intent(this, KovaForegroundService::class.java).apply {
              action = KovaForegroundService.ACTION_BLOCK_APP
              putExtra(KovaForegroundService.EXTRA_BLOCK_PACKAGE, pkg)
              putExtra(KovaForegroundService.EXTRA_BLOCK_REASON, reason)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
              startForegroundService(serviceIntent)
            } else {
              startService(serviceIntent)
            }
            result.success(true)
          } else {
            result.error("INVALID_PKG", "Package name required", null)
          }
        }
        // ── Deep-link settings openers for parent permission screen ──
        "openNotificationSettings" -> {
          try {
            val intent = Intent().apply {
              if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                action = Settings.ACTION_APP_NOTIFICATION_SETTINGS
                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
              } else {
                action = "android.settings.APP_NOTIFICATION_SETTINGS"
                putExtra("app_package", packageName)
                putExtra("app_uid", applicationInfo.uid)
              }
            }
            startActivity(intent)
          } catch (e: Exception) {
            // Fallback: generic app settings
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
              data = android.net.Uri.parse("package:$packageName")
            })
          }
          result.success(true)
        }
        "openExactAlarmSettings" -> {
          try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
              val intent = Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
                data = android.net.Uri.parse("package:$packageName")
              }
              startActivity(intent)
            } else {
              // Pre-Android 12: open general app settings
              startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = android.net.Uri.parse("package:$packageName")
              })
            }
          } catch (e: Exception) {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
              data = android.net.Uri.parse("package:$packageName")
            })
          }
          result.success(true)
        }
        "openBatterySettings" -> {
          try {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
          } catch (e: Exception) {
            startActivity(Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS))
          }
          result.success(true)
        }
        else -> result.notImplemented()
      }
    }

    // ── Blocker Channel ──
    // Handles app blocking overlay
    MethodChannel(
      flutterEngine.dartExecutor.binaryMessenger,
      BLOCKER_CHANNEL
    ).setMethodCallHandler { call, result ->
      when (call.method) {
        "blockApp" -> {
          Log.d("KOVA_BLOCK", "[OVERLAY PIPELINE] MethodChannel blockApp called")
          val pkg = call.argument<String>("pkg")
          if (pkg != null) {
            Log.d("KOVA_BLOCK", "[OVERLAY PIPELINE] Showing block overlay for package: $pkg")
            showBlockOverlay(pkg)
            result.success(true)
            Log.d("KOVA_BLOCK", "[OVERLAY PIPELINE] Block overlay launched successfully")
          } else {
            Log.e("KOVA_BLOCK", "[OVERLAY PIPELINE] ERROR: Package name is null")
            result.error("INVALID_PKG", "Package name required", null)
          }
        }
        "unblockApp" -> {
          // ─── FIX: Delegate to ForegroundService, NOT SharedPreferences ─────
          // The old approach wrote a SharedPreference and hoped BlockOverlayActivity
          // would notice. That never worked — BlockOverlayActivity had no listener.
          //
          // The new approach broadcasts via KovaForegroundService which uses
          // LocalBroadcastManager. BlockOverlayActivity has a registered receiver
          // and dismisses instantly.
          //
          // IMPORTANT: This also works when Flutter engine is dead (backgrounded)
          // because KovaForegroundService handles FCM-triggered unlocks directly.
          val pkg = call.argument<String>("pkg")
          delegateUnlockToService(pkg)
          result.success(true)
        }
        else -> result.notImplemented()
      }
    }
  }

  override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
    super.cleanUpFlutterEngine(flutterEngine)
    KovaChannelManager.unregister()
    networkModule?.dispose()
    networkModule = null
  }

  // ═══════════════════════════════════════════════
  // Setup actions
  // ═══════════════════════════════════════════════

  /// Hide the app icon from launcher
  private fun hideAppIcon() {
    try {
      val componentName = ComponentName(this, MainActivity::class.java)
      packageManager.setComponentEnabledSetting(
        componentName,
        PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
        PackageManager.DONT_KILL_APP
      )
    } catch (e: Exception) {
      e.printStackTrace()
    }
  }

  /// Activate device admin for app protection
  private fun activateDeviceAdmin() {
    try {
      val dpmIntent = Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
      dpmIntent.putExtra(
        DevicePolicyManager.EXTRA_DEVICE_ADMIN,
        ComponentName(this, KovaDeviceAdmin::class.java)
      )
      dpmIntent.putExtra(
        DevicePolicyManager.EXTRA_ADD_EXPLANATION,
        "KOVA needs device admin for full protection"
      )
      startActivity(dpmIntent)
    } catch (e: Exception) {
      e.printStackTrace()
    }
  }

  /// Start foreground protection service
  private fun startForegroundService() {
    try {
      val serviceIntent = Intent(this, KovaForegroundService::class.java)
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        startForegroundService(serviceIntent)
      } else {
        startService(serviceIntent)
      }
    } catch (e: Exception) {
      e.printStackTrace()
    }
  }

  /// Start parent foreground service
  private fun startParentForegroundService() {
    try {
      val serviceIntent = Intent(this, KovaParentForegroundService::class.java)
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        startForegroundService(serviceIntent)
      } else {
        startService(serviceIntent)
      }
    } catch (e: Exception) {
      e.printStackTrace()
    }
  }

  // ═══════════════════════════════════════════════
  // Status checks
  // ═══════════════════════════════════════════════

  /// Check if AccessibilityService is enabled
  /// Uses BOTH Settings check AND live AccessibilityManager check for EMUI compatibility
  private fun isAccessibilityServiceEnabled(): Boolean {
    // Method 1: Settings check (standard Android)
    val settingsCheck = try {
      val service = "${packageName}/${KovaAccessibilityService::class.java.canonicalName}"
      val enabledServices = Settings.Secure.getString(
        contentResolver,
        Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
      ) ?: ""
      enabledServices.contains(service)
    } catch (e: Exception) {
      false
    }

    // Method 2: Live AccessibilityManager check (EMUI-compatible)
    // This queries the actual running state rather than stored settings
    val liveCheck = try {
      val am = getSystemService(Context.ACCESSIBILITY_SERVICE) as AccessibilityManager
      val runningServices = am.getEnabledAccessibilityServiceList(
        AccessibilityServiceInfo.FEEDBACK_ALL_MASK
      )
      runningServices.any {
        it.resolveInfo.serviceInfo.packageName == packageName
      }
    } catch (e: Exception) {
      false
    }

    val result = settingsCheck && liveCheck
    Log.d("KOVA_ACCESS", "[ACCESSIBILITY CHECK] Settings check: $settingsCheck, Live check: $liveCheck, Result: $result")
    return result
  }

  /// Check if NotificationListener is enabled
  private fun isNotificationListenerEnabled(): Boolean {
    return try {
      val enabledListeners = Settings.Secure.getString(
        contentResolver,
        "enabled_notification_listeners"
      ) ?: ""
      enabledListeners.contains(packageName)
    } catch (e: Exception) {
      false
    }
  }

  /// Check if KOVA keyboard is the active IME
  private fun isKovaKeyboardEnabled(): Boolean {
    return try {
      val imeId = "${packageName}/${KovaInputMethodService::class.java.canonicalName}"
      // Check if enabled in system settings
      val enabledImes = Settings.Secure.getString(
        contentResolver,
        Settings.Secure.ENABLED_INPUT_METHODS
      ) ?: ""
      val isEnabled = enabledImes.contains(imeId)

      // Check if currently selected
      val currentIme = Settings.Secure.getString(
        contentResolver,
        Settings.Secure.DEFAULT_INPUT_METHOD
      ) ?: ""
      val isSelected = currentIme.contains(imeId)

      // Return true only if both enabled AND selected
      isEnabled && isSelected
    } catch (e: Exception) {
      false
    }
  }

  private fun isKeyboardEnabledInSettings(): Boolean {
    return try {
      val imeId = "${packageName}/${KovaInputMethodService::class.java.canonicalName}"
      val enabledImes = Settings.Secure.getString(
        contentResolver,
        Settings.Secure.ENABLED_INPUT_METHODS
      ) ?: ""
      enabledImes.contains(imeId)
    } catch (e: Exception) {
      false
    }
  }

  // ═══════════════════════════════════════════════
  // Settings launchers
  // ═══════════════════════════════════════════════

  /// Open accessibility settings
  private fun openAccessibilitySettings() {
    try {
      startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
    } catch (e: Exception) {
      e.printStackTrace()
    }
  }

  /// Open notification listener settings
  private fun openNotificationListenerSettings() {
    try {
      val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP_MR1) {
        Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
      } else {
        Intent("android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS")
      }
      startActivity(intent)
    } catch (e: Exception) {
      e.printStackTrace()
    }
  }

  /// Open input method settings (to enable KOVA keyboard)
  private fun openInputMethodSettings() {
    try {
      startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
    } catch (e: Exception) {
      e.printStackTrace()
    }
  }

  /// Show IME picker (to switch to KOVA keyboard)
  private fun openInputMethodPicker() {
    try {
      val imm = getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager
      imm.showInputMethodPicker()
    } catch (e: Exception) {
      e.printStackTrace()
    }
  }

  // ═══════════════════════════════════════════════
  // Battery & AutoStart (OEMs)
  // ═══════════════════════════════════════════════

  private fun requestIgnoreBatteryOptimizations() {
    try {
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
        intent.data = android.net.Uri.parse("package:$packageName")
        startActivity(intent)
    } catch (e: Exception) {
        // Fallback to general settings if the specific intent is restricted
        try {
            val fallback = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            startActivity(fallback)
        } catch (e2: Exception) {
            e2.printStackTrace()
        }
    }
  }

  private fun openAutoStartSettings(): Boolean {
    try {
        val manufacturer = Build.MANUFACTURER?.lowercase() ?: return false
        val intent = Intent()
        when {
            manufacturer.contains("xiaomi") -> intent.component = ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity")
            manufacturer.contains("oppo") -> intent.component = ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity")
            manufacturer.contains("vivo") -> intent.component = ComponentName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity")
            manufacturer.contains("letv") -> intent.component = ComponentName("com.letv.android.letvsafe", "com.letv.android.letvsafe.AutobootManageActivity")
            manufacturer.contains("honor") || manufacturer.contains("huawei") -> {
                // Try primary Huawei protected apps intent first
                return openHuaweiProtectedApps()
            }
            else -> return false // No specific autostart for this OEM
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
        return true
    } catch (e: Exception) {
        e.printStackTrace()
        return false
    }
  }

  /// Open Huawei Protected Apps settings (EMUI-specific)
  /// Tries multiple intents as EMUI versions vary
  private fun openHuaweiProtectedApps(): Boolean {
    Log.d("KOVA_HUAWEI", "[HUAWEI ONBOARDING] Opening protected apps settings...")

    // Intent 1: StartupNormalAppListActivity (newer EMUI versions)
    try {
        val intent = Intent().apply {
            component = ComponentName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"
            )
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
        Log.d("KOVA_HUAWEI", "[HUAWEI ONBOARDING] Opened StartupNormalAppListActivity")
        return true
    } catch (e: Exception) {
        Log.w("KOVA_HUAWEI", "[HUAWEI ONBOARDING] Primary intent failed: ${e.message}")
    }

    // Intent 2: ProtectActivity (older EMUI versions)
    try {
        val intent = Intent().apply {
            component = ComponentName(
                "com.huawei.systemmanager",
                "com.huawei.systemmanager.optimize.process.ProtectActivity"
            )
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
        Log.d("KOVA_HUAWEI", "[HUAWEI ONBOARDING] Opened ProtectActivity (fallback)")
        return true
    } catch (e: Exception) {
        Log.w("KOVA_HUAWEI", "[HUAWEI ONBOARDING] Fallback intent failed: ${e.message}")
    }

    Log.e("KOVA_HUAWEI", "[HUAWEI ONBOARDING] All Huawei intents failed")
    return false
  }

  // ═══════════════════════════════════════════════
  // Blocker actions
  // ═══════════════════════════════════════════════


  /// Show block overlay for an app
  private fun showBlockOverlay(pkg: String) {
    try {
      BlockOverlayActivity.start(this, pkg, "App is blocked for your safety")
    } catch (e: Exception) {
      e.printStackTrace()
    }
  }

  // ─── Delegate Unlock to Service Layer ────────────────────────────────────
  // Sending the unlock through the ForegroundService ensures it works even when
  // this Activity is not in the foreground or Flutter engine has been killed.
  private fun delegateUnlockToService(packageName: String?) {
    val serviceIntent = Intent(this, KovaForegroundService::class.java).apply {
      action = KovaForegroundService.ACTION_REMOTE_UNLOCK
      if (packageName != null) {
        putExtra(KovaForegroundService.EXTRA_UNLOCK_PACKAGE, packageName)
      }
    }
    startService(serviceIntent)
  }

  // ─── Ensure ForegroundService is Running ─────────────────────────────────
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    ensureProtectionServiceRunning()
  }

  private fun ensureProtectionServiceRunning() {
    val intent = Intent(this, KovaForegroundService::class.java)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      startForegroundService(intent)
    } else {
      startService(intent)
    }
  }

  // ─── Multicast Lock for UDP Discovery ───────────────────────────────────
  // Prevents Android kernel from dropping incoming UDP broadcast/multicast
  // packets when the Wi-Fi chip enters Power Save Mode (screen off).
  private var multicastLock: android.net.wifi.WifiManager.MulticastLock? = null

  private fun acquireMulticastLock() {
    try {
      val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager
      multicastLock = wifiManager.createMulticastLock("kova_discovery").apply {
        setReferenceCounted(true)
        acquire()
      }
      Log.d("KOVA_LAN", "MulticastLock acquired")
    } catch (e: Exception) {
      Log.e("KOVA_LAN", "Failed to acquire MulticastLock: ${e.message}")
    }
  }

  private fun releaseMulticastLock() {
    try {
      multicastLock?.let {
        if (it.isHeld) {
          it.release()
          Log.d("KOVA_LAN", "MulticastLock released")
        }
      }
      multicastLock = null
    } catch (e: Exception) {
      Log.e("KOVA_LAN", "Error releasing MulticastLock: ${e.message}")
    }
  }

  // ─── WiFi Lock for TCP Data Socket ──────────────────────────────────────
  // Keeps the Wi-Fi radio in HIGH_PERF mode while paired.
  // Without this, the radio enters power-save between TCP packets,
  // causing 200-400ms latency spikes on the alert delivery socket.
  // KDE Connect uses this same pattern for their persistent TCP connection.
  private var wifiLock: android.net.wifi.WifiManager.WifiLock? = null

  @Suppress("DEPRECATION") // WIFI_MODE_FULL_HIGH_PERF is deprecated in API 29 but still works
  private fun acquireWifiLock() {
    try {
      val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager
      wifiLock = wm.createWifiLock(
        android.net.wifi.WifiManager.WIFI_MODE_FULL_HIGH_PERF,
        "kova_data_socket"
      ).apply {
        setReferenceCounted(false)
        acquire()
      }
      Log.d("KOVA_LAN", "WifiLock (HIGH_PERF) acquired — TCP latency minimized")
    } catch (e: Exception) {
      Log.e("KOVA_LAN", "Failed to acquire WifiLock: ${e.message}")
    }
  }

  private fun releaseWifiLock() {
    try {
      wifiLock?.let {
        if (it.isHeld) {
          it.release()
          Log.d("KOVA_LAN", "WifiLock released")
        }
      }
      wifiLock = null
    } catch (e: Exception) {
      Log.e("KOVA_LAN", "Error releasing WifiLock: ${e.message}")
    }
  }
}
