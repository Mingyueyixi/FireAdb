package com.fire.adb

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
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
