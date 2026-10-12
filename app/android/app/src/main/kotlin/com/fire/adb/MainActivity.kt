package com.fire.adb

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
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
                    "requestAllFilesAccess" -> requestAllFilesAccess(result)
                    "externalFilesDirectory" -> externalFilesDirectory(result)
                    "openDirectory" -> openDirectory(call.arguments as String, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasAllFilesAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }
    }

    private fun externalFilesDirectory(result: MethodChannel.Result) {
        val root = getExternalFilesDir(null)
        if (root == null) {
            result.error("open_failed", "external files dir unavailable", null)
            return
        }
        result.success(root.absolutePath)
    }

    private fun openDirectory(path: String, result: MethodChannel.Result) {
        try {
            val dir = java.io.File(path)
            if (!dir.isDirectory) {
                result.error("open_failed", path, null)
                return
            }
            val relative = primaryRelative(dir)
            if (relative == null) {
                result.error("open_failed", path, null)
                return
            }
            val documentId = if (relative.isEmpty()) "primary:" else "primary:$relative"
            val uri = DocumentsContract.buildDocumentUri(
                "com.android.externalstorage.documents",
                documentId,
            )
            // 文件管理器如果还停在上次的目录，新的地址会被丢掉，界面就留在 Android/data。
            // 清掉旧任务后，这次会按日志目录重新进入。
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, DocumentsContract.Document.MIME_TYPE_DIR)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
            result.success(null)
        } catch (error: ActivityNotFoundException) {
            result.error("open_failed", error.message, null)
        } catch (error: Exception) {
            result.error("open_failed", error.message, null)
        }
    }

    private fun primaryRelative(dir: java.io.File): String? {
        val paths = listOfNotNull(
            dir.path,
            dir.absolutePath,
            runCatching { dir.canonicalPath }.getOrNull(),
        )
        val roots = listOf(
            Environment.getExternalStorageDirectory().absolutePath,
            "/storage/emulated/0",
            "/sdcard",
        )
        for (candidate in paths) {
            val normalized = candidate.replace('\\', '/')
            for (root in roots) {
                val prefix = root.replace('\\', '/').trimEnd('/')
                if (normalized == prefix) return ""
                if (normalized.startsWith("$prefix/")) {
                    return normalized.removePrefix("$prefix/")
                }
            }
        }
        return null
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
        val granted = grantResults.any { it == PackageManager.PERMISSION_GRANTED }
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
        private const val channelName = "fire_adb/storage"
        private const val requestStorage = 4101
    }
}
