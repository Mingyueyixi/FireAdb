package com.fire.adb

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pendingAccess: MethodChannel.Result? = null
    private var awaitingSettings = false
    private var leftForSettings = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasAllFilesAccess" -> result.success(hasAllFilesAccess())
                    "requestsManageAllFiles" ->
                        result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                    "requestAllFilesAccess" -> requestAllFilesAccess(result)
                    "externalFilesDirectory" -> externalFilesDirectory(result)
                    "openPath" -> openPath(call.arguments, result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fireadb/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "localSerial" -> result.success(localSerial())
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fireadb/chat")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        ChatHub.connect()
                        result.success(null)
                    }
                    "send" -> {
                        val bytes = call.arguments as? ByteArray
                        result.success(bytes != null && ChatHub.send(bytes))
                    }
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "fireadb/chat-events")
            .setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                        ChatHub.onBytes = { bytes -> sink?.success(bytes) }
                        ChatHub.onLinked = { sink?.success("linked") }
                    }

                    override fun onCancel(arguments: Any?) {
                        ChatHub.onBytes = null
                        ChatHub.onLinked = null
                    }
                },
            )
    }

    private fun localSerial(): String {
        for (key in arrayOf("ro.serialno", "ro.boot.serialno", "ril.serialnumber")) {
            val value = systemProperty(key)
            if (value.isNotEmpty()) return value
        }
        val fromBuild = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                Build.getSerial()
            } catch (_: SecurityException) {
                ""
            }
        } else {
            @Suppress("DEPRECATION")
            Build.SERIAL
        }
        if (fromBuild.isNotEmpty() && fromBuild != Build.UNKNOWN) return fromBuild
        return ""
    }

    private fun systemProperty(key: String): String {
        return try {
            val clazz = Class.forName("android.os.SystemProperties")
            val get = clazz.getMethod("get", String::class.java, String::class.java)
            val value = get.invoke(null, key, "") as String
            if (value.isEmpty() || value == Build.UNKNOWN) "" else value
        } catch (_: Exception) {
            ""
        }
    }

    private fun hasAllFilesAccess(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return Environment.isExternalStorageManager()
        }
        return checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED &&
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun openPath(arguments: Any?, result: MethodChannel.Result) {
        val args = arguments as? Map<*, *>
        val path = args?.get("path") as? String
        val openFile = args?.get("openFile") as? Boolean ?: true
        if (path.isNullOrEmpty()) {
            result.error("open_failed", "empty path", null)
            return
        }
        try {
            if (!openFile) {
                result.error("open_failed", "无法在系统文件管理器中打开指定目录", null)
                return
            }
            openLocalFile(path)
            result.success(true)
        } catch (error: ActivityNotFoundException) {
            result.error("open_failed", "没有可以打开它的应用", null)
        } catch (error: Exception) {
            result.error("open_failed", error.message ?: "无法打开", null)
        }
    }

    private fun openLocalFile(path: String) {
        val file = File(path)
        if (!file.isFile) {
            throw IllegalStateException("文件不存在")
        }
        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val extension = file.extension.lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "*/*"
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(view)
    }

    private fun externalFilesDirectory(result: MethodChannel.Result) {
        val root = getExternalFilesDir(null)
        if (root == null) {
            result.error("open_failed", "external files dir unavailable", null)
            return
        }
        result.success(root.absolutePath)
    }

    private fun requestAllFilesAccess(result: MethodChannel.Result) {
        if (hasAllFilesAccess()) {
            result.success(true)
            return
        }
        if (pendingAccess != null) {
            result.success(false)
            return
        }
        pendingAccess = result
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            awaitingSettings = true
            leftForSettings = false
            val appIntent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                data = Uri.parse("package:$packageName")
            }
            try {
                startActivity(appIntent)
            } catch (_: ActivityNotFoundException) {
                try {
                    startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                } catch (_: ActivityNotFoundException) {
                    finishAccessRequest(false)
                }
            }
            return
        }
        requestPermissions(
            arrayOf(
                Manifest.permission.READ_EXTERNAL_STORAGE,
                Manifest.permission.WRITE_EXTERNAL_STORAGE,
            ),
            requestStorage,
        )
    }

    override fun onPause() {
        super.onPause()
        if (awaitingSettings) leftForSettings = true
    }

    override fun onResume() {
        super.onResume()
        if (!awaitingSettings || !leftForSettings) return
        finishAccessRequest(hasAllFilesAccess())
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != requestStorage) return
        val granted = grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        finishAccessRequest(granted && hasAllFilesAccess())
    }

    override fun onDestroy() {
        finishAccessRequest(false)
        super.onDestroy()
    }

    private fun finishAccessRequest(granted: Boolean) {
        val pending = pendingAccess ?: return
        pendingAccess = null
        awaitingSettings = false
        leftForSettings = false
        try {
            pending.success(granted)
        } catch (_: RuntimeException) {
        }
    }

    companion object {
        private const val channelName = "fireadb/storage"
        private const val requestStorage = 4101
    }
}
