package com.fire.adb

import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 本机 `127.0.0.1:28165`。
 * 桌面经 adb 的 `tcp:` 服务连进来。抽象套接字无论谁连谁都会被 SELinux 拒绝。
 */
object ChatHub {
    private val main = Handler(Looper.getMainLooper())
    private val lock = Any()
    private val started = AtomicBoolean(false)
    private var output: OutputStream? = null
    var onBytes: ((ByteArray) -> Unit)? = null
    var onLinked: (() -> Unit)? = null

    fun connect() {
        if (!started.compareAndSet(false, true)) return
        Thread({
            val server = ServerSocket()
            try {
                server.reuseAddress = true
                server.bind(
                    InetSocketAddress(InetAddress.getByName("127.0.0.1"), PORT),
                    1,
                )
            } catch (error: Exception) {
                Log.w(TAG, "聊天端口没有打开", error)
                started.set(false)
                try {
                    server.close()
                } catch (_: Exception) {
                }
                return@Thread
            }
            Log.i(TAG, "聊天端口已打开 $PORT")
            while (true) {
                val socket = try {
                    server.accept()
                } catch (error: Exception) {
                    Log.w(TAG, "聊天接入失败", error)
                    break
                }
                serve(socket)
            }
        }, "fire-chat-port").start()
    }

    private fun serve(socket: Socket) {
        var stream: OutputStream? = null
        try {
            socket.tcpNoDelay = true
            stream = socket.outputStream
            synchronized(lock) {
                output = stream
            }
            Log.i(TAG, "已接入桌面聊天")
            main.post { onLinked?.invoke() }
            val input = socket.inputStream
            val buffer = ByteArray(8192)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                val chunk = buffer.copyOf(count)
                main.post { onBytes?.invoke(chunk) }
            }
        } catch (error: Exception) {
            Log.w(TAG, "聊天通道断开", error)
        } finally {
            synchronized(lock) {
                if (output === stream) output = null
            }
            try {
                socket.close()
            } catch (_: Exception) {
            }
        }
    }

    fun send(bytes: ByteArray): Boolean {
        val dest = synchronized(lock) { output } ?: return false
        Thread {
            try {
                synchronized(lock) {
                    dest.write(bytes)
                    dest.flush()
                }
            } catch (error: Exception) {
                Log.w(TAG, "聊天没有送出", error)
                synchronized(lock) {
                    if (output === dest) output = null
                }
            }
        }.start()
        return true
    }

    private const val TAG = "FireAdb"
    const val PORT = 28165
}
