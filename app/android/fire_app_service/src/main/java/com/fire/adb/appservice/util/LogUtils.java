package com.fire.adb.appservice.util;

import android.util.Log;

import java.util.Arrays;

/** 对 {@link Log} 的薄封装。辅助服务里的日志都走这里。 */
public final class LogUtils {
    public static final String TAG = "FireAdb";

    private LogUtils() {}

    public static void i(String message) {
        println(Log.INFO, message);
    }

    public static void w(String message) {
        println(Log.WARN, message);
    }

    public static void w(String message, Throwable error) {
        println(Log.WARN, message, error);
    }

    public static void e(String message) {
        println(Log.ERROR, message);
    }

    public static void e(String message, Throwable error) {
        println(Log.ERROR, message, error);
    }
    public static void println(int priority, Object... args) {       
        StringBuilder sb = new StringBuilder();
        int len = args.length; 
        for (int i = 0; i < len; i++) {
            Object arg = args[i];
            if(arg instanceof Throwable) {
                sb.append(Log.getStackTraceString((Throwable) arg));
            } else if (arg instanceof Object[]) {
                sb.append(Arrays.toString((Object[]) arg));
            } else {
                sb.append(arg);
            }
            if (i < len - 1) {
                sb.append(" ");
            }
        }
        Log.println(priority, TAG, sb.toString());
    }
    public static Throwable unwrap(Throwable error) {
        if (error instanceof java.lang.reflect.InvocationTargetException
                && error.getCause() != null) {
            return error.getCause();
        }
        return error;
    }
}
