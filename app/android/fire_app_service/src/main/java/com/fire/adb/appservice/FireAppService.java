package com.fire.adb.appservice;

import android.content.ClipData;
import android.content.ClipboardManager;
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
import android.util.Base64;
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
import java.util.concurrent.atomic.AtomicInteger;

/**
 * 桌面端经 {@code exec:} 拉起。主线程读标准输入上的命令，读到 {@code QUIT} 或结束就退出。
 * 没有界面，也不派发消息。标准输出是长度帧，供界面取名称、图标和版本。
 *
 * <pre>
 * LIST
 * SHOW 包名
 * CLIP:GET
 * CLIP:SET &lt;base64 utf-8 文本&gt;
 * CLIP:HIST
 * CLIP:WATCH ON|OFF
 * QUIT
 * </pre>
 *
 * 每帧：{@code FAAS}、版本 1、类型、载荷。多字节整数是大端。
 * 类型 1 就绪，7 一个应用的包名、版本、标记、APK 路径和体积，8 列表已齐，
 * 2 补上应用名，3 名称结束，
 * 6 一个应用的名称、版本、标记、图标和目录，5 错误。
 * 9 剪贴板文本（CLIP:GET 应答或 WATCH 推送），10 CLIP:SET/WATCH 已生效，
 * 11 剪贴板历史（int32 条数 + 每条一条字符串，新的在前）。
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
    private static final int TYPE_CLIP_DATA = 9;
    private static final int TYPE_CLIP_OK = 10;
    private static final int TYPE_CLIP_LIST = 11;
    private static final int FLAG_SYSTEM = 1;
    private static final int FLAG_DISABLED = 2;
    private static final int FLAG_SUSPENDED = 4;
    private static final int FLAG_DEBUG = 8;
    private static final int APP_FLAG_SUSPENDED = 1 << 30;

    private static byte[] defaultIconPng = new byte[0];
    private static boolean defaultIconLoaded;

    /** 帧输出锁：命令线程和剪贴板回调（主 Looper）都会写 stdout。 */
    private static final Object OUT_LOCK = new Object();
    private static ClipboardManager sClipboard;
    /** 最近一次 CLIP:SET 写入的内容。监听回推时跳过，避免 PC 侧回声。 */
    private static String sLastSet = "";
    private static boolean sWatching;

    /** 设备剪贴板历史（新的在前）。Android 只有当前一条，历史自己记并落盘。 */
    private static final int CLIP_HISTORY_MAX = 20;
    private static final String CLIP_HISTORY_PATH =
            "/data/local/tmp/fire-adb-clip-history.json";
    private static final java.util.ArrayDeque<String> sHistory =
            new java.util.ArrayDeque<String>();

    private FireAppService() {}

    public static void main(String[] args) {
        DataOutputStream out = new DataOutputStream(
                new BufferedOutputStream(new FileOutputStream(FileDescriptor.out)));
        try {
            run(out, args);
        } catch (Throwable error) {
            error.printStackTrace();
            try {
                writeError(out, String.valueOf(error.getMessage()));
            } catch (Throwable ignored) {
            }
            System.exit(1);
        }
    }

    private static boolean hasArg(String[] args, String name) {
        if (args == null) {
            return false;
        }
        for (String arg : args) {
            if (name.equals(arg)) {
                return true;
            }
        }
        return false;
    }

    private static void run(DataOutputStream out, String[] args) throws Exception {
        if (Looper.myLooper() == null) {
            Looper.prepareMainLooper();
        }
        Context context = AndroidContexts.system();
        PackageManager manager = context.getPackageManager();
        Map<String, PackageInfo> byPackage = new HashMap<String, PackageInfo>();
        loadClipHistory();
        writeHeader(out, TYPE_READY);
        out.flush();

        // One-shot LIST via argv: host opens `exec:... FireAppService LIST`.
        // Avoids stdin round-trips on a reused process (host saw "LIST sent"
        // then 5s of 0 bytes while the warm process sat in a bad state).
        if (hasArg(args, "LIST")) {
            writeList(out, context, manager);
            out.flush();
            return;
        }

        // stdin 命令挪到工作线程，主线程进 Looper：ClipboardManager 的变化
        // 回调（注册时落在主线程 Handler 上）只有主线程在 loop() 里才派发。
        // 命令应答与回调推送都写 stdout，帧完整性由 OUT_LOCK 保证。
        // 注意：prepareMainLooper 建的队列 mQuitAllowed=false，quitSafely()
        // 会抛 "Main thread not allowed to quit."——主 Looper 退不掉，命令
        // 线程结束时直接 System.exit 终止进程（主线程停在 loop() 里没有
        // 其他退出途径）。
        Thread commands = new Thread(
                () -> {
                    try {
                        readCommands(out, context, manager, byPackage);
                    } catch (Throwable error) {
                        Log.w(ICON_LOG_TAG, "命令循环退出", error);
                        writeErrorQuiet(out, String.valueOf(error.getMessage()));
                    } finally {
                        try {
                            out.flush();
                        } catch (Throwable ignored) {
                        }
                        System.exit(0);
                    }
                },
                "fire-app-commands");
        commands.start();
        Looper.loop();
    }

    private static void readCommands(
            DataOutputStream out,
            Context context,
            PackageManager manager,
            Map<String, PackageInfo> byPackage) throws Exception {
        // 剪贴板必须用 shell 包名上下文：ClipboardService 会校验调用包名与
        // uid 匹配，system context 的包名 "android" 属于 uid 1000，会被直接
        // 拒绝（"Package android does not belong to 2000"）。伪装成
        // com.android.shell 后与 shell uid (2000) 匹配，命中系统的测试豁免。
        Context clipContext = new ShellContext(context);
        BufferedReader input = new BufferedReader(
                new InputStreamReader(new FileInputStream(FileDescriptor.in), StandardCharsets.UTF_8));
        String line;
        while ((line = input.readLine()) != null) {
            line = line.trim();
            if (line.length() == 0) {
                continue;
            }
            if ("QUIT".equals(line)) {
                // 不 quit 主 Looper（不允许），return 后 finally 里 System.exit。
                return;
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
            } else if ("CLIP:GET".equals(line)) {
                handleClipGet(out, clipContext);
            } else if ("CLIP:HIST".equals(line)) {
                handleClipHistory(out, clipContext);
            } else if (line.startsWith("CLIP:SET ")) {
                handleClipSet(out, clipContext, line.substring("CLIP:SET ".length()).trim());
            } else if (line.startsWith("CLIP:WATCH ")) {
                handleClipWatch(out, clipContext, line.substring("CLIP:WATCH ".length()).trim());
            } else {
                writeError(out, "未知命令");
            }
        }
        // stdin 结束（宿主断开）：return 后由命令线程的 finally 结束进程。
    }

    private static ClipboardManager clipboard(Context context) {
        if (sClipboard == null) {
            // context 是 ShellContext：getSystemService(CLIPBOARD_SERVICE) 被
            // 重载为返回绑定该上下文（opPackageName=com.android.shell）的
            // ClipboardManager。直接委托 base 的 ClipboardManager 内部记住
            // 的包名是 "android"，会被 ClipboardService 校验拒绝。
            sClipboard = (ClipboardManager)
                    context.getSystemService(Context.CLIPBOARD_SERVICE);
        }
        return sClipboard;
    }

    private static void handleClipHistory(DataOutputStream out, Context context) {
        synchronized (OUT_LOCK) {
            try {
                // 顺带把当前剪贴板纳入历史：WATCH 关着时只有这里能看到新内容。
                rememberClip(clipText(clipboard(context)));
                writeHeader(out, TYPE_CLIP_LIST);
                String[] items;
                synchronized (sHistory) {
                    items = sHistory.toArray(new String[0]);
                }
                out.writeInt(items.length);
                for (String item : items) {
                    writeString(out, item);
                }
                out.flush();
            } catch (Throwable error) {
                writeErrorLocked(out, String.valueOf(error.getMessage()));
            }
        }
    }

    private static void handleClipGet(DataOutputStream out, Context context) {
        synchronized (OUT_LOCK) {
            try {
                writeHeader(out, TYPE_CLIP_DATA);
                writeString(out, clipText(clipboard(context)));
                out.flush();
            } catch (Throwable error) {
                writeErrorLocked(out, String.valueOf(error.getMessage()));
            }
        }
    }

    private static void handleClipSet(DataOutputStream out, Context context, String base64) {
        synchronized (OUT_LOCK) {
            try {
                byte[] raw = Base64.decode(base64, Base64.DEFAULT);
                String text = new String(raw, StandardCharsets.UTF_8);
                clipboard(context).setPrimaryClip(ClipData.newPlainText("FireAdb", text));
                sLastSet = text;
                rememberClip(text);
                writeHeader(out, TYPE_CLIP_OK);
                out.flush();
            } catch (Throwable error) {
                Log.w(ICON_LOG_TAG, "CLIP:SET 失败", error);
                writeErrorLocked(out, "写入剪贴板失败: " + error.getMessage());
            }
        }
    }

    private static void handleClipWatch(DataOutputStream out, Context context, String mode) {
        boolean on = "ON".equalsIgnoreCase(mode);
        try {
            ClipboardManager clips = clipboard(context);
            if (on && !sWatching) {
                sListenerOut = out;
                sListenerContext = context;
                sWatching = true;
                clips.addPrimaryClipChangedListener(sClipListener);
            } else if (!on && sWatching) {
                sWatching = false;
                clips.removePrimaryClipChangedListener(sClipListener);
            }
            writeClipOk(out);
        } catch (Throwable error) {
            sWatching = false;
            writeErrorLocked(out, "监听剪贴板失败: " + error.getMessage());
        }
    }

    /** 单一监听实例：注册与移除必须传同一个对象才匹配。 */
    private static final ClipboardManager.OnPrimaryClipChangedListener sClipListener =
            FireAppService::pushClipChanged;

    private static volatile DataOutputStream sListenerOut;
    private static volatile Context sListenerContext;

    /** 剪贴板变化回调（主 Looper 线程）。与本机刚写入的内容相同时跳过。 */
    private static void pushClipChanged() {
        DataOutputStream out = sListenerOut;
        Context context = sListenerContext;
        if (out == null || context == null) return;
        synchronized (OUT_LOCK) {
            try {
                String text = clipText(clipboard(context));
                if (sWatching && !text.equals(sLastSet)) {
                    rememberClip(text);
                    writeHeader(out, TYPE_CLIP_DATA);
                    writeString(out, text);
                    out.flush();
                }
            } catch (Throwable ignored) {
            }
        }
    }

    private static String clipText(ClipboardManager clips) {
        try {
            if (!clips.hasPrimaryClip()) {
                return "";
            }
            ClipData clip = clips.getPrimaryClip();
            if (clip == null || clip.getItemCount() == 0) {
                return "";
            }
            CharSequence text = clip.getItemAt(0).getText();
            return text == null ? "" : text.toString();
        } catch (Throwable ignored) {
            return "";
        }
    }

    /** 记一条剪贴板历史：去重置顶，超限截尾，落盘供下次进程启动复用。 */
    private static void rememberClip(String text) {
        if (text == null || text.length() == 0) {
            return;
        }
        synchronized (sHistory) {
            sHistory.remove(text);
            sHistory.addFirst(text);
            while (sHistory.size() > CLIP_HISTORY_MAX) {
                sHistory.removeLast();
            }
        }
        saveClipHistory();
    }

    /**
     * 历史落盘格式：每条 int32 UTF-8 长度 + 字节，新的在前。
     * 坏文件直接丢弃，不阻塞剪贴板功能。
     */
    private static void loadClipHistory() {
        try {
            File file = new File(CLIP_HISTORY_PATH);
            if (!file.isFile()) {
                return;
            }
            java.io.ByteArrayOutputStream buffer = new java.io.ByteArrayOutputStream();
            FileInputStream in = new FileInputStream(file);
            try {
                byte[] chunk = new byte[8192];
                int got;
                while ((got = in.read(chunk)) > 0) {
                    buffer.write(chunk, 0, got);
                }
            } finally {
                in.close();
            }
            byte[] data = buffer.toByteArray();
            int offset = 0;
            synchronized (sHistory) {
                sHistory.clear();
                while (offset + 4 <= data.length && sHistory.size() < CLIP_HISTORY_MAX) {
                    int length = ((data[offset] & 0xFF) << 24)
                            | ((data[offset + 1] & 0xFF) << 16)
                            | ((data[offset + 2] & 0xFF) << 8)
                            | (data[offset + 3] & 0xFF);
                    offset += 4;
                    if (length < 0 || offset + length > data.length) {
                        break;
                    }
                    String text = new String(data, offset, length, StandardCharsets.UTF_8);
                    offset += length;
                    if (text.length() > 0) {
                        sHistory.addLast(text);
                    }
                }
            }
        } catch (Throwable error) {
            Log.w(ICON_LOG_TAG, "读取剪贴板历史失败", error);
        }
    }

    private static void saveClipHistory() {
        try {
            java.io.ByteArrayOutputStream buffer = new java.io.ByteArrayOutputStream();
            synchronized (sHistory) {
                for (String text : sHistory) {
                    byte[] utf = text.getBytes(StandardCharsets.UTF_8);
                    buffer.write((utf.length >>> 24) & 0xFF);
                    buffer.write((utf.length >>> 16) & 0xFF);
                    buffer.write((utf.length >>> 8) & 0xFF);
                    buffer.write(utf.length & 0xFF);
                    buffer.write(utf);
                }
            }
            FileOutputStream out = new FileOutputStream(CLIP_HISTORY_PATH);
            try {
                buffer.writeTo(out);
            } finally {
                out.close();
            }
        } catch (Throwable ignored) {
        }
    }

    private static void writeClipOk(DataOutputStream out) throws Exception {
        synchronized (OUT_LOCK) {
            writeHeader(out, TYPE_CLIP_OK);
            out.flush();
        }
    }

    private static void writeErrorQuiet(DataOutputStream out, String message) {
        try {
            writeError(out, message);
        } catch (Throwable ignored) {
        }
    }

    private static void writeErrorLocked(DataOutputStream out, String message) {
        try {
            writeHeader(out, TYPE_ERROR);
            writeString(out, message == null ? "" : message);
            out.flush();
        } catch (Throwable ignored) {
        }
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
        synchronized (OUT_LOCK) {
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
        // Resolve labels on a side thread while the catalog is written, then
        // stream each LABEL as soon as it is ready. Never join() before the
        // first LABEL — that silent window made the host's 5s idle timeout
        // fire with "已收 620 包名、0 名称" even though USB was fine.
        final String[] labels = new String[apps.size()];
        // Prefix length of indices whose label slot is published (happens-before
        // via AtomicInteger). Plain boolean[] is not cross-thread visible.
        final AtomicInteger labelsReadyThrough = new AtomicInteger(0);
        Thread naming =
                new Thread(
                        () -> fillLabels(manager, apps, labels, labelsReadyThrough),
                        "fire-app-labels");
        naming.start();
        int written = 0;
        for (PackageInfo info : apps) {
            ApplicationInfo app = info.applicationInfo;
            synchronized (OUT_LOCK) {
                writeHeader(out, TYPE_APP);
                writeString(out, info.packageName);
                writeString(out, "");
                writeString(out, info.versionName == null ? "" : info.versionName);
                out.writeInt(versionCodeOf(info));
                out.writeByte(flagsOf(app));
                writeString(out, apkPaths(app));
                out.writeLong(apkBytes(app));
            }
            written++;
            // Flush early so the host idle timer sees catalog bytes while the
            // rest of the list is still being packed (ADB stream window is 1).
            if (written == 1 || (written & 15) == 0) {
                out.flush();
            }
        }
        writeHeader(out, TYPE_CATALOG_DONE);
        out.flush();
        long catalog = SystemClock.elapsedRealtime();
        int labelCount = 0;
        int next = 0;
        while (next < apps.size()) {
            if (next >= labelsReadyThrough.get()) {
                if (!naming.isAlive()) {
                    break;
                }
                try {
                    Thread.sleep(5);
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    break;
                }
                continue;
            }
            String label = labels[next];
            String packageName = apps.get(next).packageName;
            next++;
            if (label == null) {
                continue;
            }
            label = label.trim();
            if (label.length() == 0 || label.equals(packageName)) {
                continue;
            }
            synchronized (OUT_LOCK) {
                writeHeader(out, TYPE_LABEL);
                writeString(out, packageName);
                writeString(out, label);
            }
            labelCount++;
            // Keep the host idle timer fed while the rest of the names resolve.
            if ((labelCount & 15) == 0) {
                out.flush();
            }
        }
        try {
            naming.join();
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
        }
        long named = SystemClock.elapsedRealtime();
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
            PackageManager manager,
            List<PackageInfo> apps,
            String[] labels,
            AtomicInteger labelsReadyThrough) {
        try {
            for (int index = 0; index < apps.size(); index++) {
                PackageInfo info = apps.get(index);
                ApplicationInfo app = info.applicationInfo;
                labels[index] = app == null ? info.packageName : labelOf(manager, app);
                labelsReadyThrough.set(index + 1);
            }
        } catch (Throwable error) {
            Log.w(ICON_LOG_TAG, "读取应用名失败", error);
            labelsReadyThrough.set(apps.size());
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
