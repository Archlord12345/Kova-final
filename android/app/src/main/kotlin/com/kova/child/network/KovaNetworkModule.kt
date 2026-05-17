package com.kova.child.network

import android.content.Context
import android.util.Log
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.net.wifi.WifiManager
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class KovaNetworkModule(private val context: Context, private val flutterEngine: FlutterEngine) {
    private val TAG = "KovaNetworkModule"
    private val METHOD_CHANNEL = "com.kova.child/network_commands"
    private val EVENT_CHANNEL = "com.kova.child/network_events"

    private var eventSink: EventChannel.EventSink? = null
    
    private val nsdManager = KovaNsdManager(context)
    private var connectivity: KovaConnectivity? = null
    private var wsServer: KovaWebSocketServer? = null
    private var wsClient: KovaWebSocketClient? = null

    private var multicastLock: WifiManager.MulticastLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    init {
        setupChannels()
        setupConnectivity()
    }

    private fun setupChannels() {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler { call, result ->
                Log.d(TAG, "📡 [NATIVE] Method call: ${call.method}")
                when (call.method) {
                    "startServer" -> {
                        val port = call.argument<Int>("port") ?: 18757
                        val name = call.argument<String>("name") ?: "KovaChild"
                        val attributes = call.argument<Map<String, String>>("attributes")
                        acquireWifiLock()
                        startServer(port, name, attributes)
                        result.success(true)
                    }
                    "stopServer" -> {
                        stopServer()
                        result.success(true)
                    }
                    "startDiscovery" -> {
                        startDiscovery()
                        result.success(true)
                    }
                    "stopDiscovery" -> {
                        nsdManager.stopDiscovery()
                        releaseMulticastLock()
                        result.success(true)
                    }
                    "connectToParent" -> {
                        val host = call.argument<String>("host")
                        val port = call.argument<Int>("port")
                        if (host != null && port != null) {
                            connectClient(host, port)
                            result.success(true)
                        } else {
                            result.error("INVALID_ARGS", "Host or port missing", null)
                        }
                    }
                    "disconnectClient" -> {
                        wsClient?.disconnect()
                        result.success(true)
                    }
                    "sendMessage" -> {
                        val message = call.argument<String>("message") ?: ""
                        val success = sendMessage(message)
                        result.success(success)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
    }

    private fun setupConnectivity() {
        connectivity = KovaConnectivity(context) { isConnected ->
            Log.d(TAG, "🌐 Network status changed: connected=$isConnected")
            sendEvent("network_status", JSONObject().put("connected", isConnected).toString())
        }
        connectivity?.startMonitoring()
    }

    // ── Server Methods (Child Side) ──
    private fun startServer(port: Int, serviceName: String, attributes: Map<String, String>? = null) {
        stopServer()
        Log.d(TAG, "🚀 Starting WebSocket server on port $port ($serviceName)")
        wsServer = KovaWebSocketServer(
            port = port,
            onMessageReceived = { message ->
                Log.d(TAG, "📥 [SERVER] Message received: $message")
                sendEvent("message_received", message)
            },
            onClientConnected = {
                Log.d(TAG, "🤝 [SERVER] Client connected")
                sendEvent("client_connected", "{}")
            },
            onClientDisconnected = {
                Log.d(TAG, "👋 [SERVER] Client disconnected")
                sendEvent("client_disconnected", "{}")
            }
        )
        wsServer?.start()
        nsdManager.registerService(serviceName, port, attributes)
    }

    private fun stopServer() {
        Log.d(TAG, "🛑 Stopping WebSocket server and releasing locks")
        wsServer?.stop()
        releaseWifiLock()
        wsServer = null
        nsdManager.unregisterService()
    }

    // ── Discovery & Client Methods (Parent Side) ──
    private fun startDiscovery() {
        Log.d(TAG, "🔍 Starting mDNS discovery")
        acquireMulticastLock()
        nsdManager.discoverServices { ip, port, name, attributes ->
            Log.d(TAG, "✨ [DISCOVERY] Found service: $name at $ip:$port")
            val data = JSONObject().apply {
                put("ip", ip)
                put("port", port)
                put("name", name)
                put("attributes", JSONObject(attributes as Map<*, *>))
            }
            sendEvent("device_found", data.toString())
        }
    }

    private fun connectClient(host: String, port: Int) {
        Log.d(TAG, "🔗 Connecting to $host:$port")
        wsClient?.disconnect()
        wsClient = KovaWebSocketClient(
            host = host,
            port = port,
            onMessageReceived = { message ->
                Log.d(TAG, "📥 [CLIENT] Message received: $message")
                sendEvent("message_received", message)
            },
            onConnected = {
                Log.d(TAG, "🤝 [CLIENT] Connected to server")
                sendEvent("client_connected", "{}")
            },
            onDisconnected = {
                Log.d(TAG, "👋 [CLIENT] Disconnected from server")
                sendEvent("client_disconnected", "{}")
            }
        )
        wsClient?.connect()
    }

    // ── Shared ──
    private fun sendMessage(message: String): Boolean {
        // Try server broadcast first (if child), then client send (if parent)
        val success = wsServer?.broadcastMessage(message) ?: wsClient?.sendMessage(message) ?: false
        if (!success) {
            Log.w(TAG, "❌ Failed to send message (no active server/client): $message")
        }
        return success
    }

    private fun sendEvent(type: String, payload: String) {
        val eventData = mapOf("type" to type, "payload" to payload)

        // Intercept alert messages to show a native notification
        if (type == "message_received") {
            try {
                val json = JSONObject(payload)
                if (json.optString("type") == "alert") {
                    val alertData = json.optJSONObject("alert")
                    if (alertData != null) {
                        val appName = alertData.optString("app", "Application")
                        val reason = alertData.optString("reason", "Activité suspecte détectée")
                        showNativeNotification(appName, reason)
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to parse message for notification: ${e.message}")
            }
        }

        // Run on UI thread since MethodChannel requires it
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            eventSink?.success(eventData)
        }
    }

    private fun showNativeNotification(title: String, message: String) {
        val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = "kova_alerts_channel"

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Kova Security Alerts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Critical alerts from child device"
            }
            notificationManager.createNotificationChannel(channel)
        }

        // Create an Intent to open the app when the notification is clicked
        val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK
        }
        val pendingIntent: PendingIntent = PendingIntent.getActivity(
            context, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val iconResId = context.resources.getIdentifier("ic_launcher", "mipmap", context.packageName)
        val finalIcon = if (iconResId != 0) iconResId else android.R.drawable.ic_dialog_alert

        val builder = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(finalIcon)
            .setContentTitle("Kova Alert: $title")
            .setContentText(message)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)

        notificationManager.notify(System.currentTimeMillis().toInt(), builder.build())
    }

    fun dispose() {
        stopServer()
        wsClient?.disconnect()
        nsdManager.stopDiscovery()
        connectivity?.stopMonitoring()
    }

    private fun acquireMulticastLock() {
        try {
            val wifiManager = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifiManager.createMulticastLock("kova_discovery").apply {
                setReferenceCounted(true)
                acquire()
            }
            Log.d(TAG, "✅ MulticastLock acquired")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to acquire MulticastLock: ${e.message}")
        }
    }

    private fun releaseMulticastLock() {
        try {
            multicastLock?.let {
                if (it.isHeld) {
                    it.release()
                    Log.d(TAG, "✅ MulticastLock released")
                }
            }
            multicastLock = null
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error releasing MulticastLock: ${e.message}")
        }
    }

    private fun acquireWifiLock() {
        try {
            val wm = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifiLock = wm.createWifiLock(
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                else
                    @Suppress("DEPRECATION") WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                "kova_data_socket"
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
            Log.d(TAG, "✅ WifiLock acquired (HIGH_PERF)")
        } catch (e: Exception) {
            Log.e(TAG, "❌ Failed to acquire WifiLock: ${e.message}")
        }
    }

    private fun releaseWifiLock() {
        try {
            wifiLock?.let {
                if (it.isHeld) {
                    it.release()
                    Log.d(TAG, "✅ WifiLock released")
                }
            }
            wifiLock = null
        } catch (e: Exception) {
            Log.e(TAG, "❌ Error releasing WifiLock: ${e.message}")
        }
    }
}
