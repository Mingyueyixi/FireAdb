package com.fire.adb.appservice.protocol;

import android.util.Log;

import java.io.BufferedOutputStream;
import java.io.DataOutputStream;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.IOException;

/** 把 {@link FireDataResponse} 一次写到标准输出。写出前打印。命令线程和剪贴板回调共用同一把锁。 */
public final class FireDataWriter {
    private static final String TAG = "FireAdb";

    private final Object lock = new Object();
    private final DataOutputStream out;

    private FireDataWriter(DataOutputStream out) {
        this.out = out;
    }

    public static FireDataWriter stdout() {
        return new FireDataWriter(new DataOutputStream(
                new BufferedOutputStream(new FileOutputStream(FileDescriptor.out))));
    }

    public static FireDataWriter of(java.io.OutputStream raw) {
        return new FireDataWriter(new DataOutputStream(new BufferedOutputStream(raw)));
    }

    public void send(FireDataResponse response) throws IOException {
        byte[] header = response.header();
        byte[] body = response.body();
        synchronized (lock) {
            Log.i(TAG, "响应 " + response.display());
            out.write(header);
            if (body.length > 0) {
                out.write(body);
            }
            out.flush();
        }
    }

    public void sendQuiet(FireDataResponse response) {
        try {
            send(response);
        } catch (Throwable ignored) {
        }
    }

    public void flush() throws IOException {
        synchronized (lock) {
            out.flush();
        }
    }
}
