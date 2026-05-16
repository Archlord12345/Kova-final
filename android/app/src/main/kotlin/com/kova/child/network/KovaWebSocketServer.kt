package com.kova.child.network

import android.util.Log
import org.java_websocket.WebSocket
import org.java_websocket.handshake.ClientHandshake
import org.java_websocket.server.WebSocketServer
import java.net.InetSocketAddress

class KovaWebSocketServer(
    port: Int,
    private val onMessageReceived: (String) -> Unit,
    private val onClientConnected: () -> Unit,
    private val onClientDisconnected: () -> Unit
) : WebSocketServer(InetSocketAddress(port)) {

    private val TAG = "KovaWSServer"
    private var clientSocket: WebSocket? = null

    override fun onOpen(conn: WebSocket?, handshake: ClientHandshake?) {
        Log.d(TAG, "New connection: ${conn?.remoteSocketAddress}")
        clientSocket = conn
        onClientConnected()
    }

    override fun onClose(conn: WebSocket?, code: Int, reason: String?, remote: Boolean) {
        Log.d(TAG, "Connection closed: $reason")
        if (conn == clientSocket) {
            clientSocket = null
        }
        onClientDisconnected()
    }

    override fun onMessage(conn: WebSocket?, message: String?) {
        Log.d(TAG, "Message received: $message")
        if (message != null) {
            onMessageReceived(message)
        }
    }

    override fun onError(conn: WebSocket?, ex: Exception?) {
        Log.e(TAG, "Server error: ${ex?.message}")
    }

    override fun onStart() {
        Log.d(TAG, "Server started successfully on port $port")
    }

    fun broadcastMessage(message: String): Boolean {
        if (clientSocket != null && clientSocket!!.isOpen) {
            try {
                clientSocket!!.send(message)
                return true
            } catch (e: Exception) {
                Log.e(TAG, "Error sending message: ${e.message}")
            }
        } else {
            Log.w(TAG, "Cannot send message: No active client connection")
        }
        return false
    }
}
