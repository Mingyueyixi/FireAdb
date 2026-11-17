package com.fire.adb.appservice.util;

import android.util.Log;

/** 对 {@link Log} 的薄封装。辅助服务里的日志都走这里。 */
public final class LogUtils {
    public static final String TAG = "FireAdb";

    private LogUtils() {}

    public static void i(String message) {
        Log.i(TAG, message);
    }

    public static void w(String message) {
        Log.w(TAG, message);
    }

    public static void w(String message, Throwable error) {
        Log.w(TAG, message, unwrap(error));
    }

    public static void e(String message) {
        Log.e(TAG, message);
    }

    public static void e(String message, Throwable error) {
        Log.e(TAG, message, unwrap(error));
    }

    public static Throwable unwrap(Throwable error) {
        if (error instanceof java.lang.reflect.InvocationTargetException
                && error.getCause() != null) {
            return error.getCause();
        }
        return error;
    }
}
