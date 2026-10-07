package com.fire.adb.appservice;

import android.content.AttributionSource;
import android.content.Context;
import android.content.ContextWrapper;
import android.os.Process;

/**
 * 系统上下文的包名是 android，进程实际却是 shell。
 * 创建虚拟屏幕时系统会核对包名和调用方 uid，必须改成 shell 自己的包名。
 */
final class ShellContext extends ContextWrapper {
    static final String PACKAGE_NAME = "com.android.shell";

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
}
