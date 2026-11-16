package com.fire.adb.appservice.catalog;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.res.Resources;
import android.graphics.Bitmap;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.os.SystemClock;
import android.util.Log;

import com.fire.adb.appservice.protocol.CommandHandler;
import com.fire.adb.appservice.protocol.FireDataRequest;
import com.fire.adb.appservice.protocol.FireDataResponse;
import com.fire.adb.appservice.protocol.FireDataWriter;
import com.fire.adb.appservice.util.BitmapUtils;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.File;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * 应用目录：{@code catalog.list}、{@code catalog.names}、{@code catalog.icon}、
 * {@code catalog.show}。
 *
 * <p>列表一次写出全部包名、版本、标记和体积。应用名按给定包名一次返回，不含图标。
 * 图标按单个包名返回，调用方只问当前看得到的那些。查看一个应用先写 JSON，再写 PNG。
 */
public final class AppCatalogProtocol implements CommandHandler {
    private static final String TAG = "FireAdb";
    private static final int ICON_SIZE = 128;
    private static final int ICON_DENSITY = 640;
    /** ApplicationInfo.FLAG_SUSPENDED，框架里的隐藏常量。 */
    private static final int APP_FLAG_SUSPENDED = 1 << 30;

    private final FireDataWriter out;
    private final Context context;
    private final PackageManager manager;
    private final Map<String, PackageInfo> byPackage = new HashMap<String, PackageInfo>();

    private byte[] defaultIconPng = new byte[0];
    private boolean defaultIconLoaded;

    public AppCatalogProtocol(FireDataWriter out, Context context, PackageManager manager) {
        this.out = out;
        this.context = context;
        this.manager = manager;
    }

    @Override
    public boolean handle(FireDataRequest request) throws Exception {
        if ("catalog.list".equals(request.name)) {
            writeList(request.id);
            return true;
        }
        if ("catalog.names".equals(request.name)) {
            writeNames(request);
            return true;
        }
        if ("catalog.icon".equals(request.name)) {
            writeIcon(request);
            return true;
        }
        if ("catalog.show".equals(request.name)) {
            writeShow(request);
            return true;
        }
        return false;
    }

    /**
     * 一次写出全部已安装包。应用名和图标另请求，列表不必等它们。
     */
    public void writeList(int id) throws Exception {
        long started = SystemClock.elapsedRealtime();
        List<PackageInfo> packages;
        try {
            packages = manager.getInstalledPackages(0);
        } catch (Throwable error) {
            out.send(FireDataResponse.error(id, String.valueOf(error.getMessage())));
            return;
        }
        long listed = SystemClock.elapsedRealtime();
        JSONArray items = new JSONArray();
        byPackage.clear();
        if (packages != null) {
            for (PackageInfo info : packages) {
                if (info == null || info.packageName == null || info.packageName.length() == 0) {
                    continue;
                }
                byPackage.put(info.packageName, info);
                items.put(appJson(info, ""));
            }
        }
        JSONObject json = new JSONObject();
        json.put("items", items);
        out.send(FireDataResponse.json("catalog.apps", id, json));
        long finished = SystemClock.elapsedRealtime();
        Log.i(
                TAG,
                "应用列表 "
                        + items.length()
                        + " 个，包 "
                        + (listed - started)
                        + " ms，写出 "
                        + (finished - listed)
                        + " ms");
    }

    /** 按请求里的包名顺序解析应用名，一次返回。不含图标。 */
    private void writeNames(FireDataRequest request) {
        long started = SystemClock.elapsedRealtime();
        try {
            JSONArray wanted = request.json().optJSONArray("packages");
            JSONArray items = new JSONArray();
            int count = wanted == null ? 0 : wanted.length();
            for (int index = 0; index < count; index++) {
                String packageName = wanted.optString(index, "").trim();
                if (packageName.length() == 0) {
                    continue;
                }
                PackageInfo info = packageInfo(packageName);
                ApplicationInfo app = info == null ? null : info.applicationInfo;
                String label = app == null ? "" : labelOf(app);
                JSONObject item = new JSONObject();
                item.put("package", packageName);
                item.put("label", label == null ? "" : label);
                items.put(item);
            }
            JSONObject json = new JSONObject();
            json.put("items", items);
            out.send(FireDataResponse.json("catalog.names", request.id, json));
            Log.i(
                    TAG,
                    "应用名 "
                            + items.length()
                            + " 个，"
                            + (SystemClock.elapsedRealtime() - started)
                            + " ms");
        } catch (Throwable error) {
            Log.w(TAG, "catalog.names 失败", error);
            out.sendQuiet(FireDataResponse.error(request.id, "读取应用名失败: " + error.getMessage()));
        }
    }

    /** 只返回一个包的图标。空字节表示没有可用图标。 */
    private void writeIcon(FireDataRequest request) {
        try {
            String packageName = packageOf(request);
            if (packageName.length() == 0) {
                out.send(FireDataResponse.error(request.id, "缺少包名"));
                return;
            }
            PackageInfo info = packageInfo(packageName);
            ApplicationInfo app = info == null ? null : info.applicationInfo;
            byte[] png = app == null ? new byte[0] : iconOf(app, false);
            out.send(FireDataResponse.bytes("catalog.icon", request.id, png));
        } catch (Throwable error) {
            Log.w(TAG, "catalog.icon 失败", error);
            out.sendQuiet(FireDataResponse.error(request.id, "读取应用图标失败: " + error.getMessage()));
        }
    }

