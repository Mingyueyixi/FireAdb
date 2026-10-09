package com.fire.adb.appservice.util;

import android.content.Context;

import java.lang.reflect.Method;

/**
 * 给 {@code app_process} 取系统上下文。没有界面，也不能走普通应用的
 * {@code ActivityThread.main}。{@code systemMain} 是隐藏接口，公开 SDK 里没有。
 */
public final class AndroidContexts {
    private AndroidContexts() {}

    public static Context system() throws Exception {
        Class<?> activityThread = Class.forName("android.app.ActivityThread");
        Method systemMain = activityThread.getDeclaredMethod("systemMain");
        systemMain.setAccessible(true);
        Object thread = systemMain.invoke(null);
        Method getSystemContext = activityThread.getDeclaredMethod("getSystemContext");
        getSystemContext.setAccessible(true);
        return (Context) getSystemContext.invoke(thread);
    }
}
