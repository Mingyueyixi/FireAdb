package com.fire.adb.appservice;

import android.annotation.SuppressLint;
import android.content.Context;
import android.graphics.Point;
import android.graphics.Rect;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.hardware.display.VirtualDisplayConfig;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import android.util.Log;
import android.os.IBinder;
import android.os.Looper;
import android.os.Process;
import android.view.Display;
import android.view.Surface;
import android.view.WindowManager;

import com.fire.adb.appservice.util.AndroidContexts;

import java.io.File;
import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.nio.ByteBuffer;

/**
 * 辅助服务里的录屏入口。以 shell 身份运行，把 mp4 写到给定路径。
 *
 * <pre>
 * app_process / com.fire.adb.appservice.ScreenRecorder --output 路径 --time-limit 秒
 * </pre>
 *
 * {@code --time-limit 0} 表示不限时。停止时由桌面端创建
 * {@code /data/local/tmp/fireadb_rec.stop}，这里写完索引再退出。
 * 画面经虚拟屏幕或显示控制直接送进编码器。前一种没有画面就换下一种。
 * 优先环回采集正在播放的声音，扬声器继续出声。
 * 环回打不开时改为采集远程混音，并把同一份声音送回扬声器。
 * 采不到就只留画面。
 */
public final class ScreenRecorder {
    static final String STOP_PATH = "/data/local/tmp/fireadb_rec.stop";
    private static final String MIME = "video/avc";
    private static final int BITRATE = 8000000;
    private static final int FRAME_RATE = 30;
    private static final long FIRST_FRAME_NS = 2500000000L;
    private static final long DRAIN_NS = 2000000000L;

    private ScreenRecorder() {}

    public static void main(String[] args) {
        Throwable last = null;
        try {
            Arguments arguments = Arguments.parse(args);
            if (Looper.myLooper() == null) {
                Looper.prepareMainLooper();
            }
            Context context = AndroidContexts.system();
            DisplaySize display = DisplaySize.read(context);
            StopWatch watch = new StopWatch(arguments.timeLimitSec);
            String[] methods = new String[] {"virtual", "surface"};
            for (int i = 0; i < methods.length; i++) {
                if (watch.requested()) {
                    break;
                }
                String method = methods[i];
                try {
                    log("try " + method);
                    boolean saved = recordSurface(method, context, arguments.output, display, watch);
                    if (saved) {
                        log("use " + method);
                        System.exit(0);
                    }
                    if (watch.requested()) {
                        break;
                    }
                    log("skip " + method + ": no frames");
                } catch (Throwable error) {
                    last = unwrap(error);
                    logThrowable("skip " + method, error);
                }
            }
        } catch (Throwable error) {
            last = unwrap(error);
            logThrowable("failed", error);
            System.exit(1);
        }
        logThrowable("failed", last == null ? new IllegalStateException("no frames") : last);
        System.exit(1);
    }

    private static boolean recordSurface(
            String method,
            Context context,
            String output,
            DisplaySize display,
            StopWatch watch) throws Exception {
        MediaCodec codec = MediaCodec.createEncoderByType(MIME);
        Surface surface = null;
        Mirror mirror = null;
        Mp4Writer writer = null;
        PlaybackAudio audio = null;
        boolean saved = false;
        try {
            MediaFormat format = videoFormat(display.encodedX, display.encodedY, BITRATE);
            format.setInteger(
                    MediaFormat.KEY_COLOR_FORMAT,
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            surface = codec.createInputSurface();
            codec.start();
            writer = new Mp4Writer(output, codec);
            audio = PlaybackAudio.tryStart(context, writer);
            mirror = "virtual".equals(method)
                    ? new VirtualMirror()
                    : new SurfaceMirror();
            mirror.start(context, surface, display);
            long firstDeadline = System.nanoTime() + FIRST_FRAME_NS;
            boolean eosSent = false;
            long drainDeadline = 0L;
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            while (true) {
                boolean stop = watch.requested();
                if (!writer.wrote && !stop && System.nanoTime() > firstDeadline) {
                    return false;
                }
                if (stop && writer.wrote && !eosSent) {
                    codec.signalEndOfInputStream();
                    eosSent = true;
                    drainDeadline = System.nanoTime() + DRAIN_NS;
                }
                if (stop && !writer.wrote) {
                    return false;
                }
                int index = codec.dequeueOutputBuffer(info, 50000);
                if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
                    if (eosSent && System.nanoTime() > drainDeadline) {
                        break;
                    }
                    continue;
                }
                if (index < 0) {
                    writer.onFormat(index);
                    continue;
                }
                boolean eos = writer.write(index, info);
                if (eos) {
                    break;
                }
            }
            if (!writer.wrote) {
                return false;
            }
            if (audio != null) {
                audio.end();
            }
            writer.finish();
            saved = true;
            return true;
        } finally {
            if (audio != null) {
                audio.release();
            }
            if (mirror != null) {
                mirror.release();
            }
            if (writer != null) {
                writer.release();
            } else {
                releaseCodec(codec);
            }
            if (!saved) {
                new File(output).delete();
            }
        }
    }

