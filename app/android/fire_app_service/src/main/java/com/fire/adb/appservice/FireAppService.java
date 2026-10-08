package com.fire.adb.appservice;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.res.Resources;
import android.graphics.Bitmap;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.os.Looper;
import android.util.Log;

import com.fire.adb.appservice.util.AndroidContexts;
import com.fire.adb.appservice.util.BitmapUtils;

import java.io.BufferedOutputStream;
import java.io.BufferedReader;
import java.io.DataOutputStream;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

/**
 * 桌面端经 {@code exec:} 拉起的应用信息服务。进程保持运行，从标准输入读命令，
 * 往标准输出写长度帧，供界面按需取名称、图标和版本。
 *
 * <pre>
 * SHOW 包名
 * QUIT
 * </pre>
 *
 * 每帧：{@code FAAS}、版本 1、类型、载荷。多字节整数是大端。
 * 类型 1 就绪，6 一个应用的名称、版本、标记和图标，5 错误。
 * 标记位：1 系统，2 已停用，4 已暂停。版本号为 -1 表示没有。
 */
public final class FireAppService {
    private static final int ICON_SIZE = 128;
    private static final int ICON_DENSITY = 640;
    private static final String ICON_LOG_TAG = "FireAdb";
    private static final int TYPE_READY = 1;
    private static final int TYPE_ERROR = 5;
    private static final int TYPE_SHOW = 6;
    private static final int FLAG_SYSTEM = 1;
    private static final int FLAG_DISABLED = 2;
    private static final int FLAG_SUSPENDED = 4;
    private static final int APP_FLAG_SUSPENDED = 1 << 30;

    private static byte[] defaultIconPng = new byte[0];
    private static boolean defaultIconLoaded;

    private FireAppService() {}

    public static void main(String[] args) {
        DataOutputStream out = new DataOutputStream(
                new BufferedOutputStream(new FileOutputStream(FileDescriptor.out)));
        try {
            run(out);
        } catch (Throwable error) {
            error.printStackTrace();
            try {
                writeError(out, String.valueOf(error.getMessage()));
            } catch (Throwable ignored) {
            }
            System.exit(1);
        }
    }

    private static void run(DataOutputStream out) throws Exception {
        if (Looper.myLooper() == null) {
            Looper.prepareMainLooper();
        }
        Context context = AndroidContexts.system();
        PackageManager manager = context.getPackageManager();
        Map<String, PackageInfo> byPackage = new HashMap<String, PackageInfo>();
        writeHeader(out, TYPE_READY);
        out.flush();

        BufferedReader input = new BufferedReader(
                new InputStreamReader(new FileInputStream(FileDescriptor.in), StandardCharsets.UTF_8));
        String line;
        while ((line = input.readLine()) != null) {
            line = line.trim();
            if (line.length() == 0) {
                continue;
            }
            if ("QUIT".equals(line)) {
                break;
            }
            if (line.startsWith("SHOW ")) {
                writeShow(out, manager, byPackage, line.substring("SHOW ".length()).trim());
            } else {
                writeError(out, "未知命令");
            }
        }
        out.flush();
    }

    private static void writeShow(
            DataOutputStream out,
            PackageManager manager,
            Map<String, PackageInfo> byPackage,
            String packageName) throws Exception {
        PackageInfo info = packageInfo(manager, byPackage, packageName);
        ApplicationInfo app = info == null ? null : info.applicationInfo;
        byte[] png = app == null ? new byte[0] : iconOf(manager, app);
        writeHeader(out, TYPE_SHOW);
        writeString(out, packageName);
        writeString(out, app == null ? "" : labelOf(manager, app));
        writeString(out, info == null || info.versionName == null ? "" : info.versionName);
        out.writeInt(info == null ? -1 : versionCodeOf(info));
        out.writeByte(flagsOf(app));
        out.writeInt(png.length);
        if (png.length > 0) {
            out.write(png);
        }
        out.flush();
    }

