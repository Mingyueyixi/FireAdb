package com.fire.adb.appservice.record;

import android.content.Context;
import android.graphics.Rect;
import android.os.IBinder;
import android.view.Surface;

import java.lang.reflect.Method;

/** 虚拟屏幕建不起来时，用显示控制直接把画面送进编码器。 */
public final class SurfaceControlMirror implements DisplayMirror {
    private IBinder token;

    @Override
    public void start(Context context, Surface surface, DisplaySize size) throws Exception {
        token = createDisplay();
        Rect source = new Rect(0, 0, size.realX, size.realY);
        Rect target = new Rect(0, 0, size.encodedX, size.encodedY);
        int layerStack = layerStack();
        Class<?> surfaceControl = Class.forName("android.view.SurfaceControl");
        Method setSurface = RecordReflect.find(surfaceControl, "setDisplaySurface", IBinder.class, Surface.class);
        Method open = RecordReflect.find(surfaceControl, "openTransaction");
        Method close = RecordReflect.find(surfaceControl, "closeTransaction");
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
        Method applySurface = RecordReflect.find(
                transactionClass,
                "setDisplaySurface",
                IBinder.class,
                Surface.class);
        if (applySurface == null) {
            throw new IllegalStateException("setDisplaySurface unavailable");
        }
        applySurface.invoke(transaction, token, surface);
        Method projection = RecordReflect.find(
                transactionClass,
                "setDisplayProjection",
                IBinder.class,
                int.class,
                Rect.class,
                Rect.class);
        if (projection != null) {
            projection.invoke(transaction, token, Integer.valueOf(0), source, target);
        }
        Method stack = RecordReflect.find(transactionClass, "setDisplayLayerStack", IBinder.class, int.class);
        if (stack != null) {
            stack.invoke(transaction, token, Integer.valueOf(layerStack));
        }
        Method apply = RecordReflect.find(transactionClass, "apply");
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
            Method destroy = RecordReflect.find(surfaceControl, "destroyDisplay", IBinder.class);
            if (destroy == null) {
                try {
                    destroy = RecordReflect.find(
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
            Method getInfo = RecordReflect.find(service.getClass(), "getDisplayInfo", int.class);
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

    private static Object invokeOptional(Class<?> type, String name, Class<?>[] params, Object[] args)
            throws Exception {
        Method method = RecordReflect.find(type, name, params);
        if (method == null) {
            return null;
        }
        return method.invoke(null, args);
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
}