    private static MediaFormat videoFormat(int width, int height, int bitrate) {
        MediaFormat format = MediaFormat.createVideoFormat(MIME, width, height);
        format.setInteger(MediaFormat.KEY_BIT_RATE, bitrate);
        format.setInteger(MediaFormat.KEY_FRAME_RATE, FRAME_RATE);
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1);
        return format;
    }

    private static void releaseCodec(MediaCodec codec) {
        try {
            codec.stop();
        } catch (Throwable ignored) {
        }
        try {
            codec.release();
        } catch (Throwable ignored) {
        }
    }

    private static void log(String message) {
        Log.e("FireAdb", message);
        System.out.println("fireadb-record " + message);
        System.out.flush();
    }

    private static void logThrowable(String prefix, Throwable error) {
        Throwable cause = unwrap(error);
        log(prefix + ": " + cause);
        Log.e("FireAdb", prefix, cause);
        cause.printStackTrace(System.out);
        System.out.flush();
    }

    private static Throwable unwrap(Throwable error) {
        if (error instanceof java.lang.reflect.InvocationTargetException && error.getCause() != null) {
            return error.getCause();
        }
        return error;
    }

    private static final class Arguments {
        final String output;
        final int timeLimitSec;

        Arguments(String output, int timeLimitSec) {
            this.output = output;
            this.timeLimitSec = timeLimitSec;
        }

        static Arguments parse(String[] args) {
            String output = null;
            int limit = 180;
            for (int i = 0; i < args.length; i++) {
                if ("--output".equals(args[i]) && i + 1 < args.length) {
                    output = args[++i];
                } else if ("--time-limit".equals(args[i]) && i + 1 < args.length) {
                    limit = Integer.parseInt(args[++i]);
                }
            }
            if (output == null || output.length() == 0) {
                throw new IllegalArgumentException("missing --output");
            }
            if (limit < 0) {
                limit = 0;
            }
            return new Arguments(output, limit);
        }
    }

    private static final class StopWatch {
        final long limitNs;
        final long start = System.nanoTime();

        StopWatch(int timeLimitSec) {
            limitNs = timeLimitSec <= 0 ? 0L : timeLimitSec * 1000000000L;
        }

        boolean requested() {
            if (new File(STOP_PATH).exists()) {
                return true;
            }
            return limitNs > 0L && System.nanoTime() - start >= limitNs;
        }
    }

    private static final class DisplaySize {
        final int realX;
        final int realY;
        final int encodedX;
        final int encodedY;
        final int dpi;

        DisplaySize(int realX, int realY, int encodedX, int encodedY, int dpi) {
            this.realX = realX;
            this.realY = realY;
            this.encodedX = encodedX;
            this.encodedY = encodedY;
            this.dpi = dpi;
        }

        @SuppressWarnings("deprecation")
        static DisplaySize read(Context context) {
            WindowManager manager = (WindowManager) context.getSystemService(Context.WINDOW_SERVICE);
            Display display = manager.getDefaultDisplay();
            Point point = new Point();
            display.getRealSize(point);
            int x = even(point.x);
            int y = even(point.y);
            if (x < 2 || y < 2) {
                throw new IllegalStateException("display size unavailable");
            }
            int longEdge = Math.max(x, y);
            int encodedX = x;
            int encodedY = y;
            if (longEdge > 1920) {
                double scale = 1920.0 / longEdge;
                encodedX = even((int) (x * scale));
                encodedY = even((int) (y * scale));
            }
            android.util.DisplayMetrics metrics = new android.util.DisplayMetrics();
            display.getRealMetrics(metrics);
            int dpi = metrics.densityDpi > 0 ? metrics.densityDpi : 160;
            return new DisplaySize(x, y, encodedX, encodedY, dpi);
        }

        static int even(int value) {
            int sized = Math.max(value, 2);
            return sized & ~1;
        }
    }

    private interface Mirror {
        void start(Context context, Surface surface, DisplaySize display) throws Exception;

        void release();
    }

    private static String methodList(Class<?> type, String name) {
        StringBuilder builder = new StringBuilder();
        appendMethods(builder, type.getDeclaredMethods(), name);
        if (builder.length() == 0) {
            appendMethods(builder, type.getMethods(), name);
        }
        if (builder.length() == 0) {
            builder.append("none");
        }
        return builder.toString();
    }

    private static void appendMethods(StringBuilder builder, Method[] methods, String name) {
        for (int i = 0; i < methods.length; i++) {
            if (!methods[i].getName().equals(name)) {
                continue;
            }
            if (builder.length() > 0) {
                builder.append("; ");
            }
            builder.append(methods[i].toString());
        }
    }

    private static final class VirtualMirror implements Mirror {
        VirtualDisplay display;

        @Override
        public void start(Context context, Surface surface, DisplaySize size) throws Exception {
            Throwable denied = null;
            try {
                display = open(new ShellContext(context), surface, size);
            } catch (Throwable error) {
                denied = unwrap(error);
            }
            if (display != null) {
                return;
            }
            if (denied instanceof Exception) {
                throw (Exception) denied;
            }
            if (denied != null) {
                throw new IllegalStateException(denied);
            }
            throw new IllegalStateException("virtual display unavailable");
        }

        private static VirtualDisplay open(Context shell, Surface surface, DisplaySize size)
                throws Exception {
            VirtualDisplayConfig.Builder builder = new VirtualDisplayConfig.Builder(
                    "fireadb",
                    size.encodedX,
                    size.encodedY,
                    size.dpi)
                    .setSurface(surface)
                    .setFlags(DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR);
            try {
                Method setMirror = VirtualDisplayConfig.Builder.class.getDeclaredMethod(
                        "setDisplayIdToMirror",
                        int.class);
                setMirror.setAccessible(true);
                setMirror.invoke(builder, Integer.valueOf(Display.DEFAULT_DISPLAY));
            } catch (Throwable ignored) {
            }
            VirtualDisplayConfig config = builder.build();
            Throwable failure = null;
            try {
                VirtualDisplay created = openStatic(size, surface);
                if (created != null) {
                    return created;
                }
            } catch (Throwable error) {
                failure = unwrap(error);
            }
            try {
                VirtualDisplay created = openWithManager(shell, config);
                if (created != null) {
                    return created;
                }
                throw new IllegalStateException("DisplayManager returned null");
            } catch (Throwable managerError) {
                Throwable manager = unwrap(managerError);
                try {
                    return openWithService(config, surface);
                } catch (Throwable serviceError) {
                    Throwable service = unwrap(serviceError);
                    throw new IllegalStateException(
                            failure + " || " + manager + " || " + service
                                    + " || " + methodList(DisplayManager.class, "createVirtualDisplay"),
                            service);
                }
            }
        }

        private static VirtualDisplay openStatic(DisplaySize size, Surface surface) throws Exception {
            Method method = null;
            Method[] methods = DisplayManager.class.getDeclaredMethods();
            for (int i = 0; i < methods.length; i++) {
                Method candidate = methods[i];
                if (!candidate.getName().equals("createVirtualDisplay")
                        || !Modifier.isStatic(candidate.getModifiers())) {
                    continue;
                }
                Class<?>[] params = candidate.getParameterTypes();
                if (params.length == 5
                        && params[0] == String.class
                        && params[1] == int.class
                        && params[4] == Surface.class) {
                    method = candidate;
                    break;
                }
            }
            if (method == null) {
                throw new IllegalStateException("static mirror unavailable");
            }
            method.setAccessible(true);
            log("mirror static");
            Object created = method.invoke(
                    null,
                    "fireadb",
                    Integer.valueOf(size.encodedX),
                    Integer.valueOf(size.encodedY),
                    Integer.valueOf(Display.DEFAULT_DISPLAY),
                    surface);
            if (created instanceof VirtualDisplay) {
                return (VirtualDisplay) created;
            }
            throw new IllegalStateException("static mirror returned " + created);
        }

        private static VirtualDisplay openWithManager(Context shell, VirtualDisplayConfig config)
                throws Exception {
            Constructor<?> ctor = DisplayManager.class.getDeclaredConstructor(Context.class);
            ctor.setAccessible(true);
            DisplayManager manager = (DisplayManager) ctor.newInstance(shell);
            log("mirror DisplayManager");
            return manager.createVirtualDisplay(config);
        }

        private static VirtualDisplay openWithService(
                VirtualDisplayConfig config,
                Surface surface) throws Exception {
            Object displayManager = asInterface(
                    "android.hardware.display.IDisplayManager",
                    Context.DISPLAY_SERVICE);
            Method create = null;
            for (Method method : displayManager.getClass().getMethods()) {
                if (!method.getName().equals("createVirtualDisplay")) {
                    continue;
                }
                if (hasParameter(method, "android.hardware.display.VirtualDisplayConfig")
                        && hasParameter(method, String.class)) {
                    create = method;
                    break;
                }
            }
            if (create == null) {
                throw new IllegalStateException(
                        "IDisplayManager " + methodList(displayManager.getClass(), "createVirtualDisplay"));
            }
            Object callback = newCallback();
            if (callback == null) {
                throw new IllegalStateException("VirtualDisplayCallback unavailable");
            }
            Object[] args = new Object[create.getParameterTypes().length];
            Class<?>[] params = create.getParameterTypes();
            for (int i = 0; i < params.length; i++) {
                Class<?> param = params[i];
                if (param.getName().equals("android.hardware.display.VirtualDisplayConfig")) {
                    args[i] = config;
                } else if (param == String.class) {
                    args[i] = shellPackage();
                } else if (param == Surface.class) {
                    args[i] = surface;
                } else if (callback != null && param.isAssignableFrom(callback.getClass())) {
                    args[i] = callback;
                } else if (!param.isPrimitive()) {
                    args[i] = null;
                } else {
                    throw new IllegalStateException("cannot call " + create);
                }
            }
            log("mirror " + create);
            Object created = create.invoke(displayManager, args);
            if (created instanceof VirtualDisplay) {
                return (VirtualDisplay) created;
            }
            int displayId = created instanceof Integer ? ((Integer) created).intValue() : -1;
            if (displayId < 0) {
                throw new IllegalStateException("createVirtualDisplay returned " + created);
            }
            Class<?> globalClass = Class.forName("android.hardware.display.DisplayManagerGlobal");
            Method getInstance = globalClass.getDeclaredMethod("getInstance");
            getInstance.setAccessible(true);
            Object global = getInstance.invoke(null);
            Method wrap = null;
            for (Method method : globalClass.getDeclaredMethods()) {
                if ("createVirtualDisplayWrapper".equals(method.getName())) {
                    wrap = method;
                    break;
                }
            }
            if (wrap == null || callback == null) {
                throw new IllegalStateException("createVirtualDisplayWrapper unavailable");
            }
            wrap.setAccessible(true);
            Class<?>[] wrapParams = wrap.getParameterTypes();
            Object[] wrapArgs = new Object[wrapParams.length];
            for (int i = 0; i < wrapParams.length; i++) {
                Class<?> param = wrapParams[i];
                if (param.getName().equals("android.hardware.display.VirtualDisplayConfig")) {
                    wrapArgs[i] = config;
                } else if (param == int.class) {
                    wrapArgs[i] = Integer.valueOf(displayId);
                } else if (param.isAssignableFrom(callback.getClass())) {
                    wrapArgs[i] = callback;
                } else if (!param.isPrimitive()) {
                    wrapArgs[i] = null;
                } else {
                    throw new IllegalStateException("cannot call " + wrap);
                }
            }
            return (VirtualDisplay) wrap.invoke(global, wrapArgs);
        }

        private static Object newCallback() throws Exception {
            Class<?> callbackClass = Class.forName(
                    "android.hardware.display.DisplayManagerGlobal$VirtualDisplayCallback");
            Constructor<?>[] ctors = callbackClass.getDeclaredConstructors();
            for (int i = 0; i < ctors.length; i++) {
                Constructor<?> ctor = ctors[i];
                ctor.setAccessible(true);
                Class<?>[] params = ctor.getParameterTypes();
                if (params.length == 2) {
                    return ctor.newInstance(null, null);
                }
            }
            for (int i = 0; i < ctors.length; i++) {
                if (ctors[i].getParameterTypes().length == 0) {
                    ctors[i].setAccessible(true);
                    return ctors[i].newInstance();
                }
            }
            return null;
        }

        private static String shellPackage() {
            try {
                Object packageManager = asInterface("android.content.pm.IPackageManager", "package");
                String[] packages = (String[]) packageManager.getClass()
                        .getMethod("getPackagesForUid", int.class)
                        .invoke(packageManager, Integer.valueOf(Process.myUid()));
                if (packages != null && packages.length > 0 && packages[0] != null) {
                    return packages[0];
                }
            } catch (Throwable ignored) {
            }
            return ShellContext.PACKAGE_NAME;
        }

        private static Object asInterface(String stubClass, String service) throws Exception {
            Class<?> serviceManager = Class.forName("android.os.ServiceManager");
            IBinder binder = (IBinder) serviceManager
                    .getMethod("getService", String.class)
                    .invoke(null, service);
            Class<?> stub = Class.forName(stubClass + "$Stub");
            return stub.getMethod("asInterface", IBinder.class).invoke(null, binder);
        }

        private static boolean hasParameter(Method method, String name) {
            Class<?>[] params = method.getParameterTypes();
            for (int i = 0; i < params.length; i++) {
                if (params[i].getName().equals(name)) {
                    return true;
                }
            }
            return false;
        }

        private static boolean hasParameter(Method method, Class<?> type) {
            Class<?>[] params = method.getParameterTypes();
            for (int i = 0; i < params.length; i++) {
                if (params[i] == type) {
                    return true;
                }
            }
            return false;
        }

        @Override
        public void release() {
            if (display != null) {
                display.release();
                display = null;
            }
        }
    }

    private static final class SurfaceMirror implements Mirror {
        IBinder token;

        @Override
        public void start(Context context, Surface surface, DisplaySize size) throws Exception {
            token = createDisplay();
            Rect source = new Rect(0, 0, size.realX, size.realY);
            Rect target = new Rect(0, 0, size.encodedX, size.encodedY);
            int layerStack = layerStack();
            Class<?> surfaceControl = Class.forName("android.view.SurfaceControl");
            Method setSurface = Reflect.find(surfaceControl, "setDisplaySurface", IBinder.class, Surface.class);
            Method open = Reflect.find(surfaceControl, "openTransaction");
            Method close = Reflect.find(surfaceControl, "closeTransaction");
            if (setSurface != null && open != null && close != null) {
                open.invoke(null);
                try {
                    setSurface.invoke(null, token, surface);
                    invokeOptional(
                            surfaceControl,
                            "setDisplayProjection",
                            new Class<?>[] {IBinder.class, int.class, Rect.class, Rect.class},
                            new Object[] {token, Integer.valueOf(0), source, target});
                    invokeOptional(
                            surfaceControl,
                            "setDisplayLayerStack",
                            new Class<?>[] {IBinder.class, int.class},
                            new Object[] {token, Integer.valueOf(layerStack)});
                } finally {
                    close.invoke(null);
                }
                return;
            }
            Class<?> transactionClass = Class.forName("android.view.SurfaceControl$Transaction");
            Object transaction = transactionClass.newInstance();
            Method applySurface = Reflect.find(
                    transactionClass,
                    "setDisplaySurface",
                    IBinder.class,
                    Surface.class);
            if (applySurface == null) {
                throw new IllegalStateException("setDisplaySurface unavailable");
            }
            applySurface.invoke(transaction, token, surface);
            Method projection = Reflect.find(
                    transactionClass,
                    "setDisplayProjection",
                    IBinder.class,
                    int.class,
                    Rect.class,
                    Rect.class);
            if (projection != null) {
                projection.invoke(transaction, token, Integer.valueOf(0), source, target);
            }
            Method stack = Reflect.find(transactionClass, "setDisplayLayerStack", IBinder.class, int.class);
            if (stack != null) {
                stack.invoke(transaction, token, Integer.valueOf(layerStack));
            }
            Method apply = Reflect.find(transactionClass, "apply");
            if (apply == null) {
                throw new IllegalStateException("transaction apply unavailable");
            }
            apply.invoke(transaction);
        }

        @Override
        public void release() {
            if (token == null) {
                return;
            }
            try {
                Class<?> surfaceControl = Class.forName("android.view.SurfaceControl");
                Method destroy = Reflect.find(surfaceControl, "destroyDisplay", IBinder.class);
                if (destroy == null) {
                    try {
                        destroy = Reflect.find(
                                Class.forName("android.view.DisplayControl"),
                                "destroyDisplay",
                                IBinder.class);
                    } catch (ClassNotFoundException ignored) {
                        destroy = null;
                    }
                }
                if (destroy != null) {
                    destroy.invoke(null, token);
                }
            } catch (Throwable ignored) {
            }
            token = null;
        }

        private static IBinder createDisplay() throws Exception {
            IBinder created = tryCreateDisplay("android.view.SurfaceControl");
            if (created != null) {
                return created;
            }
            created = tryCreateDisplay("android.view.DisplayControl");
            if (created != null) {
                return created;
            }
            String listed = "none";
            try {
                listed = methodList(Class.forName("android.view.SurfaceControl"), "createDisplay");
            } catch (Throwable error) {
                listed = String.valueOf(error);
            }
            throw new IllegalStateException("createDisplay unavailable surface=" + listed);
        }

        private static IBinder tryCreateDisplay(String className) {
            try {
                Object created = invokeOptional(
                        Class.forName(className),
                        "createDisplay",
                        new Class<?>[] {String.class, boolean.class},
                        new Object[] {"fireadb", Boolean.FALSE});
                if (created instanceof IBinder) {
                    return (IBinder) created;
                }
            } catch (Throwable ignored) {
            }
            return null;
        }

        private static int layerStack() {
            try {
                Class<?> global = Class.forName("android.view.WindowManagerGlobal");
                Method getService = global.getDeclaredMethod("getWindowManagerService");
                getService.setAccessible(true);
                Object service = getService.invoke(null);
                Method getInfo = Reflect.find(service.getClass(), "getDisplayInfo", int.class);
                if (getInfo == null) {
                    return 0;
                }
                Object info = getInfo.invoke(service, Integer.valueOf(0));
                if (info == null) {
                    return 0;
                }
                java.lang.reflect.Field field;
                try {
                    field = info.getClass().getField("layerStack");
                } catch (NoSuchFieldException missing) {
                    field = info.getClass().getDeclaredField("layerStack");
                    field.setAccessible(true);
                }
                return field.getInt(info);
            } catch (Throwable ignored) {
                return 0;
            }
        }
    }

    /**
     * 环回采集正在播放的声音，设备自己的播放不停。
     * 打不开时调用方继续只录画面。
     */
    private static final class PlaybackAudio implements Runnable {
        static final int SAMPLE_RATE = 48000;

        final Context context;
        final Mp4Writer writer;
        final Thread thread = new Thread(this, "fireadb-audio");
        AudioRecord record;
        AudioTrack speaker;
        Object policy;
        MediaCodec codec;
        int channels = 2;
        int bytesPerFrame = 4;
        long samples;
        volatile boolean stop;
        boolean ended;

        PlaybackAudio(Context context, Mp4Writer writer) {
            this.context = context;
            this.writer = writer;
        }

        static PlaybackAudio tryStart(Context context, Mp4Writer writer) {
            PlaybackAudio audio = new PlaybackAudio(context, writer);
            try {
                audio.open();
                writer.enableAudio();
                audio.thread.start();
                return audio;
            } catch (Throwable error) {
                logThrowable("audio skipped", error);
                audio.release();
                writer.abandonAudio();
                return null;
            }
        }

        void end() {
            if (ended) {
                return;
            }
            stop = true;
            AudioRecord current = record;
            if (current != null) {
                try {
                    current.stop();
                } catch (Throwable ignored) {
                }
            }
            try {
                if (thread.isAlive()) {
                    thread.join(20000);
                }
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
            ended = !thread.isAlive();
        }

        void release() {
            if (!ended) {
                end();
            }
            if (!thread.isAlive()) {
                releaseQuiet();
            }
        }

        @SuppressLint("PrivateApi")
        private void open() throws Exception {
            boolean loopback = true;
            try {
                record = openLoopback();
            } catch (Throwable error) {
                logThrowable("loopback", error);
                unregisterPolicy();
                record = openPlaybackRecord();
                speaker = openSpeaker();
                loopback = false;
            }
            record.startRecording();
            if (record.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) {
                throw new IllegalStateException("audio recorder did not start");
            }
            MediaFormat format = MediaFormat.createAudioFormat(
                    MediaFormat.MIMETYPE_AUDIO_AAC,
                    SAMPLE_RATE,
                    channels);
            format.setInteger(
                    MediaFormat.KEY_AAC_PROFILE,
                    MediaCodecInfo.CodecProfileLevel.AACObjectLC);
            format.setInteger(MediaFormat.KEY_BIT_RATE, 128000);
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384);
            codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC);
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            codec.start();
            log(loopback ? "audio loopback" : "audio submix");
        }

        @SuppressLint({"MissingPermission", "WrongConstant"})
        private AudioRecord openPlaybackRecord() {
            int[] masks = new int[] {
                    AudioFormat.CHANNEL_IN_STEREO,
                    AudioFormat.CHANNEL_IN_MONO,
            };
            int[] counts = new int[] {2, 1};
            for (int i = 0; i < masks.length; i++) {
                int buffer = AudioRecord.getMinBufferSize(
                        SAMPLE_RATE,
                        masks[i],
                        AudioFormat.ENCODING_PCM_16BIT);
                if (buffer <= 0) {
                    buffer = SAMPLE_RATE;
                }
                int size = Math.max(buffer * 4, counts[i] * 2 * 1024);
                AudioRecord created = new AudioRecord.Builder()
                        .setContext(new ShellContext(context))
                        .setAudioSource(8)
                        .setAudioFormat(new AudioFormat.Builder()
                                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                                .setSampleRate(SAMPLE_RATE)
                                .setChannelMask(masks[i])
                                .build())
                        .setBufferSizeInBytes(size)
                        .build();
                if (created.getState() == AudioRecord.STATE_INITIALIZED) {
                    channels = counts[i];
                    bytesPerFrame = counts[i] * 2;
                    return created;
                }
                created.release();
            }
            throw new IllegalStateException("playback recorder unavailable");
        }

        private AudioTrack openSpeaker() {
            int mask = channels == 2
                    ? AudioFormat.CHANNEL_OUT_STEREO
                    : AudioFormat.CHANNEL_OUT_MONO;
            int buffer = AudioTrack.getMinBufferSize(
                    SAMPLE_RATE,
                    mask,
                    AudioFormat.ENCODING_PCM_16BIT);
            if (buffer < bytesPerFrame) {
                buffer = bytesPerFrame * 4096;
            }
            AudioTrack track = new AudioTrack(
                    new AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build(),
                    new AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(SAMPLE_RATE)
                            .setChannelMask(mask)
                            .build(),
                    buffer * 2,
                    AudioTrack.MODE_STREAM,
                    AudioManager.AUDIO_SESSION_ID_GENERATE);
            if (track.getState() != AudioTrack.STATE_INITIALIZED) {
                track.release();
                log("speaker unavailable");
                return null;
            }
            AudioDeviceInfo speaker = builtinSpeaker();
            if (speaker != null) {
                track.setPreferredDevice(speaker);
            }
            track.play();
            return track;
        }

        private AudioDeviceInfo builtinSpeaker() {
            AudioManager manager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
            if (manager == null) {
                return null;
            }
            AudioDeviceInfo[] devices = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS);
            for (int i = 0; i < devices.length; i++) {
                if (devices[i].getType() == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER) {
                    return devices[i];
                }
            }
            return null;
        }

        private AudioRecord openLoopback() throws Exception {
            channels = 2;
            bytesPerFrame = 4;
            Class<?> ruleClass = Class.forName("android.media.audiopolicy.AudioMixingRule");
            Class<?> ruleBuilderClass = Class.forName("android.media.audiopolicy.AudioMixingRule$Builder");
            Object ruleBuilder = ruleBuilderClass.getConstructor().newInstance();
            try {
                int role = ruleClass.getField("MIX_ROLE_PLAYERS").getInt(null);
                ruleBuilderClass.getMethod("setTargetMixRole", int.class)
                        .invoke(ruleBuilder, Integer.valueOf(role));
            } catch (Throwable ignored) {
            }
            int matchUsage = ruleClass.getField("RULE_MATCH_ATTRIBUTE_USAGE").getInt(null);
            Method addMixRule = null;
            try {
                addMixRule = ruleBuilderClass.getMethod("addMixRule", int.class, Object.class);
            } catch (NoSuchMethodException ignored) {
            }
            Method addRule = addMixRule == null
                    ? ruleBuilderClass.getMethod("addRule", AudioAttributes.class, int.class)
                    : null;
            int[] usages = new int[] {
                    AudioAttributes.USAGE_MEDIA,
                    AudioAttributes.USAGE_GAME,
                    AudioAttributes.USAGE_UNKNOWN,
                    AudioAttributes.USAGE_ALARM,
                    AudioAttributes.USAGE_NOTIFICATION,
                    AudioAttributes.USAGE_NOTIFICATION_RINGTONE,
                    AudioAttributes.USAGE_ASSISTANCE_SONIFICATION,
                    AudioAttributes.USAGE_VOICE_COMMUNICATION,
            };
            for (int i = 0; i < usages.length; i++) {
                AudioAttributes attributes = new AudioAttributes.Builder().setUsage(usages[i]).build();
                try {
                    if (addMixRule != null) {
                        addMixRule.invoke(ruleBuilder, Integer.valueOf(matchUsage), attributes);
                    } else {
                        addRule.invoke(ruleBuilder, attributes, Integer.valueOf(matchUsage));
                    }
                } catch (Throwable ignored) {
                }
            }
            try {
                ruleBuilderClass.getMethod("voiceCommunicationCaptureAllowed", boolean.class)
                        .invoke(ruleBuilder, Boolean.TRUE);
            } catch (Throwable ignored) {
            }
            Object rule = ruleBuilderClass.getMethod("build").invoke(ruleBuilder);

            Class<?> mixClass = Class.forName("android.media.audiopolicy.AudioMix");
            Class<?> mixBuilderClass = Class.forName("android.media.audiopolicy.AudioMix$Builder");
            Object mixBuilder = mixBuilderClass.getConstructor(ruleClass).newInstance(rule);
            AudioFormat format = new AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                    .build();
            mixBuilderClass.getMethod("setFormat", AudioFormat.class).invoke(mixBuilder, format);
            int loopBack = mixClass.getField("ROUTE_FLAG_LOOP_BACK").getInt(null);
            int render = mixClass.getField("ROUTE_FLAG_RENDER").getInt(null);
            int route = loopBack | render;
            try {
                route = mixClass.getField("ROUTE_FLAG_LOOP_BACK_RENDER").getInt(null);
            } catch (Throwable ignored) {
            }
            mixBuilderClass.getMethod("setRouteFlags", int.class)
                    .invoke(mixBuilder, Integer.valueOf(route));
            Object mix = mixBuilderClass.getMethod("build").invoke(mixBuilder);

            Class<?> policyClass = Class.forName("android.media.audiopolicy.AudioPolicy");
            Class<?> policyBuilderClass = Class.forName("android.media.audiopolicy.AudioPolicy$Builder");
            Object policyBuilder = policyBuilderClass.getConstructor(Context.class)
                    .newInstance(new ShellContext(context));
            policyBuilderClass.getMethod("addMix", mixClass).invoke(policyBuilder, mix);
            Object built = policyBuilderClass.getMethod("build").invoke(policyBuilder);
            Method register = AudioManager.class.getDeclaredMethod(
                    "registerAudioPolicyStatic",
                    policyClass);
            register.setAccessible(true);
            Object result = register.invoke(null, built);
            int code = result instanceof Integer ? ((Integer) result).intValue() : -1;
            if (code != 0) {
                throw new IllegalStateException("registerAudioPolicy " + result);
            }
            policy = built;
            return openSink(built, policyClass, mix, mixClass);
        }

        private AudioRecord openSink(
                Object built,
                Class<?> policyClass,
                Object mix,
                Class<?> mixClass) throws Exception {
            AudioRecord created = (AudioRecord) policyClass
                    .getMethod("createAudioRecordSink", mixClass)
                    .invoke(built, mix);
            if (created != null && created.getState() == AudioRecord.STATE_INITIALIZED) {
                return created;
            }
            int state = created == null ? -1 : created.getState();
            if (created != null) {
                try {
                    created.release();
                } catch (Throwable ignored) {
                }
            }
            String address = mixAddress(mix, mixClass);
            log("loopback sink state=" + state + " addr=" + address);
            if (address.length() == 0) {
                throw new IllegalStateException(
                        "loopback recorder unavailable state=" + state);
            }
            return openTaggedSubmix(address);
        }

        private static String mixAddress(Object mix, Class<?> mixClass) {
            try {
                Object value = mixClass.getMethod("getRegistration").invoke(mix);
                return value == null ? "" : String.valueOf(value);
            } catch (Throwable ignored) {
                return "";
            }
        }

        private AudioRecord openTaggedSubmix(String address) throws Exception {
            AudioAttributes.Builder attributes = new AudioAttributes.Builder();
            AudioAttributes.Builder.class
                    .getMethod("setInternalCapturePreset", int.class)
                    .invoke(attributes, Integer.valueOf(8));
            Method addTag = AudioAttributes.Builder.class.getMethod("addTag", String.class);
            addTag.invoke(attributes, "addr=" + address);
            addTag.invoke(attributes, "fixedVolume");
            AudioFormat format = new AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                    .build();
            int buffer = AudioRecord.getMinBufferSize(
                    SAMPLE_RATE,
                    AudioFormat.CHANNEL_IN_STEREO,
                    AudioFormat.ENCODING_PCM_16BIT);
            if (buffer < bytesPerFrame) {
                buffer = bytesPerFrame * 4096;
            }
            Object builder = AudioRecord.Builder.class.getConstructor().newInstance();
            Class<?> builderClass = builder.getClass();
            builderClass.getMethod("setContext", Context.class)
                    .invoke(builder, new ShellContext(context));
            builderClass.getMethod("setAudioAttributes", AudioAttributes.class)
                    .invoke(builder, attributes.build());
            builderClass.getMethod("setAudioFormat", AudioFormat.class)
                    .invoke(builder, format);
            builderClass.getMethod("setBufferSizeInBytes", int.class)
                    .invoke(builder, Integer.valueOf(Math.max(buffer * 4, bytesPerFrame * 1024)));
            AudioRecord record = (AudioRecord) builderClass.getMethod("build").invoke(builder);
            if (record.getState() != AudioRecord.STATE_INITIALIZED) {
                record.release();
                throw new IllegalStateException("loopback recorder unavailable");
            }
            return record;
        }

        @Override
        public void run() {
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO);
            try {
                pump();
            } catch (Throwable error) {
                logThrowable("audio", error);
                writer.abandonAudio();
            }
        }

        private void pump() {
            byte[] pcm = new byte[bytesPerFrame * 1024];
            int pending = 0;
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            while (!stop) {
                int read = record.read(pcm, pending, pcm.length - pending);
                if (read < 0) {
                    break;
                }
                int total = pending + read;
                int usable = total - (total % bytesPerFrame);
                if (usable > 0) {
                    play(pcm, usable);
                    queuePcm(pcm, usable);
                    drain(info, false);
                }
                int rest = total - usable;
                if (rest > 0 && usable > 0) {
                    System.arraycopy(pcm, usable, pcm, 0, rest);
                }
                pending = rest;
            }
            signalEos();
            drain(info, true);
        }

        private void play(byte[] pcm, int size) {
            AudioTrack track = speaker;
            if (track == null || size <= 0) {
                return;
            }
            try {
                track.write(pcm, 0, size, AudioTrack.WRITE_NON_BLOCKING);
            } catch (Throwable ignored) {
            }
        }

        private void queuePcm(byte[] pcm, int size) {
            int index = codec.dequeueInputBuffer(10000);
            if (index < 0) {
                return;
            }
            ByteBuffer input = codec.getInputBuffer(index);
            if (input == null) {
                return;
            }
            input.clear();
            int accepted = Math.min(size, input.remaining());
            accepted -= accepted % bytesPerFrame;
            if (accepted <= 0) {
                return;
            }
            input.put(pcm, 0, accepted);
            long pts = samples * 1000000L / SAMPLE_RATE;
            samples += accepted / bytesPerFrame;
            codec.queueInputBuffer(index, 0, accepted, pts, 0);
        }

        private void signalEos() {
            int index = codec.dequeueInputBuffer(10000);
            if (index < 0) {
                return;
            }
            codec.queueInputBuffer(
                    index,
                    0,
                    0,
                    samples * 1000000L / SAMPLE_RATE,
                    MediaCodec.BUFFER_FLAG_END_OF_STREAM);
        }

        private void drain(MediaCodec.BufferInfo info, boolean untilEos) {
            while (true) {
                int index = codec.dequeueOutputBuffer(info, untilEos ? 10000 : 0);
                if (index == MediaCodec.INFO_TRY_AGAIN_LATER) {
                    return;
                }
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    writer.addAudioFormat(codec.getOutputFormat());
                    continue;
                }
                if (index < 0) {
                    continue;
                }
                ByteBuffer buffer = codec.getOutputBuffer(index);
                boolean eos = writer.acceptAudio(buffer, info);
                codec.releaseOutputBuffer(index, false);
                if (eos || (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                    return;
                }
            }
        }

        private void unregisterPolicy() {
            Object current = policy;
            policy = null;
            if (current == null) {
                return;
            }
            try {
                Class<?> policyClass = current.getClass();
                Method method;
                try {
                    method = AudioManager.class.getDeclaredMethod(
                            "unregisterAudioPolicyStatic",
                            policyClass);
                } catch (NoSuchMethodException missing) {
                    method = AudioManager.class.getDeclaredMethod(
                            "unregisterAudioPolicyAsyncStatic",
                            policyClass);
                }
                method.setAccessible(true);
                method.invoke(null, current);
            } catch (Throwable error) {
                log("audio policy: " + error);
            }
        }

        private void releaseQuiet() {
            if (codec != null) {
                releaseCodec(codec);
                codec = null;
            }
            if (record != null) {
                try {
                    record.release();
                } catch (Throwable ignored) {
                }
                record = null;
            }
            if (speaker != null) {
                try {
                    speaker.release();
                } catch (Throwable ignored) {
                }
                speaker = null;
            }
            unregisterPolicy();
        }
    }

    private static final class PendingSample {
        final boolean audio;
        final byte[] data;
        final MediaCodec.BufferInfo info;

        PendingSample(boolean audio, byte[] data, MediaCodec.BufferInfo info) {
            this.audio = audio;
            this.data = data;
            this.info = info;
        }
    }

    private static final class Mp4Writer {
        final String path;
        final MediaCodec codec;
        final Object lock = new Object();
        final java.util.ArrayList<PendingSample> pending =
                new java.util.ArrayList<PendingSample>();
        MediaMuxer muxer;
        MediaFormat videoFormat;
        MediaFormat audioFormat;
        int videoTrack = -1;
        int audioTrack = -1;
        boolean audioEnabled;
        boolean started;
        volatile boolean wrote;
        long lastVideoPts = -1L;
        long lastAudioPts = -1L;
        long videoOrigin = -1L;

        Mp4Writer(String path, MediaCodec codec) {
            this.path = path;
            this.codec = codec;
            new File(path).delete();
        }

        void enableAudio() {
            synchronized (lock) {
                audioEnabled = true;
            }
        }

        void addAudioFormat(MediaFormat format) {
            synchronized (lock) {
                if (audioFormat != null || !audioEnabled || started) {
                    return;
                }
                audioFormat = format;
                startIfReady();
            }
        }

        void abandonAudio() {
            synchronized (lock) {
                if (started || !audioEnabled) {
                    return;
                }
                audioEnabled = false;
                audioFormat = null;
                startIfReady();
            }
        }

        void onFormat(int index) throws java.io.IOException {
            if (index != MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                return;
            }
            synchronized (lock) {
                if (videoFormat != null) {
                    throw new IllegalStateException("encoder format changed twice");
                }
                videoFormat = codec.getOutputFormat();
                startIfReady();
            }
        }

        boolean write(int index, MediaCodec.BufferInfo info) {
            boolean eos;
            synchronized (lock) {
                eos = acceptVideo(index, info);
            }
            codec.releaseOutputBuffer(index, false);
            return eos;
        }

        boolean acceptAudio(ByteBuffer buffer, MediaCodec.BufferInfo info) {
            synchronized (lock) {
                boolean sample = info.size > 0
                        && buffer != null
                        && (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0;
                if (sample && (audioEnabled || audioTrack >= 0)) {
                    long pts = monotonic(info.presentationTimeUs, true);
                    if (!started) {
                        pending.add(copySample(true, buffer, info, pts));
                        if (pending.size() > 300) {
                            audioEnabled = false;
                            startIfReady();
                        }
                    } else if (audioTrack >= 0) {
                        writeTrack(audioTrack, buffer, info, pts);
                    }
                }
                return (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
            }
        }

        void finish() {
            synchronized (lock) {
                if (!started) {
                    audioEnabled = false;
                    startIfReady();
                }
                if (!started || muxer == null) {
                    return;
                }
                try {
                    muxer.stop();
                } catch (Throwable ignored) {
                }
                started = false;
            }
        }

        void release() {
            releaseCodec(codec);
            synchronized (lock) {
                if (muxer == null) {
                    return;
                }
                try {
                    if (started) {
                        muxer.stop();
                    }
                } catch (Throwable ignored) {
                }
                try {
                    muxer.release();
                } catch (Throwable ignored) {
                }
                muxer = null;
                started = false;
            }
        }

        private boolean acceptVideo(int index, MediaCodec.BufferInfo info) {
            ByteBuffer buffer = codec.getOutputBuffer(index);
            boolean sample = info.size > 0
                    && buffer != null
                    && (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0;
            if (sample) {
                wrote = true;
                long pts = rebaseVideo(info.presentationTimeUs);
                if (!started) {
                    pending.add(copySample(false, buffer, info, pts));
                    if (pending.size() > 300 && audioEnabled && audioFormat == null) {
                        audioEnabled = false;
                        startIfReady();
                    }
                } else {
                    writeTrack(videoTrack, buffer, info, pts);
                }
            }
            return (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
        }

        private void startIfReady() {
            if (started || videoFormat == null) {
                return;
            }
            if (audioEnabled && audioFormat == null) {
                return;
            }
            try {
                muxer = new MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
                videoTrack = muxer.addTrack(videoFormat);
                if (audioFormat != null && audioEnabled) {
                    audioTrack = muxer.addTrack(audioFormat);
                }
                muxer.start();
                started = true;
                for (int i = 0; i < pending.size(); i++) {
                    PendingSample sample = pending.get(i);
                    int track = sample.audio ? audioTrack : videoTrack;
                    if (track < 0) {
                        continue;
                    }
                    writeTrack(track, ByteBuffer.wrap(sample.data), sample.info, sample.info.presentationTimeUs);
                }
                pending.clear();
            } catch (java.io.IOException error) {
                throw new IllegalStateException(error);
            }
        }

        private PendingSample copySample(
                boolean audio,
                ByteBuffer buffer,
                MediaCodec.BufferInfo info,
                long pts) {
            byte[] data = new byte[info.size];
            buffer.position(info.offset);
            buffer.limit(info.offset + info.size);
            buffer.get(data);
            MediaCodec.BufferInfo copy = new MediaCodec.BufferInfo();
            copy.set(0, data.length, pts, info.flags);
            return new PendingSample(audio, data, copy);
        }

        private void writeTrack(int track, ByteBuffer buffer, MediaCodec.BufferInfo info, long pts) {
            buffer.position(info.offset);
            buffer.limit(info.offset + info.size);
            long saved = info.presentationTimeUs;
            info.presentationTimeUs = pts;
            muxer.writeSampleData(track, buffer, info);
            info.presentationTimeUs = saved;
        }

        private long rebaseVideo(long pts) {
            if (videoOrigin < 0) {
                videoOrigin = pts;
            }
            long relative = pts - videoOrigin;
            if (relative < 0) {
                relative = 0;
            }
            return monotonic(relative, false);
        }

        private long monotonic(long pts, boolean audio) {
            long last = audio ? lastAudioPts : lastVideoPts;
            if (pts <= last) {
                pts = last + 1;
            }
            if (audio) {
                lastAudioPts = pts;
            } else {
                lastVideoPts = pts;
            }
            return pts;
        }
    }

    private static Object invokeOptional(Class<?> type, String name, Class<?>[] params, Object[] args)
            throws Exception {
        Method method = Reflect.find(type, name, params);
        if (method == null) {
            return null;
        }
        return method.invoke(null, args);
    }

    private static final class Reflect {
        private Reflect() {}

        static Method find(Class<?> type, String name, Class<?>... params) {
            Class<?> current = type;
            while (current != null) {
                try {
                    Method method = current.getDeclaredMethod(name, params);
                    method.setAccessible(true);
                    return method;
                } catch (NoSuchMethodException ignored) {
                }
                current = current.getSuperclass();
            }
            if (params.length == 0) {
                for (Method method : type.getMethods()) {
                    if (method.getName().equals(name) && method.getParameterTypes().length == 0) {
                        method.setAccessible(true);
                        return method;
                    }
                }
            }
            return null;
        }
    }
}
