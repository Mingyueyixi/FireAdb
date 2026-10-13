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
import android.os.SystemClock;
import android.util.Log;

import com.fire.adb.appservice.util.AndroidContexts;
import com.fire.adb.appservice.util.BitmapUtils;

import java.io.BufferedOutputStream;
import java.io.BufferedReader;
import java.io.DataOutputStream;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * 桌面端经 {@code exec:} 拉起。主线程读标准输入上的命令，读到 {@code QUIT} 或结束就退出。
 * 没有界面，也不派发消息。标准输出是长度帧，供界面取名称、图标和版本。
 *
 * <pre>
 * LIST
 * SHOW 包名
 * QUIT
 * </pre>
 *
 * 每帧：{@code FAAS}、版本 1、类型、载荷。多字节整数是大端。
 * 类型 1 就绪，7 一个应用的包名、版本、标记、APK 路径和体积，8 列表已齐，
 * 2 补上应用名，3 名称结束，
 * 6 一个应用的名称、版本、标记、图标和目录，5 错误。
 * 标记位：1 系统，2 已停用，4 已暂停，8 可调试。版本号为 -1 表示没有。
 * SHOW 的图标之后是数据目录、缓存目录、SD 卡目录，各一条字符串。
 */
public final class FireAppService {
    private static final int ICON_SIZE = 128;
    private static final int ICON_DENSITY = 640;
    private static final String ICON_LOG_TAG = "FireAdb";
    private static final int TYPE_READY = 1;
    private static final int TYPE_LABEL = 2;
    private static final int TYPE_LABELS_DONE = 3;
    private static final int TYPE_ERROR = 5;
    private static final int TYPE_SHOW = 6;
    private static final int TYPE_APP = 7;
    private static final int TYPE_CATALOG_DONE = 8;
    private static final int FLAG_SYSTEM = 1;
    private static final int FLAG_DISABLED = 2;
    private static final int FLAG_SUSPENDED = 4;
    private static final int FLAG_DEBUG = 8;
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
            if ("LIST".equals(line)) {
                writeList(out, context, manager);
            } else if (line.startsWith("SHOW ")) {
                writeShow(
                        out,
                        context,
                        manager,
                        byPackage,
                        line.substring("SHOW ".length()).trim());
            } else {
                writeError(out, "未知命令");
            }
        }
        out.flush();
    }

    private static void writeShow(
            DataOutputStream out,
            Context context,
            PackageManager manager,
            Map<String, PackageInfo> byPackage,
            String packageName) throws Exception {
        PackageInfo info = packageInfo(manager, byPackage, packageName);
        ApplicationInfo app = info == null ? null : info.applicationInfo;
        byte[] png = app == null ? new byte[0] : iconOf(manager, app);
        String[] directories = directories(context, app, packageName);
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
        writeString(out, directories[0]);
        writeString(out, directories[1]);
        writeString(out, directories[2]);
        out.flush();
    }

    /**
     * 先写出包名、版本、标记和 APK 路径，界面可以马上显示。
     * 应用名在另一条线程里按包解析，写完列表后一次补上。不含图标。
     */
    @SuppressWarnings("deprecation")
    private static void writeList(
            DataOutputStream out, Context context, PackageManager manager) throws Exception {
        long started = SystemClock.elapsedRealtime();
        List<PackageInfo> packages;
        try {
            packages = manager.getInstalledPackages(0);
        } catch (Throwable error) {
            writeError(out, String.valueOf(error.getMessage()));
            return;
        }
        long listed = SystemClock.elapsedRealtime();
        if (packages == null) {
            packages = java.util.Collections.emptyList();
        }
        List<PackageInfo> apps = new java.util.ArrayList<PackageInfo>();
        for (PackageInfo info : packages) {
            if (info == null || info.packageName == null || info.packageName.length() == 0) {
                continue;
            }
            apps.add(info);
        }
        final String[] labels = new String[apps.size()];
        Thread naming = new Thread(() -> fillLabels(manager, apps, labels), "fire-app-labels");
        naming.start();
        for (PackageInfo info : apps) {
            ApplicationInfo app = info.applicationInfo;
            writeHeader(out, TYPE_APP);
            writeString(out, info.packageName);
            writeString(out, "");
            writeString(out, info.versionName == null ? "" : info.versionName);
            out.writeInt(versionCodeOf(info));
            out.writeByte(flagsOf(app));
            writeString(out, apkPaths(app));
            out.writeLong(apkBytes(app));
        }
        writeHeader(out, TYPE_CATALOG_DONE);
        out.flush();
        long catalog = SystemClock.elapsedRealtime();
        try {
            naming.join();
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
        }
        long named = SystemClock.elapsedRealtime();
        int labelCount = 0;
        for (int index = 0; index < apps.size(); index++) {
            String label = labels[index];
            if (label == null) {
                continue;
            }
            label = label.trim();
            String packageName = apps.get(index).packageName;
            if (label.length() == 0 || label.equals(packageName)) {
                continue;
            }
            writeHeader(out, TYPE_LABEL);
            writeString(out, packageName);
            writeString(out, label);
            labelCount++;
        }
        writeHeader(out, TYPE_LABELS_DONE);
        out.flush();
        long finished = SystemClock.elapsedRealtime();
        Log.i(
                ICON_LOG_TAG,
                "应用列表 "
                        + apps.size()
                        + " 个，包 "
                        + (listed - started)
                        + " ms，列表 "
                        + (catalog - listed)
                        + " ms，名称 "
                        + labelCount
                        + " 个 "
                        + (named - catalog)
                        + " ms，写出 "
                        + (finished - named)
                        + " ms");
    }

    private static void fillLabels(
            PackageManager manager, List<PackageInfo> apps, String[] labels) {
        try {
            for (int index = 0; index < apps.size(); index++) {
                PackageInfo info = apps.get(index);
                ApplicationInfo app = info.applicationInfo;
                labels[index] = app == null ? info.packageName : labelOf(manager, app);
            }
        } catch (Throwable error) {
            Log.w(ICON_LOG_TAG, "读取应用名失败", error);
        }
    }

    private static String apkPaths(ApplicationInfo app) {
        if (app == null) {
            return "";
        }
        StringBuilder paths = new StringBuilder();
        if (app.sourceDir != null && app.sourceDir.length() > 0) {
            paths.append(app.sourceDir);
        }
        if (app.splitSourceDirs != null) {
            for (String split : app.splitSourceDirs) {
                if (split == null || split.length() == 0) {
                    continue;
                }
                if (paths.length() > 0) {
                    paths.append('\n');
                }
                paths.append(split);
            }
        }
        return paths.toString();
    }

    /** 安装包体积。只读文件长度，不再为每一行另开 shell。 */
    private static long apkBytes(ApplicationInfo app) {
        if (app == null) {
            return 0;
        }
        long total = fileLength(app.sourceDir);
        if (app.splitSourceDirs != null) {
            for (String split : app.splitSourceDirs) {
                total += fileLength(split);
            }
        }
        return total;
    }

    private static long fileLength(String path) {
        if (path == null || path.length() == 0) {
            return 0;
        }
        try {
            long length = new File(path).length();
            return length > 0 ? length : 0;
        } catch (Throwable ignored) {
            return 0;
        }
    }

    /** 数据目录、缓存目录、SD 卡上的应用目录。取不到时用约定路径。 */
    private static String[] directories(
            Context system, ApplicationInfo app, String packageName) {
        String data = app == null || app.dataDir == null ? "" : app.dataDir;
        String cache = "";
        String external = "";
        Context pkg = packageContext(system, packageName);
        if (pkg != null) {
            try {
                File cacheFile = pkg.getCacheDir();
                if (cacheFile != null) {
                    cache = cacheFile.getAbsolutePath();
                }
            } catch (Throwable ignored) {
            }
            try {
                File externalFiles = pkg.getExternalFilesDir(null);
                if (externalFiles != null) {
                    File parent = externalFiles.getParentFile();
                    external = parent == null
                            ? externalFiles.getAbsolutePath()
                            : parent.getAbsolutePath();
                }
            } catch (Throwable ignored) {
            }
        }
        if (data.length() == 0 && packageName.length() > 0) {
            data = "/data/data/" + packageName;
        }
        if (cache.length() == 0 && data.length() > 0) {
            cache = data + "/cache";
        }
        if (external.length() == 0 && packageName.length() > 0) {
            external = "/sdcard/Android/data/" + packageName;
        }
        return new String[] {data, cache, external};
    }

    private static Context packageContext(Context system, String packageName) {
        if (packageName.length() == 0) {
            return null;
        }
        try {
            return system.createPackageContext(packageName, Context.CONTEXT_IGNORE_SECURITY);
        } catch (Throwable ignored) {
            return null;
        }
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
        if ((info.flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            flags |= FLAG_DEBUG;
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
