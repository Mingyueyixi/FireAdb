package com.fire.adb.appservice;

import android.content.Context;
import android.graphics.Point;
import android.graphics.Rect;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.hardware.display.VirtualDisplayConfig;
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
            writer.finish();
            saved = true;
            return true;
        } finally {
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

    private static final class Mp4Writer {
        final String path;
        final MediaCodec codec;
        MediaMuxer muxer;
        int track = -1;
        boolean started;
        boolean wrote;
        long lastPts = -1L;

        Mp4Writer(String path, MediaCodec codec) {
            this.path = path;
            this.codec = codec;
            new File(path).delete();
        }

        void onFormat(int index) throws java.io.IOException {
            if (index != MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                return;
            }
            if (started) {
                throw new IllegalStateException("encoder format changed twice");
            }
            muxer = new MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
            track = muxer.addTrack(codec.getOutputFormat());
            muxer.start();
            started = true;
        }

        boolean write(int index, MediaCodec.BufferInfo info) {
            ByteBuffer buffer = codec.getOutputBuffer(index);
            boolean sample = started
                    && info.size > 0
                    && buffer != null
                    && (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0;
            if (sample) {
                buffer.position(info.offset);
                buffer.limit(info.offset + info.size);
                if (info.presentationTimeUs <= lastPts) {
                    info.presentationTimeUs = lastPts + 1;
                }
                lastPts = info.presentationTimeUs;
                muxer.writeSampleData(track, buffer, info);
                wrote = true;
            }
            codec.releaseOutputBuffer(index, false);
            return (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
        }

        void finish() {
            if (!started) {
                return;
            }
            muxer.stop();
            started = false;
        }

        void release() {
            releaseCodec(codec);
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