    private static PackageInfo packageInfo(
            PackageManager manager,
            Map<String, PackageInfo> byPackage,
            String packageName) {
        if (packageName.length() == 0) {
            return null;
        }
        PackageInfo cached = byPackage.get(packageName);
        if (cached != null) {
            return cached;
        }
        try {
            PackageInfo info = manager.getPackageInfo(packageName, 0);
            byPackage.put(packageName, info);
            return info;
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static int flagsOf(ApplicationInfo info) {
        if (info == null) {
            return 0;
        }
        int flags = 0;
        if ((info.flags & ApplicationInfo.FLAG_SYSTEM) != 0) {
            flags |= FLAG_SYSTEM;
        }
        if (!info.enabled) {
            flags |= FLAG_DISABLED;
        }
        if ((info.flags & APP_FLAG_SUSPENDED) != 0) {
            flags |= FLAG_SUSPENDED;
        }
        return flags;
    }

    @SuppressWarnings("deprecation")
    private static int versionCodeOf(PackageInfo info) {
        if (Build.VERSION.SDK_INT >= 28) {
            long code = info.getLongVersionCode();
            if (code > Integer.MAX_VALUE) {
                return Integer.MAX_VALUE;
            }
            if (code < 0) {
                return 0;
            }
            return (int) code;
        }
        return info.versionCode;
    }

    private static byte[] iconOf(PackageManager manager, ApplicationInfo info) {
        String packageName = info.packageName == null ? "" : info.packageName;
        Drawable loaded = loadIcon(manager, info);
        byte[] png = iconBytes(loaded);
        if (png.length > 0 && !isDefaultIcon(manager, png)) {
            logIcon(packageName, "loadIcon", loaded);
            return png;
        }
        if (png.length > 0) {
            logIcon(packageName, "loadIcon 默认图标", loaded);
        }
        Drawable packaged = packageIcon(manager, info);
        byte[] fromPackage = iconBytes(packaged);
        if (fromPackage.length > 0) {
            logIcon(packageName, "安装包", packaged);
            return fromPackage;
        }
        if (png.length == 0) {
            logIcon(packageName, "loadIcon", loaded);
        }
        return new byte[0];
    }

    private static byte[] iconBytes(Drawable drawable) {
        return BitmapUtils.compress(
                drawable,
                ICON_SIZE,
                ICON_SIZE,
                Bitmap.CompressFormat.PNG,
                100);
    }

    private static Drawable loadIcon(PackageManager manager, ApplicationInfo info) {
        try {
            return info.loadIcon(manager);
        } catch (Throwable ignored) {
            return null;
        }
    }

    /** {@code loadIcon} 画出的是系统默认图标或没有像素时，再按资源号读安装包。 */
    private static Drawable packageIcon(PackageManager manager, ApplicationInfo info) {
        if (info.icon == 0) {
            return null;
        }
        try {
            Resources resources = manager.getResourcesForApplication(info);
            return resources.getDrawableForDensity(info.icon, ICON_DENSITY, null);
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static boolean isDefaultIcon(PackageManager manager, byte[] png) {
        byte[] fallback = defaultIconPng(manager);
        return png.length > 0 && fallback.length > 0 && java.util.Arrays.equals(png, fallback);
    }

    private static byte[] defaultIconPng(PackageManager manager) {
        if (defaultIconLoaded) {
            return defaultIconPng;
        }
        defaultIconLoaded = true;
        try {
            defaultIconPng = iconBytes(manager.getDefaultActivityIcon());
        } catch (Throwable ignored) {
            defaultIconPng = new byte[0];
        }
        return defaultIconPng;
    }

    private static String labelOf(PackageManager manager, ApplicationInfo info) {
        String packageName = info.packageName == null ? "" : info.packageName;
        try {
            CharSequence label = info.loadLabel(manager);
            if (label == null) {
                return packageName;
            }
            String text = label.toString().trim();
            if (text.length() == 0) {
                return packageName;
            }
            return text;
        } catch (Throwable ignored) {
            return packageName;
        }
    }

    private static void logIcon(String packageName, String source, Drawable drawable) {
        String type = drawable == null ? "-" : drawable.getClass().getName();
        Log.i(ICON_LOG_TAG, "图标 " + packageName + " " + source + " " + type);
    }

    private static void writeHeader(DataOutputStream out, int type) throws Exception {
        out.write(new byte[] {'F', 'A', 'A', 'S'});
        out.writeByte(1);
        out.writeByte(type);
    }

    private static void writeError(DataOutputStream out, String message) throws Exception {
        writeHeader(out, TYPE_ERROR);
        writeString(out, message == null ? "" : message);
        out.flush();
    }

    private static void writeString(DataOutputStream out, String value) throws Exception {
        byte[] utf = value.getBytes(StandardCharsets.UTF_8);
        if (utf.length > 65535) {
            utf = java.util.Arrays.copyOf(utf, 65535);
        }
        out.writeShort(utf.length);
        if (utf.length > 0) {
            out.write(utf);
        }
    }
}