    private void writeShow(FireDataRequest request) throws Exception {
        String packageName = packageOf(request);
        if (packageName.length() == 0) {
            out.send(FireDataResponse.error(request.id, "缺少包名"));
            return;
        }
        PackageInfo info = packageInfo(packageName);
        ApplicationInfo app = info == null ? null : info.applicationInfo;
        if (info == null) {
            out.send(FireDataResponse.error(request.id, "找不到应用"));
            return;
        }
        byte[] png = app == null ? new byte[0] : iconOf(app, true);
        String[] directories = directories(app, packageName);
        String label = app == null ? "" : labelOf(app);
        out.send(FireDataResponse.json(
                "catalog.show", request.id, showJson(info, label, directories)));
        out.send(FireDataResponse.bytes("catalog.icon", request.id, png));
    }

    private static String packageOf(FireDataRequest request) {
        try {
            String name = request.json().optString("package", "");
            return name == null ? "" : name.trim();
        } catch (Throwable ignored) {
            return "";
        }
    }

    private JSONObject appJson(PackageInfo info, String label) throws Exception {
        ApplicationInfo app = info.applicationInfo;
        JSONObject json = new JSONObject();
        json.put("package", info.packageName);
        json.put("label", label == null ? "" : label);
        json.put("versionName", info.versionName == null ? "" : info.versionName);
        int code = versionCodeOf(info);
        if (code >= 0) {
            json.put("versionCode", code);
        }
        putFlags(json, flagsOf(app));
        json.put("apk", apkArray(app));
        json.put("size", apkBytes(app));
        return json;
    }

    private JSONObject showJson(PackageInfo info, String label, String[] directories)
            throws Exception {
        JSONObject json = appJson(info, label);
        json.put("dataDir", directories[0]);
        json.put("cacheDir", directories[1]);
        json.put("externalDir", directories[2]);
        return json;
    }

    private static void putFlags(JSONObject json, int flags) throws Exception {
        json.put("system", (flags & 1) != 0);
        json.put("disabled", (flags & 2) != 0);
        json.put("suspended", (flags & 4) != 0);
        json.put("debuggable", (flags & 8) != 0);
    }

    private static JSONArray apkArray(ApplicationInfo app) {
        JSONArray paths = new JSONArray();
        String joined = apkPaths(app);
        if (joined.length() == 0) {
            return paths;
        }
        for (String path : joined.split("\n")) {
            if (path.length() > 0) {
                paths.put(path);
            }
        }
        return paths;
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
    private String[] directories(ApplicationInfo app, String packageName) {
        String data = app == null || app.dataDir == null ? "" : app.dataDir;
        String cache = "";
        String external = "";
        Context pkg = packageContext(packageName);
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

    private Context packageContext(String packageName) {
        if (packageName.length() == 0) {
            return null;
        }
        try {
            return context.createPackageContext(packageName, Context.CONTEXT_IGNORE_SECURITY);
        } catch (Throwable ignored) {
            return null;
        }
    }

    private PackageInfo packageInfo(String packageName) {
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
            flags |= 1;
        }
        if (!info.enabled) {
            flags |= 2;
        }
        if ((info.flags & APP_FLAG_SUSPENDED) != 0) {
            flags |= 4;
        }
        if ((info.flags & ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            flags |= 8;
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

    private byte[] iconOf(ApplicationInfo info, boolean log) {
        String packageName = info.packageName == null ? "" : info.packageName;
        Drawable loaded = loadIcon(info);
        byte[] png = iconBytes(loaded);
        if (png.length > 0 && !isDefaultIcon(png)) {
            if (log) {
                logIcon(packageName, "loadIcon", loaded);
            }
            return png;
        }
        if (log && png.length > 0) {
            logIcon(packageName, "loadIcon 默认图标", loaded);
        }
        Drawable packaged = packageIcon(info);
        byte[] fromPackage = iconBytes(packaged);
        if (fromPackage.length > 0) {
            if (log) {
                logIcon(packageName, "安装包", packaged);
            }
            return fromPackage;
        }
        if (log && png.length == 0) {
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

    private Drawable loadIcon(ApplicationInfo info) {
        try {
            return info.loadIcon(manager);
        } catch (Throwable ignored) {
            return null;
        }
    }

    /** {@code loadIcon} 画出的是系统默认图标或没有像素时，再按资源号读安装包。 */
    private Drawable packageIcon(ApplicationInfo info) {
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

    private boolean isDefaultIcon(byte[] png) {
        byte[] fallback = defaultIconPng();
        return png.length > 0 && fallback.length > 0 && Arrays.equals(png, fallback);
    }

    private byte[] defaultIconPng() {
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

    private String labelOf(ApplicationInfo info) {
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
        Log.i(TAG, "图标 " + packageName + " " + source + " " + type);
    }
}
