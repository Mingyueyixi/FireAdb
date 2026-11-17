package com.fire.adb.appservice.record;

import android.content.Context;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.hardware.display.VirtualDisplayConfig;
import android.os.IBinder;
import android.os.Process;
import android.view.Display;
import android.view.Surface;

import com.fire.adb.appservice.ShellContext;
import com.fire.adb.appservice.util.LogUtils;

import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;

/** 用虚拟屏幕镜像当前画面。 */
public final class VirtualDisplayMirror implements DisplayMirror {
    private VirtualDisplay display;

    @Override
    public void start(Context context, Surface surface, DisplaySize size) throws Exception {
        Throwable denied = null;
        try {
            display = open(new ShellContext(context), surface, size);
        } catch (Throwable error) {
            denied = LogUtils.unwrap(error);
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
            failure = LogUtils.unwrap(error);
        }
        try {
            VirtualDisplay created = openWithManager(shell, config);
            if (created != null) {
                return created;
            }
            throw new IllegalStateException("DisplayManager returned null");
        } catch (Throwable managerError) {
            Throwable manager = LogUtils.unwrap(managerError);
            try {
                return openWithService(config, surface);
            } catch (Throwable serviceError) {
                Throwable service = LogUtils.unwrap(serviceError);
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
        LogUtils.i("mirror static");
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
        LogUtils.i("mirror DisplayManager");
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
        LogUtils.i("mirror " + create);
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

    @Override
    public void release() {
        if (display != null) {
            display.release();
            display = null;
        }
    }
}
