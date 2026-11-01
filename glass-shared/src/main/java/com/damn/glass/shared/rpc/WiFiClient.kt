package com.damn.glass.shared.rpc

import android.content.Context
import android.util.Log
import com.damn.anotherglass.shared.Constants
import com.damn.anotherglass.shared.rpc.IRPCClient
import com.damn.anotherglass.shared.rpc.PingAPI
import com.damn.anotherglass.shared.rpc.RPCHandler
import com.damn.anotherglass.shared.rpc.RPCMessage
import com.damn.anotherglass.shared.rpc.RPCMessageListener
import com.damn.anotherglass.shared.rpc.SerializerProvider
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.LinkedBlockingDeque
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class WiFiClient(private val hostIP: String? = null) : IRPCClient {

    @Volatile
    private var workerThread: WorkerThread? = null

    override fun start(context: Context, listener: RPCMessageListener) {
        if (workerThread != null) {
            Log.e(TAG, "Already started")
            return
        }

        val ip = hostIP ?: ConnectionUtils.getHostIPAddress(context)
        if (ip == null) {
            Log.e(TAG, "No host IP address")
            listener.onShutdown()
            return
        }

        Log.i(TAG, "Connecting to $ip")
        workerThread = WorkerThread(listener, ip).also { it.start() }
    }

    override fun send(message: RPCMessage) {
        workerThread?.send(message)
    }

    override fun stop() {
        workerThread?.let {
            it.shutdown()
            it.join()
        }
    }

    private inner class WorkerThread(
        listener: RPCMessageListener,
        private val ip: String
    ) : Thread() {

        private val handler: RPCHandler = RPCHandler(listener)
        private val queue = LinkedBlockingDeque<RPCMessage>(MAX_QUEUED_MESSAGES)

        @Volatile
        private var active = true

        @Volatile
        private var currentSocket: Socket? = null

        override fun run() {
            var attempt = 0
            while (active) {
                handler.onWaiting()
                val socket = Socket()
                currentSocket = socket
                try {
                    try {
                        socket.tcpNoDelay = true
                        // Closing a failed link must not block the service waiting for linger.
                        socket.setSoLinger(false, 0)
                    } catch (_: Exception) {
                    }
                    attempt++
                    Log.i(TAG, "Connecting to $ip (attempt $attempt/$MAX_RECONNECT_ATTEMPTS)...")
                    socket.connect(InetSocketAddress(ip, Constants.defaultPort), CONNECT_TIMEOUT_MS)
                    socket.soTimeout = PING_TIMEOUT_MS.toInt()
                    if (!active) {
                        break
                    }
                    try {
                        socket.tcpNoDelay = true
                    } catch (_: Exception) {
                    }
                    Log.i(TAG, "Connected to $ip on attempt $attempt")
                    attempt = 0 // Reset attempt counter on success
                    handler.onConnectionStarted(socket.inetAddress.toString())

                    runLoop(socket)

                    if (!active) {
                        break
                    }
                    Log.w(TAG, "Connection lost to $ip")
                    handler.onConnectionLost(null)
                } catch (e: Exception) {
                    if (!active) {
                        break
                    }
                    Log.w(TAG, "Connection failed (attempt $attempt/$MAX_RECONNECT_ATTEMPTS): ${e.message}")
                    handler.onConnectionLost(e.message)
                } finally {
                    // Replies belong to this connection, never to the next approved session.
                    queue.clear()
                    currentSocket = null
                    try {
                        socket.close()
                    } catch (_: Exception) {
                    }
                }

                if (!active) {
                    break
                }

                if (attempt >= MAX_RECONNECT_ATTEMPTS) {
                    Log.e(TAG, "Exhausted all $MAX_RECONNECT_ATTEMPTS reconnect attempts to $ip")
                    break
                }

                try {
                    sleep(RECONNECT_DELAY_MS)
                } catch (_: InterruptedException) {
                    break
                }
            }
            workerThread = null
            handler.onShutdown()
        }

        private fun runLoop(socket: Socket) {
            val serializer = SerializerProvider.getSerializer(socket.getInputStream(), socket.getOutputStream())
            val connected = AtomicBoolean(true)
            // A single writer owns serialization. Blocking queue waits wake immediately on send;
            // the timeout exists only to emit an idle heartbeat, never to pace data transfers.
            val writer = Thread({
                try {
                    while (active && connected.get()) {
                        val message = queue.poll(PING_INTERVAL_MS, TimeUnit.MILLISECONDS)
                            ?: RPCMessage(PingAPI.ID, null)
                        serializer.writeMessage(message)
                    }
                } catch (e: Exception) {
                    if (active && connected.get()) Log.w(TAG, "Wi-Fi writer stopped: ${e.message}")
                } finally {
                    connected.set(false)
                    try { socket.close() } catch (_: Exception) { }
                }
            }, "Glass-WiFi-Writer")
            writer.start()
            try {
                // A blocking reader runs independently of the writer. Socket timeout detects a
                // silent peer; neither queued replies nor partial packets incur polling sleeps.
                while (active && connected.get()) {
                    val message = serializer.readMessage()
                    if (message?.service == null) return
                    when (message.service) {
                        PingAPI.ID -> enqueue(RPCMessage(PingAPI.PONG_ID, null), priority = true)
                        PingAPI.PONG_ID -> Unit
                        else -> handler.onDataReceived(message)
                    }
                }
            } finally {
                connected.set(false)
                try { socket.close() } catch (_: Exception) { }
                writer.interrupt()
                writer.join()
            }
        }

        private fun enqueue(message: RPCMessage, priority: Boolean = false) {
            if (!active) return
            val accepted = if (priority) queue.offerFirst(message) else queue.offerLast(message)
            if (!accepted) {
                // Bound the memory used by large media replies. A full queue is a broken/slow
                // connection, not permission to retain an unbounded video in Glass memory.
                Log.w(TAG, "Wi-Fi send backlog exceeded its limit; reconnecting")
                try { currentSocket?.close() } catch (_: Exception) { }
            }
        }

        fun send(message: RPCMessage) {
            enqueue(message)
        }

        fun shutdown() {
            active = false
            queue.clear()
            // Closing wakes a blocking read/connect/write immediately; no shutdown sleep.
            try { currentSocket?.close() } catch (_: Exception) { }
            interrupt()
        }
    }

    companion object {
        private const val TAG = "WiFiClient"
        private const val CONNECT_TIMEOUT_MS = 5000
        private const val MAX_RECONNECT_ATTEMPTS = 5
        private const val RECONNECT_DELAY_MS = 2000L
        private const val PING_INTERVAL_MS = 5000L
        private const val PING_TIMEOUT_MS = 15000L
        private const val MAX_QUEUED_MESSAGES = 32
    }
}
