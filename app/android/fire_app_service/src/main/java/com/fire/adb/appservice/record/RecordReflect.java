package com.fire.adb.appservice.record;

import java.lang.reflect.Method;

final class RecordReflect {
    private RecordReflect() {}

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
