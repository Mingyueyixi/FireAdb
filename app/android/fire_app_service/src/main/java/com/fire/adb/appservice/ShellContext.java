package com.fire.adb.appservice;

import android.content.AttributionSource;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.ContextWrapper;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.util.Log;

import java.lang.reflect.Constructor;

/**
 * 系统上下文的包名是 android，进程实际却是 shell。
 * 创建虚拟屏幕时系统会核对包名和调用方 uid，必须改成 shell 自己的包名。
 */
final class ShellContext extends ContextWrapper {
    static final String PACKAGE_NAME = "com.android.shell";
    private static final String TAG = "FireAdb";

    private ClipboardManager mClipboardManager;

    ShellContext(Context base) {
        super(base);
    }

    @Override
    public String getPackageName() {
        return PACKAGE_NAME;
    }

    @Override
    public String getOpPackageName() {
        return PACKAGE_NAME;
    }

    @Override
    public AttributionSource getAttributionSource() {
        return new AttributionSource.Builder(Process.myUid())
                .setPackageName(PACKAGE_NAME)
                .build();
    }

    @Override
    public Object getSystemService(String name) {
        if (Context.CLIPBOARD_SERVICE.equals(name)) {
            return clipboard();
        }
        return super.getSystemService(name);
    }

    /**
     * 剪贴板服务的调用方校验（包名必须属于调用 uid）用的是 binder 调用里
     * 携带的 opPackageName，来自创建 ClipboardManager 时传入的 context。
     * base 的 ContextImpl opPackageName 是 "android" 且改不了
     * （createPackageContext 也保留调用方的 op 包名），所以只能用隐藏
     * 构造器 ClipboardManager(Context, Handler) 传入 this（SDK stub 里没有
     * 这个构造器，走反射）。
     */
    ClipboardManager clipboard() {
        if (mClipboardManager == null) {
            try {
                Constructor<?> constructor = ClipboardManager.class
                        .getDeclaredConstructor(Context.class, Handler.class);
                constructor.setAccessible(true);
                mClipboardManager = (ClipboardManager)
                        constructor.newInstance(this, new Handler(Looper.getMainLooper()));
            } catch (Throwable error) {
                Log.w(TAG, "反射创建 ClipboardManager 失败", error);
                mClipboardManager = (ClipboardManager)
                        super.getSystemService(Context.CLIPBOARD_SERVICE);
            }
        }
        return mClipboardManager;
    }
}
